#!/usr/bin/env bash
# Sourced by every pkgs/<name>/build.sh.  Direct descendant of the helper block
# in the old build_config.sh.in, minus the autoconf substitution that baked
# absolute paths into everything.
#
# Provided by mk/pkg.mk: STACK WORK SRC_CACHE CONDA_HOME NPROC MAKE_J_L
#                        TARGET_PLATFORM BLAS_PROVIDER MPI_FAMILY RPATH_MODE
#                        ISA_BASELINE USE_WRAPPERS TOPDIR
#                        PKG_NAME PKG_VERSION PKG_URL PKG_DIR
#                        PKG_SOURCE PKG_GIT_URL PKG_GIT_REF

set -euo pipefail

: "${STACK:?}" "${WORK:?}" "${PKG_NAME:?}" "${PKG_VERSION:?}"

SRC_CACHE="${SRC_CACHE:-${WORK}/src}"
BUILD_TMP="${WORK}/build/${PKG_NAME}-${PKG_VERSION}"
# mk/pkg.mk exports this for every package, but a recipe run by hand may not
# have it, and 'set -u' is on.
PKG_SOURCE="${PKG_SOURCE:-tarball}"
NPROC="${NPROC:-4}"
# Prefer MAKE_J_L over a bare -j: it carries the -l load cap, which is what
# keeps a shared build host usable.
MAKE_J_L="${MAKE_J_L:--j ${NPROC}}"

mkdir -p "${SRC_CACHE}" "${BUILD_TMP}"

log () { printf '=== %s: %s\n' "${PKG_NAME}" "$*"; }

require () {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { echo "missing required command: $c" >&2; exit 1; }
  done
}

# Dump the build environment into the package log.  Carried over from the v0
# build_config.sh.in, where it repeatedly earned its keep: when a build fails
# three hours in, the log is all you have, and "what was CC actually set to"
# is the first question.  Call it right after activate_toolchain.
list_build_env () {
  log "build environment"
  printenv | sort -u | grep -Ev '_git|_ModuleTable|^__|^LS_COLORS='
  log "toolchain"
  for c in "${CC:-cc}" "${CXX:-c++}" "${FC:-gfortran}"; do
    command -v "$c" >/dev/null 2>&1 && "$c" --version 2>&1 | head -1
  done
}

# assert_no_host_paths LABEL -- read text on stdin (a generated Make fragment,
# 'libmesh-config' output, a .pc file) and fail if it names a path outside the
# stack.  "Outside" means under /usr or /opt but not under $STACK or $WORK.
# $STACK itself may live under /opt -- the compose loop's BUILD_ROOT does -- so
# the in-tree prefixes are stripped first and whatever /usr/ or /opt/ remains is
# the host's.  A build system that found a host package and recorded where
# writes exactly such a path (-I/usr/include/, -L/usr/lib64, -ltirpc via
# -I/usr/include/tirpc), and that string is what a customer's compile line
# would then carry.  See pkgs/libmesh/build.sh for the case that earned this.
assert_no_host_paths () {
  local label="$1" hits
  hits="$(sed -e "s|${STACK}||g" -e "s|${WORK}||g" | grep -n -E '/(usr|opt)/' || true)"
  if [ -n "${hits}" ]; then
    echo "${label}: names a host path -- something on the build host was found" >&2
    echo "  and recorded, and would follow the artifact to every customer:" >&2
    printf '%s\n' "${hits}" | head -10 | sed 's/^/    /' >&2
    exit 1
  fi
  log "no host paths in ${label}"
}

