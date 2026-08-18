#!/usr/bin/env bash
# Emit the two content hashes that identify a published builder image.
#
# These name what an image IS, so that "have we already built this?" is a
# question about inputs rather than about branches or timestamps.  Nothing
# consumes them as a cache yet -- that is a later change -- but the tags have to
# be right from the first push, because retagging published images is how a
# registry becomes untrustworthy.
#
# The two hashes NEST, and that is the point of having two:
#
#   SHA_CONDA  the provisioned toolchain.  Config plus conda/ only, so it
#              survives every change to the build machinery -- which is what
#              makes it a useful second fallback tier when the build image
#              misses.
#   SHA_BUILD  SHA_CONDA plus everything that decides what gets compiled into
#              the stack: the package recipes, the compiler wrappers, the stage
#              graph, the profiles and the hooks.
#
# Content, never mtimes, and 'git ls-files' rather than a find: tracked files
# only, already ordered, and blind to build output that would otherwise make the
# hash depend on whether the tree had been built before.
#
# TRACKED ONLY is a decision, not an accident, and site/ is where it shows.  A
# local site/ package really does get built -- 'make -n all' plans site-demo.
# But site/ is in .gitignore, so it is not in this hash and it is not in the
# 'git archive HEAD' that becomes the image either.  Those two exclusions have
# to agree: hashing something the image will not contain would name an image
# after content it does not have.  The rule is that a published image is built
# from tracked content, and its tag says so.
#
# Usage:  eval "$(.github/scripts/inputs-sha.sh)"   # or >> "$GITHUB_ENV"
set -euo pipefail

: "${BASE_IMAGE:?}"
: "${TARGET_PLATFORM:?}"
: "${BLAS_PROVIDER:?}"
: "${MPI_FAMILY:?}"
: "${HDF5_PARALLEL:?}"
: "${GLIBC_FLOOR:?}"
: "${GCC_VERSION:?}"
# Not ':?': a caller that predates profiles, or one building the default set,
# should not have to say so.
: "${PROFILE:=default}"

hash_stdin() { sha256sum | cut -d' ' -f1; }

hash_paths() {
    git ls-files -z -- "$@" | sort -z | xargs -0 -r sha256sum | hash_stdin
}

# Everything that changes what conda resolves to.  GLIBC_FLOOR and GCC_VERSION
# belong here rather than with the build inputs: conda/bootstrap.sh pins the
# sysroot and the compiler from them, so they change the environment itself.
config="$(printf '%s\n' \
    "base_image=${BASE_IMAGE}" \
    "target_platform=${TARGET_PLATFORM}" \
    "blas_provider=${BLAS_PROVIDER}" \
    "mpi_family=${MPI_FAMILY}" \
    "hdf5_parallel=${HDF5_PARALLEL}" \
    "glibc_floor=${GLIBC_FLOOR}" \
    "gcc_version=${GCC_VERSION}" | hash_stdin)"

conda_files="$(hash_paths conda/bootstrap.sh conda/env conda/lock conda/prune.list)"
build_files="$(hash_paths pkgs wrappers mk profiles hooks Makefile)"

# PROFILE belongs to the BUILD half only, and that asymmetry is the point.
# Hashing the contents of profiles/ says which version sets exist; it does not
# say which one was selected, so without this two profiles compute the same
# SHA_BUILD and publish over each other.  It must NOT reach SHA_CONDA: the
# toolchain image is profile-independent -- one env builds every profile -- and
# folding it in there would fragment the builder image for no reason.
sha_conda="$(printf '%s\n%s\n' "${config}" "${conda_files}" | hash_stdin)"
sha_build="$(printf '%s\n%s\n%s\n' "${sha_conda}" "${build_files}" \
             "profile=${PROFILE}" | hash_stdin)"

printf 'SHA_CONDA=%s\n' "${sha_conda:0:7}"
printf 'SHA_BUILD=%s\n' "${sha_build:0:7}"
