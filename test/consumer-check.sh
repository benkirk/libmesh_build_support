#!/usr/bin/env bash
# test/consumer-check.sh MODE   (MODE = discovery | build)
#
# Proves the "submodule consumer" path: a customer whose OWN repo is the top
# level, with this repo vendored as a submodule and their packages in
# packages/<name>/{pkg.mk,build.sh}, driven by the thin wrapper Makefile in
# examples/consumer/.
#
#   discovery  (default) synthesize the consumer layout and assert, WITHOUT
#              compiling anything, that the wrapper forwards correctly: the
#              customer packages are discovered and the graph orders
#              libmesh -> hello -> goodbye.  Seconds; no conda, no compiler.
#              This is the always-on gate (checks.yml).
#   build      everything discovery does, then a REAL 'make all' through the
#              wrapper -- builds the stack plus the customer packages, relocates,
#              validates and packs.  ~an hour; needs the toolchain.  Set PROFILE
#              in the environment to pick a version set.
#
# The fixture uses the checked-out repo itself as build_support via a symlink;
# a real customer runs 'git submodule add'.  BUILD_ROOT and DIST_DIR are
# redirected into the temp consumer dir by the wrapper, so this repo's checkout
# is never written to.
set -euo pipefail

MODE="${1:-discovery}"
case "${MODE}" in discovery|build) ;; *) echo "usage: $0 [discovery|build]" >&2; exit 2 ;; esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${REPO_ROOT}/examples/consumer"

work="$(mktemp -d "${TMPDIR:-/tmp}/consumer-check.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
consumer="${work}/consumer"

# Build the consumer repo from the tracked template -- exactly what a customer
# gets by copying examples/consumer/ and adding the submodule.
mkdir -p "${consumer}"
cp "${TEMPLATE}/Makefile"   "${consumer}/"
cp "${TEMPLATE}/.gitignore" "${consumer}/"
cp -r "${TEMPLATE}/packages" "${consumer}/"
ln -s "${REPO_ROOT}" "${consumer}/build_support"

say ()  { printf '\n=== %s\n' "$*"; }
fail () { echo "FAIL: $*" >&2; exit 1; }
# Every make below goes through the wrapper, so it is the wrapper -- SITE_DIRS
# redirection, BUILD_ROOT/DIST_DIR redirection, the submodule guard and the
# forward-once rule -- that is under test, not a hand-rolled sub-make.
mk ()   { make --no-print-directory -C "${consumer}" "$@"; }

pkgs_line () { awk '/^PACKAGES /{ $1=""; print }'; }

#------------------------------------------------------------------------------
say "discovery: the wrapper forwards, and finds the customer packages"
found="$(mk print-config | pkgs_line)"
echo "  PACKAGES:${found}"
for p in hello goodbye; do
  case "${found}" in
    *"${p}"*) echo "  ok ${p}" ;;
    *) fail "${p} was not discovered through the wrapper" ;;
  esac
done

#------------------------------------------------------------------------------
# The graph, from a dry run.  The wrapper's recipe contains $(MAKE), so GNU make
# runs it even under -n and the -n propagates to the submodule sub-make, which
# then prints the BUILD lines it WOULD run.  Their order is the dependency order.
say "graph: libmesh -> hello -> goodbye"
graph="$(mk -n build)"
line_of () {
  local n
  n="$(printf '%s\n' "${graph}" | grep -n "BUILD '$1-" | head -1 | cut -d: -f1)"
  [ -n "${n}" ] || { printf '%s\n' "${graph}" | sed 's/^/    /'; fail "no BUILD line for $1"; }
  printf '%s' "${n}"
}
lm="$(line_of libmesh)"; h="$(line_of hello)"; g="$(line_of goodbye)"
echo "  libmesh@${lm} -> hello@${h} -> goodbye@${g}"
[ "${lm}" -lt "${h}" ] || fail "hello is not ordered after libmesh"
[ "${h}"  -lt "${g}" ] || fail "goodbye is not ordered after hello"

# The graph must also resolve serially and in parallel -- the check that caught
# the stage-graph regression the top-level checks.yml guards against.
mk -n all     >/dev/null
mk -j8 -n all >/dev/null
echo "  ok: 'make all' orders itself, serial and -j8"

#------------------------------------------------------------------------------
say "the default build is untouched: no consumer package leaks into it"
default="$(make --no-print-directory -C "${REPO_ROOT}" print-config | pkgs_line)"
case "${default}" in
  *hello*|*goodbye*) fail "a consumer package leaked into the default build" ;;
  *) echo "  ok:${default}" ;;
esac

#------------------------------------------------------------------------------
if [ "${MODE}" = build ]; then
  say "build: real end-to-end 'make all' through the wrapper (PROFILE=${PROFILE:-default})"
  mk all
  # 'all' runs the test stage, which runs every libexec/stack-tests binary in
  # place and again from the relocated tree inside distcheck -- so a green 'all'
  # already proves goodbye (goodbye -> hello -> libMesh) built, relocated and RAN
  # from a tree unpacked at a different path.  Confirm the artifacts landed in
  # the CONSUMER's tree, not inside the submodule checkout.
  ls "${consumer}"/dist/*.tar.gz >/dev/null 2>&1 \
    || fail "no tarball in the consumer's dist/ -- DIST_DIR was not redirected"
  if [ -e "${REPO_ROOT}/dist" ]; then
    fail "a dist/ appeared inside the submodule checkout -- DIST_DIR leaked"
  fi
  echo "  ok: tarball in ${consumer}/dist, submodule checkout clean"
fi

say "consumer-check ${MODE}: OK"
