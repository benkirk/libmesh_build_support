#!/usr/bin/env bash
# Package the build root as it stands right now, and push it.
#
# Called twice per build, at the two points where the tree is worth handing to
# somebody else:
#
#   builder  after 'make conda' -- the provisioned toolchain, nothing compiled
#   devel    after 'make build' -- toolchain plus the built stack, BEFORE
#            relocate strips it, slim trims it and prune removes binutils
#
# The second is the one that earns its keep.  This repo has an extension point
# already -- site/ packages, PKG_STAGE, twelve hook stages, docs/EXTENDING.md --
# and no delivery vehicle for it.  This is the vehicle: pull the image, drop a
# package into site/, run 'make build', and the stamps under .work/stamps mean
# every package already in the tree is accounted for, so only the addition
# compiles.  Then 'make all' relocates and packages the result.
#
# Nothing consumes these as a cache yet.  The tags are content hashes so that it
# can later, without republishing anything.
#
# Environment:
#   STAGE       builder | devel
#   TAG         full registry reference to push
#   CONFIG      human-readable configuration label, for the image description
#   GIT_SHA     commit being built
#   INPUTS_SHA  the content hash this tag is named for
#   PUSH        0 to build the image and stop.  CI never sets it; it exists so
#               the packaging can be exercised locally, and because this path is
#               off for pull requests -- without it, the first time this script
#               ever ran would be the merge to main.
set -euo pipefail

: "${STAGE:?}"
: "${TAG:?}"
: "${CONFIG:?}"
: "${GIT_SHA:?}"
: "${INPUTS_SHA:?}"

ROOT="$(git rev-parse --show-toplevel)"
CTX="${RUNNER_TEMP:-/tmp}/publish-${STAGE}"
rm -rf "${CTX}"
mkdir -p "${CTX}"

# Read the build root out of the container rather than repeating compose.yaml's
# value here.  One copy of the path, so it cannot drift.
BUILD_ROOT="$(cd "${ROOT}/docker" && docker compose run --rm -T build \
    bash -c 'printf %s "$BUILD_ROOT"')"
echo "build root: ${BUILD_ROOT}"

# Written to the bind-mounted repo rather than streamed over stdout: compose
# writes its own progress to the same terminal, and a tar that is one stray byte
# out is a tar nobody can extract.  A file has no such failure mode.
#
# stack/, .conda/ and .work/stamps only.  .work/src and the package build trees
# are re-derivable and would add gigabytes to every layer.
( cd "${ROOT}/docker" && docker compose run --rm -T build \
    tar -C "${BUILD_ROOT}" -cf /src/.publish-build-root.tar stack .conda .work/stamps )
mv "${ROOT}/.publish-build-root.tar" "${CTX}/build-root.tar"

# The tracked tree at this commit: no dist/, no ci-diag/, no local scratch.
git -C "${ROOT}" archive --format=tar HEAD -o "${CTX}/repo.tar"

ls -lh "${CTX}"

docker build \
    --file "${ROOT}/docker/Dockerfile.publish" \
    --build-arg "BUILDER_IMAGE=libmesh-stack-builder:local" \
    --build-arg "BUILD_ROOT=${BUILD_ROOT}" \
    --build-arg "STAGE=${STAGE}" \
    --build-arg "INPUTS_SHA=${INPUTS_SHA}" \
    --build-arg "GIT_SHA=${GIT_SHA}" \
    --build-arg "BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --build-arg "CONFIG=${CONFIG}" \
    --tag "${TAG}" \
    "${CTX}"

if [ "${PUSH:-1}" = 0 ]; then
    echo "PUSH=0 -- built ${TAG}, not pushing"
else
    docker push "${TAG}"
fi

# Reclaim immediately.  The context tar and the image together are several GB,
# and the steps after this one still have a build to finish.
rm -rf "${CTX}"

size="$(docker image inspect "${TAG}" --format '{{.Size}}' 2>/dev/null || echo 0)"
echo "${TAG} ready ($(( size / 1000000 )) MB)"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "- \`${TAG}\` — ${STAGE}, $(( size / 1000000 )) MB"
    } >> "${GITHUB_STEP_SUMMARY}"
fi
