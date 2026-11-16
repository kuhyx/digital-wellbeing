#!/bin/bash
# The pacman wrapper no longer gates Steam. Since 2026-11-16 steam-backlog-
# enforcer is the only thing that blocks, removes or allows Steam; the old
# weekday block and weekend word-scramble challenge here fought with it (the
# enforcer lifted its block, the wrapper still refused the reinstall). This
# asserts the gate, its helpers and the challenge dictionary are gone, and
# that the installer purges a stale deployed words.txt.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WRAPPER_DIR="$REPO_DIR/pacman"

failed=0
pass() { echo "✓ $1"; }
fail() {
	echo "✗ $1"
	failed=1
}

echo "[TEST] Challenge dictionary is deleted from the repo..."
if [[ -e "$WRAPPER_DIR/words.txt" ]]; then fail "words.txt still exists"; else pass "words.txt removed"; fi

echo "[TEST] No code still gates Steam..."
# The installer's purge helper is the one place allowed to name words.txt.
pattern='check_for_steam|is_steam_package|steam_challenge|is_weekday|run_word_challenge|current_day_name|current_day_of_week|current_hour_24|WORDS_(SOURCE|DEST)'
hits="$(git -C "$REPO_DIR" grep -nIE "$pattern" -- pacman tests \
	':!tests/test_pacman_no_steam_gate.sh' || true)"
if [[ -n $hits ]]; then
	fail "Steam gate references remain:"
	printf '  %s\n' "$hits" | head -40
else
	pass "no Steam gate references in pacman/ or tests/"
fi

echo "[TEST] Policy still lets steam through (check_for_steam undefined)..."
set +e
(
	# shellcheck source=../pacman/pw_policy.sh
	source "$WRAPPER_DIR/pw_policy.sh"
	! declare -F check_for_steam >/dev/null
)
then_rc=$?
set -e
if ((then_rc == 0)); then pass "pw_policy.sh defines no Steam check"; else fail "pw_policy.sh still defines check_for_steam"; fi

echo "[TEST] Installer purges a stale deployed words.txt..."
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
printf 'STALE\n' >"$fixture/words.txt"
(
	# shellcheck disable=SC2034 # colour vars and INSTALL_DIR are read by the sourced libs
	RED='' YELLOW='' GREEN='' BLUE='' CYAN='' NC='' INSTALL_DIR="$fixture"
	# shellcheck source=../pacman/lib/managed_copy.sh
	source "$WRAPPER_DIR/lib/managed_copy.sh"
	# shellcheck source=../pacman/lib/install_files.sh
	source "$WRAPPER_DIR/lib/install_files.sh"
	remove_retired_policy_files
) >/dev/null 2>&1 || true
if [[ -e "$fixture/words.txt" ]]; then fail "installer left words.txt deployed"; else pass "installer purges words.txt"; fi

# shellcheck disable=SC2031 # only the subshells above fork; fail() runs in the main shell
exit "$failed"
