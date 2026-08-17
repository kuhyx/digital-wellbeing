#!/bin/bash
# Copies the wrapper, policy lists and helper scripts into /usr/local/bin.
# Sourced by install_pacman_wrapper.sh; inherits the caller's strict mode.

install_managed_files() {
	echo -e "${CYAN}Installing pacman wrapper...${NC}"

	# Install the wrapper script
	echo -e "${BLUE}Copying wrapper script to ${WRAPPER_DEST}...${NC}"
	copy_managed_file "$WRAPPER_SOURCE" "$WRAPPER_DEST" required "wrapper script"
	copy_managed_file "$LOCK_LIB_SOURCE" "$LOCK_LIB_DEST" required "stale-lock library"
	chmod 644 "$LOCK_LIB_DEST"
	copy_managed_file "$WORDS_SOURCE" "$WORDS_DEST" required "words list"
	copy_managed_file "$BLOCKED_SOURCE" "$BLOCKED_DEST" required "blocked keywords list"
	copy_managed_file "$WHITELIST_SOURCE" "$WHITELIST_DEST" optional "whitelist"
	copy_managed_file "$GREYLIST_SOURCE" "$GREYLIST_DEST" required "greylist"
	chmod +x "$WRAPPER_DEST"
	copy_managed_file "$MAKEPKG_CAPPED_SOURCE" "$MAKEPKG_CAPPED_DEST" required "makepkg capped wrapper"
	chmod +x "$MAKEPKG_CAPPED_DEST"
	copy_managed_file "$MKPKG_SOURCE" "$MKPKG_DEST" required "mkpkg helper"
	chmod +x "$MKPKG_DEST"
	# The heavy-job lock is sourced by pacman_wrapper.sh and makepkg_capped.sh from
	# a fixed absolute path, so it has to land next to them rather than be read out
	# of a repo checkout that may move.
	copy_managed_file "$HEAVY_LOCK_SOURCE" "$HEAVY_LOCK_DEST" required "heavy-job lock library"
	chmod 755 "$HEAVY_LOCK_DEST"
	chmod 644 "$WORDS_DEST" "$BLOCKED_DEST" "$WHITELIST_DEST" "$GREYLIST_DEST" 2>/dev/null || true
}
