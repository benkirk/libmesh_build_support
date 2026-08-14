#!/usr/bin/env bash
# relocate/patchelf.sh -- rewrite every RPATH in $STACK to be $ORIGIN-relative.
#
# This is the mechanism the whole project rests on.  After this runs, no ELF in
# the tree names an absolute path to any other ELF in the tree, so the tree can
# be unpacked anywhere and still resolve itself.
#
# RPATH, not RUNPATH, by default (RPATH_MODE=rpath):
#   - DT_RPATH is consulted BEFORE LD_LIBRARY_PATH; DT_RUNPATH after.  For a
#     redistributable that must survive an arbitrary customer environment, we
#     want our own libraries to win over whatever they have exported.
#   - DT_RPATH is inherited by the dependencies of a dependency; DT_RUNPATH is
#     not.  Since we patch every object that matters, either would work here --
#     but RPATH degrades more gracefully if something slips through.
#   - RPATH_MODE=runpath is the debugging escape hatch, and the natural hook for
#     the deferred external-MPI substitution work, which needs LD_LIBRARY_PATH
#     to be able to win.
#
# Deliberately NOT done here:
#   - --set-interpreter.  The premise is that the host's glibc satisfies our
#     declared floor; rewriting the interpreter would contradict that and break
#     on any host whose loader lives elsewhere.
#   - touching .a archives, scripts, or symlinks (the target is patched once,
#     via its real path).
#
# Idempotent: RPATHs are removed and recomputed from scratch every run.
set -euo pipefail

: "${STACK:?}"
RPATH_MODE="${RPATH_MODE:-rpath}"
PATCHELF="${PATCHELF:-${STACK}/bin/patchelf}"

command -v "${PATCHELF}" >/dev/null 2>&1 || PATCHELF=patchelf
command -v "${PATCHELF}" >/dev/null 2>&1 || { echo "patchelf not found" >&2; exit 1; }

# patchelf < 0.18 can corrupt binaries when it has to grow the program headers,
# and the plan called for pinning >= 0.18 "from conda".  That turns out not to
# be possible: conda-forge marked EVERY patchelf 0.18.0 build 'broken' on the
# main label, on every Linux subdir, and 0.19.1 was never promoted off the
# 'patchelf_dev' label.  The newest installable patchelf is 0.17.2 -- precisely
# the version the plan warns about.  See amendment A15.
#
# So this does not trust a version number.  It snapshots the load-bearing
# dynamic facts of every object (SONAME, DT_NEEDED, interpreter, ELF type and
# machine) before and after the rewrite, and fails if any of them moved.  That
# is strictly stronger than a version check: patchelf is only ever asked to
# change DT_RPATH, so ANY other difference is damage -- from this bug, a future
# one, or a truncated write.
#
# In practice growth is rare here anyway: conda's absolute RPATHs are longer
# than the '$ORIGIN:$ORIGIN/../lib' that replaces them, so the common case
# shrinks.  But "usually shrinks" is not a guarantee, which is the point.
pe_ver="$(${PATCHELF} --version 2>/dev/null | awk '{print $NF}')"
pe_major="${pe_ver%%.*}"; pe_minor="${pe_ver#*.}"; pe_minor="${pe_minor%%.*}"
if [ "${pe_major:-0}" -eq 0 ] && [ "${pe_minor:-0}" -lt 18 ]; then
  echo "note: patchelf ${pe_ver} (< 0.18; conda-forge has no installable 0.18+)."
  echo "      relying on the before/after integrity check below instead."
fi

PY="${PY:-${CONDA_HOME:-}/bin/python}"
[ -x "${PY}" ] || PY=python3
SNAPDIR="${WORK:-/tmp}/relocate"
mkdir -p "${SNAPDIR}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "snapshotting ELF state before the rewrite"
"${PY}" "${HERE}/depsolve.py" snapshot --root "${STACK}" > "${SNAPDIR}/before.json"

