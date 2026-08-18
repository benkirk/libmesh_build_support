#!/usr/bin/env bash
# relocate/validate.sh -- the gate.
#
#   validate.sh [--full|--runtime] [--stage relocated|final] [ROOT]
#
# Two modes, because the checks need different tools and the two places we run
# them have different tools available:
#
#   --full     the complete set.  Needs a Python interpreter for depsolve.py.
#              Uses $CONDA_HOME/bin/python -- the miniforge base, which lives
#              OUTSIDE the stack, is never pruned and is never shipped.  That
#              matters: binutils and the stack's own python are both on
#              prune.list, so a validator depending on either would stop
#              working exactly when the post-slim gate needs it.
#
#   --runtime  loader-only.  No python, no binutils -- just ld.so answering
#              "can you resolve this?".  This is what the pristine verify image
#              can run, and it is the check that most directly mimics what
#              happens on the customer's machine.
#
# Two stages, because the tree is not final until after slim:
#
#   --stage relocated   embedded-prefix residue is REPORTED.  Most of it lives
#                       in packages prune.list removes (the sysroot alone is
#                       ~350 files), so failing here would mean failing on
#                       files that are about to be deleted.
#   --stage final       residue is FATAL.  This is the artifact.
set -euo pipefail

MODE=full
STAGE=relocated
ROOT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --full)    MODE=full ;;
    --runtime) MODE=runtime ;;
    --stage)   STAGE="$2"; shift ;;
    --stage=*) STAGE="${1#*=}" ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *)  ROOT="$1" ;;
  esac
  shift
done

ROOT="${ROOT:-${STACK:-}}"
: "${ROOT:?usage: validate.sh [--full|--runtime] [--stage S] ROOT}"
ROOT="$(cd "${ROOT}" && pwd)"
GLIBC_FLOOR="${GLIBC_FLOOR:-2.28}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fails=0
warns=0
bad  () { echo "  FAIL  $*"; fails=$((fails + 1)); }
warn () { echo "  warn  $*"; warns=$((warns + 1)); }
ok   () { echo "  ok    $*"; }

# Stage-dependent severity.  The two gates ask genuinely different questions.
#
# Post-relocate, a third of the tree is about to be deleted: the sysroot, the
# compilers, the autotools (and their perl), tk (and its X11 dependency),
# libsystemd.  Their
# unresolved references and their glibc requirements are facts about packages
# that will not be in the artifact.  Failing on them there would mean failing on
# files we are about to remove -- which trains you to ignore the gate, and a
# gate you ignore is not a gate.
#
# So: checks whose verdict CANNOT improve by deleting things (integrity, the C++
# runtime resolving in-tree, dangling symlinks, path length) are fatal at both
# stages.  Checks that are properties of the final dependency closure are
# advisory until the closure is final.
soft () {
  if [ "${STAGE}" = final ]; then bad "$@"; else warn "$* [advisory: pre-slim]"; fi
}

echo "=== validate (${MODE}, stage=${STAGE}) ${ROOT}"

#------------------------------------------------------------------------------
# Checks that need no tools at all, so they run in both modes.

# A6: conda pads embedded-prefix binary slots to a fixed 255 bytes.  A longer
# install path cannot be written back into them.  Measured, not assumed.
if [ "${#ROOT}" -gt 255 ]; then
  bad "install path is ${#ROOT} bytes; conda's padded prefix slots hold 255"
else
  ok "install path ${#ROOT}/255 bytes"
fi

dangling=$(find "${ROOT}" -xtype l 2>/dev/null | head -20)
if [ -n "${dangling}" ]; then
  bad "dangling symlinks:"; echo "${dangling}" | sed 's/^/          /'
else
  ok "no dangling symlinks"
fi

la=$(find "${ROOT}" -name '*.la' -type f 2>/dev/null | head -10)
if [ -n "${la}" ]; then
  bad "libtool .la files present (they carry absolute paths):"
  echo "${la}" | sed 's/^/          /'
else
  ok "no .la files"
fi

