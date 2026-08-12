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
	[google-chrome-stable]="Google Chrome"
	[google-chrome]="Google Chrome"
	[brave-browser]="Brave"
	[vivaldi-stable]="Vivaldi"
	[vivaldi]="Vivaldi"
	[opera]="Opera"
	[thorium-browser]="Thorium"
)

found_any=0

# Add uBO to a browser launcher's --load-extension flag without dropping any
# extension a previous installer (LeechBlock) already wired in. Handles the
# same two cases as install_leechblock.sh's replace_browser_in_place:
#   1) The binary is a shell script with an "exec" line — patch it in-place.
#   2) The binary is a compiled ELF — wrap it with a shell script.
# Follows symlinks only one level, same as install_leechblock.sh, so shared
# wrapper scripts (e.g. browser-preexec-wrapper used by multiple symlinks)
# only get patched once regardless of which browser name triggered it.
wire_browser_in_place() {
	local bin="$1"
	shift
	local pretty="$1"
	shift

	local bin_path
	bin_path=$(command -v "$bin" || true)
	[[ -z $bin_path ]] && return

	local real_bin
	real_bin=$(readlink -f "$bin_path")

	# Already comma-joined in: nothing to do.
	if grep -qE -- "--load-extension=\"[^\"]*${EXT_PATH//\//\\/}[^\"]*\"" "$real_bin" 2>/dev/null; then
		info "$pretty ($bin) already has uBlock Origin in --load-extension — skipping"
		found_any=1
		return
	fi

	# Case 1: Shell script with an exec line carrying an existing
	# --load-extension="..." flag (most likely from install_leechblock.sh) —
	# rewrite it in-place into a comma-joined flag so both extensions load.
	if file "$real_bin" 2>/dev/null | grep -qi 'text\|script'; then
		if grep -qE -- '--load-extension="[^"]*"' "$real_bin" 2>/dev/null; then
			info "Adding uBlock Origin to existing --load-extension flag in $real_bin…"
			pkill -f "$real_bin" 2>/dev/null || true
			sleep 1

			local orig_backup="${real_bin}.orig"
			if [[ ! -f $orig_backup ]]; then
				info "Backing up $real_bin → $orig_backup"
				sudo cp -a "$real_bin" "$orig_backup"
			fi

			sudo sed -i -E "s|--load-extension=\"([^\"]*)\"|--load-extension=\"\1,${EXT_PATH}\"|" "$real_bin"

			info "✓ $pretty --load-extension flag now includes uBlock Origin"
			found_any=1
			return
		fi

		if grep -qE '^exec ' "$real_bin"; then
			info "Patching exec line in $real_bin to add uBlock Origin…"
			pkill -f "$real_bin" 2>/dev/null || true
			sleep 1

			local orig_backup="${real_bin}.orig"
			if [[ ! -f $orig_backup ]]; then
				info "Backing up $real_bin → $orig_backup"
				sudo cp -a "$real_bin" "$orig_backup"
			fi

			sudo sed -i "s|^exec \(.*\) \"\\\$@\"|exec \1 --load-extension=\"$EXT_PATH\" \"\\\$@\"|" "$real_bin"

			info "✓ $pretty exec line patched with uBlock Origin"
			found_any=1
			return
		fi
	fi

	# Case 2: Binary or script without a recognisable exec/--load-extension
	# line — wrap it directly (no prior LeechBlock installer has run here).
	local orig_backup="${real_bin}.orig"

	info "Killing running $pretty instances…"
	pkill -f "$real_bin" 2>/dev/null || true
	pkill -f "$(basename "$real_bin")" 2>/dev/null || true
	sleep 1

	if [[ ! -f $orig_backup ]]; then
		info "Backing up $real_bin → $orig_backup"
		sudo cp -a "$real_bin" "$orig_backup"
	else
		info "Backup already exists: $orig_backup"
	fi

	info "Replacing $real_bin with uBlock Origin wrapper…"
	sudo tee "$real_bin" >/dev/null <<WRAP
#!/usr/bin/env bash
# __UBLOCK_WRAPPER__ — auto-generated by install_ublock.sh
# Original backed up at: $orig_backup
exec "$orig_backup" --load-extension="$EXT_PATH" "\$@"
WRAP
	sudo chmod +x "$real_bin"

	info "✓ $pretty now always launches with uBlock Origin"
	found_any=1
}

info "Detecting installed browsers…"
for bin in "${!BROWSERS[@]}"; do
	if command -v "$bin" >/dev/null 2>&1; then
		wire_browser_in_place "$bin" "${BROWSERS[$bin]}"
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
