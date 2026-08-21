#!/bin/bash
# filepath: /home/kuhy/linux-configuration/scripts/install_pacman_wrapper.sh
#
# The steps live in lib/; this file owns the paths, the root check, the EXIT
# trap, the /usr/bin handling and the call order. Two blocks stay here
# deliberately
# because the trace harness cannot execute them (it cannot bind /usr/bin), so
# a split that moved them could not be verified: the pacman.orig backup plus
# the sed rewrite, and everything from the symlink onwards.

set -euo pipefail

# Auto-sudo functionality
if [ "$EUID" -ne 0 ]; then
	echo "Executing with sudo..."
	sudo "$0" "$@"
	exit $?
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script locations. These stay in the entry script rather than moving to a lib:
# a definitions-only lib assigns without referencing, which is SC2034, and the
# repo forbids suppressions. The libs only reference these globals, a shape the
# linter accepts. `$0` is the entry script either way.
WRAPPER_SOURCE="$(dirname "$0")/pacman_wrapper.sh"
LOCK_LIB_SOURCE="$(dirname "$0")/pacman_lock_lib.sh"
WORDS_SOURCE="$(dirname "$0")/words.txt"
BLOCKED_SOURCE="$(dirname "$0")/pacman_blocked_keywords.txt"
WHITELIST_SOURCE="$(dirname "$0")/pacman_whitelist.txt"
GREYLIST_SOURCE="$(dirname "$0")/pacman_greylist.txt"
MAKEPKG_CAPPED_SOURCE="$(dirname "$0")/makepkg_capped.sh"
MKPKG_SOURCE="$(dirname "$0")/mkpkg.sh"
HEAVY_LOCK_SOURCE="$(dirname "$0")/../../utils/heavy_job_lock.sh"
INSTALL_DIR="/usr/local/bin"
WRAPPER_DEST="${INSTALL_DIR}/pacman_wrapper"
LOCK_LIB_DEST="${INSTALL_DIR}/pacman_lock_lib.sh"
WORDS_DEST="${INSTALL_DIR}/words.txt"
BLOCKED_DEST="${INSTALL_DIR}/pacman_blocked_keywords.txt"
WHITELIST_DEST="${INSTALL_DIR}/pacman_whitelist.txt"
GREYLIST_DEST="${INSTALL_DIR}/pacman_greylist.txt"
MAKEPKG_CAPPED_DEST="${INSTALL_DIR}/makepkg_capped"
MKPKG_DEST="${INSTALL_DIR}/mkpkg"
HEAVY_LOCK_DEST="${INSTALL_DIR}/heavy_job_lock.sh"
INTEGRITY_DIR="/var/lib/pacman-wrapper"
INTEGRITY_FILE="${INTEGRITY_DIR}/policy.sha256"
SOURCE_MANIFEST="${INTEGRITY_DIR}/source.sha256"
LEECHBLOCK_INSTALLER_SOURCE="$(dirname "$0")/../install_leechblock.sh"
LEECHBLOCK_DEFAULTS_SOURCE="$(dirname "$0")/../leechblock_defaults.json"
LEECHBLOCK_SEEDER_SOURCE="$(dirname "$0")/../seed_leechblock_storage.js"
LEECHBLOCK_PKG_SOURCE="$(dirname "$0")/../package.json"
LEECHBLOCK_INSTALL_DIR="/usr/local/share/digital_wellbeing"
LEECHBLOCK_INSTALLER_DEST="${LEECHBLOCK_INSTALL_DIR}/install_leechblock.sh"
LEECHBLOCK_DEFAULTS_DEST="${LEECHBLOCK_INSTALL_DIR}/leechblock_defaults.json"
LEECHBLOCK_SEEDER_DEST="${LEECHBLOCK_INSTALL_DIR}/seed_leechblock_storage.js"
LEECHBLOCK_LIB_SOURCE="$(dirname "$0")/../lib"
LEECHBLOCK_LIB_DEST="${LEECHBLOCK_INSTALL_DIR}/lib"
VBOX_ENFORCE_SOURCE="$(dirname "$0")/../virtualbox/enforce_vbox_hosts.sh"
VBOX_INSTALL_DIR="/usr/local/share/digital_wellbeing/virtualbox"
VBOX_ENFORCE_DEST="${VBOX_INSTALL_DIR}/enforce_vbox_hosts.sh"

# readlink -f so a symlinked entry point still finds lib/.
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=lib/managed_copy.sh
source "$SCRIPT_DIR/lib/managed_copy.sh"
# shellcheck source=lib/install_files.sh
source "$SCRIPT_DIR/lib/install_files.sh"
# shellcheck source=lib/integrity.sh
source "$SCRIPT_DIR/lib/integrity.sh"
# shellcheck source=lib/protect_and_extras.sh
source "$SCRIPT_DIR/lib/protect_and_extras.sh"

trap relock_files_on_exit EXIT

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
	echo -e "${RED}Please run as root${NC}"
	exit 1
fi

# Check if the wrapper script exists
if [ ! -f "$WRAPPER_SOURCE" ]; then
	echo -e "${RED}Error: Wrapper script not found at ${WRAPPER_SOURCE}${NC}"
	exit 1
fi

install_managed_files

# Automatically use symbolic link installation method
echo -e "${YELLOW}Installing using symbolic link method...${NC}"

# Backup original pacman. Refresh the backup whenever /usr/bin/pacman is a real
# file (e.g. a pacman-git upgrade replaced our symlink with the new binary), but
# NEVER when it is already our symlink — copying the symlink's target would put
# the wrapper into pacman.orig and cause an exec loop.
if [ ! -L /usr/bin/pacman ]; then
	echo -e "${BLUE}Backing up original pacman to /usr/bin/pacman.orig...${NC}"
	cp -f /usr/bin/pacman /usr/bin/pacman.orig
fi

# Update the PACMAN_BIN variable in the wrapper to point to the original
sed -i 's|PACMAN_BIN="\/usr\/bin\/pacman"|PACMAN_BIN="\/usr\/bin\/pacman.orig"|g' "$WRAPPER_DEST"

write_policy_integrity_file
write_drift_manifest
protect_policy_files
install_leechblock_payload
install_vbox_enforcement

# Create symbolic link
echo -e "${BLUE}Creating symbolic link...${NC}"
ln -sf "$WRAPPER_DEST" /usr/bin/pacman
echo -e "${GREEN}Installation complete!${NC}"
echo -e "Pacman is now wrapped. The original pacman is available at ${CYAN}/usr/bin/pacman.orig${NC}"
if [ -f "$MAKEPKG_CAPPED_DEST" ]; then
	echo -e "Run constrained package builds with: ${CYAN}pacman --makepkg-capped <args>${NC}"
fi
if [ -f "$MKPKG_DEST" ]; then
	echo -e "Shortcut available: ${CYAN}mkpkg <args>${NC}"
fi
echo -e "${CYAN}Policy files are now protected with immutable attributes.${NC}"
if [ -f "$VBOX_ENFORCE_DEST" ]; then
	echo -e "${CYAN}VirtualBox VMs will automatically be configured to use host's /etc/hosts.${NC}"
fi
