#!/usr/bin/env bash

# LeechBlockNG installer for Arch Linux (and derivatives)
# - Downloads the latest release from GitHub
# - Extracts it under ~/.local/share/leechblockng/<version>
# - Wires Chromium-based browsers to auto-load the extension via --load-extension
# - For Firefox-based browsers, prints safe next steps (stable Firefox requires signed XPI)

set -Eeuo pipefail

# Each phase of the install lives in a lib beside this file; this script
# keeps the flag parsing, the shared configuration and the order the phases
# run in.
# Resolved here, in the entry script, so it points at the directory holding
# leechblock_defaults.json and seed_leechblock_storage.js. Resolving it
# inside lib/ would yield lib/ itself and silently skip default seeding.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
# shellcheck source=lib/leechblock_fetch.sh
. "$LIB_DIR/leechblock_fetch.sh"
# shellcheck source=lib/leechblock_config.sh
. "$LIB_DIR/leechblock_config.sh"
# shellcheck source=lib/leechblock_browsers.sh
. "$LIB_DIR/leechblock_browsers.sh"
# shellcheck source=lib/leechblock_firefox.sh
. "$LIB_DIR/leechblock_firefox.sh"
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
require_cmd unzip
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

resolve_version
download_extension

EXT_PATH="$CURRENT_LINK" # stable path used by wrappers

inject_default_config
detect_browsers
wire_up_browsers
install_firefox_policy "$ff_found"
