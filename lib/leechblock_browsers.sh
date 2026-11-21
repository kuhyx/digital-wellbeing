#!/usr/bin/env bash
# Browser detection and launcher wiring for install_leechblock.sh.
# Sourced by the installer; inherits its strict mode and info/warn helpers.
#
# detect_browsers, replace_browser_in_place and wire_up_browsers live in ONE
# file on purpose: detect_browsers writes BROWSERS/FIREFOXES, which the other
# two read. Splitting them would make those globals write-only across a file
# boundary — a genuine SC2034 the hook cannot see past (it runs shellcheck
# without -x), and suppressions are forbidden.

# shellcheck source=browser_extension_wiring.sh
. "$(dirname "${BASH_SOURCE[0]}")/browser_extension_wiring.sh"

detect_browsers() {
	# Detect browsers
	declare -gA BROWSERS
	BROWSERS=(
		[chromium]="Chromium"
		["helium-browser"]="Helium"
		["google-chrome-stable"]="Google Chrome"
		["google-chrome"]="Google Chrome"
		["brave-browser"]="Brave"
		["vivaldi-stable"]="Vivaldi"
		[vivaldi]="Vivaldi"
		[opera]="Opera"
		["thorium-browser"]="Thorium"
	)

	declare -gA FIREFOXES
	FIREFOXES=(
		[firefox]="Firefox"
		["firefox-developer-edition"]="Firefox Developer Edition"
		[librewolf]="LibreWolf"
	)

	found_any=0

	# Create a user desktop entry
	user_apps_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
	mkdir -p "$user_apps_dir"
}

# Inject --load-extension into a browser launcher so every launch includes
# LeechBlock. The how (flags file, exec-line patch, or binary wrapper) lives in
# browser_extension_wiring.sh, shared with install_ublock.sh.
replace_browser_in_place() {
	if wire_extension_into_browser "$1" "$2" "$EXT_PATH" LEECHBLOCK; then
		found_any=1
	fi
	return 0
}

wire_up_browsers() {
	# The Firefox guidance and the closing summary interpolate the install
	# layout. Those are set by resolve_version, which the entry script always
	# runs first; defaulting them keeps this function callable on its own
	# without aborting under `set -u` on an unbound VERSION_DIR.
	local version_dir="${VERSION_DIR:-<not yet resolved>}"
	local version="${VERSION:-<unknown>}"
	local tag="${TAG:-<unknown>}"

	info "Detecting installed browsers…"
	for bin in "${!BROWSERS[@]}"; do
		if command -v "$bin" >/dev/null 2>&1; then
			replace_browser_in_place "$bin" "${BROWSERS[$bin]}"
		fi
	done

	# Global on purpose: written and read only within this file, and the entry
	# script forwards it to install_firefox_policy as an argument.
	ff_found=0
	for bin in "${!FIREFOXES[@]}"; do
		if command -v "$bin" >/dev/null 2>&1; then
			ff_found=1
		fi
	done

	echo
	if [[ $found_any -eq 1 ]]; then
		info "Chromium-based integration complete. Launch the browser via its '(LeechBlock)' launcher."
		warn "Chromium will mark it as a developer extension; this is expected for unpacked installs."
	fi

	if [[ $ff_found -eq 1 ]]; then
		echo
		warn "Detected Firefox-based browser(s). Permanent install from GitHub source isn't possible on stable builds due to required signing."
		cat <<FF
Options:
  1) Install from Mozilla Add-ons (recommended):
     https://addons.mozilla.org/firefox/addon/leechblock-ng/
  2) For testing with Developer Edition or Nightly, you can set xpinstall.signatures.required=false
     and install a built XPI. We'll still keep the downloaded source at:
       $version_dir

To load temporarily for testing (session-only), open 'about:debugging#/runtime/this-firefox' and "Load Temporary Add-on…" then select $version_dir/manifest.json.

Tip: Re-run this script with --install-firefox to auto-install from AMO via enterprise policy (requires sudo).
FF
	fi

	if [[ $found_any -eq 0 && $ff_found -eq 0 ]]; then
		warn "No supported browsers detected. We placed the extension at: $version_dir"
		echo "Supported (auto-wired): ${!BROWSERS[*]}. Detected Firefox variants will show guidance only."
	fi

	echo
	info "Done. Version: $version (tag $tag) installed under $version_dir"
}
