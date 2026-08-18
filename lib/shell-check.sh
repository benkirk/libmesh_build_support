#!/usr/bin/env bash
# The gate 'make shell' has to pass: build a real libMesh example the way a
# customer would, using ONLY what lib/devshell.sh hands over.
#
# This deliberately sources lib/devshell.sh rather than re-deriving the
# environment, so what is tested is the file the interactive shell actually
# uses.  A gate that reimplements the thing it checks proves only that two
# copies agree.
#
# It overlaps test/smoke/Makefile, which also builds introduction_ex4, and the
# difference is the entire point: test/smoke runs under test/run.sh's plain
# environment and passes its own explicit flags, proving the ARTIFACT is
# buildable against given the right compile line.  This runs under devshell.sh
# and passes nothing by hand, proving the FRAMEWORK hands over that line.
#
# There are two assertions here and they cover different things.  Do not merge
# them, and do not assume either one covers the other:
#
#   introduction_ex4  the customer-shaped case -- a real libMesh example built
#                     through libmesh-config.  It gates the SHELL: compilers,
#                     include paths, the ISA wrappers, a working link and run.
#                     Measured: it does NOT depend on -rpath-link, because
#                     'libmesh-config --libs' lists the transitive libraries
#                     explicitly, so ld never has to chase a DT_NEEDED.
#   petsc link        a bare '-lpetsc' against a header-only main.  This is the
#                     one that gates the ENVIRONMENT, and it is not
#                     hypothetical: under the old PATH-only 'make shell' it
#                     fails on 'undefined reference to HYPRE_AMSSetDimension'
#                     and 'dstev_' while ldd reports libpetsc.so fully
#                     resolved, because LDFLAGS was unset and ld uses neither
#                     -L nor -rpath to resolve a linked library's own DT_NEEDED
#                     entries -- only -rpath-link, which arrives with conda's
#                     activate.d.  Measured both ways, linux-aarch64,
#                     2026-08-18.  ex4 does not catch this; libmesh-config
#                     enumerates the transitive libraries, so ld never chases
#                     a DT_NEEDED.  That is why both cases are here.

set -euo pipefail

: "${STACK:?}" "${WORK:?}" "${TOPDIR:?}"

# shellcheck source=lib/devshell.sh
. "${TOPDIR}/lib/devshell.sh"

say () { printf '=== shell-check: %s\n' "$*"; }
die () { printf '=== shell-check: FAIL: %s\n' "$*" >&2; exit 1; }

work="${WORK}/shell-check"
rm -rf "${work}"
mkdir -p "${work}"

#-------------------------------------------------------------------------------
# 1. The wrappers are on the path mpicxx resolves through.
#
# Asserted on the RESOLVED BINARY, not on a flag: 'mpicxx -show' naming a
# triplet compiler proves nothing by itself, because both the wrapper and the
# real compiler carry that name.  Which directory it comes from is the claim.
mpicxx_cc="$(mpicxx -show | awk '{print $1}')"
mpicxx_bin="$(command -v "${mpicxx_cc}")" \
  || die "mpicxx drives '${mpicxx_cc}', which is not on PATH"
say "mpicxx drives ${mpicxx_bin}"

case "${USE_WRAPPERS:-yes}" in
  yes)
    case "${mpicxx_bin}" in
      "${WORK}/wrappers/bin/"*) say "ISA wrappers are in front of mpicxx" ;;
      *) die "mpicxx drives ${mpicxx_bin}, which is not under ${WORK}/wrappers/bin --
    this shell would compile without the -march=${ISA_BASELINE:-?} cap" ;;
    esac ;;
  *)  say "USE_WRAPPERS=${USE_WRAPPERS}, skipping the wrapper assertion" ;;
esac

#-------------------------------------------------------------------------------
# 2. Build libMesh's introduction_ex4 with nothing but the framework's flags.
#
# Copied out of the installed tree rather than built in place: $STACK is the
# artifact, and a gate that writes into it is a gate that changes what it is
# measuring.  libMesh installs the example sources but no binary, which is why
# there is something to compile at all.
ex4_dir="${LIBMESH_DIR:-${STACK}}/examples/introduction/ex4"
[ -d "${ex4_dir}" ] || die "no ${ex4_dir} -- run 'make build' first"

cp "${ex4_dir}"/*.C "${work}/"
say "building introduction_ex4 from ${ex4_dir}"

# METHOD=opt because libmesh-config emits per-method flags and defaults are not
# a contract.  $LDFLAGS and the libmesh-config expansions are left unquoted
# deliberately: word splitting is what carries the framework's flags onto the
# command line, and that is the whole assertion of this gate.
# shellcheck disable=SC2086,SC2046
"${STACK}/bin/mpicxx" \
  $(METHOD=opt "${STACK}/bin/libmesh-config" --cppflags --cxxflags --include) \
  -o "${work}/introduction_ex4" "${work}"/*.C \
  ${LDFLAGS} \
  $(METHOD=opt "${STACK}/bin/libmesh-config" --libs) \
  || die "the link failed with only the framework's flags.
    If this is 'undefined reference' against symbols that ldd says are present,
    it is the -rpath-link gap: ld does not use -L or -rpath to resolve a linked
    library's own DT_NEEDED entries.  See activate_toolchain in
    lib/build_common.sh and 'Things that will bite you' in docs/EXTENDING.md."

say "linked"

#-------------------------------------------------------------------------------
# 3. It runs.  A binary that links and cannot load has proved nothing about the
# rpaths, which is the property the rest of the pipeline is built on.
( cd "${work}" && ./introduction_ex4 -d 1 -n 5 >"${work}/ex4.log" 2>&1 ) \
  || { tail -20 "${work}/ex4.log" >&2; die "introduction_ex4 exited non-zero"; }

say "ran introduction_ex4 -d 1 -n 5"

#-------------------------------------------------------------------------------
# 4. A bare '-lpetsc' link, which is what actually exercises -rpath-link.
#
# Deliberately minimal and deliberately NOT routed through a *-config script:
# the moment a build system enumerates the transitive libraries for you, the
# gap closes and this stops testing anything.  A customer linking one library
# and letting the loader metadata do the rest is the case that breaks.
cat > "${work}/petsc_link.c" <<'EOF'
#include <petscvec.h>
int main(int argc, char **argv)
{
    PetscInitialize(&argc, &argv, NULL, NULL);
    PetscFinalize();
    return 0;
}
EOF

say "linking a bare -lpetsc with only the framework's LDFLAGS"
# shellcheck disable=SC2086
"${STACK}/bin/mpicc" -I"${STACK}/include" -o "${work}/petsc_link" \
  "${work}/petsc_link.c" ${LDFLAGS} -lpetsc \
  || die "a bare -lpetsc link failed with only the framework's flags.
    If these are 'undefined reference' errors against symbols ldd says
    libpetsc.so resolves, LDFLAGS has lost -Wl,-rpath-link,\$STACK/lib -- which
    means the conda activate.d scripts were not sourced, i.e. this shell is not
    the build environment after all.  See activate_toolchain in
    lib/build_common.sh."

say "OK -- 'make shell' builds against the stack with no hand-written flags"
