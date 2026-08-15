#!/usr/bin/env bash
# Print the base-image matrix declared in docker/bases.env.
#
#   bases.sh            one image per line -- for shell loops
#   bases.sh --json     a JSON array -- for a GitHub Actions matrix
#
# This exists so the CI matrix and the local compose loop read the SAME list.
# §S7 asks for that explicitly ("same bases.env matrix list, so a green local
# 'compose run verify' means something about CI rather than being a parallel
# implementation that drifts"), and a list transcribed into a workflow file is
# a list that drifts the first time someone adds an image and updates one copy.
#
# BASES may be overridden in the environment for a targeted run, in which case
# bases.env is not read at all:
#
#   BASES="ubuntu:24.04" bash docker/bases.sh --json
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${BASES:-}" ]; then
  # shellcheck source=bases.env
  . "${HERE}/bases.env"
fi
: "${BASES:?docker/bases.env defined no BASES}"

read -r -a bases <<<"${BASES}"
[ "${#bases[@]}" -gt 0 ] || { echo "BASES is empty" >&2; exit 1; }

case "${1:---list}" in
  --list)
    printf '%s\n' "${bases[@]}"
    ;;
  --json)
    # Hand-rolled rather than via jq: this runs on the CI host before anything
    # is installed, and in the builder images, which deliberately carry almost
    # nothing.  Image names are [a-z0-9./:-], so there is nothing to escape.
    sep=''
    printf '['
    for b in "${bases[@]}"; do
      case "${b}" in
        *[!a-zA-Z0-9./:_-]*) echo "suspicious image name: ${b}" >&2; exit 1 ;;
      esac
      printf '%s"%s"' "${sep}" "${b}"
      sep=','
    done
    printf ']\n'
    ;;
  *)
    echo "usage: bases.sh [--list|--json]" >&2
    exit 2
    ;;
esac
