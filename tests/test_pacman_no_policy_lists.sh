#!/bin/bash
# The pacman wrapper no longer carries package policy lists: the blocked
# keywords, whitelist and greylist were retired on 2026-10-17 because hosts /
# DNS blocking now covers what they guarded. This asserts the lists, every
# piece of code that read them, and every copy the installer used to deploy
# are gone, and that re-running the installer purges stale deployed copies
# (including the chattr +i greylist).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WRAPPER_DIR="$REPO_DIR/pacman"
readonly RETIRED=(pacman_blocked_keywords.txt pacman_whitelist.txt pacman_greylist.txt)

failed=0
pass() { echo "✓ $1"; }
fail() {
	echo "✗ $1"
	failed=1
}

echo "[TEST] Policy list files are deleted from the repo..."
for f in "${RETIRED[@]}"; do
	if [[ -e "$WRAPPER_DIR/$f" ]]; then fail "$f still exists"; else pass "$f removed"; fi
done
if [[ -e "$WRAPPER_DIR/allow_and_install.sh" ]]; then
	fail "allow_and_install.sh (whitelist shipper) still exists"
else
	pass "allow_and_install.sh removed"
fi

echo "[TEST] No code still reads or enforces the lists..."
# The installer's purge helper is the one place allowed to name the files.
pattern='whitelist|greylist|blocked_keywords|BLOCKED_KEYWORDS|is_blocked_package_name|check_for_always_blocked|remove_installed_blocked_packages|strip_pkgfile_suffix'
hits="$(git -C "$REPO_DIR" grep -nIE "$pattern" -- pacman tests \
	':!tests/test_pacman_no_policy_lists.sh' ':!pacman/lib/install_files.sh' || true)"
if [[ -n $hits ]]; then
	fail "list references remain:"
	printf '  %s\n' "$hits" | head -40
else
	pass "no list references in pacman/ or tests/"
fi

echo "[TEST] Installer purges stale deployed copies..."
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
for f in "${RETIRED[@]}"; do printf 'stale\n' >"$fixture/$f"; done
(
	# shellcheck disable=SC2034 # colour vars and INSTALL_DIR are read by the sourced libs
	RED='' YELLOW='' GREEN='' BLUE='' CYAN='' NC='' INSTALL_DIR="$fixture"
	# shellcheck source=../pacman/lib/managed_copy.sh
	source "$WRAPPER_DIR/lib/managed_copy.sh"
	# shellcheck source=../pacman/lib/install_files.sh
	source "$WRAPPER_DIR/lib/install_files.sh"
	remove_retired_policy_files
) >/dev/null 2>&1 || true
for f in "${RETIRED[@]}"; do
	if [[ -e "$fixture/$f" ]]; then fail "installer left $f deployed"; else pass "installer purges $f"; fi
done

exit "$failed"
