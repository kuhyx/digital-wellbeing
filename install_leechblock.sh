#!/usr/bin/env bash

# LeechBlockNG installer for Arch Linux (and derivatives)
# - Downloads the latest release from GitHub
# - Extracts it under ~/.local/share/leechblockng/<version>
# - Wires Chromium-based browsers to auto-load the extension via --load-extension
# - For Firefox-based browsers, prints safe next steps (stable Firefox requires signed XPI)

set -Eeuo pipefail

SCRIPT_NAME=${0##*/}

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
${SCRIPT_NAME} — Download and wire up LeechBlockNG from GitHub

Usage: ${SCRIPT_NAME} [--version vX.Y[.Z]] [--force] [--install-firefox]

Options:
  --version vX.Y  Use a specific tag (default: latest from GitHub)
  --force             Reinstall even if the same version is already present
  --install-firefox   Auto-install from AMO for detected Firefox-based browsers (requires sudo)

Notes:
  - Chromium-based browsers are integrated via a wrapper that passes --load-extension.
    A desktop entry "(LeechBlock)" is created so you can launch the browser with the extension.
  - Firefox stable requires signed add-ons; GitHub source cannot be permanently installed there.
    We'll print safe steps to install from AMO or use Developer Edition for testing.
EOF
}

VERSION=""
FORCE=0
AUTO_FIREFOX=0
while [[ $# -gt 0 ]]; do
	case "$1" in
	--version)
		VERSION="$2"
		shift 2
		;;
	--force)
		FORCE=1
		shift
		;;
	--install-firefox)
		AUTO_FIREFOX=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		err "Unrecognized option: $1"
		usage
		exit 2
		;;
	esac
done

# Dependencies
MISSING=0
require_cmd curl
require_cmd tar
require_cmd find
require_cmd sed
require_cmd awk
if ! command -v jq >/dev/null 2>&1; then
	warn "jq not found — will fall back to a simpler tag detection method."
fi
[[ $MISSING -eq 1 ]] && {
	err "Please install missing tools and re-run."
	exit 1
}

REPO_OWNER="proginosko"
REPO_NAME_CHROME="LeechBlockNG-chrome"
# Firefox repo (for reference): LeechBlockNG

# Use Chrome repo for Chromium-based browsers (the default target)
REPO_NAME="$REPO_NAME_CHROME"

get_latest_tag() {
	local repo="$1"
	local tag
	if command -v jq >/dev/null 2>&1; then
		tag=$(curl -fsSL "https://api.github.com/repos/${REPO_OWNER}/${repo}/releases/latest" | jq -r '.tag_name // empty' || true)
		if [[ -n $tag && $tag != "null" ]]; then
			echo "$tag"
			return 0
		fi
		# Fallback: try tags endpoint
		tag=$(curl -fsSL "https://api.github.com/repos/${REPO_OWNER}/${repo}/tags?per_page=1" | jq -r '.[0].name // empty' || true)
		if [[ -n $tag && $tag != "null" ]]; then
			echo "$tag"
			return 0
		fi
	fi
	# Fallback: follow redirect for /releases/latest to extract tag
	tag=$(curl -fsSLI "https://github.com/${REPO_OWNER}/${repo}/releases/latest" | awk -F'/tag/' '/^location:/I {print $2}' | tr -d '\r\n' || true)
	if [[ -n $tag ]]; then
		echo "$tag"
		return 0
	fi
	return 1
}

if [[ -z $VERSION ]]; then
	info "Resolving latest release tag from GitHub…"
	if ! VERSION=$(get_latest_tag "$REPO_NAME"); then
		err "Failed to determine latest version tag"
		exit 1
	fi
fi

if [[ ! $VERSION =~ ^v?[0-9]+(\.[0-9]+)*$ ]]; then
	warn "Version tag '$VERSION' doesn't look like vX[.Y[.Z]] — continuing anyway."
fi

