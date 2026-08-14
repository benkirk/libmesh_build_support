#!/usr/bin/env bash
# relocate/validate.sh -- NOT YET IMPLEMENTED (sprint item S4/S5).
# See docs/RELOCATABLE-STACK-PLAN.md for the specified behaviour.
set -euo pipefail
echo "relocate/validate.sh: not implemented yet (see docs/RELOCATABLE-STACK-PLAN.md)" >&2
exit 1

# S4, specified -- this is the gate.  For every ELF under $STACK, env -i:
#   1. no unresolved ("not found") dependencies
#   2. anything resolving outside $STACK must be in the core allowlist:
#      libc libm libdl libpthread librt libutil libresolv ld-linux linux-vdso
#   3. libstdc++.so.6 and libgcc_s.so.1 MUST resolve inside $STACK
#   4. required GLIBC_/GLIBCXX_/CXXABI_ symbol versions within GLIBC_FLOOR
#   5. no absolute $BUILD_ROOT strings in text files; no .la; no dangling symlinks
# Emits a report, a non-zero exit, and stack/etc/stack-manifest.json.
