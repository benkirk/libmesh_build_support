#!/usr/bin/env bash
# Pull a published stack image and drop into an interactive shell inside it.
#
# CI publishes two images per configuration, named by CONTENT HASH rather than
# by branch or tag-of-convenience (see .github/scripts/publish-stage-image.sh):
#
#   builder  the provisioned toolchain, nothing compiled -- tagged SHA_CONDA
#   devel    toolchain PLUS the built stack, before relocate strips it and prune
#            removes binutils -- tagged SHA_BUILD.  This is the one to pull: you
#            get a tree where 'make build' already accounts for every package,
#            so dropping a recipe into site/ compiles only the addition.
#
# The tag is not guessed here.  It is computed by the SAME inputs-sha.sh that
# named the image when CI pushed it, run against the SAME tracked tree -- so on
# a checkout of the commit that built the image, this reproduces its ref exactly.
# One copy of the naming logic, so the local ref and the published ref cannot
# drift.  Change the tree (or the config knobs) away from a published build and
# the computed tag simply will not exist in the registry; the pull says so.
#
# Usage:
#   docker/pull-shell.sh                 # devel image for the default config
#   STAGE=builder docker/pull-shell.sh   # the toolchain-only image instead
#   docker/pull-shell.sh make build      # run a command instead of a shell
#   TAG=ghcr.io/.../devel:... docker/pull-shell.sh   # pull an exact ref verbatim
#
# Config knobs (same names and defaults as docker/compose.yaml's local loop, so
# the image you pull matches the one you would build here):
#   STAGE BASE_IMAGE TARGET_PLATFORM BLAS_PROVIDER MPI_FAMILY
#   HDF5_PARALLEL GLIBC_FLOOR GCC_VERSION PLATFORM
#
# Overrides for where the images live:
#   REGISTRY  default ghcr.io
#   REPO      default: derived from 'origin', else benkirk/libmesh_build_support
#   TAG       a full reference, bypassing all tag computation
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

STAGE="${STAGE:-devel}"
case "${STAGE}" in
  builder|devel) ;;
  *) echo "STAGE must be 'builder' or 'devel', not '${STAGE}'" >&2; exit 2 ;;
esac

# Defaults mirror compose.yaml's local loop -- the config a contributor builds
# here by default, and a real published combination (linux-aarch64, openblas,
# mpich, serial hdf5, built on almalinux:9).  Override any of them to name a
# different published image.
export BASE_IMAGE="${BASE_IMAGE:-almalinux:9}"
export TARGET_PLATFORM="${TARGET_PLATFORM:-linux-aarch64}"
export BLAS_PROVIDER="${BLAS_PROVIDER:-openblas}"
export MPI_FAMILY="${MPI_FAMILY:-mpich}"
export HDF5_PARALLEL="${HDF5_PARALLEL:-no}"
export GLIBC_FLOOR="${GLIBC_FLOOR:-2.28}"
export GCC_VERSION="${GCC_VERSION:-14}"

if [ -n "${TAG:-}" ]; then
  ref="${TAG}"
else
  REGISTRY="${REGISTRY:-ghcr.io}"
  # Match CI's ghcr.io/${{ github.repository }}: prefer the checked-out remote,
  # fall back to the same owner/name the Dockerfile.publish label hardcodes.
  if [ -z "${REPO:-}" ]; then
    origin="$(git config --get remote.origin.url 2>/dev/null || true)"
    REPO="$(printf '%s' "${origin}" \
            | sed -E 's#^.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#')"
    REPO="${REPO:-benkirk/libmesh_build_support}"
  fi

  # SHA_CONDA names the builder, SHA_BUILD the devel image -- exactly as the two
  # publish steps in stack.yml pair them.
  eval "$(.github/scripts/inputs-sha.sh)"
  if [ "${STAGE}" = builder ]; then sha="${SHA_CONDA}"; else sha="${SHA_BUILD}"; fi

  tag="${TARGET_PLATFORM}-${BLAS_PROVIDER}-${MPI_FAMILY}-${sha}"
  ref="${REGISTRY}/${REPO}/${STAGE}:${tag}"
fi

echo "image: ${ref}"
if ! docker pull "${ref}"; then
  cat >&2 <<EOF

Could not pull ${ref}.

The tag is the content hash of THIS tree's config + recipes, so it exists only
if that exact combination was published.  Likely causes:
  - local edits (or different knobs) put the tree at a hash CI never built
  - the image is private and this host is not logged in:
        echo \$GITHUB_TOKEN | docker login ghcr.io -u <you> --password-stdin
  - the registry pruned it (see .github/workflows/prune-ghcr.yml)

Browse what exists at:
  https://github.com/${REPO:-benkirk/libmesh_build_support}/pkgs/container/${REPO##*/}%2F${STAGE}
or pass an exact reference with TAG=...
EOF
  exit 1
fi

# Put the stack's bin on PATH, the way 'make shell' does for a local tree.  The
# path is read from the image's own BUILD_ROOT, so there is nothing to keep in
# sync here.  Default command is an interactive shell; anything passed through
# is run instead (e.g. 'pull-shell.sh make build').
PLATFORM="${PLATFORM:-}"
platform_arg=()
[ -n "${PLATFORM}" ] && platform_arg=(--platform "${PLATFORM}")

if [ "$#" -gt 0 ]; then
  exec docker run --rm -it "${platform_arg[@]}" "${ref}" \
    bash -lc 'export PATH="${BUILD_ROOT}/stack/bin:${PATH}"; exec "$@"' _ "$@"
else
  exec docker run --rm -it "${platform_arg[@]}" "${ref}" \
    bash -c 'export PATH="${BUILD_ROOT}/stack/bin:${PATH}"; exec bash -i'
fi
