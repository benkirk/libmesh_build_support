#!/usr/bin/env bash
# abi-check.sh -- build and RUN package B's three front-ends against a mock of
# package A, in a throwaway prefix, with no stack present.
#
# The demo's central claim is that package A's C ABI is a real boundary: C, C++
# and Fortran 2003 all consume the same header, the same library and the same
# .pc file, and none of them sees libMesh.  That claim is cheap to state and,
# without this script, expensive to check -- the real article needs conda,
# PETSc and libMesh, which is tens of minutes and several GB.
#
# So the boundary is tested against customer/test/abi-stub/, which implements
# gust_core.h's documented contract and nothing else.  Seconds, on any machine
# with a compiler, on every push.  What that buys, specifically:
#
#   - the Fortran BIND(C) derived type really does match the C struct.  A
#     mismatch is not a diagnostic in either language -- it is a silently wrong
#     layout -- and the front-ends assert field values, so it is caught here.
#   - -fopenmp really reaches the C++ compile (the source #errors otherwise),
#     and the reduction produces the right answer.
#   - all three link with the ordinary compilers and `pkg-config gust-core`
#     alone, which is the encapsulation claim in executable form.
#   - the installed layout -- include/gust/gust_core.h, include/gust_core.mod,
#     lib/pkgconfig/gust-core.pc -- is the one the recipes actually create.
#
# What it does NOT check, and must not be mistaken for: libMesh, PETSc, MPI,
# multi-rank behaviour, relocation.  Those need the real stack, and test/run.sh
# plus distcheck are where they are answered.
#
# Usage: customer/test/abi-check.sh [WORKDIR]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/.." && pwd)"          # customer/
work="${1:-$(mktemp -d "${TMPDIR:-/tmp}/gust-abi.XXXXXX")}"
prefix="${work}/prefix"

CC="${CC:-gcc}"
CXX="${CXX:-g++}"
FC="${FC:-gfortran}"

