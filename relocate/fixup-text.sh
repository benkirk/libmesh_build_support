#!/usr/bin/env bash
# relocate/fixup-text.sh -- remove the build prefix from generated text files.
#
# patchelf handles the RPATHs, which is what the loader needs.  This handles
# what the *build tools* need: pkg-config files, compiler wrappers and config
# scripts that were generated with an absolute prefix baked in.  Without it the
# tree runs anywhere but can only be compiled against where it was built.
#
# Two mechanisms, chosen because each is the idiom the consuming tool already
# supports -- we are not inventing a relocation scheme, just using theirs:
#
#   *.pc          prefix=${pcfiledir}/../..     pkg-config expands pcfiledir to
#                                               the directory of the .pc itself
#   shell wrappers  prefix="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
#                                               then every literal path becomes
#                                               ${prefix}/...
#
# Binary files with an embedded prefix are NOT rewritten here.  Conda pads them
# to a fixed 255-byte field, so they can be rewritten in place, but none of them
# are load-bearing for us -- the load-bearing case is RPATH, and patchelf owns
# that.  They are inventoried instead, and validate.sh asserts on the list.
#
# Idempotent: already-fixed files carry a marker and are skipped.
set -euo pipefail

: "${STACK:?}"
MARKER='# relocated-by-libmesh_build_support'
REPORT="${WORK:-/tmp}/relocate/fixup-report.txt"
mkdir -p "$(dirname "${REPORT}")"

pc_fixed=0 sh_fixed=0 skipped=0

#------------------------------------------------------------------------------
# pkg-config files.  ${pcfiledir} has been supported since pkg-config 0.29 and
# is the sanctioned way to write a relocatable .pc.
while IFS= read -r f; do
  grep -q "${MARKER}" "$f" 2>/dev/null && { skipped=$((skipped + 1)); continue; }
  # How far up from this .pc to the prefix root?
  rel="$(realpath --relative-to="$(dirname "$f")" "${STACK}")"
  up="\${pcfiledir}/${rel}"
  tmp="$f.tmp.$$"
  {
    echo "${MARKER}"
    sed -e "s|^\(prefix=\)${STACK}\$|\1${up}|" \
        -e "s|^\(exec_prefix=\)${STACK}\$|\1${up}|" \
        -e "s|${STACK}|${up}|g" "$f"
  } > "${tmp}"
  mv -f "${tmp}" "$f"
  pc_fixed=$((pc_fixed + 1))
done < <(find "${STACK}" -name '*.pc' -type f 2>/dev/null)

#------------------------------------------------------------------------------
# Shell-script wrappers: mpicc, mpicxx, mpifort, *-config, and friends.
#
# The injected preamble must come after the shebang but before the script's own
# 'prefix=' assignment, which then becomes the no-op 'prefix=${prefix}'.  That
# is deliberate -- it means we do not have to know which variable each wrapper
# uses, only that our value lands first.
while IFS= read -r f; do
  grep -q "${MARKER}" "$f" 2>/dev/null && { skipped=$((skipped + 1)); continue; }
  LC_ALL=C grep -qI . "$f" 2>/dev/null || continue          # skip binaries
  LC_ALL=C grep -q "${STACK}" "$f" 2>/dev/null || continue  # nothing to do
  # One pattern, not four: '*sh' already matches '...bash', and '#!'* already
  # matches '#! '*.  The other three were redundant rather than wrong, but they
  # read as if they covered cases this one does not.
  case "$(head -c 128 "$f" | head -1)" in
    '#!'*sh) ;;
    *) continue ;;                                          # not a shell script
  esac

  rel="$(realpath --relative-to="$(dirname "$f")" "${STACK}")"
  tmp="$f.tmp.$$"
  {
    head -1 "$f"
    echo "${MARKER}"
    echo "prefix=\"\$(cd \"\$(dirname \"\$(readlink -f \"\${BASH_SOURCE[0]:-\$0}\")\")/${rel}\" && pwd)\""
    # Put our own bin/ on PATH from inside the wrapper.  mpicc invokes the
    # compiler by bare name -- 'aarch64-conda-linux-gnu-cc' -- so without this
    # it fails with a bare "command not found" naming a compiler the user has
    # never heard of, unless they happened to source activate.sh first.  Making
    # the wrapper self-sufficient removes a documented footgun rather than
    # documenting it again.
    echo "PATH=\"\${prefix}/bin:\${PATH}\""
    tail -n +2 "$f" | sed -e "s|${STACK}|\${prefix}|g"
  } > "${tmp}"
  chmod --reference="$f" "${tmp}"
  mv -f "${tmp}" "$f"
  sh_fixed=$((sh_fixed + 1))
done < <(find "${STACK}/bin" "${STACK}/sbin" "${STACK}/libexec" "${STACK}/contrib/bin" \
              -type f 2>/dev/null)

