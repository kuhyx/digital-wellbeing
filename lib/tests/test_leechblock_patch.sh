#!/usr/bin/env bash
# Covers replace_browser_in_place's exec-line patching: one --load-extension.
#
# Chromium keeps only the LAST --load-extension switch. Before 2026-10-10 the
# "already patched" check matched only the lone-path form, so once uBlock or
# leetcode-guard had been comma-joined into the flag, every pacman -S appended
# a second LeechBlock-only flag that silently dropped the others.
#
# Safe to execute: sudo, pkill and sleep are shell functions here, and the
# "browser" is a script in the test's temp dir found through PATH.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=leechblock_harness.sh
source "$HERE/leechblock_harness.sh"
# shellcheck source=../leechblock_browsers.sh
source "$LEECHBLOCK_LIB_DIR/leechblock_browsers.sh"

_t_setup_shims
trap _t_teardown EXIT

sudo() { "$@"; }
pkill() { :; }
sleep() { :; }
info() { :; }

# Read by the sourced lib, which shellcheck cannot trace.
# shellcheck disable=SC2034
EXT_PATH="/opt/leech/current"
found_any=0
readonly BROWSER="$SHIM_DIR/fakebrowser"

# Writes a wrapper whose exec line is $1, patches it twice (the second run must
# be a no-op) and prints the resulting exec line.
patched_twice() {
	printf '#!/usr/bin/env bash\nreal_bin=/bin/true\n%s\n' "$1" >"$BROWSER"
	chmod +x "$BROWSER"
	rm -f "$BROWSER.orig"
	replace_browser_in_place fakebrowser Fake
	replace_browser_in_place fakebrowser Fake
	grep '^exec' "$BROWSER"
}

flag_count() {
	grep -o -- '--load-extension=' <<<"$1" | wc -l
}

# shellcheck disable=SC2016 # the exec lines are literal wrapper text
{
	printf 'a wrapper with no flag gets exactly one\n'
	got="$(patched_twice 'exec "$real_bin" "$@"')"
	_t_eq 'exec "$real_bin" --load-extension="/opt/leech/current" "$@"' "$got" \
		"the flag is inserted before \"\$@\""

	printf '\nan existing list is extended, never joined by a second flag\n'
	got="$(patched_twice 'exec "$real_bin" --load-extension="/x/ublock,/y/lg" "$@"')"
	_t_eq 'exec "$real_bin" --load-extension="/x/ublock,/y/lg,/opt/leech/current" "$@"' \
		"$got" "LeechBlock joins the list"
	_t_eq "1" "$(flag_count "$got")" "one --load-extension after two runs"

	printf '\nLeechBlock inside a joined list counts as already patched\n'
	got="$(patched_twice 'exec "$real_bin" --load-extension="/x/ublock,/opt/leech/current,/y/lg" "$@"')"
	_t_eq "1" "$(flag_count "$got")" "no second flag is appended"
	_t_has "$got" "/x/ublock,/opt/leech/current,/y/lg" "the list is left as it was"
}

_t_report "test_leechblock_patch"
