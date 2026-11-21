#!/bin/bash
# The pacman wrapper deploys install_leechblock.sh plus the libs it sources to
# /usr/local/share/digital_wellbeing. A lib the payload forgets leaves a copy
# that dies on its first `source`: lib/leechblock_browsers.sh sources
# browser_extension_wiring.sh, which is not a leechblock_* file.
# Runs install_leechblock_payload against temp dirs; nothing system-wide.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BLUE="" GREEN="" YELLOW="" NC=""
LEECHBLOCK_INSTALL_DIR="$TMP/share"
LEECHBLOCK_INSTALLER_SOURCE="$REPO_DIR/install_leechblock.sh"
LEECHBLOCK_INSTALLER_DEST="$LEECHBLOCK_INSTALL_DIR/install_leechblock.sh"
LEECHBLOCK_LIB_SOURCE="$REPO_DIR/lib"
LEECHBLOCK_LIB_DEST="$LEECHBLOCK_INSTALL_DIR/lib"
LEECHBLOCK_DEFAULTS_SOURCE="$TMP/none" LEECHBLOCK_DEFAULTS_DEST="$TMP/none"
LEECHBLOCK_SEEDER_SOURCE="$TMP/none" LEECHBLOCK_SEEDER_DEST="$TMP/none"
LEECHBLOCK_PKG_SOURCE="$TMP/none"
export BLUE GREEN YELLOW NC LEECHBLOCK_DEFAULTS_DEST LEECHBLOCK_SEEDER_DEST

# shellcheck source=../pacman/lib/protect_and_extras.sh
source "$REPO_DIR/pacman/lib/protect_and_extras.sh"
install_leechblock_payload >/dev/null

# Every lib the deployed browser wiring needs must source cleanly from the copy.
if bash -c 'set -euo pipefail; . "$1/leechblock_browsers.sh"; declare -F wire_extension_into_browser >/dev/null' \
	_ "$LEECHBLOCK_LIB_DEST" 2>/dev/null; then
	echo "leechblock payload checks passed."
else
	echo "FAIL: deployed leechblock_browsers.sh cannot source its helpers" >&2
	exit 1
fi
