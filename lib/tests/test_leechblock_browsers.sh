#!/usr/bin/env bash
# Covers lib/leechblock_browsers.sh's detection table and dispatch logic.
#
# replace_browser_in_place is NOT executed: it pkills browsers and rewrites
# system binaries under sudo. What is asserted here is everything that decides
# *whether* it runs and *what* it would be handed — the table itself, the
# global-scope contract, and the command-v gating in wire_up_browsers.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=leechblock_harness.sh
source "$HERE/leechblock_harness.sh"
# shellcheck source=../leechblock_browsers.sh
source "$LEECHBLOCK_LIB_DIR/leechblock_browsers.sh"

_t_setup_shims
trap _t_teardown EXIT

HOME="$TEST_TMPDIR/home"
XDG_DATA_HOME="$TEST_TMPDIR/home/.local/share"

# Assigned by wire_up_browsers in the sourced lib. Declared here so the
# assertions below read as checking a known variable rather than tripping
# SC2154 on something shellcheck cannot trace across the source boundary.
ff_found=0

printf 'detect_browsers: the tables survive as globals\n'
# declare -A inside a function is function-local; the pre-split code ran at top
# level. If the -g were ever dropped these counts would be 0 and every browser
# would silently go unwired, so assert the count rather than just a lookup.
detect_browsers
_t_eq "8" "${#BROWSERS[@]}" "all eight Chromium-family browsers are present"
_t_eq "3" "${#FIREFOXES[@]}" "all three Firefox-family browsers are present"

printf '\ndetect_browsers: hyphenated keys resolve\n'
# The subscripts are QUOTED deliberately. shfmt -w rewrites an unquoted
# ${BROWSERS[google-chrome-stable]} into arithmetic
# (the key becomes a subtraction expression), which resolves to the empty key and
# makes every one of these assertions read an absent entry. Reproduced in this
# very file during the split; quoting is what makes shfmt leave it alone.
_t_eq "Google Chrome" "${BROWSERS["google-chrome-stable"]}" "google-chrome-stable maps to its pretty name"
_t_eq "Brave" "${BROWSERS["brave-browser"]}" "brave-browser maps to its pretty name"
_t_eq "Vivaldi" "${BROWSERS["vivaldi-stable"]}" "vivaldi-stable maps to its pretty name"
_t_eq "Thorium" "${BROWSERS["thorium-browser"]}" "thorium-browser maps to its pretty name"
_t_eq "Firefox Developer Edition" "${FIREFOXES["firefox-developer-edition"]}" "firefox-developer-edition maps to its pretty name"

printf '\ndetect_browsers: it creates the user applications directory\n'
if [[ -d "$XDG_DATA_HOME/applications" ]]; then
	_t_pass "the desktop-entry directory is created"
else
	_t_fail "the desktop-entry directory is missing"
fi
_t_eq "0" "$found_any" "found_any starts at zero"

printf '\nwire_up_browsers: no installed browser means nothing is patched\n'
# This machine really does have Chromium and Firefox installed, so PATH must be
# narrowed to the shim dir for "nothing installed" to be testable at all.
# _t_setup_shims seeded that dir with the utilities the function needs, so
# narrowing hides the browsers without breaking the code under test.
_t_isolate_path
replace_browser_in_place() {
	printf 'PATCHED %s\n' "$1" >>"$TEST_TMPDIR/patched"
	found_any=1
}
: >"$TEST_TMPDIR/patched"
wire_up_browsers >"$TEST_TMPDIR/wire.out" 2>&1
_t_restore_path
_t_eq "0" "$(wc -l <"$TEST_TMPDIR/patched")" "no browser present means no binary is touched"
_t_eq "0" "$ff_found" "no Firefox present leaves ff_found at zero"
_t_has "$(cat "$TEST_TMPDIR/wire.out")" "No supported browsers detected" "it reports that nothing was found"

printf '\nwire_up_browsers: an installed browser is dispatched with its pretty name\n'
# SHIM_DIR is first on PATH, so these stand in for a real installed browser.
printf '#!/usr/bin/env bash\nexit 0\n' >"$SHIM_DIR/chromium"
chmod +x "$SHIM_DIR/chromium"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SHIM_DIR/firefox"
chmod +x "$SHIM_DIR/firefox"
: >"$TEST_TMPDIR/patched"
found_any=0
wire_up_browsers >"$TEST_TMPDIR/wire2.out" 2>&1
_t_has "$(cat "$TEST_TMPDIR/patched")" "PATCHED chromium" "an installed Chromium is handed to the patcher"
_t_eq "1" "$ff_found" "an installed Firefox sets ff_found"
_t_has "$(cat "$TEST_TMPDIR/wire2.out")" "Detected Firefox-based browser" "it prints the Firefox guidance"

_t_report "test_leechblock_browsers"