#------------------------------------------------------------------------------
# The rewritten build-integration files must RESOLVE, not merely stop naming the
# build prefix.
#
# This check exists because the textual one above passed while the answer was
# wrong.  relocate/fixup-text.sh rewrites libMesh's example Makefiles to locate
# the prefix from their own position; the first version computed the depth from
# etc/libmesh/Make.common but that file is also symlinked as <prefix>/Make.common,
# which is the path the examples actually include -- so it climbed two levels too
# far and every LIBMESH_DIR resolved to "/opt".  Nothing else would have noticed:
# the prefix string was gone, so the residue scan was satisfied.
#
# Asking make what it got is the only form of this check that means anything,
# and it costs one process.
# $(info) fires while make PARSES, so the value is printed before any recipe
# would run.  The probe still defines its own goal, because this script runs
# under 'set -o pipefail' and a make that exits non-zero on an unknown target
# fails the whole pipeline -- which silently produced an empty answer and a
# confusing "resolves to ''" the first time round.
#
# A path containing whitespace is exempt, and that is a real limitation rather
# than an excuse.  GNU make's path functions are list functions: with the tree
# at ".../a b/c", $(realpath ...) returns the right string but $(dir ...) and
# $(abspath ...) split it on the space and return nonsense.  Nothing a makefile
# can do fixes that -- make cannot represent a filename containing a space.
#
# So the ELF side of the artifact works from such a path (the loader has no such
# problem, and every object here resolves) while the make-based build
# integration does not.  Say so, once, rather than either failing the whole gate
# or quietly skipping the check.
ex4mk="${ROOT}/examples/introduction/ex4/Makefile"
if [ -f "${ex4mk}" ] && [ "${ROOT}" != "${ROOT%%[[:space:]]*}" ]; then
  warn "skipping the LIBMESH_DIR probe: this path contains whitespace, which" \
       "GNU make cannot represent (binaries are unaffected)"
elif [ -f "${ex4mk}" ] && command -v make >/dev/null 2>&1; then
  probe="$( cd "$(dirname "${ex4mk}")" \
            && printf 'include Makefile\n$(info __LMD=$(LIBMESH_DIR))\n__libmesh_probe:\n\t@true\n' \
               | make -f - -n __libmesh_probe 2>/dev/null )" || probe=''
  got="$(printf '%s\n' "${probe}" | sed -n 's/^__LMD=//p')"
  if [ "${got}" = "${ROOT}" ]; then
    ok "example Makefiles resolve LIBMESH_DIR to the tree they are in"
  elif [ -z "${got}" ]; then
    bad "example Makefile probe produced no value for LIBMESH_DIR"
  else
    bad "example Makefile resolves LIBMESH_DIR to '${got}', expected '${ROOT}'"
  fi
fi

#------------------------------------------------------------------------------
# The shipped CMake package configs must RESOLVE, not merely stop naming the
# build prefix -- the same question the LIBMESH_DIR probe above asks of the make
# fragments, asked of the 500-odd .cmake files.
#
# This is not hypothetical symmetry.  The LIBMESH_DIR bug was exactly this: the
# prefix string was gone, the residue scan was satisfied, and every path
# resolved to "/opt".  fixup-text.sh rewrites the CMake configs with the same
# class of expression, and until now nothing evaluated one -- there is no
# consumer of Trilinos_INCLUDE_DIRS anywhere in this repo, so a config that
# resolved to nonsense would ship silently.
#
# Done textually rather than by running cmake, because cmake is on
# conda/prune.list and the builder image has none either: at --stage final, and
# inside distcheck, there is no cmake anywhere.  The rewrite fixup-text.sh
# performs is a fixed shape --
#   get_filename_component(__stack_prefix_N "${CMAKE_CURRENT_LIST_DIR}/<rel>" REALPATH)
# -- so resolving it needs only the file's own directory, which is what cmake
# would have done with it.  Checking a path EXISTS is the part that has teeth;
# "/opt" does not.
# Full mode only: this needs an interpreter, and --runtime deliberately has
# none.  The verify image is where "no python" is a feature, not a gap.
cmcfg_checked=0 cmcfg_bad=0
cmcfg_py="${CONDA_HOME:-}/bin/python"
[ -x "${cmcfg_py}" ] || cmcfg_py="$(command -v python3 || true)"
[ "${MODE}" = full ] && [ -x "${cmcfg_py}" ] || cmcfg_py=""
while [ -n "${cmcfg_py}" ] && IFS= read -r cfg; do
  [ -f "${cfg}" ] || continue
  eval "$(PY_CFG="${cfg}" PY_ROOT="${ROOT}" "${cmcfg_py}" - <<'CMPY' 2>/dev/null || echo "CM_N=0 CM_BAD=0 CM_SAMPLE=''"