# Activate the conda toolchain: puts the compilers on PATH and exports
# CC/CXX/FC and CONDA_BUILD_SYSROOT via the env's activate.d scripts.
activate_toolchain () {
  local d="${STACK}/etc/conda/activate.d"
  export CONDA_PREFIX="${STACK}"
  export PATH="${STACK}/bin:${PATH}"
  if [ -d "${d}" ]; then
    # conda generates these per-env; there is nothing in the tree to follow.
    # shellcheck source=/dev/null
    for s in "${d}"/*.sh; do [ -e "$s" ] && . "$s"; done
  fi
  # Build against the single merged prefix with an absolute rpath; the
  # $ORIGIN conversion is relocate/patchelf.sh's job.  Fighting libtool's
  # $ORIGIN mangling at configure time is not worth it.
  export LDFLAGS="-L${STACK}/lib -Wl,-rpath,${STACK}/lib ${LDFLAGS:-}"
  export CPPFLAGS="-I${STACK}/include ${CPPFLAGS:-}"
  export PKG_CONFIG_PATH="${STACK}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

  # The ISA wrappers go on LAST, so they sit ahead of $STACK/bin -- including
  # ahead of anything the activate.d scripts just prepended.  That ordering is
  # the mechanism: CC/CXX/FC arrive from conda as bare triplet names, so PATH
  # decides which binary they mean.  See wrappers/generate.sh.
  local wbin="${WORK}/wrappers/bin"
  if [ "${USE_WRAPPERS:-yes}" = yes ] && [ -d "${wbin}" ]; then
    export PATH="${wbin}:${PATH}"
    # shellcheck disable=SC1091
    [ -r "${WORK}/wrappers/env.sh" ] && . "${WORK}/wrappers/env.sh"
    log "ISA wrappers active: ${wbin}"
  else
    log "ISA wrappers NOT active (USE_WRAPPERS=${USE_WRAPPERS:-yes})"
  fi
}

# download_src URL [SHA256] -- cached, resumable, unpacked into $BUILD_TMP.
download_src () {
  local url="$1" sha="${2:-}" f
  f="${SRC_CACHE}/$(basename "${url}")"
  if [ ! -s "${f}" ]; then
    log "fetching $(basename "${url}")"
    curl -fsSL --retry 3 -o "${f}.part" "${url}"
    mv "${f}.part" "${f}"
  fi
  if [ -n "${sha}" ]; then
    echo "${sha}  ${f}" | sha256sum -c - >/dev/null \
      || { echo "checksum mismatch for ${f}" >&2; exit 1; }
  fi
  log "unpacking $(basename "${f}")"
  tar -xf "${f}" -C "${BUILD_TMP}"
}

# fetch_git URL REF [DESTDIR] -- cached bare mirror, detached checkout in DESTDIR.
#
# A bare MIRROR rather than a shallow clone, and that is not thrift: --depth 1
# cannot check out an arbitrary SHA, and cannot serve a different ref later from
# the same cache.  The mirror is fetched once and every subsequent ref -- tag,
# branch or commit -- is a local operation.
#
# git comes from docker/Dockerfile.builder, not the conda env; see the note
# there about fetchers versus build tools.
fetch_git () {
  local url="$1" ref="$2" dest="${3:-${BUILD_TMP}/${PKG_NAME}-${PKG_VERSION}}" m
  [ -n "${url}" ] || { echo "fetch_git: no URL (is PKG_GIT_URL set?)" >&2; exit 1; }
  [ -n "${ref}" ] || { echo "fetch_git: no ref (is PKG_GIT_REF set?)" >&2; exit 1; }

  m="${SRC_CACHE}/$(basename "${url}" .git).git"
  if [ ! -d "${m}" ]; then
    log "mirroring ${url}"
    rm -rf "${m}.part"
    git clone --quiet --mirror "${url}" "${m}.part"
    mv "${m}.part" "${m}"                 # atomic, as download_src does
  else
    # Non-fatal on purpose: an existing mirror plus no network is a valid state,
    # and 'set -e' would otherwise turn an offline rebuild into a build failure.
    log "refreshing mirror $(basename "${m}")"
    git -C "${m}" remote update --prune \
      || log "warning: mirror refresh failed; building from cached objects"
  fi

  rm -rf "${dest}"
  git clone --quiet --no-checkout "${m}" "${dest}"
  # Point origin back upstream BEFORE touching submodules.  .gitmodules may use
  # relative URLs, which git resolves against origin -- and origin is currently
  # a path into SRC_CACHE, where no submodule has ever been mirrored.
  git -C "${dest}" remote set-url origin "${url}"
  # --detach gives one code path for a tag, a branch and a raw SHA.
  git -C "${dest}" checkout --quiet --detach "${ref}"
  git -C "${dest}" submodule update --init --recursive
  log "checked out ${ref} at $(git -C "${dest}" rev-parse --short HEAD)"
}

# fetch_src -- dispatch on PKG_SOURCE.  Both modes leave the sources at the same
# predictable path, so a recipe resolves 'src' the same way either way.
fetch_src () {
  case "${PKG_SOURCE}" in
    tarball) download_src "${PKG_URL}" "$@" ;;
    git)     fetch_git "${PKG_GIT_URL}" "${PKG_GIT_REF}" ;;
    *) echo "unknown PKG_SOURCE: ${PKG_SOURCE} (want tarball or git)" >&2; exit 1 ;;
  esac
}

clean_build_tmp () { rm -rf "${BUILD_TMP}"; }

# Libtool .la files record the absolute path of the prefix they were installed
# into, plus absolute paths to their dependencies.  A relocated tree carries
# them around pointing at a directory that no longer exists, which is why
# relocate/validate.sh rejects them outright.  Every autotools package installs
# them by default, so any recipe using autotools should call this after
# 'make install'.  Nothing links against them -- the .so and the .pc file carry
# everything a consumer needs.
remove_libtool_archives () {
  local n
  n=$(find "${STACK}" -name '*.la' -type f -print -delete 2>/dev/null | wc -l)
  [ "${n}" -gt 0 ] && log "removed ${n} libtool .la file(s)"
  return 0
}

#------------------------------------------------------------------------------
# Source-install manifest -- amendment A10.
#
# relocate/prune.sh removes build-only conda packages by their conda-meta file
# lists.  A source package that overwrites a conda-owned path would lose that
# file when its original owner is pruned: conda still claims it, we deleted it,
# nothing notices until the tree is unpacked somewhere else and a library is
# missing.  So every source build records what it put in $STACK, and prune.sh
# treats those paths as untouchable.
#
# This runs from an EXIT trap rather than being called at the end of each
# recipe.  A recipe author who forgets loses the protection silently, and
# "silently" is the whole problem -- the failure would surface much later, in
# the artifact, as a missing file nobody deleted on purpose.  Recording on
# failure too is deliberate: a partial install is still files on disk.
_SRC_MANIFEST="${STACK}/etc/source-files.txt"
_SRC_BEFORE="${WORK}/manifest/${PKG_NAME}.before"

_stack_files () {
  [ -d "${STACK}" ] || return 0
  find "${STACK}" -mindepth 1 \( -type f -o -type l \) -printf '%P\n' 2>/dev/null \
    | LC_ALL=C sort
}

_record_source_install () {
  local rc=$?
  [ -s "${_SRC_BEFORE}" ] || return "${rc}"
  local after="${WORK}/manifest/${PKG_NAME}.after"
  _stack_files > "${after}" 2>/dev/null || return "${rc}"

  mkdir -p "$(dirname "${_SRC_MANIFEST}")"
  local n tmp="${WORK}/manifest/${PKG_NAME}.merged"
  # The temp file is assembled OUTSIDE $STACK on purpose: the mtime sweep below
  # walks $STACK, so a partially-written manifest sitting in there gets swept
  # into itself.  (Measured -- the first run recorded exactly one path, its own
  # scratch file.)
  #
  # comm -13: lines only in 'after' -- what this package added.  Files it
  # OVERWROTE do not appear, and overwriting a conda-owned path is the case
  # this manifest exists for, so those are caught by mtime instead.
  {
    [ -f "${_SRC_MANIFEST}" ] && cat "${_SRC_MANIFEST}"
    LC_ALL=C comm -13 "${_SRC_BEFORE}" "${after}"
    ( cd "${STACK}" && find . -newer "${_SRC_BEFORE}" \( -type f -o -type l \) \
        -printf '%P\n' 2>/dev/null )
  } | grep -v '^etc/source-files\.txt' | LC_ALL=C sort -u > "${tmp}"
  mv -f "${tmp}" "${_SRC_MANIFEST}"
  n=$(wc -l < "${_SRC_MANIFEST}")
  log "recorded source-installed paths; ${n} total in etc/source-files.txt"
  return "${rc}"
}

mkdir -p "${WORK}/manifest"
_stack_files > "${_SRC_BEFORE}" 2>/dev/null || true
trap _record_source_install EXIT