case "${RPATH_MODE}" in
  rpath)   force=(--force-rpath) ;;
  runpath) force=(--force-runpath) ;;
  *) echo "RPATH_MODE must be rpath or runpath, got: ${RPATH_MODE}" >&2; exit 1 ;;
esac

echo "patchelf ${pe_ver}, mode=${RPATH_MODE}, root=${STACK}"

patched=0 skipped=0 failed=0

while IFS= read -r -d '' f; do
  # ELF magic, by content -- extensions lie, especially in bin/ and libexec/.
  [ "$(LC_ALL=C head -c4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' ')" = "7f454c46" ] || continue

  dir="$(dirname "$f")"

  # Every object gets: its own directory (siblings, e.g. lib/ucx plugins
  # finding each other), then the merged lib/ (everything else).  The merged
  # prefix is what makes the second entry a single simple hop for almost
  # everything -- see the "Prefix" locked decision.
  rel_lib="$(realpath --relative-to="$dir" "${STACK}/lib")"
  if [ "${rel_lib}" = "." ]; then
    newpath='$ORIGIN'
  else
    newpath="\$ORIGIN:\$ORIGIN/${rel_lib}"
  fi

  # Patch a COPY and rename it into place, never the file itself.  Two
  # distinct reasons, both of which bite in practice:
  #
  #  1. patchelf is a C++ program that loads libstdc++.so.6 and libgcc_s.so.1
  #     from this very tree, and its own executable lives here too.  Rewriting
  #     a file the running process has mmap'd earns SIGBUS or SIGSEGV -- and
  #     those three files are exactly the ones we cannot skip, since validator
  #     rule 3 requires the C++ runtime to resolve in-tree.  Observed: patchelf
  #     0.17.2 dying on bin/patchelf, libstdc++.so.6 and libgcc_s.so.1.
  #  2. When the package cache and the env share a filesystem, conda hardlinks
  #     files into the env rather than copying.  Editing in place would then
  #     silently rewrite the cache too, poisoning every future env built from
  #     it.  rename() breaks the link instead of following it.
  #
  # rename(2) within a directory is atomic, so a crash mid-patch cannot leave
  # a half-written binary either.
  tmp="${dir}/.patchelf-tmp-$$-${RANDOM}"
  if ! cp -p "$f" "${tmp}" 2>/dev/null; then
    echo "  FAILED (copy): ${f#"${STACK}"/}" >&2
    failed=$((failed + 1))
    continue
  fi

  if "${PATCHELF}" --remove-rpath "${tmp}" 2>/dev/null &&
     "${PATCHELF}" "${force[@]}" --set-rpath "${newpath}" "${tmp}" 2>/dev/null; then
    mv -f "${tmp}" "$f"
    patched=$((patched + 1))
  else
    rm -f "${tmp}"
    # Not everything with ELF magic can take an RPATH: relocatable objects
    # (.o), and the sysroot's static bits.  Those are not load-time consumers
    # of an RPATH anyway, so this is a skip and not an error.
    if "${PATCHELF}" --print-rpath "$f" >/dev/null 2>&1; then
      echo "  FAILED: ${f#"${STACK}"/}" >&2
      failed=$((failed + 1))
    else
      skipped=$((skipped + 1))
    fi
  fi
done < <(find "${STACK}" -type f ! -name '*.a' ! -name '*.la' ! -name '*.py' \
                         ! -name '*.pyc' -print0)

echo "patchelf: ${patched} patched, ${skipped} skipped, ${failed} failed"
[ "${failed}" -eq 0 ] || exit 1

# The integrity gate.  This is what stands in for the version pin we cannot
# have -- see the note above.
echo "verifying nothing but the RPATH changed"
"${PY}" "${HERE}/depsolve.py" snapshot --root "${STACK}" > "${SNAPDIR}/after.json"
"${PY}" "${HERE}/depsolve.py" compare "${SNAPDIR}/before.json" "${SNAPDIR}/after.json"
