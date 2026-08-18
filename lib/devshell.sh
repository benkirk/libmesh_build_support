# shellcheck shell=bash
# The interactive form of activate_toolchain.  Sourced as the --rcfile of
# 'make shell', and sourced again -- non-interactively -- by lib/shell-check.sh,
# so the gate exercises this file rather than a re-implementation of it.
#
# WHY THIS EXISTS.  'make shell' used to put $STACK/bin on PATH and stop there.
# That shell looked right and was not: conda's activate.d scripts had not run,
# so CC/CXX/FC were unset, CPPFLAGS/LDFLAGS/PKG_CONFIG_PATH were unset, and --
# the one that actually bites -- $WORK/wrappers/bin was not ahead of $STACK/bin.
#
# mpicxx worked either way, which is precisely the trap.  mpich's wrapper
# invokes the compiler by BARE TRIPLET NAME and lets PATH decide what that
# means: inside a package build it lands on the ISA wrapper and gets
# -march=$ISA_BASELINE appended, and inside the old 'make shell' it landed on
# the raw conda compiler and got nothing.  Same command, same apparent success,
# different instructions emitted -- and the difference surfaces two stages later
# as an ISA-scan failure in validate, pointing nowhere near the shell.
#
# The workaround a customer reaches for -- exporting CPPFLAGS/LDFLAGS by hand --
# is silently undone, because activate_toolchain scrubs exactly those variables
# on entry.  So the fix has to be to hand over the real environment, not to
# document an approximation of it.

# Save the caller's shell options BEFORE build_common.sh turns on
# 'set -euo pipefail' at source time.  'set +o' prints them in a form that
# re-inputs, so the restore at the bottom is exact rather than a guess about
# what the caller wanted.
__devshell_opts="$(set +o)"

# An interactive shell gets the user's own rc, and gets it FIRST, so that the
# stack's values win over whatever it sets.  That is the same rule
# activate_toolchain's scrub enforces, applied one level out.  A non-interactive
# caller (shell-check) deliberately does not read it: a gate whose result
# depends on the developer's ~/.bashrc is not a gate.
case "$-" in
  *i*) # shellcheck disable=SC1090,SC1091
       [ -r "${HOME}/.bashrc" ] && . "${HOME}/.bashrc" ;;
esac

# build_common.sh hard-requires a package identity (': "${PKG_NAME:?}"') and
# builds $BUILD_TMP out of it.  Borrow one and remove the empty directory
# afterwards, rather than teaching every recipe's contract about a shell.
# shellcheck disable=SC2034  # both are consumed by the sourced build_common.sh
PKG_NAME=devshell
# shellcheck disable=SC2034
PKG_VERSION=0
# shellcheck source=lib/build_common.sh
. "${TOPDIR:?TOPDIR must be set -- run this through 'make shell'}/lib/build_common.sh"
rmdir "${BUILD_TMP}" 2>/dev/null || true

# Drop the source-manifest EXIT trap build_common.sh just installed.  It exists
# so that every PACKAGE records what it added to $STACK, and prune.sh treats
# those paths as untouchable -- correct for a recipe, wrong for a shell.  Left
# in place, merely opening and closing 'make shell' rewrites
# $STACK/etc/source-files.txt, which is to say a read-only-looking target
# mutates the artifact, and what the manifest says starts to depend on who
# opened a terminal and when.  Anything you actually want recorded should be
# installed by a recipe and built with 'make <pkg>', which records it properly.
trap - EXIT
rm -f "${WORK}/manifest/devshell.before"

activate_toolchain

# A compact banner, not list_build_env.  list_build_env dumps all of printenv
# because it is written for a log file read after a three-hour failure; a
# terminal wants the six variables you are about to get wrong.  It stays
# defined, and the banner says so.
__devshell_banner () {
  local mpicxx_drives
  # What mpicxx actually resolves its compiler to.  This is the line that
  # distinguishes this shell from the old one, so it is worth the two forks:
  # field 1 of 'mpicxx -show' is the compiler name, and 'command -v' says which
  # binary that name means under the PATH we just built.
  mpicxx_drives="$(command -v "$(mpicxx -show 2>/dev/null | awk '{print $1}')" 2>/dev/null)"

  printf '\n  stack   %s\n' "${STACK}"
  printf '  profile %s  %s  %s/%s  isa %s\n\n' \
    "${PROFILE:-?}" "${TARGET_PLATFORM:-?}" "${BLAS_PROVIDER:-?}" \
    "${MPI_FAMILY:-?}" "${ISA_BASELINE:-?}"
  printf '  %-16s %s\n' \
    CC       "${CC:-<unset>}" \
    CXX      "${CXX:-<unset>}" \
    FC       "${FC:-<unset>}" \
    CPPFLAGS "${CPPFLAGS:-<unset>}" \
    LDFLAGS  "${LDFLAGS:-<unset>}" \
    PKG_CONFIG_PATH "${PKG_CONFIG_PATH:-<unset>}" \
    'mpicxx drives' "${mpicxx_drives:-<not found>}"
  printf '\n  This is the environment pkgs/*/build.sh gets.  Run list_build_env\n'
  printf '  for the full dump, or print-config from the repo for the knobs.\n\n'
}

case "$-" in
  *i*) __devshell_banner ;;
esac

# Restore the caller's options.  For an interactive shell this is the whole
# point: build_common.sh turned on 'set -euo pipefail', which is right for a
# recipe and fatal for a terminal -- 'set -e' would close the window on the
# first non-zero exit, so a mistyped grep would log you out.  For shell-check,
# which sets -euo pipefail itself, this restores exactly that.
eval "${__devshell_opts}"
unset __devshell_opts

# Say plainly which shell this is.  A shell that IS the build environment and
# one that merely has $STACK/bin on PATH are otherwise indistinguishable, and
# that ambiguity is what this file exists to remove.
case "$-" in
  *i*) PS1="(stack) ${PS1:-\w\$ }" ;;
esac
