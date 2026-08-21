#!/usr/bin/env bash
# Runs every digital_wellbeing lib test. Used directly as the coverage subject:
# meta/scripts/shell_coverage.sh wants the test script itself, not `bash <it>`.
#
# The glob is test_*.sh, NOT one prefix per split: this directory holds suites
# for several entry scripts (leechblock, block_compulsive_opening, ...), and a
# prefix glob silently skips every suite added after it — including in the CI
# discovery step, which runs this file.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rc=0
for t in "$HERE"/test_*.sh; do
	printf '\n=== %s ===\n' "$(basename "$t")"
	# Each suite exits non-zero on failure; keep going so one red suite does not
	# hide the state of the others, then fail the run as a whole.
	# Invoked directly, NOT as `bash "$t"`: under kcov the latter instruments
	# bash itself and reports zero lines for every lib.
	"$t" || rc=1
done

exit "$rc"
