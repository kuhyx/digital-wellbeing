#!/bin/bash
# Runs every suite in this repo: the top-level regression tests beside this
# file, plus each lib/tests/run_all.sh from the 250-line-cap splits.
#
# The lib runners are DISCOVERED rather than listed. A hardcoded list silently
# leaves each new split running only on its author's machine -- four such
# runners already existed in the monorepo and none ran in CI until discovery
# was added there.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

failed=0
run_one() {
	local label="$1" cmd="$2"
	printf '\n=== %s ===\n' "$label"
	if bash "$cmd"; then
		printf 'PASS %s\n' "$label"
	else
		printf 'FAIL %s\n' "$label"
		failed=$((failed + 1))
	fi
}

for t in "$SCRIPT_DIR"/test_*.sh; do
	[[ -f $t ]] || continue
	run_one "$(basename "$t")" "$t"
done

# vendor/ is a verbatim copy of the monorepo lib; it is tested there.
while IFS= read -r r; do
	run_one "$r" "$r"
done < <(find "$REPO_DIR" -path "$REPO_DIR/vendor" -prune -o \
	-path '*/lib/tests/run_all.sh' -print | sort)

if [[ $failed -gt 0 ]]; then
	printf '\n%d suite(s) failed\n' "$failed"
	exit 1
fi
printf '\nAll digital-wellbeing suites passed.\n'