#------------------------------------------------------------------------------
# Source-built packages bring their own build-integration metadata, and it bakes
# the prefix in formats the two passes above do not cover: GNU make fragments
# and CMake package configs.  On a conda-only tree there were none of these; the
# three source packages install 105 of them.
#
# Same principle as above -- use the idiom the consuming tool already has:
#
#   make    $(dir $(realpath $(lastword $(MAKEFILE_LIST))))
#   cmake   ${CMAKE_CURRENT_LIST_DIR}
#
# both being the directory of the file currently being parsed, so each fragment
# is right whether it is used directly or included from somewhere else entirely.
#
# The $(realpath ...) is not decoration.  libMesh installs Make.common at
# etc/libmesh/Make.common AND symlinks it as <prefix>/Make.common, and that
# symlink is the path the example Makefiles include.  Without realpath,
# $(dir $(lastword $(MAKEFILE_LIST))) yields the SYMLINK's directory -- the
# prefix root -- so a depth computed for etc/libmesh/ climbed two levels too
# far and resolved to "/opt".  Measured, by asking make what it got rather than
# by checking that the old path was gone.
#
# The injected variable is numbered per file for the same class of reason: these
# fragments include one another, a plain shared name would let the last one
# parsed win, and 'LIBMESH_DIR ?= $(...)' is recursively expanded, so it would
# pick up whatever that name meant at the end rather than at its own line.
#
# Both are evaluated at parse time by the tool itself, so a consumer who unpacks
# the tarball anywhere gets correct paths without being told to run anything.
mk_fixed=0 cm_fixed=0

rel_up () { realpath --relative-to="$(dirname "$1")" "${STACK}"; }

# fix_generated FILE PREAMBLE REPLACEMENT
fix_generated () {
  local f="$1" preamble="$2" repl="$3" tmp
  LC_ALL=C grep -qI . "$f" 2>/dev/null || return 0          # binary
  LC_ALL=C grep -q "${STACK}" "$f" 2>/dev/null || return 0  # nothing to do
  grep -q "${MARKER}" "$f" 2>/dev/null && { skipped=$((skipped + 1)); return 0; }
  tmp="$f.tmp.$$"
  {
    echo "${MARKER}"
    echo "${preamble}"
    sed -e "s|${STACK}|${repl}|g" "$f"
  } > "${tmp}"
  chmod --reference="$f" "${tmp}"
  mv -f "${tmp}" "$f"
}

nvar=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  rel="$(rel_up "$f")"
  before=$(LC_ALL=C grep -c "${STACK}" "$f" 2>/dev/null) || before=0
  nvar=$((nvar + 1))
  fix_generated "$f" \
    "__stack_prefix_${nvar} := \$(abspath \$(dir \$(realpath \$(lastword \$(MAKEFILE_LIST))))${rel})" \
    "\$(__stack_prefix_${nvar})"
  [ "${before}" -gt 0 ] && mk_fixed=$((mk_fixed + 1))
done < <(
  find "${STACK}/examples" -name 'Makefile' -type f 2>/dev/null
  find "${STACK}/lib/petsc/conf" -type f \
       ! -name '*.py' ! -name 'configure-hash' 2>/dev/null | grep -v '/modules/'
  find "${STACK}/share/petsc" -name 'gmakefile*' -type f 2>/dev/null
  ls "${STACK}/etc/libmesh/Make.common" "${STACK}/lib/pkgconfig/Make.common" 2>/dev/null
)

# NOTE on CMake bracket arguments: TriBITS records the compiler flags it was
# built with as [[ ... ]] literals, and CMake does not expand variables inside
# those.  The substitution still removes the machine-specific path -- which is
# what the gate is about -- but those particular strings are provenance, not
# something a consumer resolves.  Trilinos_INCLUDE_DIRS and friends are ordinary
# quoted set() calls and do expand correctly.
while IFS= read -r f; do
  [ -f "$f" ] || continue
  rel="$(rel_up "$f")"
  before=$(LC_ALL=C grep -c "${STACK}" "$f" 2>/dev/null) || before=0
  nvar=$((nvar + 1))
  fix_generated "$f" \
    "get_filename_component(__stack_prefix_${nvar} \"\${CMAKE_CURRENT_LIST_DIR}/${rel}\" REALPATH)" \
    "\${__stack_prefix_${nvar}}"
  [ "${before}" -gt 0 ] && cm_fixed=$((cm_fixed + 1))
done < <(find "${STACK}/lib" -name '*.cmake' -type f 2>/dev/null)

#------------------------------------------------------------------------------
# Libtool archives are a relocation landmine -- they carry absolute dependency
# paths that nothing rewrites and that break silently.  The plan says drop them
# wholesale; do it here so the residue report below is honest.
la_removed="$(find "${STACK}" -name '*.la' -type f -print -delete 2>/dev/null | wc -l)"

