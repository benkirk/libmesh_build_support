#!/usr/bin/env bash
# wrappers/selftest.sh -- prove the wrappers do what they claim, by looking at
# the object files they produce.
#
# The claim is narrow and testable: whatever -march the caller passed, the
# emitted code stays within the declared baseline.  Testing that by inspecting
# the command line would only prove we appended a flag; the flag is not the
# point, the instructions are.  So every assertion here runs relocate/isa-scan.py
# over real .o files.
#
# THE NEGATIVE CONTROL IS THE LOAD-BEARING PART.  "No above-baseline
# instructions found" is exactly what a broken test prints too -- a source that
# does not vectorise, a regex that never matches, a compiler that ignored the
# flag.  So each case is run twice: once through the REAL compiler with a
# permissive -march, which must produce above-baseline code, and once through
# the wrapper with the identical arguments, which must not.  If the control does
# not trip, this script fails rather than passing vacuously.
set -euo pipefail

: "${STACK:?}" "${WORK:?}" "${ISA_BASELINE:?}"
TOPDIR="${TOPDIR:-$PWD}"
BIN="${WORK}/wrappers/bin"
PY="${CONDA_HOME:-}/bin/python"
[ -x "${PY}" ] || PY="$(command -v python3)"

[ -d "${BIN}" ] || { echo "no wrappers at ${BIN}; run 'make wrappers' first" >&2; exit 1; }

TMP="$(mktemp -d "${WORK}/wrappers-selftest.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

fails=0
ok   () { printf '  ok    %s\n' "$*"; }
bad  () { printf '  FAIL  %s\n' "$*"; fails=$(( fails + 1 )); }

#------------------------------------------------------------------------------
# A permissive -march, and sources chosen so that permission visibly changes the
# generated code.  Both loops are trivially vectorisable on purpose.
case "$(uname -m)" in
  x86_64)  HIGH='-march=x86-64-v4' ;;
  aarch64) HIGH='-march=armv8.2-a+sve+dotprod' ;;
  *)       echo "selftest: unsupported machine $(uname -m)" >&2; exit 1 ;;
esac

cat > "${TMP}/t.c" <<'EOF'
#include <stdint.h>
void dscale(double *restrict a, const double *restrict b, double s, int n)
{ for (int i = 0; i < n; i++) a[i] = b[i] * s + a[i]; }

int32_t idot(const int8_t *restrict a, const int8_t *restrict b, int n)
{ int32_t s = 0; for (int i = 0; i < n; i++) s += (int32_t)a[i] * (int32_t)b[i]; return s; }
EOF

cat > "${TMP}/t.cc" <<'EOF'
#include <vector>
#include <numeric>
double sum(const std::vector<double> &v) { return std::accumulate(v.begin(), v.end(), 0.0); }
EOF

cat > "${TMP}/t.f90" <<'EOF'
subroutine fscale(a, b, s, n)
  integer, intent(in) :: n
  double precision, intent(inout) :: a(n)
  double precision, intent(in) :: b(n), s
  integer :: i
  do i = 1, n
     a(i) = b(i) * s + a(i)
  end do
end subroutine fscale
EOF

