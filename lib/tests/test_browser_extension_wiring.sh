#!/usr/bin/env bash
# Covers how an installer wires an unpacked extension into a browser launcher.
#
# On 2026-11-21 install_ublock.sh wrapped /usr/local/bin/browser-preexec-wrapper,
# the shared script every browser name symlinks to. Its exec lines are indented,
# so the "patch the exec line" case missed and the "wrap the binary" case ran:
# it moved the script to .orig (a stale copy already sat there) and exec'd it.
# The script picks the browser from basename "$0", which was now ".orig", so it
# took the --load-extension argument as the browser and every browser died with
# "exec: --: invalid option". These cases pin the rules that stop it:
#   * a launcher that reads ~/.config/<name>-flags.conf gets the extension there,
#     merged into the ONE --load-extension line (Chromium keeps only the last);
#   * a script is patched or left alone, never wrapped;
#   * a wrapped binary always execs the current binary, never a stale .orig.
#
# Safe to execute: sudo, pkill and sleep are shell functions here, and every
# "browser" lives in the test's temp dir, found through PATH.
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
warn() { :; }

# Read by the sourced lib, which shellcheck cannot trace.
# shellcheck disable=SC2034
EXT_PATH="/opt/leech/current"
found_any=0
XDG_CONFIG_HOME="$TEST_TMPDIR/config"
export XDG_CONFIG_HOME
mkdir -p "$XDG_CONFIG_HOME"
readonly REAL_DIR="$TEST_TMPDIR/real"
mkdir -p "$REAL_DIR"

# A dispatcher shaped like browser-preexec-wrapper: one script, many symlinked
# names, the real browser chosen by basename "$0", exec lines indented.
readonly DISPATCH="$SHIM_DIR/browser-preexec-wrapper"
cat >"$DISPATCH" <<DISPATCH
#!/usr/bin/env bash
prog_name="\$(basename "\$0")"
real_bin="$REAL_DIR/\$prog_name"
if [[ \$prog_name == never ]]; then
	exec "\$real_bin" "\$@"
fi
	exec "\$real_bin" "\$@"
DISPATCH
chmod +x "$DISPATCH"
DISPATCH_BEFORE="$(cat "$DISPATCH")"
readonly DISPATCH_BEFORE

# A real browser that just echoes its arguments.
fake_real_browser() {
	printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*"\n' >"$REAL_DIR/$1"
	chmod +x "$REAL_DIR/$1"
	ln -sf "$DISPATCH" "$SHIM_DIR/$1"
}

{
	printf 'a shared dispatcher script is never wrapped\n'
	fake_real_browser thorium-browser
	replace_browser_in_place thorium-browser Thorium || true
	got="$("$SHIM_DIR/thorium-browser" --probe 2>&1 || true)"
	_t_has "$got" "--probe" "the browser still starts through its symlink"
	_t_eq "$DISPATCH_BEFORE" "$(cat "$DISPATCH")" "the dispatcher is left as it was"

	printf '\na launcher with a flags file gets the extension there\n'
	fake_real_browser chromium
	replace_browser_in_place chromium Chromium
	_t_eq "--load-extension=/opt/leech/current" \
		"$(cat "$XDG_CONFIG_HOME/chromium-flags.conf" 2>/dev/null || true)" \
		"chromium-flags.conf carries the flag"
	_t_eq "$DISPATCH_BEFORE" "$(cat "$DISPATCH")" "the dispatcher is still untouched"

	printf '\nseveral --load-extension lines collapse into one, twice over\n'
	fake_real_browser helium-browser
	printf '%s\n' '--password-store=basic' '--load-extension=/a,/b' \
		'--load-extension=/c' >"$XDG_CONFIG_HOME/helium-browser-flags.conf"
	replace_browser_in_place helium-browser Helium
	replace_browser_in_place helium-browser Helium
	_t_eq $'--password-store=basic\n--load-extension=/a,/b,/c,/opt/leech/current' \
		"$(cat "$XDG_CONFIG_HOME/helium-browser-flags.conf")" \
		"one merged line, other flags kept in place"

	printf '\na wrapped binary execs the current binary, not a stale .orig\n'
	readonly ELF="$SHIM_DIR/vivaldi-stable"
	cp "$(type -P echo)" "$ELF"
	printf '#!/usr/bin/env bash\necho STALE\n' >"$ELF.orig"
	chmod +x "$ELF.orig"
	replace_browser_in_place vivaldi-stable Vivaldi
	got="$("$ELF" --probe 2>&1 || true)"
	_t_eq "--load-extension=/opt/leech/current --probe" "$got" \
		"the wrapper runs the binary that was installed"
}

_t_report "test_browser_extension_wiring"
