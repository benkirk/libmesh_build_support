#!/usr/bin/env bash
# relocate/make-installer.sh -- assemble the .run from the proven tarball.
#
#   header + marker line + THE TARBALL, BYTE FOR BYTE.
#
# The last clause is the whole design.  The payload is not repacked, not
# re-tarred and not staged through a temp dir: it is the same bytes `make
# distcheck` just proved, so the .run inherits every guarantee distcheck
# establishes rather than re-opening them.  test/installer-check.sh asserts
# exactly this by diffing --extract-only against a plain untar.
#
# Reproducible for free: the payload is the reproducible tarball and the header
# carries no timestamp of its own, so the same inputs give the same .run.
# installer-check assembles twice and compares, because this repo tests its
# claims rather than stating them.
#
#   TARBALL=... INSTALLER=... bash relocate/make-installer.sh
set -euo pipefail

: "${TARBALL:?TARBALL is required}"
: "${INSTALLER:?INSTALLER is required}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${HERE}/installer-header.sh.in"

[ -f "${TARBALL}" ]  || { echo "no tarball at ${TARBALL}" >&2; exit 1; }
[ -r "${TEMPLATE}" ] || { echo "no header template at ${TEMPLATE}" >&2; exit 1; }

# Same interpreter choice validate.sh makes: the miniforge base lives OUTSIDE
# the stack, is never pruned and is never shipped, so it is still there after
# slim removed the stack's own python.
PY="${CONDA_HOME:-}/bin/python"
[ -x "${PY}" ] || PY="$(command -v python3 || true)"
[ -x "${PY}" ] || { echo "no python to read the manifest" >&2; exit 1; }

#------------------------------------------------------------------------------
# The payload must have exactly one top-level entry, and it must be stack/.
#
# --prefix installs AS DIR by stripping one component; if the tarball ever grew
# a second top-level entry that strip would silently drop it.  Assert instead.
tops="$(tar -tzf "${TARBALL}" | awk -F/ 'NF && $1 != "" {print $1}' | sort -u)"
if [ "${tops}" != "stack" ]; then
  echo "the tarball's top level is '${tops}', not exactly 'stack'" >&2
  echo "--strip-components=1 would be wrong; refusing to build an installer" >&2
  exit 1
fi

#------------------------------------------------------------------------------
# Facts come from the manifest INSIDE the tarball, not from the make variables.
#
# A37: the .run then describes the artifact rather than the build that was
# requested.  Same `tar -xzOf` move .github/workflows/stack.yml already makes.
# DIST_NAME/DIST_VERSION are the exception and come from make -- they are what
# the thing is CALLED, not something measured about it.
man="$(tar -xzOf "${TARBALL}" stack/etc/stack-manifest.json)" \
  || { echo "the tarball carries no stack/etc/stack-manifest.json" >&2; exit 1; }

