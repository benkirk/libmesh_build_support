#!/usr/bin/env bash
# relocate/slim.sh -- file-level trimming, in two profiles.
#
#   devel    (default) drop documentation, man pages, __pycache__ and test data;
#            strip unneeded symbols from libraries.  KEEP headers, .pc files,
#            cmake configs and the compiler wrappers -- customers extend this
#            tree, and taking those away would break the template premise.
#   runtime  additionally drop include/, lib/pkgconfig, lib/cmake, *-config
#            scripts and the GPU transport plugins.
#
# ORDERING NOTE: this runs BEFORE relocate/prune.sh, which is the reverse of
# what the plan describes, for a concrete reason found by implementing it --
# 'strip' is provided only by binutils_impl_*, which is on conda/prune.list.
# Pruning first removes the only strip in the tree (the miniforge base has none
# either), so stripping would silently become a no-op exactly when it matters
# most, on the large unstripped source-built libraries.  Trim first, then prune.
#
# Neither profile deletes below whole-package granularity for anything that
# could be dlopen'ed -- that stays prune.sh's job and its rule.  The one
# exception is the UCX CUDA transports under runtime, which are removed
# deliberately and by name: they are optional plugins UCX probes for and skips,
# they cannot work without a host GPU driver, and single-node MPI has no use
# for them.
set -euo pipefail

: "${STACK:?}"
SLIM_PROFILE="${SLIM_PROFILE:-devel}"

case "${SLIM_PROFILE}" in
  devel|runtime) ;;
  *) echo "SLIM_PROFILE must be devel or runtime, got: ${SLIM_PROFILE}" >&2; exit 1 ;;
esac

before=$(du -sk "${STACK}" | awk '{print $1}')
echo "  profile=${SLIM_PROFILE}, starting at $((before / 1024)) MB"

# gone <label> <find-args...>
#
# Counts first, then deletes with -exec rm -rf.  Deliberately NOT find -delete:
# it cannot be combined with -prune, and under 'set -o pipefail' that turns into
# a silent stage failure rather than a visible error.  rm -rf also handles
# directories with content, which -delete will not.
gone () {
  local label="$1"; shift
  local n
  n=$(find "${STACK}" "$@" -print 2>/dev/null | wc -l | tr -d ' ')
  if [ "${n}" -gt 0 ]; then
    find "${STACK}" "$@" -exec rm -rf {} + 2>/dev/null || true
    echo "  removed ${n} ${label}"
  fi
}

#------------------------------------------------------------------------------
# Always: things that are never needed at runtime or build time.
gone "libtool .la files"  -name '*.la' -type f
gone "__pycache__ dirs"   -name '__pycache__' -type d
gone "compiled python"    \( -name '*.pyc' -o -name '*.pyo' \) -type f

# share/terminfo and share/tabset are ncurses' terminal database.  Nothing in a
# compute stack reads them, and terminfo entries bake an absolute path to
# share/tabset/* -- ~150 files of embedded build prefix for capability no
# batch job has ever wanted.
# conda-meta/history is conda's log of the create command, which quotes the
# build prefix verbatim.  The per-package .json files stay: they are the
# license inventory and the manifest is built from them.
rm -f "${STACK}/conda-meta/history"
for d in share/doc share/man share/info share/gtk-doc share/locale man \
         share/terminfo share/tabset; do
  [ -d "${STACK}/${d}" ] || continue
  sz=$(du -sk "${STACK}/${d}" | awk '{print $1}')
  rm -rf "${STACK:?}/${d}"
  echo "  removed ${d} ($((sz / 1024)) MB)"
done

#------------------------------------------------------------------------------
# sbin/ is entirely fabric and Kerberos administration: rdma-ndd, ibacm, iwpmd,
# the ib* diagnostic tools, kpropd, kadmin.local.  Nothing in this stack execs
# any of them, and none is a dlopen target -- so removing them at file level
# does not weaken the whole-package rule, which exists to protect libraries and
# plugins that a dependency closure cannot see.
#
# They are also the single largest source of embedded build paths and of
# unresolved references left after pruning (they link libsystemd/libudev, which
# we drop to hold the glibc floor at 2.28).  Keeping them would mean either
# shipping a 2.34 artifact or shipping known-broken binaries.
if [ -d "${STACK}/sbin" ]; then
  n=$(find "${STACK}/sbin" -type f | wc -l | tr -d ' ')
  rm -rf "${STACK:?}/sbin"
  echo "  removed sbin/ (${n} fabric/kerberos admin binaries)"
fi

#------------------------------------------------------------------------------
# The rest of the fabric-administration surface, now that its binaries are gone:
# systemd unit files for daemons we do not ship, and hwloc's hwdata dumper unit.
# All of them quote the build prefix in ExecStart=.
gone "systemd unit files"  -path "${STACK}/lib/systemd/*"
gone "hwloc systemd units" -path "${STACK}/share/hwloc/*.service"

# Static archives.  Every library in this tree is shipped shared -- that is the
# entire premise -- so a .a is dead weight that also happens to carry the build
# path in its embedded object paths.
gone "static archives" -name '*.a' -type f

# Build-system fragments left behind by icu and openssl: Makefile snippets and a
# perl helper, all quoting the build prefix, none of them reachable from
# anything we ship (perl itself is pruned).
gone "icu build fragments" -path "${STACK}/lib/icu/*" \( -name '*.inc' -o -name 'Makefile*' \)
gone "openssl c_rehash"    -path "${STACK}/bin/c_rehash"

