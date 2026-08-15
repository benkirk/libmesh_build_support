#!/usr/bin/env bash
# Sourced by every pkgs/<name>/build.sh.  Direct descendant of the helper block
# in the old build_config.sh.in, minus the autoconf substitution that baked
# absolute paths into everything.
#
# Provided by mk/pkg.mk: STACK WORK SRC_CACHE CONDA_HOME NPROC MAKE_J_L
#                        TARGET_PLATFORM BLAS_PROVIDER MPI_FAMILY RPATH_MODE
#                        TOPDIR PKG_NAME PKG_VERSION PKG_URL PKG_DIR

set -euo pipefail

: "${STACK:?}" "${WORK:?}" "${PKG_NAME:?}" "${PKG_VERSION:?}"

SRC_CACHE="${SRC_CACHE:-${WORK}/src}"
BUILD_TMP="${WORK}/build/${PKG_NAME}-${PKG_VERSION}"
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
