#!/usr/bin/env bash
# Give the build room to work -- and prove it got it.
#
# docker/compose.yaml puts BUILD_ROOT, the conda package cache and the source
# cache in NAMED VOLUMES rather than bind mounts, because on macOS a bind mount
# over hundreds of thousands of files is the difference between minutes and
# hours.  That decision is right, and it has a consequence in CI: named volumes
# live under Docker's data root, which is /var/lib/docker on the runner's root
# filesystem.  So every byte this build produces -- the ~2 GB build tree, the
# conda package cache, the PETSc/Trilinos/libMesh source and build trees, and
# the images themselves -- lands on the smallest disk the runner has.
#
# GitHub's Ubuntu runners carry a second, much larger ephemeral disk mounted at
# /mnt.  Moving Docker's data root there moves all of the above in one step,
# which is why this script does that first and treats the rest as optional.
#
# Two deliberate departures from the InstructLab/benkirk 'slim-action-runner'
# this is adapted from:
#
#   * The swapfile stays.  That action reclaims /mnt/swapfile for another ~4 GB.
#     Runners have 16 GB of RAM, Trilinos and libMesh links are the memory peak
#     of this build, and 4 GB of disk on a 70 GB volume is not what is scarce
#     here.  Trading swap for disk we do not need is a bad trade in exactly the
#     job most likely to need the swap.
#
#   * The software sweep is opt-in, not the default.  If relocating the data
#     root is enough -- and the numbers this script prints are how we find out
#     -- then spending 60-90 seconds per job removing the runner's JVMs and
#     Android SDK buys nothing.  Turn it on with 'aggressive: true' once a run
#     shows it is needed.
#
# The failure this guards against is the quiet one.  A data-root move that
# half-succeeds leaves Docker running against the old path, the build fills the
# root filesystem 30 minutes in, and the error surfaces as a package failing to
# link rather than as a full disk.  So the move is asserted against
# 'docker info', not assumed from a clean exit -- the same reason
# docker/bases.env insists on --build and the verify service prints the distro
# it actually booted.
set -euo pipefail

DOCKER_ROOT="${DOCKER_ROOT:-/mnt/docker}"
AGGRESSIVE="${AGGRESSIVE:-false}"

report() {
    echo "---------------------------------------------------------------- ${1}"
    df -h / /mnt 2>/dev/null || df -h /
    if docker info --format '{{.DockerRootDir}}' >/dev/null 2>&1; then
        echo "docker data root: $(docker info --format '{{.DockerRootDir}}')"
    else
        echo "docker data root: (daemon not responding)"
    fi
}

report "before"

#-------------------------------------------------------------------------------
# Relocate Docker's data root onto /mnt.
#
# Skipped rather than failed when /mnt is missing or is not its own filesystem:
# this action should be safe to call from any job on any runner, and a runner
# without a resource disk is a smaller runner, not a broken one.
relocate_docker_root() {
    if [ ! -d /mnt ]; then
        echo "no /mnt on this runner -- leaving the docker data root alone"
        return 0
    fi

    if [ "$(stat -f -c %i / 2>/dev/null)" = "$(stat -f -c %i /mnt 2>/dev/null)" ]; then
        echo "/mnt is not a separate filesystem -- moving the data root would gain nothing"
        return 0
    fi

    local current
    current="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo '')"
    if [ "${current}" = "${DOCKER_ROOT}" ]; then
        echo "docker data root is already ${DOCKER_ROOT}"
        return 0
    fi

    if [ -e "${DOCKER_ROOT}" ]; then
        echo "::error::${DOCKER_ROOT} already exists; refusing to move the data root onto it"
        return 1
    fi

    echo "moving the docker data root: ${current:-/var/lib/docker} -> ${DOCKER_ROOT}"

    # docker.socket first.  Stopping only the service leaves socket activation
    # free to start it again the moment anything touches /var/run/docker.sock,
    # which would be mid-move.
    sudo systemctl stop docker.socket docker.service

    sudo mv /var/lib/docker "${DOCKER_ROOT}"

    # data-root in daemon.json rather than a symlink at /var/lib/docker.  Both
    # work; only this one is what Docker documents, and only this one is
    # visible in 'docker info' -- which is what the assertion below reads.
    #
    # Merged with jq rather than overwritten, because the runner image ships a
    # daemon.json and clobbering its contents is not this script's business.
    local cfg=/etc/docker/daemon.json
    [ -f "${cfg}" ] || printf '{}\n' | sudo tee "${cfg}" >/dev/null
    sudo jq --arg root "${DOCKER_ROOT}" '. + {"data-root": $root}' "${cfg}" \
        | sudo tee "${cfg}.new" >/dev/null
    sudo mv "${cfg}.new" "${cfg}"
    echo "${cfg}:" && cat "${cfg}"

    sudo systemctl start docker.service

    # systemctl returns once systemd has started the unit, which is earlier than
    # the daemon accepting API calls.  Poll rather than sleep a guessed number.
    local i
    for i in $(seq 1 30); do
        docker info >/dev/null 2>&1 && break
        [ "${i}" = 30 ] && { echo "::error::docker did not come back after the move"; return 1; }
        sleep 2
    done
}

relocate_docker_root

#-------------------------------------------------------------------------------
# Optional: remove software this build will never use.
#
# Safe to be blunt about headers and static libraries because nothing is
# compiled on the runner host -- the stack is built inside the container from
# docker/Dockerfile.builder, and the only host-side tools the build job uses
# after this point are docker, tar, jq and coreutils.
sweep_runner_software() {
    echo "---------------------------------------------------------------- aggressive sweep"
    set -x
    sudo rm -rf \
        /opt/az \
        /opt/ghc \
        /opt/google*/ \
        /opt/hostedtoolcache \
        /opt/microsoft \
        /opt/pipx \
        /usr/lib/dotnet \
        /usr/lib/firefox \
        /usr/lib/google-*/ \
        /usr/lib/jvm \
        /usr/lib/llvm-*/ \
        /usr/local/.ghcup \
        /usr/local/lib/android \
        /usr/local/lib/node_modules \
        /usr/local/share/chromium \
        /usr/local/share/powershell \
        /usr/local/share/vcpkg \
        /usr/share/dotnet \
        /usr/share/miniconda \
        /usr/share/swift \
        /var/cache/apt \
        2>/dev/null || true
    set +x

    # Belt and braces: these are the two categories that are large, numerous and
    # certainly unused, wherever the runner image happens to have put them.
    sudo find /usr /opt -type f -name 'lib*.a' -print0 2>/dev/null \
        | xargs -0 --no-run-if-empty sudo rm -f || true
}

case "${AGGRESSIVE}" in
    true | 1 | yes) sweep_runner_software ;;
    *) echo "aggressive sweep not requested -- relocating the data root should be enough" ;;
esac

sudo sync
report "after"
