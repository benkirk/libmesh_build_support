#!/usr/bin/env bash
# Sourced by every pkgs/<name>/build.sh.  Direct descendant of the helper block
# in the old build_config.sh.in, minus the autoconf substitution that baked
# absolute paths into everything.
#
# Provided by mk/pkg.mk: STACK WORK SRC_CACHE CONDA_HOME NPROC BLAS_PROVIDER
#                        MPI_FAMILY RPATH_MODE TOPDIR
#                        PKG_NAME PKG_VERSION PKG_URL PKG_DIR

set -euo pipefail

: "${STACK:?}" "${WORK:?}" "${PKG_NAME:?}" "${PKG_VERSION:?}"

SRC_CACHE="${SRC_CACHE:-${WORK}/src}"
BUILD_TMP="${WORK}/build/${PKG_NAME}-${PKG_VERSION}"
NPROC="${NPROC:-4}"

mkdir -p "${SRC_CACHE}" "${BUILD_TMP}"

log () { printf '=== %s: %s\n' "${PKG_NAME}" "$*"; }

require () {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { echo "missing required command: $c" >&2; exit 1; }
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
