#!/usr/bin/env bash
# test/run.sh MODE   (MODE = inplace | relocated)
#
#   inplace    build the smoke example against the stack, then run it.
#   relocated  $STACK is an unpacked tarball somewhere else on disk.  Run the
#              PREBUILT binary first -- that is the guarantee that matters --
#              and only then try to rebuild, and only if this host can.
#
# The asymmetry is the whole point.  In relocated mode a rebuild would prove
# that the tree can still compile, which is a weaker and different claim than
# "the binary we shipped runs where you put it".  The verify image has no
# compiler at all, so the rebuild is skipped there rather than failing.
set -euo pipefail

MODE="${1:-inplace}"
: "${STACK:?STACK must be set}"
SMOKE_RANKS="${SMOKE_RANKS:-4}"
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/smoke" && pwd)"
SMOKE_BIN="${STACK}/libexec/smoke"
EX4_BIN="${STACK}/libexec/introduction_ex4"
# The extension point: any package -- including one from site/ -- that installs
# an executable into $STACK/libexec/stack-tests/ gets run by this harness, in
# place and again from the relocated tree, with no edit here.  A customer
# proving their own code survives relocation should not have to patch the test
# suite to do it.
#
# Its own directory, NOT libexec/ itself: libexec is shared with conda packages,
# and rdma-core ships an executable 'truescale-serdes.cmds' there.  Running
# everything in libexec found it immediately and failed the suite -- a useful
# reminder that no directory in this prefix belongs to us alone.
SITE_BIN_DIR="${STACK}/libexec/stack-tests"
SITE_BINS=()
while IFS= read -r b; do SITE_BINS+=("$b"); done < <(
  find "${SITE_BIN_DIR}" -maxdepth 1 -type f -perm -u+x 2>/dev/null | sort)

# The contract this harness supplies to test/smoke/Makefile.
export STACK
export WORK="${WORK:-${TMPDIR:-/tmp}/smoke-work}"
export PETSC_DIR="${PETSC_DIR:-${STACK}}"
export LIBMESH_DIR="${LIBMESH_DIR:-${STACK}}"
export TRILINOS_DIR="${TRILINOS_DIR:-${STACK}}"
export MPIEXEC="${MPIEXEC:-${STACK}/bin/mpiexec}"

# activate.sh is installed by the relocate stage, so before it the stack goes
# on PATH by hand.  mpicc invokes <triplet>-cc by name and fails confusingly
# without it.
if [ -r "${STACK}/activate.sh" ]; then
  # shellcheck disable=SC1091
  . "${STACK}/activate.sh"
else
  export PATH="${STACK}/bin:${PATH}"
fi

fail () { echo "FAIL: $*" >&2; exit 1; }

#------------------------------------------------------------------------------
# Assert the output really came from N cooperating ranks.
#
# Checking only the rank-0 summary would miss the failure mode this exists for:
# a binary that is not MPI-linked, or is linked against a different MPI than the
# launcher, yields N independent processes that each believe they are rank 0 of
# 1 -- and all of them exit 0.  So require every rank id 0..N-1 to appear, and
# require every rank to have reported the same size.
assert_ranks () {
  local want="$1" out="$2" r seen
  for (( r = 0; r < want; r++ )); do
    grep -qx "smoke: rank ${r}/${want}" <<<"${out}" \
      || fail "no 'rank ${r}/${want}' line -- ranks did not agree on the communicator size"
  done
  seen=$(grep -c '^smoke: rank ' <<<"${out}" || true)
  [ "${seen}" -eq "${want}" ] || fail "expected ${want} rank lines, saw ${seen}"
  grep -qx "smoke: ranks=${want}" <<<"${out}" || fail "missing 'ranks=${want}' summary"
}

run_serial () {
  local out
  echo "--- serial"
  out=$("${SMOKE_BIN}") || fail "serial run exited non-zero"
  echo "${out}"
  assert_ranks 1 "${out}"
}

run_parallel () {
  local out
  echo "--- mpiexec -n ${SMOKE_RANKS}"
  out=$("${MPIEXEC}" -n "${SMOKE_RANKS}" "${SMOKE_BIN}") \
    || fail "mpiexec -n ${SMOKE_RANKS} exited non-zero"
  echo "${out}"
  assert_ranks "${SMOKE_RANKS}" "${out}"
}

#------------------------------------------------------------------------------
# libMesh's introduction_ex4 -- the endpoint this harness was always aiming at.
#
# A real FEM solve in 1D, 2D and 3D, exercising libMesh, PETSc, HDF5, netcdf and
# MPI at once.  It is run in a scratch directory because it writes mesh output,
# and that output is the point: the ExodusII write is the step that caught the
# stale netcdf_meta.h in the libMesh tarball (amendment A29).  A test that only
# checked the solve would have passed while every ExodusII file silently failed
# to be written.
#
# Each dimension writes a DIFFERENT artifact, and naming them individually is
# the point.  introduction_ex4 sends 1D to GnuPlot and only 2D and 3D to
# ExodusII, so "at least one .e file exists" is satisfied by the 2D run alone --
# the 3D write could fail completely and the test would still pass.  Requiring
# the specific file each run is supposed to produce is barely more code and
# actually pins down what happened.
run_ex4 () {
  local label="$1"; shift
  local dir out spec opts want
  [ -x "${EX4_BIN}" ] || { echo "--- ex4 skipped: libMesh not in this stack"; return 0; }
  mkdir -p "${WORK:-/tmp}"
  dir="$(mktemp -d "${WORK:-/tmp}/ex4.XXXXXX")"

  for spec in "-d 1 -n 20|gnuplot_script" \
              "-d 2 -n 15|out_2.e" \
              "-d 3 -n 6|out_3.e"; do
    # Two statements: bash expands every word of a 'local' before assigning any
    # of them, so a second initialiser referring to the first gets nothing.
    opts="${spec%%|*}"
    want="${spec##*|}"
    echo "--- introduction_ex4 ${label} ${opts}  -> ${want}"
    rm -f "${dir:?}/${want}"
    # shellcheck disable=SC2086
    out=$( cd "${dir}" && "$@" "${EX4_BIN}" ${opts} 2>&1 ) \
      || { echo "${out}" | tail -25; fail "introduction_ex4 ${opts} exited non-zero"; }
    grep -q "Error creating ExodusII" <<<"${out}" \
      && { echo "${out}" | tail -15; fail "ex4 could not write its ExodusII output"; }
    [ -s "${dir}/${want}" ] \
      || fail "ex4 ${opts} exited 0 but wrote no non-empty ${want}"
    echo "    ${want}: $(wc -c < "${dir}/${want}") bytes"
  done
  rm -rf "${dir}"
}

