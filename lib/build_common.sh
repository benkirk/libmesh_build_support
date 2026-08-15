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
