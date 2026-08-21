#!/usr/bin/env bash
# Runs every leechblock lib test. Used directly as the coverage subject:
# meta/scripts/shell_coverage.sh wants the test script itself, not `bash <it>`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rc=0
for t in "$HERE"/test_leechblock_*.sh; do
	printf '\n=== %s ===\n' "$(basename "$t")"
	# Each suite exits non-zero on failure; keep going so one red suite does not
	# hide the state of the others, then fail the run as a whole.
	# Invoked directly, NOT as `bash "$t"`: under kcov the latter instruments
	# bash itself and reports zero lines for every lib.
	"$t" || rc=1
done

exit "$rc"
