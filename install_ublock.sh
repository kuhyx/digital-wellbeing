#!/usr/bin/env bash

# uBlock Origin installer/wirer for Arch Linux (and derivatives)
# - Uses the ublock-origin pacman package already unpacked at /usr/lib/ublock-origin
#   (install via `sudo pacman -S ublock-origin` if missing)
# - Wires Chromium-based browsers to auto-load it via --load-extension, alongside
#   any extension a previous installer (e.g. install_leechblock.sh) already wired in
# - Seeds every selectable filter list into the extension's storage so uBO runs in
#   full/classic mode with everything enabled, not just the shipped defaults
#
# IMPORTANT: --load-extension is last-wins across *separate* occurrences of the
# flag — Chromium silently drops every extension but the last one specified this
# way. Only a single, comma-joined "--load-extension=pathA,pathB" loads both.
# This script therefore never appends a second --load-extension flag: it always
# rewrites the existing flag (if any) into a comma-joined one.

set -Eeuo pipefail

SCRIPT_NAME=${0##*/}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*"; }

require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		err "Missing dependency: $1"
		MISSING=1
	fi
}

usage() {
	cat <<EOF
${SCRIPT_NAME} — Wire up uBlock Origin (pacman package) for Chromium-based browsers

Usage: ${SCRIPT_NAME}

Notes:
  - Requires the 'ublock-origin' pacman package (sudo pacman -S ublock-origin).
  - Chromium-based browsers are integrated via the same wrapper pattern used by
    install_leechblock.sh; running both installers preserves both extensions in
    a single comma-joined --load-extension flag.
  - Firefox-based browsers are out of scope here — install uBlock Origin from
    addons.mozilla.org instead, permanent installs work there unlike LeechBlock.
EOF
}

case "${1:-}" in
-h | --help)
	usage
	exit 0
	;;
"") ;;
*)
	err "Unrecognized option: $1"
	usage
	exit 2
	;;
esac

MISSING=0
require_cmd sed
require_cmd find
[[ $MISSING -eq 1 ]] && {
	err "Please install missing tools and re-run."
	exit 1
}

EXT_PATH="/usr/lib/ublock-origin"
if [[ ! -f "$EXT_PATH/manifest.json" ]]; then
	err "uBlock Origin not found at $EXT_PATH (manifest.json missing)."
	err "Install it first: sudo pacman -S ublock-origin"
	exit 1
fi

# ── Seed default filter-list selection (all lists enabled) ────────────
if [[ ! -d "$SCRIPT_DIR/node_modules/classic-level" ]]; then
	info "Installing classic-level npm package into $SCRIPT_DIR ..."
	npm install --prefix "$SCRIPT_DIR" 2>&1 | grep -v '^npm warn' || true
fi

# Chrome locks its LevelDB files while running — close all Chromium browsers
# so the write succeeds.
pkill -f 'google-chrome|chromium|brave-browser|vivaldi|thorium' 2>/dev/null || true
sleep 1

if node "$SCRIPT_DIR/seed_ublock_storage.js"; then
	info "Seeded uBlock Origin filter-list selection into browser storage"
else
	warn "Could not seed uBlock Origin defaults — run manually after install:"
	warn "  node $SCRIPT_DIR/seed_ublock_storage.js"
fi

# ── Detect browsers ─────────────────────────────────────────────────────
declare -A BROWSERS
BROWSERS=(
	[chromium]="Chromium"
	[helium-browser]="Helium"
	[google-chrome-stable]="Google Chrome"
	[google-chrome]="Google Chrome"
	[brave-browser]="Brave"
	[vivaldi-stable]="Vivaldi"
	[vivaldi]="Vivaldi"
	[opera]="Opera"
	[thorium-browser]="Thorium"
)

found_any=0

# The flags file / exec-line / binary-wrapper logic is shared with
# install_leechblock.sh; see lib/browser_extension_wiring.sh.
# shellcheck source=lib/browser_extension_wiring.sh
. "$SCRIPT_DIR/lib/browser_extension_wiring.sh"

info "Detecting installed browsers…"
for bin in "${!BROWSERS[@]}"; do
	if command -v "$bin" >/dev/null 2>&1; then
		if wire_extension_into_browser "$bin" "${BROWSERS[$bin]}" "$EXT_PATH" UBLOCK; then
			found_any=1
		fi
	fi
done

echo
if [[ $found_any -eq 1 ]]; then
	info "uBlock Origin integration complete."
	warn "Chromium will mark it as a developer extension; this is expected for unpacked installs."
else
	warn "No supported browsers detected. uBlock Origin package is present at: $EXT_PATH"
	echo "Supported (auto-wired): ${!BROWSERS[*]}."
fi

echo
info "Done."

# Credit line last; a no-op when this installer runs outside the repo.
# shellcheck source=lib/kuhy_credit.sh
. "$SCRIPT_DIR/lib/kuhy_credit.sh" 2>/dev/null || kuhy_credit() { :; }
kuhy_credit