import os, re, sys
cfg, root = os.environ["PY_CFG"], os.environ["PY_ROOT"]
here = os.path.dirname(cfg)
text = open(cfg, errors="replace").read()
# The preamble fixup-text.sh injects, and the directory it resolves to.
prefixes = {}
for m in re.finditer(r'get_filename_component\((__stack_prefix_\d+)\s+"\$\{CMAKE_CURRENT_LIST_DIR\}/([^"]*)"\s+REALPATH\)', text):
    prefixes[m.group(1)] = os.path.realpath(os.path.join(here, m.group(2)))
bad, n = [], 0
# Only the variables a consumer actually dereferences to reach the tree.
for m in re.finditer(r'set\((\w*(?:INCLUDE_DIRS|LIBRARY_DIRS|_COMPILER|INSTALL_DIR))\s+"([^"]*)"\)', text):
    name, val = m.group(1), m.group(2)
    for k, v in prefixes.items():
        val = val.replace("${%s}" % k, v)
    if "${" in val or not val:
        continue
    for path in val.split(";"):
        path = path.strip()
        if not path or not path.startswith("/"):
            continue
        n += 1
        if not os.path.exists(path):
            bad.append(f"{name}={path}")
print("CM_N=%d" % n)
print("CM_BAD=%d" % len(bad))
print("CM_SAMPLE=%s" % repr("; ".join(bad[:3])))
CMPY
)"
  cmcfg_checked=$((cmcfg_checked + ${CM_N:-0}))
  if [ "${CM_BAD:-0}" -gt 0 ]; then
    cmcfg_bad=$((cmcfg_bad + CM_BAD))
    echo "          ${cfg#"${ROOT}"/}: ${CM_SAMPLE}"
  fi
done < <(find "${ROOT}/lib/cmake" -maxdepth 2 -name '*Config.cmake' -type f 2>/dev/null)

if [ "${cmcfg_checked}" -eq 0 ]; then
  : # no CMake package configs in this tree (or no python); nothing to assert
elif [ "${cmcfg_bad}" -eq 0 ]; then
  ok "${cmcfg_checked} path(s) from the shipped CMake configs resolve inside the tree"
else
  bad "${cmcfg_bad} path(s) named by a shipped CMake config do not exist"
fi

#------------------------------------------------------------------------------
# Embedded build-prefix residue.
#
# Scans binary files too.  'grep -rI' skips them, which is exactly how a prefix
# baked into an ELF stays invisible -- and that is the failure that breaks
# relocation.  See amendment A5.
if [ -n "${BUILD_ROOT:-}" ]; then
  # ELF objects are split out and reported separately, because for them the
  # bytes lie.  patchelf rewrites DT_RPATH but leaves the OLD rpath string
  # behind in .dynstr as an unreferenced orphan -- so grep still finds the build
  # prefix in a file whose live rpath is perfectly relocatable.  What actually
  # governs an ELF is its dynamic table, and that is checked directly below
  # ("no absolute RPATH entries").  Grepping bytes is the right check for
  # everything that is NOT an ELF, where a path string is what gets used.
  elf_hits=0 other_hits=0 other_list=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ "$(LC_ALL=C head -c4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' ')" = "7f454c46" ]; then
      elf_hits=$((elf_hits + 1))
    else
      other_hits=$((other_hits + 1))
      other_list="${other_list}${f}\n"
    fi
  done < <(LC_ALL=C grep -rla "${BUILD_ROOT}" "${ROOT}" 2>/dev/null || true)

  [ "${elf_hits}" -eq 0 ] || \
    warn "${elf_hits} ELF object(s) retain an orphaned build-prefix string (dead .dynstr entries; live rpaths checked below)"

  if [ "${other_hits}" -eq 0 ]; then
    ok "no build-prefix strings in any non-ELF file"
  elif [ "${STAGE}" = final ]; then
    bad "${other_hits} non-ELF file(s) still contain ${BUILD_ROOT}:"
    printf '%b' "${other_list}" | head -15 | sed "s|${ROOT}/|          |"
  else
    warn "${other_hits} non-ELF file(s) still contain ${BUILD_ROOT} (expected pre-slim)"
  fi
fi

