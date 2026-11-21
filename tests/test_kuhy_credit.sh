#!/bin/bash
# The kuhy credit (kuhy_credit terminal stack, vendored from kuhyx/utils) must
# appear in every CLI's help and at the end of every installer's success
# output. It must never appear on the enforcement path (pacman refusal,
# shutdown/lockdown runtime): kuhy_credit's README keeps lockers credit-free.
#
# The help checks run the real scripts without root. The installers need root,
# so they are checked statically: their last executed line calls kuhy_credit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
readonly URL="https://kuhy.duckdns.org"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

# 1. The vendored terminal stack exists and prints the credit line.
[[ -f $REPO_DIR/vendor/kuhy-credit.sh ]] || fail "vendor/kuhy-credit.sh missing"
[[ "$(bash "$REPO_DIR/vendor/kuhy-credit.sh")" == "Created by kuhy $URL" ]] ||
	fail "vendor/kuhy-credit.sh prints the wrong line"
[[ -f $REPO_DIR/vendor/kuhy-credit.svg ]] || fail "vendor/kuhy-credit.svg missing"
echo "  OK: vendored credit prints its line"

# 2. Every CLI help ends with the credit (run for real, no root needed).
for cmd in "setup_night_lockdown.sh help" "block_compulsive_opening.sh help" \
	"setup_midnight_shutdown.sh help"; do
	# shellcheck disable=SC2086 # cmd is "<script> <arg>", split on purpose
	out="$(cd "$REPO_DIR" && bash $cmd 2>&1 || true)"
	[[ "$(tail -n 1 <<<"$out")" == *"$URL"* ]] || fail "$cmd does not end with the credit"
	echo "  OK: $cmd ends with the credit"
done

# 3. Each installer calls kuhy_credit as its last command.
for f in install_ublock.sh install_leechblock.sh pacman/install_pacman_wrapper.sh \
	pacman/install_makepkg_wrapper.sh work_laptop/food_block/install.sh; do
	last="$(grep -vE '^\s*(#|$)' "$REPO_DIR/$f" | tail -n 1)"
	[[ $last == kuhy_credit ]] || fail "$f does not end with kuhy_credit (last: $last)"
	echo "  OK: $f ends with kuhy_credit"
done

# 4. The helper stays silent when the vendored file is missing (a copied
#    installer must never fail over a credit line).
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/lib"
cp "$REPO_DIR/lib/kuhy_credit.sh" "$tmp/lib/"
out="$(bash -c "source '$tmp/lib/kuhy_credit.sh'; kuhy_credit; echo rc=\$?" 2>&1)"
[[ $out == "rc=0" ]] || fail "kuhy_credit without vendor file printed: $out"
echo "  OK: kuhy_credit is silent without the vendored file"

# 5. The enforcement path stays credit-free.
if grep -lE 'kuhy_credit|kuhy-credit' "$REPO_DIR"/pacman/pacman_wrapper.sh \
	"$REPO_DIR"/pacman/pw_*.sh "$REPO_DIR"/lib/payloads/*.sh >/dev/null 2>&1; then
	fail "enforcement path references the credit"
fi
echo "  OK: enforcement path is credit-free"
