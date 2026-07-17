#!/bin/bash
# install_makepkg_wrapper.sh — wrap /usr/bin/makepkg so an orphaned pacman db.lck
# cannot hang `makepkg -i` forever (see makepkg_wrapper.sh for the full why).
#
# Mirrors install_pacman_wrapper.sh: preserves the real binary at
# /usr/bin/makepkg.orig and points /usr/bin/makepkg at the wrapper. Also installs
# the shared stale-lock library (idempotent) and the upgrade-survival hook that
# re-establishes BOTH wrapper symlinks after a pacman-git upgrade.

set -euo pipefail

# Auto-sudo
if [ "$EUID" -ne 0 ]; then
	echo "Executing with sudo..."
	exec sudo "$0" "$@"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SRC_DIR="$(dirname "$(readlink -f "$0")")"
INSTALL_DIR="/usr/local/bin"

LOCK_LIB_SOURCE="$SRC_DIR/pacman_lock_lib.sh"
LOCK_LIB_DEST="${INSTALL_DIR}/pacman_lock_lib.sh"
WRAPPER_SOURCE="$SRC_DIR/makepkg_wrapper.sh"
WRAPPER_DEST="${INSTALL_DIR}/makepkg_wrapper"
REWRAP_SOURCE="$SRC_DIR/rewrap_pkg_managers.sh"
REWRAP_DEST="${INSTALL_DIR}/rewrap_pkg_managers.sh"
HOOK_SOURCE="$SRC_DIR/96-restore-pkg-wrappers.hook"
HOOK_DEST="/etc/pacman.d/hooks/96-restore-pkg-wrappers.hook"

# Copy a file, unlocking an immutable destination first (the shared lib may be
# chattr +i from install_pacman_wrapper.sh's integrity protection).
deploy_file() { # <src> <dest> <mode>
	local src="$1" dest="$2" mode="$3"
	if [[ ! -f $src ]]; then
		echo -e "${RED}Error:${NC} missing source $src" >&2
		exit 1
	fi
	if command -v chattr >/dev/null 2>&1 && [[ -e $dest ]] &&
		[[ $(lsattr -d "$dest" 2>/dev/null | awk '{print $1}') == *i* ]]; then
		chattr -i "$dest" 2>/dev/null || true
	fi
	cp -f "$src" "$dest"
	chmod "$mode" "$dest"
}

echo -e "${CYAN}Installing makepkg wrapper...${NC}"

# Shared stale-lock library (idempotent — install_pacman_wrapper.sh also deploys
# and integrity-protects it; the makepkg wrapper needs it present regardless).
deploy_file "$LOCK_LIB_SOURCE" "$LOCK_LIB_DEST" 644

# makepkg wrapper itself
deploy_file "$WRAPPER_SOURCE" "$WRAPPER_DEST" 755

# Preserve the real makepkg. Refresh the backup whenever /usr/bin/makepkg is a
# real file (fresh install, or a pacman-git upgrade replaced our symlink); NEVER
# when it is already our symlink — copying the symlink's target would put the
# wrapper into makepkg.orig and cause an exec loop.
if [ ! -L /usr/bin/makepkg ]; then
	echo -e "${BLUE}Backing up original makepkg to /usr/bin/makepkg.orig...${NC}"
	cp -f /usr/bin/makepkg /usr/bin/makepkg.orig
fi

# Sanity: refuse to symlink if we have no real binary to fall back to.
if [ ! -e /usr/bin/makepkg.orig ]; then
	echo -e "${RED}Error: /usr/bin/makepkg.orig missing; refusing to create wrapper symlink.${NC}" >&2
	exit 1
fi

# Upgrade-survival: rewrap helper + PostTransaction hook restoring BOTH symlinks.
deploy_file "$REWRAP_SOURCE" "$REWRAP_DEST" 755
mkdir -p /etc/pacman.d/hooks
deploy_file "$HOOK_SOURCE" "$HOOK_DEST" 644

# Point /usr/bin/makepkg at the wrapper.
echo -e "${BLUE}Creating symbolic link /usr/bin/makepkg -> ${WRAPPER_DEST}...${NC}"
ln -sf "$WRAPPER_DEST" /usr/bin/makepkg

echo -e "${GREEN}makepkg wrapper installed.${NC} Original preserved at ${CYAN}/usr/bin/makepkg.orig${NC}"
echo -e "Upgrade-survival hook installed at ${CYAN}${HOOK_DEST}${NC}"