#------------------------------------------------------------------------------
if [ "${MODE}" = runtime ]; then
  # Loader-only.  Ask ld.so to resolve each object with a scrubbed environment,
  # exactly as an unlucky customer's shell would not.
  echo "--- loader resolution (env -i)"
  missing=0 checked=0
  while IFS= read -r f; do
    [ "$(LC_ALL=C head -c4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' ')" = "7f454c46" ] || continue
    checked=$((checked + 1))
    out=$(env -i LD_TRACE_LOADED_OBJECTS=1 "${f}" 2>/dev/null || true)
    while read -r line; do
      case "${line}" in
        *"not found"*)
          lib="${line%% *}"
          case "${lib}" in
            libcuda.so.1|libcudart.so.*|libnvidia-ml.so.1) continue ;;  # host GPU driver, by design
          esac
          echo "          ${f#"${ROOT}"/}: ${line}"
          missing=$((missing + 1)) ;;
      esac
    done <<< "${out}"
  done < <(find "${ROOT}/lib" "${ROOT}/bin" "${ROOT}/libexec" -type f ! -name '*.a' 2>/dev/null)
  if [ "${missing}" -eq 0 ]; then ok "${checked} objects resolve with no environment"
  else soft "${missing} unresolved dependency reference(s) across ${checked} objects"; fi

else
  #----------------------------------------------------------------------------
  PY="${CONDA_HOME:-}/bin/python"
  [ -x "${PY}" ] || PY="$(command -v python3 || true)"
  [ -x "${PY}" ] || { echo "  FAIL  no python for depsolve.py" >&2; exit 1; }

  rep="$(mktemp)"
  trap 'rm -f "${rep}"' EXIT
  "${PY}" "${HERE}/depsolve.py" scan --root "${ROOT}" --brief > "${rep}"

  eval "$("${PY}" - "${rep}" "${GLIBC_FLOOR}" <<'PY'
import json, sys
rep = json.load(open(sys.argv[1]))
floor = tuple(int(x) for x in sys.argv[2].split("."))
meas = rep["glibc_max"]
mt = tuple(int(x) for x in meas.split(".")) if meas else (0, 0)
print(f"N_ELF={rep['elf_count']}")
print(f"N_UNRES={len(rep['unresolved'])}")
print(f"N_OPT={len(rep['optional_host'])}")
print(f"GLIBC_MEASURED={meas or 'none'}")
print(f"GLIBC_FILE={rep.get('glibc_max_file') or '-'}")
print(f"GLIBC_OVER={1 if mt > floor else 0}")
bad_internal = [m for m in rep["must_be_internal"] if not m["inside"]]
print(f"N_EXTERNAL_CXX={len(bad_internal)}")
print(f"N_ABSRPATH={len(rep.get('absolute_rpath', []))}")
print("ABSRPATH_SAMPLE=" + json.dumps(
    "\n".join(f"          {u['file']}: {u['entry']}"
              for u in rep.get("absolute_rpath", [])[:10])))
print("UNRES_SAMPLE=" + json.dumps(
    "\n".join(f"          {u['file']}: {u['lib']}" for u in rep["unresolved"][:12])))
print("CXX_SAMPLE=" + json.dumps(
    "\n".join(f"          {u['file']}: {u['lib']}" for u in bad_internal[:8])))
PY
)"

  # 1. no unresolved dependencies
  if [ "${N_UNRES}" -eq 0 ]; then ok "all ${N_ELF} ELF objects resolve within the tree + core glibc"
  else soft "${N_UNRES} unresolved dependency reference(s):"; printf '%b\n' "${UNRES_SAMPLE}"; fi

  # THE check.  Every RPATH must be $ORIGIN-relative: that, and nothing else,
  # is what lets the tree be unpacked at an arbitrary path and still resolve
  # itself.  Read from the live dynamic table, not from the file's bytes.
  if [ "${N_ABSRPATH}" -eq 0 ]; then ok "every rpath is \$ORIGIN-relative"
  else bad "${N_ABSRPATH} absolute rpath entr(ies) -- the tree is NOT relocatable:"
       printf '%b\n' "${ABSRPATH_SAMPLE}"; fi

  # 2/3. the C++ runtime must come from inside the tree, never the host
  if [ "${N_EXTERNAL_CXX}" -eq 0 ]; then ok "libstdc++/libgcc_s/libgfortran all resolve in-tree"
  else bad "${N_EXTERNAL_CXX} reference(s) to a HOST C++ runtime:"; printf '%b\n' "${CXX_SAMPLE}"; fi

  # 4. glibc floor -- measured, never assumed.  See amendment A4.
  if [ "${GLIBC_OVER}" -eq 1 ]; then
    soft "requires GLIBC_${GLIBC_MEASURED} but GLIBC_FLOOR is ${GLIBC_FLOOR} (worst: ${GLIBC_FILE})"
  else
    ok "max required GLIBC_${GLIBC_MEASURED} <= floor ${GLIBC_FLOOR}"
  fi

  [ "${N_OPT}" -eq 0 ] || warn "${N_OPT} optional host-GPU reference(s) (expected; UCX CUDA plugins)"

  #----------------------------------------------------------------------------
  # 6. Instruction-set floor.  Reads the report written during 'relocate', while
  # objdump was still in the tree, and filters it to the files that survived
  # pruning -- so one scan serves both stages without re-running.
  #
  # This is the one defect that would reach the customer as a SIGILL in the
  # middle of a run, on a machine we never see, in a library nobody suspected.
  if [ -s "${ISA_REPORT:-}" ]; then
    eval "$("${PY}" - "${ISA_REPORT}" "${ROOT}" "${ISA_BASELINE:-x86-64-v2}" <<'ISAPY'
