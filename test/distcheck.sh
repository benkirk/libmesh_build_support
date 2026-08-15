#!/usr/bin/env bash
# test/distcheck.sh -- the proof, and the headline claim of this project.
#
#   tar the tree -> move the original OUT of its path -> untar somewhere else,
#   at a DIFFERENT DIRECTORY DEPTH -> validate -> run the prebuilt binaries.
#
# Two details that look fussy and are not:
#
#   Different depth.  A same-depth move is satisfied by any hard-coded '../..'
#   that happens to still land somewhere plausible.  Changing the depth is what
#   catches it.
#
#   The original moves away first.  While the build tree still sits at its build
#   path, an absolute path baked into a binary resolves -- to the wrong tree,
#   silently, and the test passes.  Taking it out of the way is what converts
#   that into a failure.  It is moved rather than deleted so a failure here
#   leaves something to debug; the path is what matters, not the bytes.
set -euo pipefail

: "${TARBALL:?}" "${STACK:?}"
SMOKE_RANKS="${SMOKE_RANKS:-4}"
TOPDIR="${TOPDIR:-$PWD}"
[ -f "${TARBALL}" ] || { echo "no tarball at ${TARBALL}" >&2; exit 1; }

# Deliberately deeper than the build path, and named so it is obvious in a
# stack trace where a leaked absolute path came from.
#
# The space in "a b" is deliberate too.  An unquoted "$STACK" or "$prefix"
# somewhere in a wrapper, a .pc file or a rewritten Makefile survives every test
# that unpacks into a tidy path and fails the first time a customer puts the
# stack under "/opt/My Tools/".  It costs one character to check.
SCRATCH="$(mktemp -d "${DISTCHECK_TMP:-/tmp}/distcheck.XXXXXX")"
DEEP="${SCRATCH}/relocated/a b/c"
STASH="${STACK}.stashed-by-distcheck"

cleanup () {
  local rc=$?
  if [ -d "${STASH}" ] && [ ! -d "${STACK}" ]; then
    mv "${STASH}" "${STACK}"
    echo "restored the original tree"
  fi
  if [ "${rc}" -eq 0 ]; then
    rm -rf "${SCRATCH}"
  else
    echo "distcheck FAILED; the unpacked tree is left at ${DEEP}/stack" >&2
  fi
  return "${rc}"
}
trap cleanup EXIT

echo "=== distcheck"
echo "  tarball : ${TARBALL} ($(du -h "${TARBALL}" | cut -f1))"
echo "  built at: ${STACK}  (depth $(awk -F/ '{print NF-1}' <<<"${STACK}"))"

mkdir -p "${DEEP}"
tar -xzf "${TARBALL}" -C "${DEEP}"
NEW="${DEEP}/stack"
[ -d "${NEW}" ] || { echo "tarball did not contain stack/" >&2; exit 1; }
echo "  unpacked: ${NEW}  (depth $(awk -F/ '{print NF-1}' <<<"${NEW}"))"

# Out of the way, so nothing can accidentally resolve back to it.
mv "${STACK}" "${STASH}"
echo "  original moved aside: ${STACK} no longer exists"

echo
echo "--- validate the unpacked tree (full)"
env STACK="${NEW}" BUILD_ROOT="${BUILD_ROOT:-}" GLIBC_FLOOR="${GLIBC_FLOOR:-2.28}" \
    CONDA_HOME="${CONDA_HOME:-}" TOPDIR="${TOPDIR}" \
    ISA_BASELINE="${ISA_BASELINE:-}" ISA_REPORT="${ISA_REPORT:-}" \
    bash "${TOPDIR}/relocate/validate.sh" --full --stage final "${NEW}"

echo
echo "--- validate the unpacked tree (runtime: loader only, no python)"
env STACK="${NEW}" GLIBC_FLOOR="${GLIBC_FLOOR:-2.28}" \
    bash "${TOPDIR}/relocate/validate.sh" --runtime --stage final "${NEW}"

echo
echo "--- run the prebuilt binaries from the relocated tree"
env STACK="${NEW}" SMOKE_RANKS="${SMOKE_RANKS}" WORK="${SCRATCH}/work" \
    bash "${TOPDIR}/test/run.sh" relocated

#------------------------------------------------------------------------------
# And again from a READ-ONLY tree.
#
# This is how the stack actually gets deployed: unpacked once into a shared
# location by someone with write access, then used by everyone else. Anything
# that writes into its own prefix at runtime -- a cache, a log, a lock, a
# generated config -- works perfectly for whoever unpacked it and fails for
# every other user, on a machine nobody can reproduce it on.
#
# Cheap to check, and only meaningful as a SECOND pass: the first run may have
# created files that mask the problem, so this must come after everything above.
echo
echo "--- run again with the tree made read-only"
chmod -R a-w "${NEW}"
ro_rc=0
env STACK="${NEW}" SMOKE_RANKS="${SMOKE_RANKS}" WORK="${SCRATCH}/work-ro" \
    bash "${TOPDIR}/test/run.sh" relocated || ro_rc=$?
# Restore write permission before cleanup, or the trap cannot remove the tree.
chmod -R u+w "${NEW}"
[ "${ro_rc}" -eq 0 ] || { echo "the stack does not work from a read-only tree" >&2; exit "${ro_rc}"; }

echo
echo "=== distcheck OK: built at ${STACK}, ran at ${NEW}"
echo "    (unpacked under a path containing a space, and run read-only)"
