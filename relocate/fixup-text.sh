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
  case "$(head -c 128 "$f" | head -1)" in
    '#!'*sh|'#!'*bash|'#! '*sh|'#! '*bash) ;;
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
done < <(find "${STACK}/bin" "${STACK}/sbin" "${STACK}/libexec" \
              -type f 2>/dev/null)

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

echo "fixup: ${pc_fixed} .pc, ${sh_fixed} wrappers, ${skipped} already done, ${la_removed} .la removed"
echo "fixup: residue -> ${REPORT}"
awk '{print $1}' "${REPORT}" | sort | uniq -c | sed 's/^/  /'