import json, os, sys
rep = json.load(open(sys.argv[1]))
root, baseline = sys.argv[2], sys.argv[3]
X86 = ["x86-64", "x86-64-v2", "x86-64-v3", "x86-64-v4"]
ARM = ["armv8-a", "armv8.1-a", "armv8.2-a", "armv8-a+sve"]
levels = ARM if baseline.startswith("armv8") else X86
DISPATCH = ("libopenblas", "libblas", "liblapack", "libmkl", "libcblas",
            "libcrypto", "libssl", "libzstd", "libz.", "libz-ng", "libgomp")
# (library prefix, feature) pairs where the instruction is present but can never
# execute on hardware lacking it.  Narrower than the DISPATCH list on purpose:
# it exempts one feature of one library, not the library wholesale.
#
# libgcc_s carries the SVE/SME save-restore stubs required by the vector
# procedure call standard (9 'cntd' occurrences).  They are reached only from
# code compiled for SVE -- which cannot exist in a process running on a CPU
# without SVE -- so they are unreachable rather than merely guarded.
GUARDED = {("libgcc_s", "armv8-a+sve")}
def rank(f):
    return levels.index(f) if f in levels else -1
base = rank(baseline)
over, dispatched, scanned = [], [], 0
for rel, info in rep.get("files", {}).items():
    if not os.path.exists(os.path.join(root, rel)):
        continue                       # pruned since the scan; not our problem
    scanned += 1
    feats = info.get("features", [])
    worst = max(feats, key=rank) if feats else None
    if worst is None or rank(worst) <= base:
        continue
    entry = {"file": rel, "isa": worst}
    bn = os.path.basename(rel)
    if info.get("cpuid_dispatch") or bn.startswith(DISPATCH) or any(
            bn.startswith(lib) and worst == feat for lib, feat in GUARDED):
        dispatched.append(entry)
    else:
        over.append(entry)
print("ISA_SKIPPED=" + json.dumps(rep.get("skipped", "")))
print("ISA_SCANNED=%d" % scanned)
print("ISA_OVER=%d" % len(over))
print("ISA_DISPATCH=%d" % len(dispatched))
print("ISA_SAMPLE=" + json.dumps(
    "\n".join("          %s: %s" % (e["file"], e["isa"]) for e in over[:12])))