say  () { printf '=== %s\n' "$*"; }
fail () { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

for c in "${CC}" "${CXX}" "${FC}" pkg-config; do
  command -v "${c}" >/dev/null 2>&1 || fail "missing required tool: ${c}"
done

mkdir -p "${prefix}/include/gust" "${prefix}/lib/pkgconfig" "${work}/build"
cd "${work}/build"

#------------------------------------------------------------------------------
say "mock of package A -> libgustcore.so"

# The mock includes "gust_core.h" beside itself, exactly as gust_core.C does.
cp "${root}/gust-core/src/gust_core.h" .
"${CXX}" -O1 -g -fPIC -I. -c "${root}/test/abi-stub/gust_core_stub.C" -o stub.o
# The real libgustcore.so is linked with an absolute rpath into $STACK/lib (which
# relocate/patchelf.sh later rewrites to $ORIGIN-relative).  The mock gets the
# equivalent -- an rpath to its own toolchain's C++ runtime -- so that running
# the front-ends resolves libstdc++ deterministically instead of falling through
# to whatever the host has installed.
stub_rpath=()
_cxxdir="$(dirname "$("${CXX}" -print-file-name=libstdc++.so 2>/dev/null || echo .)")"
[ -e "${_cxxdir}/libstdc++.so" ] && stub_rpath=("-Wl,-rpath,${_cxxdir}")
"${CXX}" -shared -Wl,-soname,libgustcore.so -o "${prefix}/lib/libgustcore.so" stub.o \
   "${stub_rpath[@]}"

# The installed layout, matching what customer/gust-core/build.sh creates.
install -m 0644 "${root}/gust-core/src/gust_core.h" "${prefix}/include/gust/"

say "Fortran 2003 interface module -> gust_core.mod"
# -J puts the .mod where we want it; the object has no symbols and is dropped,
# which is the interface-only property gust_core_mod.f90 documents.
"${FC}" -O1 -g -J"${prefix}/include" -c "${root}/gust-core/src/gust_core_mod.f90" -o mod.o
[ -f "${prefix}/include/gust_core.mod" ] || fail "no gust_core.mod was produced"

# The module must define no PROCEDURE.  If a helper ever gets added to it,
# every C and C++ consumer of package A silently acquires a libgfortran
# dependency to reach it -- so assert the property rather than trusting it.
#
# Not "no symbols": gfortran emits __vtab_/__copy_/__def_init_ type-support
# symbols for the derived type regardless, so a naive count fails on a module
# that is perfectly interface-only.  (Measured -- it did, on the first run.)
# Those three prefixes are compiler-generated; anything else under the module's
# name mangling would be a procedure somebody wrote.
if command -v nm >/dev/null 2>&1; then
  procs="$(nm -g --defined-only mod.o 2>/dev/null | awk '{print $NF}' \
           | grep '^__gust_core_MOD_' \
           | grep -vE '^__gust_core_MOD___(copy|def_init|vtab)' || true)"
  [ -z "${procs}" ] || fail "gust_core_mod.f90 defines procedure(s), must be interface-only: ${procs}"
  say "  ok: interface-only (no procedures; type-support symbols only)"
fi

# The claim above, proved rather than inspected: mod.o is NOT linked into
# gust-hello-f03 below.  If the module ever grew a procedure the program used,
# that link would fail with an undefined reference.

say "gust-core.pc"
cat > "${prefix}/lib/pkgconfig/gust-core.pc" <<EOF
prefix=${prefix}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: gust-core
Description: Gust Dynamics core layer (ABI mock)
Version: 0.0.0-stub
Libs: -L\${libdir} -Wl,-rpath,\${libdir} -lgustcore
Cflags: -I\${includedir}
EOF

export PKG_CONFIG_PATH="${prefix}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
pkg-config --exists gust-core || fail "pkg-config cannot see the mock gust-core.pc"

cflags="$(pkg-config --cflags gust-core)"
libs="$(pkg-config --libs gust-core)"
say "pkg-config --cflags: ${cflags}"
say "pkg-config --libs:   ${libs}"

# -rpath-link, for the same reason customer/gust-app/build.sh passes it.
#
# libgustcore.so is C++ and so DT_NEEDEDs libstdc++.so.6.  When package B links
# it with a C or Fortran driver -- which is the whole point of the C ABI -- ld
# still has to resolve that entry to finish the link, and it uses neither -L nor
# -rpath for that search.  The real recipe points it at $STACK/lib; here the
# equivalent is wherever this toolchain keeps its own libstdc++.
#
# Without it the link only WARNS and still succeeds, which is worse than
# failing: the binary then resolves libstdc++ from the host at run time, so the
# harness silently stops testing a self-contained tree and starts depending on
# whatever the machine happens to have.  Measured against the conda-forge
# toolchain, where $STACK/lib is not on any default search path.
cxxdir="$(dirname "$("${CXX}" -print-file-name=libstdc++.so 2>/dev/null || echo .)")"
rpath_link=()
if [ -e "${cxxdir}/libstdc++.so" ]; then
  rpath_link=("-Wl,-rpath-link,${cxxdir}")
  say "C++ runtime for -rpath-link: ${cxxdir}"
else
  say "C++ runtime dir not resolved from ${CXX}; relying on default search"
fi

#------------------------------------------------------------------------------
# All three built exactly as customer/gust-app/build.sh builds them: ordinary
# compilers, pkg-config flags, and nothing else from the stack.
say "package B, three front-ends"

: > link.err
build_one () {
  local what="$1" rc=0
  shift
  # Capture stderr to a file: an ld warning here means the harness is not
  # reproducing the recipe's link, and a warning nobody reads is how that goes
  # unnoticed.  A plain redirect rather than a process substitution -- bash does
  # not wait for >(tee ...) to finish, so the grep below could run before the
  # warning had been written, which is precisely the kind of race a checking
  # harness must not contain.
  "$@" 2> one.err || rc=$?
  cat one.err >&2
  cat one.err >> link.err
  rm -f one.err
  [ "${rc}" -eq 0 ] || fail "${what} failed to build"
  say "  built ${what}"
}

# shellcheck disable=SC2086
build_one "gust-hello (C99)" \
  "${CC}" -std=c99 -O1 -g -Wall -Wextra -Werror ${cflags} \
   -DGUST_APP_VERSION='"abi-check"' \
   -o gust-hello "${root}/gust-app/src/gust_hello.c" ${libs} "${rpath_link[@]}"

# shellcheck disable=SC2086
build_one "gust-hello-omp (C++17/OpenMP)" \
  "${CXX}" -std=c++17 -O1 -g -Wall -Wextra -Werror -fopenmp ${cflags} \
   -DGUST_APP_VERSION='"abi-check"' \
   -o gust-hello-omp "${root}/gust-app/src/gust_hello_omp.cpp" ${libs} "${rpath_link[@]}"

# shellcheck disable=SC2086
build_one "gust-hello-f03 (Fortran 2003)" \
  "${FC}" -std=f2003 -O1 -g -Wall -Werror ${cflags} \
   -o gust-hello-f03 "${root}/gust-app/src/gust_hello_f03.f90" ${libs} "${rpath_link[@]}"

# A link that warns about an unresolvable DT_NEEDED still succeeds, and the
# binary then picks the library up from the host at run time.  That is exactly
# the dependency this project exists to eliminate, so treat it as an error here.
if grep -q 'not found (try using -rpath' link.err; then
  echo "--- ld warnings ---" >&2
  sort -u link.err >&2
  fail "a front-end linked with an unresolved library; -rpath-link is wrong or missing"
fi

#------------------------------------------------------------------------------
# Run them.  Each asserts its own arithmetic internally and exits non-zero on a
# mismatch, so a clean exit is already most of the check; the greps below pin
# down that the expected lines were actually produced rather than the program
# exiting early for some other reason.
say "running"

check () {
  local bin="$1" want="$2" out
  out="$("./${bin}" 2>&1)" || { printf '%s\n' "${out}"; fail "${bin} exited non-zero"; }
  printf '%s\n' "${out}" | sed 's/^/    /'
  grep -q "${want}" <<<"${out}" || fail "${bin}: no line matching '${want}'"
  grep -q "^${bin}: rank 0/1$" <<<"${out}" || fail "${bin}: missing rank line"
}

# refinements=2 -> side 16 -> 256 elements, 289 dofs.  Spelled out rather than
# computed, so this file and the front-ends cannot drift together into agreeing
# on the wrong answer.
check gust-hello     'solved on 1 rank(s): 256 elements, 289 dofs'
check gust-hello-omp 'reduction=41616 ok'
check gust-hello-f03 'solved on 1 rank(s): 256 elements, 289'

#------------------------------------------------------------------------------
# The encapsulation claim, checked against the binaries rather than the source:
# nothing here may have picked up a direct dependency on the stack.
say "DT_NEEDED"
if command -v readelf >/dev/null 2>&1; then
  for b in gust-hello gust-hello-omp gust-hello-f03; do
    needed="$(readelf -d "${b}" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
    printf '    %-16s %s\n' "${b}:" "${needed}"
    case "${needed}" in
      *libmesh*|*libpetsc*|*libmpi*)
        fail "${b} links the stack directly; package A is supposed to hide it" ;;
    esac
    case "${needed}" in
      *libgustcore.so*) ;;
      *) fail "${b} does not link libgustcore.so" ;;
    esac
  done
  # The OpenMP binary must carry libgomp -- that is the DT_NEEDED that has to
  # survive conda/prune.list and resolve through $ORIGIN in the shipped tree.
  readelf -d gust-hello-omp | grep -q 'libgomp' \
    || fail "gust-hello-omp has no libgomp dependency; did -fopenmp take effect?"
  say "  ok: only libgustcore.so from the stack side; libgomp present on the OpenMP build"
else
  say "  skipped: no readelf"
fi

say "ABI check passed (${work})"
