#!/usr/bin/env bash
# test/installer-check.sh -- the gate for the .run, mirroring distcheck.sh.
#
# distcheck proves the TARBALL relocates.  This proves the INSTALLER delivers
# that same tarball and refuses hosts that cannot run it.  It keeps both of
# distcheck's deliberate cruelties -- a different directory depth, and a path
# containing a space -- and adds two checks distcheck has no reason to make:
#
#   PAYLOAD IDENTITY.  --extract-only diffed against a plain `tar xzf` of the
#   tarball.  "The payload is the proven tarball, byte for byte" is the premise
#   the entire design rests on; a premise that is only asserted in a document is
#   the one that quietly stops being true.  It is also the check that catches
#   the offset being wrong -- an octal-parsed PAYLOAD_OFFSET fails here rather
#   than at a customer.
#
#   REPRODUCIBILITY.  Assemble twice, compare SHA-256.  This repo tests that
#   claim rather than stating it.
set -euo pipefail

: "${TARBALL:?}" "${INSTALLER:?}"
TOPDIR="${TOPDIR:-$PWD}"
SMOKE_RANKS="${SMOKE_RANKS:-4}"
[ -f "${TARBALL}" ]   || { echo "no tarball at ${TARBALL}" >&2; exit 1; }
[ -f "${INSTALLER}" ] || { echo "no installer at ${INSTALLER}" >&2; exit 1; }

# The builder image has no diffutils -- 'diff' and 'cmp' are both absent, which
# this gate discovered the hard way on the first CI run.  Adding a package just
# to compare two trees would inflate the very minimal-host claim this repo
# spends its effort measuring, so the comparisons below use python instead: it
# is already required here (validate.sh --full and make-installer.sh both need
# it), and hashing content is a stricter identity check than diff -r anyway.
PY="${CONDA_HOME:-}/bin/python"
[ -x "${PY}" ] || PY="$(command -v python3 || true)"
[ -x "${PY}" ] || { echo "no python to compare trees with" >&2; exit 1; }

SCRATCH="$(mktemp -d "${DISTCHECK_TMP:-/tmp}/installer-check.XXXXXX")"
cleanup () {
  local rc=$?
  if [ "${rc}" -eq 0 ]; then
    chmod -R u+w "${SCRATCH}" 2>/dev/null || true
    rm -rf "${SCRATCH}"
  else
    echo "installer-check FAILED; the working tree is left at ${SCRATCH}" >&2
  fi
  return "${rc}"
}
trap cleanup EXIT

echo "=== installer-check"
echo "  installer: ${INSTALLER} ($(du -h "${INSTALLER}" | cut -f1))"

#------------------------------------------------------------------------------
echo
echo "--- metadata and integrity"
sh "${INSTALLER}" --info
sh "${INSTALLER}" --check

# --list must agree with the tarball's own table of contents, or the offset is
# off by something that happens to still gunzip.
sh "${INSTALLER}" --list | sort > "${SCRATCH}/list.run"
tar -tzf "${TARBALL}"     | sort > "${SCRATCH}/list.tar"
if [ "$(cat "${SCRATCH}/list.tar")" != "$(cat "${SCRATCH}/list.run")" ]; then
  echo "--list does not match the tarball's contents" >&2
  "${PY}" -c '
import sys
a = set(open(sys.argv[1]).read().split("\n"))
b = set(open(sys.argv[2]).read().split("\n"))
for x in sorted(a - b)[:20]: print("    only in the tarball:", x, file=sys.stderr)
for x in sorted(b - a)[:20]: print("    only in --list     :", x, file=sys.stderr)
' "${SCRATCH}/list.tar" "${SCRATCH}/list.run"
  exit 1
fi
echo "  ok    --list matches the tarball ($(wc -l < "${SCRATCH}/list.tar" | tr -d ' ') entries)"

#------------------------------------------------------------------------------
# PAYLOAD IDENTITY.  The premise, asserted.
echo
echo "--- payload identity: --extract-only vs a plain untar"
mkdir -p "${SCRATCH}/from-run" "${SCRATCH}/from-tar"
sh "${INSTALLER}" --extract-only --dest "${SCRATCH}/from-run" --quiet --skip-validate
tar -xzf "${TARBALL}" -C "${SCRATCH}/from-tar"
"${PY}" - "${SCRATCH}/from-tar/stack" "${SCRATCH}/from-run/stack" <<'IDENT'
import hashlib, os, sys