#------------------------------------------------------------------------------
# HDF5 bakes an absolute plugin directory into its public header, so every
# consumer that includes H5pubconf.h would inherit OUR build path.  There is no
# relative form for a #define, so reset it to HDF5's own upstream default rather
# than inventing one.  We ship no HDF5 filter plugins, so nothing looks there.
h5conf="${STACK}/include/H5pubconf.h"
if [ -f "${h5conf}" ] && grep -q "${STACK}" "${h5conf}"; then
  sed -i "s|\"${STACK}[^\"]*\"|\"/usr/local/hdf5/lib/plugin\"|g" "${h5conf}"
  echo "fixup: reset H5_DEFAULT_PLUGINDIR in H5pubconf.h"
fi

#------------------------------------------------------------------------------
# Provenance strings, which have no relative form at all.
#
# A C '#define' cannot be made self-locating, and neither can a hash or a
# settings report.  These record HOW the stack was built -- PETSc's
# PETSC_MPICC_SHOW, libMesh's LIBMESH_CONFIGURE_INFO, netcdf's build report --
# and every one of them names a directory that will not exist on the machine
# the tarball is unpacked on.
#
# So neutralise rather than rewrite, which is the same call already made for
# H5pubconf.h above: replace the path with something that is obviously not a
# path.  A stale absolute path invites a consumer to resolve it and silently get
# nothing; a visible placeholder tells them what happened.  PETSC_DIR is the one
# that could in principle be used rather than merely read, and pointing it at a
# directory that no longer exists is not better than pointing it at a marker.
#
# BUILD_ROOT is handled here too, and only here: paths into $BUILD_ROOT/.work
# refer to a build tree that is never shipped under any name, so there is
# nothing to make them relative TO.
NEUTRAL='@LIBMESH_STACK_BUILD_PREFIX_REMOVED@'
prov_fixed=0
while IFS= read -r f; do
  LC_ALL=C grep -qI . "$f" 2>/dev/null || continue
  sed -i -e "s|${STACK}|${NEUTRAL}|g" "$f"
  prov_fixed=$((prov_fixed + 1))
done < <(
  find "${STACK}/include" -type f \( -name '*.h' -o -name '*.hpp' \) 2>/dev/null \
    | xargs -r grep -l "${STACK}" 2>/dev/null
  find "${STACK}/lib/petsc/conf" -type f \
       \( -name '*.py' -o -name 'configure-hash' \) 2>/dev/null
  find "${STACK}/lib/petsc/conf/modules" -type f 2>/dev/null
  ls "${STACK}/lib/libnetcdf.settings" 2>/dev/null
)

# References to the BUILD TREE -- $BUILD_ROOT/.work and $BUILD_ROOT/.conda --
# which name directories that are never shipped under any name, so there is
# nothing to make them relative to.
#
# Restricted to those two subdirectories ON PURPOSE.  $STACK is itself
# $BUILD_ROOT/stack, so a sweep over the whole of $BUILD_ROOT matches every
# prefix path in the tree and neutralises paths the passes above are supposed to
# rewrite relatively -- 460 files on the first attempt, against the ~11 that
# actually needed it.  Blunt instruments here do not fail loudly; they quietly
# replace working configuration with a placeholder.
if [ -n "${BUILD_ROOT:-}" ] && [ "${BUILD_ROOT}" != "${STACK}" ]; then
  while IFS= read -r f; do
    LC_ALL=C grep -qI . "$f" 2>/dev/null || continue
    # '#' as the delimiter, not '|': the alternation below contains a '|', and
    # with '|' as the delimiter sed reads it as the end of the pattern.
    sed -i -E "s#${BUILD_ROOT}/\.(work|conda)[^\"'[:space:]]*#${NEUTRAL}#g" "$f"
    prov_fixed=$((prov_fixed + 1))
  done < <(LC_ALL=C grep -rlE "${BUILD_ROOT}/\.(work|conda)" "${STACK}" 2>/dev/null || true)
fi

#------------------------------------------------------------------------------
# The shipped activation script.  Installed here rather than at conda time
# because it belongs to the relocated artifact, not to the build environment.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "${HERE}/../stack/activate.sh.in" ]; then
  install -m 0644 "${HERE}/../stack/activate.sh.in" "${STACK}/activate.sh"
  echo "fixup: installed activate.sh"
fi

#------------------------------------------------------------------------------
# Inventory whatever still names the build prefix.  Deliberately scans BINARY
# files too: 'grep -rI' skips them, which would hide a prefix baked into an ELF
# -- the exact failure that breaks relocation.  See amendment A5.
: > "${REPORT}"
while IFS= read -r f; do
  if LC_ALL=C grep -qI . "$f" 2>/dev/null; then kind=text; else kind=binary; fi
  echo "${kind} ${f#"${STACK}"/}" >> "${REPORT}"
done < <(LC_ALL=C grep -rla "${STACK}" "${STACK}" 2>/dev/null || true)

echo "fixup: ${pc_fixed} .pc, ${sh_fixed} wrappers, ${mk_fixed} make, ${cm_fixed} cmake," \
     "${prov_fixed} provenance, ${skipped} already done, ${la_removed} .la removed"
echo "fixup: residue -> ${REPORT}"
awk '{print $1}' "${REPORT}" | sort | uniq -c | sed 's/^/  /'