ISAPY
)"
    if [ -n "${ISA_SKIPPED}" ]; then
      # isa-scan.py returns 0 and writes {"skipped": ...} when it cannot find an
      # objdump -- deliberate, and right where it lives, since it also runs after
      # prune has removed binutils.  But the report it leaves has no file list,
      # so every consumer counting entries sees zero and reads it as a clean
      # tree.  This branch exists so that a gate which never ran cannot report
      # "all 0 objects within baseline" and be believed.  Fatal at both stages:
      # a scan that did not happen is not a verdict that pruning can improve.
      bad "ISA scan was skipped (${ISA_SKIPPED}); instruction-set floor NOT checked"
    elif [ "${ISA_OVER}" -eq 0 ]; then
      ok "all ${ISA_SCANNED} objects within ISA baseline ${ISA_BASELINE:-x86-64-v2}"
    else
      # Advisory pre-slim, like the other closure properties: nearly every hit
      # at that point is in the sysroot glibc or the compiler binaries, which
      # prune removes.  Fatal once the tree is final.
      soft "${ISA_OVER} object(s) exceed ISA baseline ${ISA_BASELINE:-x86-64-v2} -- these SIGILL on older CPUs:"
      printf '%b\n' "${ISA_SAMPLE}"
    fi
    # Runtime-dispatch libraries legitimately carry higher kernels behind a
    # CPUID check.  Reported, never fatal -- flagging them would be flagging
    # correct behaviour, on precisely the libraries where a hit is expected.
    [ "${ISA_DISPATCH}" -eq 0 ] || \
      warn "${ISA_DISPATCH} object(s) above baseline but carrying CPUID dispatch (expected: OpenBLAS, libgfortran matmul, MPICH yaksa kernels)"
  else
    warn "no ISA scan report at ${ISA_REPORT:-<unset>}; instruction-set floor NOT checked"
  fi


  #----------------------------------------------------------------------------
  # The manifest: what this artifact actually is.
  mkdir -p "${ROOT}/etc"
  "${PY}" - "${ROOT}" "${GLIBC_MEASURED}" "${GLIBC_FLOOR}" <<'PY'
import glob, json, os, subprocess, sys
root, measured, floor = sys.argv[1], sys.argv[2], sys.argv[3]
pkgs = {}
for j in sorted(glob.glob(os.path.join(root, "conda-meta", "*.json"))):
    try:
        d = json.load(open(j))
    except (OSError, ValueError):
        continue
    pkgs[d.get("name", os.path.basename(j))] = {
        "version": d.get("version"), "build": d.get("build"),
        "license": d.get("license"),
    }
def sh(*a):
    try:
        return subprocess.run(a, capture_output=True, text=True,
                              timeout=10).stdout.strip() or None
    except Exception:
        return None
man = {
    "generated_by": "relocate/validate.sh",
    "build_date": os.environ.get("SOURCE_DATE_EPOCH") or sh("date", "-u", "+%Y-%m-%dT%H:%M:%SZ"),
    "git_sha": sh("git", "-C", os.environ.get("TOPDIR", "."), "rev-parse", "HEAD"),
    "target_platform": os.environ.get("TARGET_PLATFORM"),
    # Which version set this is.  The conda side of the manifest is complete
    # without it, and the source side was previously not described at all -- a
    # tarball could not say which PETSc it carried without being unpacked.
    "profile": os.environ.get("PROFILE"),
    "source_packages": {
        k: v for k, v in (
            ("petsc", os.environ.get("PETSC_VERSION")),
            ("libmesh", os.environ.get("LIBMESH_VERSION")),
            ("trilinos", os.environ.get("TRILINOS_VERSION")),
        ) if v
    },
    "trilinos_kokkos": os.environ.get("TRILINOS_KOKKOS"),
    "trilinos_openmp": os.environ.get("TRILINOS_OPENMP"),
    "blas_provider": os.environ.get("BLAS_PROVIDER"),
    "mpi_family": os.environ.get("MPI_FAMILY"),
    "mpi_provider": os.environ.get("MPI_PROVIDER"),
    "hdf5_parallel": os.environ.get("HDF5_PARALLEL"),
    "rpath_mode": os.environ.get("RPATH_MODE"),
    "slim_profile": os.environ.get("SLIM_PROFILE"),
    # The floor we ASKED for and the floor we MEASURED.  Both, because they are
    # not the same thing and the difference is the whole point of A4.
    "glibc_floor_requested": floor,
    "glibc_floor_measured": measured,
    "isa_baseline": os.environ.get("ISA_BASELINE"),
    # GCC_VERSION pins the compiler; conda-forge ships its newest libstdc++
    # regardless, so the runtime version is recorded separately.  See A13.
    "gcc_version_requested": os.environ.get("GCC_VERSION"),
    "libstdcxx_version": (pkgs.get("libstdcxx") or {}).get("version"),
    "package_count": len(pkgs),
    "packages": pkgs,
}
out = os.path.join(root, "etc", "stack-manifest.json")
with open(out, "w") as fh:
    json.dump(man, fh, indent=2, sort_keys=True)
print(f"  ok    manifest -> etc/stack-manifest.json ({len(pkgs)} packages)")
PY
fi

#------------------------------------------------------------------------------
echo "=== validate: ${fails} failure(s), ${warns} warning(s)"
[ "${fails}" -eq 0 ] || exit 1