def manifest(root):
    # rel path -> (kind, content hash + mode | symlink target).  Mode is part
    # of identity: an installer that drops the executable bit produces a tree
    # that compares equal by content and does not run.
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(dirnames + filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            if os.path.islink(full):
                out[rel] = ("link", os.readlink(full))
            elif os.path.isdir(full):
                out[rel] = ("dir", "")
            else:
                h = hashlib.sha256()
                with open(full, "rb") as fh:
                    for b in iter(lambda: fh.read(1 << 20), b""):
                        h.update(b)
                mode = os.stat(full).st_mode & 0o7777
                out[rel] = ("file", "%s:%o" % (h.hexdigest(), mode))
    return out


a, b = manifest(sys.argv[1]), manifest(sys.argv[2])
if a == b:
    print("  ok    identical trees (%d entries, content and mode)" % len(a))
    sys.exit(0)

print("the .run payload is NOT the tarball -- the premise is broken", file=sys.stderr)
for rel in sorted(set(a) - set(b))[:20]:
    print("    only in the tarball:", rel, file=sys.stderr)
for rel in sorted(set(b) - set(a))[:20]:
    print("    only in the .run   :", rel, file=sys.stderr)
for rel in sorted(set(a) & set(b)):
    if a[rel] != b[rel]:
        print("    differs:", rel, a[rel], "!=", b[rel], file=sys.stderr)
sys.exit(1)
IDENT

#------------------------------------------------------------------------------
# REPRODUCIBILITY.  Same inputs, same bytes.
echo
echo "--- reproducibility: assemble twice, compare"
sha_of () {
  if   command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum    >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else echo "no sha256 tool to compare with" >&2; return 1
  fi
}
env TARBALL="${TARBALL}" INSTALLER="${SCRATCH}/again.run" \
    DIST_NAME="${DIST_NAME:-}" DIST_VERSION="${DIST_VERSION:-}" \
    CONDA_HOME="${CONDA_HOME:-}" \
    bash "${TOPDIR}/relocate/make-installer.sh" >/dev/null
a="$(sha_of "${INSTALLER}")"
b="$(sha_of "${SCRATCH}/again.run")"
[ "${a}" = "${b}" ] || {
  echo "assembling twice gave different bytes:" >&2
  echo "  ${a}  ${INSTALLER}" >&2
  echo "  ${b}  ${SCRATCH}/again.run" >&2
  exit 1
}
echo "  ok    ${a}"

#------------------------------------------------------------------------------
# Tamper detection.  The checksum is the tamper check, so prove it detects one.
echo
echo "--- a modified payload is refused"
cp "${INSTALLER}" "${SCRATCH}/tampered.run"
if [ -x "${PY}" ]; then
  "${PY}" -c '
import sys
p = sys.argv[1]
with open(p, "rb") as fh: b = bytearray(fh.read())
b[-4096] ^= 0xFF          # deep in the payload, not in the header
with open(p, "wb") as fh: fh.write(b)
' "${SCRATCH}/tampered.run"
  rc=0
  sh "${SCRATCH}/tampered.run" --check >/dev/null 2>&1 || rc=$?
  [ "${rc}" -eq 4 ] || { echo "a tampered payload was not refused with exit 4 (got ${rc})" >&2; exit 1; }
  echo "  ok    refused with exit 4"
else
  echo "  skip  no python to corrupt a copy with"
fi

#------------------------------------------------------------------------------
# A NON-EMPTY PREFIX is refused without --force.  Cheap, and the failure mode it
# guards is someone installing on top of a stack that is currently in use.
echo
echo "--- refusals"
mkdir -p "${SCRATCH}/occupied"; : > "${SCRATCH}/occupied/in-use"
rc=0; sh "${INSTALLER}" --prefix "${SCRATCH}/occupied" --quiet >/dev/null 2>&1 || rc=$?
[ "${rc}" -eq 3 ] || { echo "a non-empty prefix was not refused with exit 3 (got ${rc})" >&2; exit 1; }
echo "  ok    non-empty prefix refused with exit 3"

rc=0; sh "${INSTALLER}" --no-such-option >/dev/null 2>&1 || rc=$?
[ "${rc}" -eq 2 ] || { echo "a bad option did not exit 2 (got ${rc})" >&2; exit 1; }
echo "  ok    bad option refused with exit 2"

# $0 is how the header reads its own payload, so a pipe cannot work and must
# say so rather than failing on a missing file.
rc=0; cat "${INSTALLER}" | sh >/dev/null 2>&1 || rc=$?
[ "${rc}" -eq 2 ] || { echo "piping into sh did not exit 2 (got ${rc})" >&2; exit 1; }
echo "  ok    'cat installer | sh' refused with exit 2"

#------------------------------------------------------------------------------
# THE REAL INSTALL.  Deeper than the build path, and under a directory whose
# name contains a space -- an unquoted "$prefix" anywhere in a wrapper, a .pc
# file or a rewritten Makefile survives every test that unpacks into a tidy path
# and fails the first time a customer puts the stack under "/opt/My Tools/".
echo
echo "--- install into a deep path containing a space"
PREFIX="${SCRATCH}/relocated/a b/c/opt/libmesh-stack"
sh "${INSTALLER}" --prefix "${PREFIX}"

# --prefix installs AS DIR: activate.sh at the top, no nested stack/.
[ -r "${PREFIX}/activate.sh" ] || { echo "no activate.sh at ${PREFIX}" >&2; exit 1; }
[ ! -d "${PREFIX}/stack" ]     || { echo "--prefix nested a stack/ inside ${PREFIX}" >&2; exit 1; }
echo "  ok    installed AS the prefix (depth $(awk -F/ '{print NF-1}' <<<"${PREFIX}"))"

echo
echo "--- run the prebuilt binaries from the installed tree"
env STACK="${PREFIX}" SMOKE_RANKS="${SMOKE_RANKS}" WORK="${SCRATCH}/work" \
    bash "${TOPDIR}/test/run.sh" relocated

#------------------------------------------------------------------------------
# And again READ-ONLY.  Same reasoning as distcheck: this is how the stack is
# actually deployed -- unpacked once by someone with write access, then used by
# everyone else.  Only meaningful as a second pass, after the first run has had
# its chance to create the files that would mask the problem.
echo
echo "--- run again with the installed tree made read-only"
chmod -R a-w "${PREFIX}"
ro_rc=0
env STACK="${PREFIX}" SMOKE_RANKS="${SMOKE_RANKS}" WORK="${SCRATCH}/work-ro" \
    bash "${TOPDIR}/test/run.sh" relocated || ro_rc=$?
chmod -R u+w "${PREFIX}"
[ "${ro_rc}" -eq 0 ] || { echo "the installed stack does not work read-only" >&2; exit "${ro_rc}"; }

echo
echo "=== installer-check OK"
echo "    payload identical to the tarball, reproducible, tamper-detected,"
echo "    installed under a path containing a space and run read-only"