# The last of the fabric-administration surface: sysvinit scripts and modprobe
# fragments for the same RDMA daemons, plus HDF5's build-configuration summary,
# which is a human-readable record of how it was compiled and quotes every path.
gone "rdma init scripts"   -path "${STACK}/etc/init.d/*"
gone "rdma modprobe conf"  -path "${STACK}/etc/modprobe.d/*"
gone "hdf5 build summary"  -path "${STACK}/lib/libhdf5.settings"

#------------------------------------------------------------------------------
# Strip.  Must happen while binutils is still present -- see the ordering note.
STRIP="$(ls "${STACK}"/bin/*-strip 2>/dev/null | head -1 || true)"
[ -x "${STRIP:-}" ] || STRIP="$(command -v strip || true)"
if [ -x "${STRIP:-}" ]; then
  n=0
  nfail=0
  while IFS= read -r -d '' f; do
    [ "$(LC_ALL=C head -c4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' ')" = "7f454c46" ] || continue
    # --strip-unneeded, never --strip-all: the latter can remove the dynamic
    # symbols a shared library exists to provide.
    #
    # Failures stay non-fatal -- that tolerance is deliberate, since a library
    # we cannot strip is a size problem and not a correctness one -- but they
    # are no longer INVISIBLE.  The previous form, '2>/dev/null && n=... ||
    # true', discarded both the message and the status, and CI has been dying
    # in here: SIGBUS on x86-64, SIGSEGV on aarch64, every run.  All the log
    # carried was bash's own "Bus error (core dumped)" line, which names
    # neither the file nor the reason.
    #
    # Decoding the status matters more than capturing stderr, because a process
    # killed by a signal writes nothing to stderr at all -- 128+signum is the
    # whole diagnosis.  So report both, and name the file, which is the part
    # that was missing.
    # -o and rename, rather than stripping in place, and this is the fix for
    # the crash above rather than a style preference.  strip is itself running
    # out of this tree: it is ${STACK}/bin/*-strip, dynamically linked against
    # ${STACK}/lib/libzstd.so.  Rewriting a file that is mmap'd into the
    # running process invalidates those mappings, and the kernel delivers
    # SIGBUS -- which is exactly what CI reported, on libzstd specifically, plus
    # an "unable to copy file" when strip reached its own binary.
    #
    # Writing a new file and renaming over it touches neither mapping: the old
    # inode stays alive for as long as the process holds it, and the directory
    # entry swap is atomic.  Same directory, so the rename cannot cross a
    # filesystem.
    tmp="${f}.strip.$$"
    if err="$("${STRIP}" --strip-unneeded -o "${tmp}" "$f" 2>&1)"; then
      chmod --reference="$f" "${tmp}" 2>/dev/null || true
      mv -f "${tmp}" "$f"
      n=$((n + 1))
    else
      rc=$?   # must be first: anything else here clobbers it
      rm -f "${tmp}"
      nfail=$((nfail + 1))
      # Only the first few.  One systematically bad object should not bury the
      # rest of the slim log, and the count below still reports the total.
      if [ "${nfail}" -le 5 ]; then
        if [ "${rc}" -gt 128 ] && [ "${rc}" -lt 192 ]; then
          why="killed by SIG$(kill -l "$((rc - 128))" 2>/dev/null || echo "?")"
        else
          why="exit ${rc}"
        fi
        echo "  warn: strip ${why}: ${f#"${STACK}"/}${err:+ -- ${err}}"
      fi
    fi
    # Executables too, not just libraries: -g leaves the build directory in
    # DWARF, which shows up as embedded-build-path residue at the final gate.
  done < <(find "${STACK}/lib" "${STACK}/bin" "${STACK}/libexec" \
                -type f ! -name '*.a' -print0 2>/dev/null)
  if [ "${nfail}" -gt 0 ]; then
    # Deliberately not a failure.  It is a number to watch: it was 0 before the
    # source builds landed, and any growth is worth a look.
    echo "  stripped ${n} objects, ${nfail} failed"
  else
    echo "  stripped ${n} objects"
  fi
else
  echo "  warn: no strip found; skipping (binutils already pruned?)"
fi

#------------------------------------------------------------------------------
if [ "${SLIM_PROFILE}" = runtime ]; then
  for d in include lib/pkgconfig lib/cmake share/cmake share/pkgconfig; do
    [ -e "${STACK}/${d}" ] || continue
    rm -rf "${STACK:?}/${d}"
    echo "  removed ${d} (runtime profile)"
  done
  gone "*-config scripts" -path "${STACK}/bin/*-config" -type f
  # Optional GPU transports: dlopen-ed by UCX, unusable without a host driver,
  # and irrelevant to the single-node requirement.  Removed by name rather than
  # by closure, because a closure walk cannot see a dlopen either way.
  gone "UCX GPU transport plugins" -path "${STACK}/lib/ucx/*cuda*"
  gone "UCX GPU-direct plugins"    -path "${STACK}/lib/ucx/*gda*"
fi

after=$(du -sk "${STACK}" | awk '{print $1}')
echo "  ---"
echo "  slim: $((before / 1024)) MB -> $((after / 1024)) MB (freed $(( (before - after) / 1024 )) MB)"
