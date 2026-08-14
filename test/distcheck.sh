#!/usr/bin/env bash
# Step 7: tar -> remove the original tree -> untar at a DIFFERENT path depth
# -> validate -> run the smoke test.  The depth change is deliberate: it is
# what catches a hard-coded ../.. assumption that a same-depth move would hide.
set -euo pipefail
echo "test/distcheck.sh: not implemented yet (sprint item S5)" >&2
exit 1