read_field () { printf '%s' "${man}" | "${PY}" -c '
import json,sys
d = json.load(sys.stdin)
v = d.get(sys.argv[1])
sys.stdout.write("" if v is None else str(v))
' "$1"; }

GLIBC_MEASURED="$(read_field glibc_floor_measured)"
GLIBC_REQUESTED="$(read_field glibc_floor_requested)"
ISA_BASELINE_M="$(read_field isa_baseline)"
TARGET_PLATFORM_M="$(read_field target_platform)"
BLAS_PROVIDER_M="$(read_field blas_provider)"
MPI_PROVIDER_M="$(read_field mpi_provider)"
PROFILE_M="$(read_field profile)"
PACKAGE_COUNT="$(read_field package_count)"
GIT_SHA="$(read_field git_sha)"
BUILD_DATE="$(read_field build_date)"

for v in GLIBC_MEASURED ISA_BASELINE_M TARGET_PLATFORM_M PACKAGE_COUNT; do
  [ -n "${!v}" ] || { echo "manifest has no ${v}; refusing to bake a blank fact" >&2; exit 1; }
done

PAYLOAD_BYTES="$(wc -c < "${TARBALL}" | tr -d ' ')"
PAYLOAD_SHA256="$("${PY}" -c '
import hashlib,sys
h = hashlib.sha256()
with open(sys.argv[1],"rb") as fh:
    for b in iter(lambda: fh.read(1 << 20), b""):
        h.update(b)
print(h.hexdigest())
' "${TARBALL}")"
# Installed size from the archive's own member sizes -- what the tree costs
# once unpacked, which is the number the disk preflight has to compare against.
# Read with tarfile rather than by awk-ing `tar -tv`, whose column layout is not
# the same on GNU tar and bsdtar; this ran on macOS during development and would
# have baked a wrong number from the wrong column.
INSTALLED_KB="$("${PY}" -c '
import sys, tarfile
total = 0
with tarfile.open(sys.argv[1], "r:gz") as tf:
    for m in tf:
        total += m.size
print(int(total / 1024) + 1)
' "${TARBALL}")"

#------------------------------------------------------------------------------
# Substitution, in two passes, and the ORDER is the point.
#
# Pass 1 substitutes everything whose width does not matter.  Then the header's
# byte length is measured -- and that length IS the payload offset, because the
# template already ends with the marker line.
#
# Pass 2 substitutes the offset at EXACTLY the placeholder's width, so the
# measurement stays true.  The padding is a trailing comment, never leading
# zeros: `$((0000012345 + 1))` is octal in POSIX sh and evaluates to 5350, which
# would send tail to the wrong byte and fail looking like a corrupt download.
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
hdr="${tmp}/header"

esc () { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g' -e "s/'/'\\\\''/g"; }

sed -e "s|@PAYLOAD_SHA256@|$(esc "${PAYLOAD_SHA256}")|g" \
    -e "s|@PAYLOAD_BYTES@|$(esc "${PAYLOAD_BYTES}")|g" \
    -e "s|@INSTALLED_KB@|$(esc "${INSTALLED_KB}")|g" \
    -e "s|@DIST_NAME@|$(esc "${DIST_NAME:-libmesh-stack}")|g" \
    -e "s|@DIST_VERSION@|$(esc "${DIST_VERSION:-0.0.0}")|g" \
    -e "s|@TARGET_PLATFORM@|$(esc "${TARGET_PLATFORM_M}")|g" \
    -e "s|@GLIBC_MEASURED@|$(esc "${GLIBC_MEASURED}")|g" \
    -e "s|@GLIBC_REQUESTED@|$(esc "${GLIBC_REQUESTED}")|g" \
    -e "s|@ISA_BASELINE@|$(esc "${ISA_BASELINE_M}")|g" \
    -e "s|@BLAS_PROVIDER@|$(esc "${BLAS_PROVIDER_M}")|g" \
    -e "s|@MPI_PROVIDER@|$(esc "${MPI_PROVIDER_M}")|g" \
    -e "s|@PROFILE@|$(esc "${PROFILE_M}")|g" \
    -e "s|@PACKAGE_COUNT@|$(esc "${PACKAGE_COUNT}")|g" \
    -e "s|@GIT_SHA@|$(esc "${GIT_SHA}")|g" \
    -e "s|@BUILD_DATE@|$(esc "${BUILD_DATE}")|g" \
    "${TEMPLATE}" > "${hdr}"

# @PAYLOAD_OFFSET@ is the one that is SUPPOSED to still be here; anything else
# left over is a placeholder the template grew and the assembler does not know
# about, which would ship as a literal @NAME@ in the customer's --info output.
left="$(grep -o '@[A-Z_]*@' "${hdr}" | grep -v '^@PAYLOAD_OFFSET@$' | sort -u || true)"
if [ -n "${left}" ]; then
  echo "unsubstituted placeholders remain:" >&2
  printf '%s\n' "${left}" >&2
  exit 1
fi

PLACEHOLDER='@PAYLOAD_OFFSET@'
WIDTH=${#PLACEHOLDER}
OFFSET="$(wc -c < "${hdr}" | tr -d ' ')"

# value + " #" + dashes, padded to exactly WIDTH.  A trailing comment rather
# than trailing spaces, so no tool that trims whitespace can move the payload.
pad_to () {
  local v="$1" w="$2" out
  out="${v}"
  if [ "${#out}" -lt "${w}" ]; then out="${out} #"; fi
  while [ "${#out}" -lt "${w}" ]; do out="${out}-"; done
  [ "${#out}" -eq "${w}" ] || { echo "offset ${v} does not fit in ${w} columns" >&2; exit 1; }
  printf '%s' "${out}"
}
FIELD="$(pad_to "${OFFSET}" "${WIDTH}")"
sed -e "s|${PLACEHOLDER}|${FIELD}|" "${hdr}" > "${hdr}.final"

# The measurement must still hold, or tail reads from the wrong byte.
FINAL="$(wc -c < "${hdr}.final" | tr -d ' ')"
[ "${FINAL}" -eq "${OFFSET}" ] || {
  echo "header length changed under substitution (${OFFSET} -> ${FINAL})" >&2; exit 1; }
sh -n "${hdr}.final" || { echo "the assembled header is not valid sh" >&2; exit 1; }

#------------------------------------------------------------------------------
mkdir -p "$(dirname "${INSTALLER}")"
cat "${hdr}.final" "${TARBALL}" > "${INSTALLER}.tmp"
chmod 0755 "${INSTALLER}.tmp"
mv -f "${INSTALLER}.tmp" "${INSTALLER}"

# Checksums for both artifacts.  The embedded sha covers the payload and
# nothing else covers the header, so this file is the only thing that does.
# Consequence, stated rather than discovered: `make dist` alone writes no
# SHA256SUMS, because it has no .run to name.
#
# Hashed by ABSOLUTE path and named by basename -- an earlier version cd'd into
# the installer's directory and hashed bare names, which worked only because the
# tarball happens to live there too, and failed SILENTLY (a traceback into a
# redirect, exit 0, no SHA256SUMS) the first time it did not.
"${PY}" -c '
import hashlib, os, sys
lines = []
for path in sys.argv[1:]:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    lines.append(f"{h.hexdigest()}  {os.path.basename(path)}")
sys.stdout.write("".join(l + "\n" for l in sorted(lines, key=lambda l: l.split()[1])))
' "${TARBALL}" "${INSTALLER}" > "$(dirname "${INSTALLER}")/SHA256SUMS"

echo "  ok    installer -> $(basename "${INSTALLER}") ($((PAYLOAD_BYTES / 1048576)) MB payload at offset ${OFFSET})"