#------------------------------------------------------------------------------
# Extra executables from libexec/, run serially and under mpiexec.
#
# The assertion is deliberately weak -- exit 0, and something on stdout -- because
# this harness cannot know what a customer's program prints.  What it DOES know,
# and what is worth checking, is that the binary loads: every library resolved,
# from wherever the tree now lives.  A program that runs at all here has proved
# the thing this project is about.
run_site_bins () {
  local label="$1"; shift
  local b out
  [ "${#SITE_BINS[@]}" -gt 0 ] || return 0
  for b in "${SITE_BINS[@]}"; do
    echo "--- $(basename "${b}") ${label}"
    out=$( "$@" "${b}" 2>&1 ) || { echo "${out}" | tail -20; fail "$(basename "${b}") exited non-zero"; }
    [ -n "${out}" ] || fail "$(basename "${b}") produced no output"
    echo "${out}" | sed 's/^/    /'
  done
}

#------------------------------------------------------------------------------
echo "=== smoke: ${MODE} (ranks=${SMOKE_RANKS}, stack=${STACK})"
# 'if', not '[ ] && echo': as the last command in a list under 'set -e', a false
# test makes the whole && return non-zero and takes the script with it -- and
# the empty case here is the NORMAL one, so that would have failed every run
# that had no site package.
if [ "${#SITE_BINS[@]}" -gt 0 ]; then
  echo "    extra libexec binaries: ${SITE_BINS[*]##*/}"
fi

case "${MODE}" in
  inplace)
    [ -f "${SMOKE_DIR}/Makefile" ] || fail "test/smoke/ has no Makefile"
    make -C "${SMOKE_DIR}" all
    run_serial
    run_parallel
    run_ex4 serial
    run_ex4 "on ${SMOKE_RANKS} ranks" "${MPIEXEC}" -n "${SMOKE_RANKS}"
    run_site_bins serial
    run_site_bins "on ${SMOKE_RANKS} ranks" "${MPIEXEC}" -n "${SMOKE_RANKS}"
    ;;

  relocated)
    # The prebuilt binary, first and unconditionally.
    [ -x "${SMOKE_BIN}" ] || fail "no prebuilt ${SMOKE_BIN} in the unpacked tree"
    run_serial
    run_parallel
    run_ex4 serial
    run_ex4 "on ${SMOKE_RANKS} ranks" "${MPIEXEC}" -n "${SMOKE_RANKS}"
    run_site_bins serial
    run_site_bins "on ${SMOKE_RANKS} ranks" "${MPIEXEC}" -n "${SMOKE_RANKS}"

    # Then, and only as a bonus, prove the relocated tree can still compile --
    # but only where that is even possible.
    # Is there a working C compiler IN the tree?  Testing for mpicc is not
    # enough: mpicc is a wrapper, it is deliberately shipped, and the compiler
    # it wraps is deliberately NOT -- conda/prune.list drops gcc_impl and the
    # sysroot, which is where the measured ~530 MB of the artifact's diet comes
    # from.  So the shipped tarball has mpicc and no cc behind it.
    #
    # That is the intended shape, not a defect: the supported way to build
    # against this stack is inside the template, before the prune, where the
    # whole toolchain is present.  A customer compiling against the shipped
    # tarball uses their own compiler, and mpicc is still useful to them --
    # 'mpicc -show' yields the flags, and MPICH honours MPICH_CC to point the
    # wrapper at a compiler of their choosing.
    cc_in_tree=""
    for c in "${STACK}"/bin/*-gcc "${STACK}"/bin/*-cc "${STACK}/bin/gcc" "${STACK}/bin/cc"; do
      [ -x "${c}" ] && { cc_in_tree="${c}"; break; }
    done

    if [ -z "${cc_in_tree}" ]; then
      echo "--- rebuild skipped: the artifact ships no compiler (by design; see conda/prune.list)"
    elif [ ! -f "${SMOKE_DIR}/Makefile" ]; then
      echo "--- rebuild skipped: no smoke sources mounted"
    elif ! command -v make >/dev/null 2>&1; then
      echo "--- rebuild skipped: no make on this host (pristine verify image)"
    else
      echo "--- rebuild against the relocated tree"
      make -C "${SMOKE_DIR}" clean all
      run_serial
      run_parallel
    fi
    ;;

  *) fail "unknown MODE '${MODE}' (want inplace | relocated)" ;;
esac

echo "=== smoke: ${MODE} OK"