# above_baseline DIR -> prints the count of objects carrying instructions above
# $ISA_BASELINE.  Levels come from isa-scan.py itself rather than being repeated
# here, so the two can never disagree about what "above" means.
above_baseline () {
  # Two statements, not one: bash expands every word of a 'local' command before
  # performing any of its assignments, so a second initialiser referring to the
  # first gets an empty value -- and under 'set -u' the subshell in it dies
  # noisily while the caller carries on with a degenerate filename.
  local dir="$1"
  # SC2155 (assignment masks the substitution's status) does not apply: basename
  # cannot meaningfully fail on a path we just created, and there is no status
  # here worth preserving.  The split above is the one that matters.
  # shellcheck disable=SC2155
  local report="${TMP}/scan-$(basename "${dir}").json"
  # --objdump is not optional here, and the reason is easy to miss.  isa-scan.py
  # resolves objdump as <root>/bin/*-objdump and only then falls back to PATH --
  # but 'root' here is a scratch directory of .o files with no bin/ in it, so it
  # ALWAYS falls back.  The builder image installs no binutils (conda supplies
  # it, deliberately), so on a base image that ships none of its own the scan
  # finds no objdump, skips, and reports an empty file list -- which this test
  # then reads as "nothing above the baseline".  Measured: almalinux 8 and 9
  # ship /usr/bin/objdump, opensuse/leap:15 and both ubuntus do not.  Name the
  # toolchain's own objdump and the base image stops mattering, which is the
  # premise the builder image is built on.
  "${PY}" "${TOPDIR}/relocate/isa-scan.py" --root "${dir}" --out "${report}" \
    --objdump "${OBJDUMP}" >/dev/null 2>&1
  "${PY}" - "${report}" "${ISA_BASELINE}" "${TOPDIR}/relocate/isa-scan.py" <<'PY'
import importlib.util, json, sys
# The repo is bind-mounted into the container; do not litter it with .pyc.
sys.dont_write_bytecode = True
report, baseline, scanner = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("isascan", scanner)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
levels = m.X86_LEVELS if baseline.startswith("x86") else m.ARM_LEVELS
base = levels.index(baseline)
data = json.load(open(report))
over = [f for f, v in data.get("files", {}).items()
        if any(x in levels and levels.index(x) > base for x in v.get("features", []))]
print(len(over))
for f in over:
    print("      over:", f, data["files"][f]["features"], file=sys.stderr)
PY
}

# compile_with CC OUTDIR EXTRA... -- one .o per source, nothing else in the dir.
compile_with () {
  local cc="$1" cxx="$2" fc="$3" out="$4"; shift 4
  mkdir -p "${out}"
  "${cc}"  -O3 "${HIGH}" -c "${TMP}/t.c"   -o "${out}/t.o"    "$@" || return 1
  "${cxx}" -O3 "${HIGH}" -c "${TMP}/t.cc"  -o "${out}/tcc.o"  "$@" || return 1
  "${fc}"  -O3 "${HIGH}" -c "${TMP}/t.f90" -o "${out}/tf.o"   "$@" || return 1
}

#------------------------------------------------------------------------------
echo "=== wrapper selftest (baseline ${ISA_BASELINE}, control ${HIGH})"