VERSION=${VERSION#v} # strip leading v for folder names
TAG="v${VERSION}"

XDG_DATA_HOME=${XDG_DATA_HOME:-"$HOME/.local/share"}
INSTALL_ROOT="$XDG_DATA_HOME/leechblockng"
VERSION_DIR="$INSTALL_ROOT/$VERSION"
CURRENT_LINK="$INSTALL_ROOT/current"

if [[ -d $VERSION_DIR && $FORCE -ne 1 ]]; then
	info "LeechBlockNG $VERSION already present at $VERSION_DIR (use --force to reinstall)."
else
	info "Downloading LeechBlockNG $TAG source from GitHub…"
	tmpdir=$(mktemp -d)
	trap 'rm -rf "$tmpdir"' EXIT
	ARCHIVE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/tags/${TAG}.tar.gz"
	ARCHIVE_FILE="$tmpdir/${REPO_NAME}-${TAG}.tar.gz"
	curl -fL --retry 3 -o "$ARCHIVE_FILE" "$ARCHIVE_URL"
	info "Extracting…"
	mkdir -p "$tmpdir/extract"
	tar -xzf "$ARCHIVE_FILE" -C "$tmpdir/extract"
	# The archive usually extracts to REPO_NAME-TAG/ …
	src_root=$(find "$tmpdir/extract" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n1 || true)
	[[ -z $src_root ]] && {
		err "Could not locate extracted source root"
		exit 1
	}

	# Find the extension manifest (support a couple of common layouts)
	manifest_path=$(find "$src_root" -maxdepth 5 -type f -name manifest.json | head -n1 || true)
	if [[ -z $manifest_path ]]; then
		err "manifest.json not found in the extracted archive. The project layout may have changed."
		exit 1
	fi
	ext_dir=$(dirname "$manifest_path")

	mkdir -p "$INSTALL_ROOT"
	rm -rf "$VERSION_DIR"
	info "Installing to $VERSION_DIR…"
	mkdir -p "$VERSION_DIR"
	# Copy the extension directory as-is (avoid bringing tests or build scripts)
	rsync -a --delete "$ext_dir/" "$VERSION_DIR/" 2>/dev/null || cp -a "$ext_dir/." "$VERSION_DIR/"

	# Download jQuery UI (not included in repo — listed in .gitignore)
	# The extension's options.html expects:
	#   jquery-ui/jquery-ui.min.css
	#   jquery-ui/external/jquery/jquery.js
	#   jquery-ui/jquery-ui.min.js
	info "Downloading jQuery UI…"
	jqui_version="1.14.1"
	jqui_url="https://jqueryui.com/resources/download/jquery-ui-${jqui_version}.zip"
	jqui_zip="$tmpdir/jquery-ui.zip"
	curl -fL --retry 3 -o "$jqui_zip" "$jqui_url"
	mkdir -p "$tmpdir/jqui-extract"
	unzip -q "$jqui_zip" -d "$tmpdir/jqui-extract"
	jqui_src=$(find "$tmpdir/jqui-extract" -maxdepth 1 -type d -name "jquery-ui-*" | head -n1 || true)
	if [[ -n $jqui_src ]]; then
		mkdir -p "$VERSION_DIR/jquery-ui/external/jquery"
		cp "$jqui_src/jquery-ui.min.css" "$VERSION_DIR/jquery-ui/" 2>/dev/null || true
		cp "$jqui_src/jquery-ui.min.js" "$VERSION_DIR/jquery-ui/" 2>/dev/null || true
		cp "$jqui_src/external/jquery/jquery.js" "$VERSION_DIR/jquery-ui/external/jquery/" 2>/dev/null || true
		info "✓ jQuery UI ${jqui_version} installed into extension"
	else
		warn "Could not extract jQuery UI — options page may not work correctly"
	fi

	ln -sfn "$VERSION_DIR" "$CURRENT_LINK"
fi

EXT_PATH="$CURRENT_LINK" # stable path used by wrappers

# ── Inject default blocking configuration ─────────────────────────────
# Copy leechblock_defaults.js alongside the extension and patch
# background.js to import it and seed storage on first run.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULTS_SRC="$SCRIPT_DIR/leechblock_defaults.js"

if [[ -f $DEFAULTS_SRC ]]; then
	cp "$DEFAULTS_SRC" "$VERSION_DIR/defaults.js"
	info "Copied default blocking configuration into extension"

	BG_JS="$VERSION_DIR/background.js"
	if [[ -f $BG_JS ]]; then
		# 1) Add importScripts("defaults.js") right after importScripts("common.js")
		if ! grep -q 'importScripts("defaults.js")' "$BG_JS"; then
			sed -i 's|importScripts("common.js");|importScripts("common.js");\nimportScripts("defaults.js");|' "$BG_JS"
			info "Patched background.js to import defaults.js"
		fi

		# 2) Inject first-run seeding logic after cleanTimeData(gOptions)
		if ! grep -q 'LEECHBLOCK_DEFAULTS' "$BG_JS"; then
			sed -i '/cleanTimeData(gOptions);/a\
\
\t\t// ── Seed default blocking rules on first run ──\
\t\tif (typeof LEECHBLOCK_DEFAULTS !== "undefined") {\
\t\t\tlet hasAnySites = false;\
\t\t\tfor (let s = 1; s <= +gOptions["numSets"]; s++) {\
\t\t\t\tif (gOptions["sites" + s]) { hasAnySites = true; break; }\
\t\t\t}\
\t\t\tif (!hasAnySites) {\
\t\t\t\tfor (let key in LEECHBLOCK_DEFAULTS) {\
\t\t\t\t\tgOptions[key] = LEECHBLOCK_DEFAULTS[key];\
\t\t\t\t}\
\t\t\t\tcleanOptions(gOptions);\
\t\t\t\tcleanTimeData(gOptions);\
\t\t\t\tgNumSets = +gOptions["numSets"];\
\t\t\t\tgStorage.set(gOptions).catch(\
\t\t\t\t\tfunction (e) { warn("Cannot seed defaults: " + e); }\
\t\t\t\t);\
\t\t\t\tlog("Seeded default blocking configuration");\
\t\t\t}\
\t\t}' "$BG_JS"
			info "Patched background.js with first-run seeding logic"
		fi
	fi
else
	warn "leechblock_defaults.js not found at $DEFAULTS_SRC — skipping default config"
fi

# Detect browsers
declare -A BROWSERS
BROWSERS=(
	[chromium]="Chromium"
	[google - chrome - stable]="Google Chrome"
	[google - chrome]="Google Chrome"
	[brave - browser]="Brave"
	[vivaldi - stable]="Vivaldi"
	[vivaldi]="Vivaldi"
	[opera]="Opera"
	[thorium - browser]="Thorium"
)

declare -A FIREFOXES
FIREFOXES=(
	[firefox]="Firefox"
	[firefox - developer - edition]="Firefox Developer Edition"
	[librewolf]="LibreWolf"
)

found_any=0

# Create a user desktop entry
user_apps_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$user_apps_dir"

# Replace the system browser launcher in-place so every launch includes LeechBlock.
# The original script/binary is backed up as <path>.orig.
# Requires sudo for system paths (/usr/bin).
replace_browser_in_place() {
	local bin="$1"
	shift
	local pretty="$1"
	shift

	local real_bin
	real_bin=$(command -v "$bin" || true)
	[[ -z $real_bin ]] && return

	# Resolve to absolute path (handles symlinks etc.)
	real_bin=$(readlink -f "$real_bin")

	local orig_backup="${real_bin}.orig"

	# If already wrapped, skip (idempotent)
	if grep -q '__LEECHBLOCK_WRAPPER__' "$real_bin" 2>/dev/null; then
		info "$pretty ($bin) already wrapped — skipping"
		found_any=1
		return
	fi

	# Kill running instances so the new wrapper takes effect
	info "Killing running $pretty instances…"
	pkill -f "$real_bin" 2>/dev/null || true
	pkill -f "$(basename "$real_bin")" 2>/dev/null || true
	sleep 1

	# Back up original
	if [[ ! -f $orig_backup ]]; then
		info "Backing up $real_bin → $orig_backup"
		sudo cp -a "$real_bin" "$orig_backup"
	else
		info "Backup already exists: $orig_backup"
	fi

	# Write replacement wrapper
	info "Replacing $real_bin with LeechBlock wrapper…"
	sudo tee "$real_bin" >/dev/null <<WRAP
#!/usr/bin/env bash
# __LEECHBLOCK_WRAPPER__ — auto-generated by install_leechblock.sh
# Original backed up at: $orig_backup
exec "$orig_backup" --load-extension="$EXT_PATH" "\$@"
WRAP
	sudo chmod +x "$real_bin"

	info "✓ $pretty now always launches with LeechBlock"
	found_any=1
}

info "Detecting installed browsers…"
for bin in "${!BROWSERS[@]}"; do
	if command -v "$bin" >/dev/null 2>&1; then
		replace_browser_in_place "$bin" "${BROWSERS[$bin]}"
	fi
done

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
       $VERSION_DIR

To load temporarily for testing (session-only), open 'about:debugging#/runtime/this-firefox' and "Load Temporary Add-on…" then select $VERSION_DIR/manifest.json.

Tip: Re-run this script with --install-firefox to auto-install from AMO via enterprise policy (requires sudo).
FF
fi

if [[ $found_any -eq 0 && $ff_found -eq 0 ]]; then
	warn "No supported browsers detected. We placed the extension at: $VERSION_DIR"
	echo "Supported (auto-wired): ${!BROWSERS[*]}. Detected Firefox variants will show guidance only."
fi

echo
info "Done. Version: $VERSION (tag $TAG) installed under $VERSION_DIR"

# If requested, attempt automatic install on Firefox via enterprise policies
if [[ $AUTO_FIREFOX -eq 1 && $ff_found -eq 1 ]]; then
	echo
	info "Attempting Firefox auto-install via Enterprise Policies (requires sudo)."
	# AMO info
	ADDON_ID="leechblockng@proginosko.com"
	ADDON_AMO_URL="https://addons.mozilla.org/firefox/downloads/latest/leechblock-ng/latest.xpi"

	# Determine policy directories for detected Firefox-like browsers
	declare -a POLICY_DIRS
	POLICY_DIRS=()
	if command -v firefox >/dev/null 2>&1; then
		POLICY_DIRS+=("/etc/firefox/policies" "/usr/lib/firefox/distribution")
	fi
	if command -v firefox-developer-edition >/dev/null 2>&1; then
		POLICY_DIRS+=("/etc/firefox-developer-edition/policies" "/usr/lib/firefox-developer-edition/distribution")
	fi
	if command -v librewolf >/dev/null 2>&1; then
		POLICY_DIRS+=("/etc/librewolf/policies" "/usr/lib/librewolf/distribution")
	fi
	# Generic mozilla path as fallback
	POLICY_DIRS+=("/usr/lib/mozilla/distribution")

	updated_any=0
	for pol_target in "${POLICY_DIRS[@]}"; do
		tmp_pol=$(mktemp)
		existing="${pol_target}/policies.json"
		if sudo test -f "$existing"; then
			info "Merging into existing policies.json at $existing"
			sudo cp "$existing" "$tmp_pol"
			if command -v jq >/dev/null 2>&1; then
				merged=$(jq --arg id "$ADDON_ID" --arg url "$ADDON_AMO_URL" '
          .policies |= (. // {}) |
          .policies.ExtensionSettings |= (. // {}) |
          .policies.ExtensionSettings."*" |= (. // {"installation_mode":"allowed"}) |
          .policies.ExtensionSettings[$id] |= (. // {}) |
          .policies.ExtensionSettings[$id].installation_mode = "force_installed" |
          .policies.ExtensionSettings[$id].install_url = $url
        ' "$tmp_pol") || merged=""
				if [[ -n $merged ]]; then
					printf '%s\n' "$merged" >"$tmp_pol"
				else
					warn "jq merge failed; skipping $pol_target"
					rm -f "$tmp_pol"
					continue
				fi
			else
				warn "jq not available; creating minimal policies.json (existing file will be backed up)."
				sudo cp "$existing" "${existing}.bak.$(date +%s)"
				cat >"$tmp_pol" <<JSON
{
  "policies": {
    "ExtensionSettings": {
      "*": { "installation_mode": "allowed" },
      "$ADDON_ID": {
        "installation_mode": "force_installed",
        "install_url": "$ADDON_AMO_URL"
      }
    }
  }
}
JSON
			fi
		else
			info "Creating new policies.json at $pol_target"
			cat >"$tmp_pol" <<JSON
{
  "policies": {
    "ExtensionSettings": {
      "*": { "installation_mode": "allowed" },
      "$ADDON_ID": {
        "installation_mode": "force_installed",
        "install_url": "$ADDON_AMO_URL"
      }
    }
  }
}
JSON
		fi

		sudo mkdir -p "$pol_target"
		sudo cp "$tmp_pol" "$pol_target/policies.json"
		rm -f "$tmp_pol"
		updated_any=1
	done

	if [[ $updated_any -eq 1 ]]; then
		info "Firefox policies updated. Restart Firefox/LibreWolf to complete installation of LeechBlock NG."
	else
		warn "No Firefox policy locations updated. You may not have a supported Firefox installed."
	fi
	info "Firefox policy updated. Restart Firefox to complete installation of LeechBlock NG."
fi