# Find the real compilers the wrappers point at, without going through PATH.
REAL_CC="$(sed -n "s/^real='\(.*\)'$/\1/p" "${BIN}/cc" 2>/dev/null || true)"
[ -n "${REAL_CC}" ] || REAL_CC="$(readlink -f "$(ls "${STACK}"/bin/*-gcc | head -1)")"
REAL_CXX="$(readlink -f "$(ls "${STACK}"/bin/*-g++ | head -1)")"
REAL_FC="$(readlink -f "$(ls "${STACK}"/bin/*-gfortran | head -1)")"

# The toolchain's own objdump, for the same reason the compilers are taken from
# the toolchain: what the base image happens to ship is not this test's business.
# Fatal rather than skipped -- a scan with no disassembler cannot distinguish
# "nothing above the baseline" from "I did not look", and this test's whole
# purpose is to prove it can tell the difference.
OBJDUMP="$(ls "${STACK}"/bin/*-objdump 2>/dev/null | head -1)"
[ -n "${OBJDUMP}" ] || { echo "no objdump in ${STACK}/bin: cannot verify anything" >&2; exit 1; }

echo "--- 1. negative control: the real compiler, permitted to exceed the baseline"
if compile_with "${REAL_CC}" "${REAL_CXX}" "${REAL_FC}" "${TMP}/control"; then
  n="$(above_baseline "${TMP}/control")"
  if [ "${n}" -gt 0 ]; then
    ok "control produced ${n} object(s) above ${ISA_BASELINE} -- the test can detect a failure"
  else
    bad "control produced NOTHING above ${ISA_BASELINE}: this test proves nothing as written"
  fi
else
  bad "control compile failed"
fi

echo "--- 2. the same command line through the wrappers"
W_CC="${BIN}/cc"; [ -x "${W_CC}" ] || W_CC="$(ls "${BIN}"/*-cc "${BIN}"/*-gcc 2>/dev/null | head -1)"
W_CXX="${BIN}/c++"; [ -x "${W_CXX}" ] || W_CXX="$(ls "${BIN}"/*-c++ "${BIN}"/*-g++ 2>/dev/null | head -1)"
W_FC="${BIN}/gfortran"; [ -x "${W_FC}" ] || W_FC="$(ls "${BIN}"/*-gfortran 2>/dev/null | head -1)"
if compile_with "${W_CC}" "${W_CXX}" "${W_FC}" "${TMP}/wrapped"; then
  n="$(above_baseline "${TMP}/wrapped")"
  [ "${n}" -eq 0 ] && ok "0 objects above ${ISA_BASELINE} despite ${HIGH} on the command line" \
                   || bad "${n} object(s) above ${ISA_BASELINE} -- the injection did not win"
else
  bad "wrapped compile failed"
fi

echo "--- 3. mpicc reaches the wrapped compiler"
# The one route PATH order might not cover: mpicc runs whatever compiler mpich
# recorded at ITS build time, which may be an absolute path.  Compile through it
# exactly as PETSc and libMesh will.
if [ -x "${STACK}/bin/mpicc" ]; then
  mkdir -p "${TMP}/viampi"
  if ( set -a; . "${WORK}/wrappers/env.sh"; set +a
       PATH="${BIN}:${STACK}/bin:${PATH}" \
       "${STACK}/bin/mpicc" -O3 "${HIGH}" -c "${TMP}/t.c" -o "${TMP}/viampi/t.o" ) 2>/dev/null; then
    n="$(above_baseline "${TMP}/viampi")"
    [ "${n}" -eq 0 ] && ok "mpicc-compiled object is within ${ISA_BASELINE}" \
                     || bad "mpicc bypassed the wrapper: ${n} object(s) above baseline"
  else
    bad "mpicc compile failed"
  fi
else
  echo "  skip  no mpicc in the stack"
fi

echo "--- 4. -march=native is refused, loudly"
if "${W_CC}" -march=native -c "${TMP}/t.c" -o "${TMP}/native.o" 2>"${TMP}/native.err"; then
  bad "-march=native was accepted"
else
  grep -q 'refusing' "${TMP}/native.err" && ok "-march=native rejected with an explanation" \
                                         || bad "-march=native failed, but not with our message"
fi
mkdir -p "${TMP}/warned"
if WRAPPER_ON_NATIVE=warn "${W_CC}" -O3 -march=native -c "${TMP}/t.c" \
     -o "${TMP}/warned/t.o" 2>/dev/null; then
  n="$(above_baseline "${TMP}/warned")"
  [ "${n}" -eq 0 ] && ok "WRAPPER_ON_NATIVE=warn proceeds, and 'native' still loses to the baseline" \
                   || bad "WRAPPER_ON_NATIVE=warn let host detection through"
else
  bad "WRAPPER_ON_NATIVE=warn did not proceed"
fi

echo "--- 5. introspection is byte-identical"
# String comparison rather than diff(1): the builder image is deliberately
# minimal and diffutils is not part of it.
for flag in --version -dumpmachine -dumpversion; do
  if [ "$("${W_CC}" "${flag}" 2>&1)" = "$("${REAL_CC}" "${flag}" 2>&1)" ]; then
    ok "${flag} unchanged"
  else
    bad "${flag} output differs from the real compiler"
  fi
done

echo "--- 6. nothing on stdout during a compile"
out="$("${W_CC}" -O2 -c "${TMP}/t.c" -o "${TMP}/quiet.o" 2>/dev/null)"
[ -z "${out}" ] && ok "compile is silent on stdout" || bad "wrapper wrote to stdout: ${out}"

echo "--- 7. bare 'cc' on PATH is ours, and does not recurse"
# The host image has its own gcc.  A build system falling back to plain 'cc'
# must land on the conda compiler behind our wrapper, not on the host's -- that
# is the difference between the declared glibc floor and an accident.
mkdir -p "${TMP}/viapath"
found="$( PATH="${BIN}:${STACK}/bin:${PATH}"; command -v cc || true )"
if [ "${found}" = "${BIN}/cc" ]; then
  ok "'cc' resolves to the wrapper, not the host compiler"
else
  bad "'cc' on PATH is '${found}', expected ${BIN}/cc"
fi
if ( PATH="${BIN}:${STACK}/bin:${PATH}"
     cc -O3 "${HIGH}" -c "${TMP}/t.c" -o "${TMP}/viapath/t.o" ) 2>/dev/null; then
  n="$(above_baseline "${TMP}/viapath")"
  [ "${n}" -eq 0 ] && ok "compiled via PATH without recursing, and within baseline" \
                   || bad "bare 'cc' produced ${n} object(s) above baseline"
else
  bad "'cc' via PATH failed to compile (recursion?)"
fi

echo "--- 7b. binutils resolve to the toolchain, not to the base image"
# The regression this guards is silent on almalinux and fatal on Debian: conda
# ships only triplet-prefixed binutils, so a bare 'ar' resolves to whatever the
# base image happens to carry -- and three of the five supported bases carry
# nothing.  Asserting the RESOLVED PATH rather than mere existence is the point;
# /usr/bin/ar existing would satisfy 'command -v' while proving the opposite of
# what this checks.
bu_bad=0
for tool in ar ranlib nm strip objdump; do
  if ! [ -e "${BIN}/${tool}" ]; then
    bad "no '${tool}' in ${BIN}: a site package calling it would get the base image's, or none"
    bu_bad=$((bu_bad + 1)); continue
  fi
  got="$( PATH="${BIN}:${STACK}/bin:${PATH}" command -v "${tool}" )"
  target="$(readlink -f "${got}")"
  case "${target}" in
    "${STACK}"/*) ;;
    *) bad "'${tool}' on PATH resolves to ${got} -> ${target}, outside ${STACK}"
       bu_bad=$((bu_bad + 1)); continue ;;
  esac
  # Inside $STACK is necessary but not sufficient.  conda ships <triplet>-nm and
  # <triplet>-gcc-nm side by side -- the latter is GCC's LTO wrapper, not the
  # binutils tool -- and both live here, so a path check alone accepts the wrong
  # one.  It did, until this line: the first version of the shims linked nm to
  # gcc-nm and every other assertion still passed.
  case "$(basename "${target}")" in
    *-gcc-"${tool}") bad "'${tool}' resolves to GCC's LTO wrapper $(basename "${target}"), not binutils"
                     bu_bad=$((bu_bad + 1)) ;;
  esac
done
[ "${bu_bad}" -eq 0 ] && ok "ar/ranlib/nm/strip/objdump all resolve inside the toolchain"

echo "--- 8. a linked executable still runs"
cat > "${TMP}/hello.cc" <<'EOF'
#include <string>
#include <cstdio>
int main(){ std::string s = "wrapped"; printf("%s\n", s.c_str()); return 0; }
EOF
if "${W_CXX}" -O2 "${TMP}/hello.cc" -o "${TMP}/hello" 2>/dev/null \
   && [ "$("${TMP}/hello")" = wrapped ]; then
  ok "C++ link and run (libstdc++ resolved -- the wrapper kept the g++ driver)"
else
  bad "C++ link/run through the wrapper failed"
fi

echo
[ "${fails}" -eq 0 ] && echo "=== wrapper selftest OK" && exit 0
echo "=== wrapper selftest: ${fails} failure(s)" >&2
exit 1
