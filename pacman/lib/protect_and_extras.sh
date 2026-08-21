#!/bin/bash
# Policy-file immutability, plus the LeechBlock and VirtualBox payloads.
# Sourced by install_pacman_wrapper.sh; inherits the caller's strict mode.

# Make policy files immutable to prevent easy tampering
protect_policy_files() {
	echo -e "${BLUE}Protecting policy files from modification...${NC}"
	if command -v chattr >/dev/null 2>&1; then
		chattr +i "$BLOCKED_DEST" 2>/dev/null || echo -e "${YELLOW}Warning: Could not make blocked list immutable${NC}"
		chattr +i "$GREYLIST_DEST" 2>/dev/null || echo -e "${YELLOW}Warning: Could not make greylist immutable${NC}"
		chattr +i "$LOCK_LIB_DEST" 2>/dev/null || echo -e "${YELLOW}Warning: Could not make lock library immutable${NC}"
		# Note: whitelist is intentionally left modifiable for user convenience
	else
		echo -e "${YELLOW}Warning: chattr not available, policy files will not be immutable${NC}"
	fi
}

# Install LeechBlock installer and defaults if available
install_leechblock_payload() {
	mkdir -p "$LEECHBLOCK_INSTALL_DIR"
	if [ -f "$LEECHBLOCK_INSTALLER_SOURCE" ]; then
		echo -e "${BLUE}Installing LeechBlock installer to ${LEECHBLOCK_INSTALLER_DEST}...${NC}"
		cp "$LEECHBLOCK_INSTALLER_SOURCE" "$LEECHBLOCK_INSTALLER_DEST"
		chmod +x "$LEECHBLOCK_INSTALLER_DEST"
		# The installer sources every install phase from lib/ beside itself, so
		# the directory has to travel with it. Deploying the entry script alone
		# leaves a copy that dies on its first `source`. Mirror rather than
		# merge, so a lib deleted upstream does not linger here.
		if [ -d "$LEECHBLOCK_LIB_SOURCE" ]; then
			rm -rf "$LEECHBLOCK_LIB_DEST"
			mkdir -p "$LEECHBLOCK_LIB_DEST"
			# Only the leechblock_* libs: lib/ is shared with unrelated scripts
			# (the music_* helpers) that this payload has no business shipping.
			cp "$LEECHBLOCK_LIB_SOURCE"/leechblock_*.sh "$LEECHBLOCK_LIB_DEST"/
			chmod +x "$LEECHBLOCK_LIB_DEST"/leechblock_*.sh
			echo -e "${GREEN}LeechBlock libs deployed to ${LEECHBLOCK_LIB_DEST}${NC}"
		else
			echo -e "${YELLOW}LeechBlock lib/ not found at ${LEECHBLOCK_LIB_SOURCE}; the deployed installer will not run${NC}"
		fi
		echo -e "${GREEN}LeechBlock installer deployed to ${LEECHBLOCK_INSTALLER_DEST}${NC}"
	else
		echo -e "${YELLOW}LeechBlock installer not found at ${LEECHBLOCK_INSTALLER_SOURCE}, skipping...${NC}"
	fi
	if [ -f "$LEECHBLOCK_DEFAULTS_SOURCE" ]; then
		cp "$LEECHBLOCK_DEFAULTS_SOURCE" "$LEECHBLOCK_DEFAULTS_DEST"
		echo -e "${GREEN}LeechBlock defaults deployed to ${LEECHBLOCK_DEFAULTS_DEST}${NC}"
	fi
	if [ -f "$LEECHBLOCK_SEEDER_SOURCE" ]; then
		cp "$LEECHBLOCK_SEEDER_SOURCE" "$LEECHBLOCK_SEEDER_DEST"
		echo -e "${GREEN}LeechBlock seeder deployed to ${LEECHBLOCK_SEEDER_DEST}${NC}"
	fi
	if [ -f "$LEECHBLOCK_PKG_SOURCE" ]; then
		cp "$LEECHBLOCK_PKG_SOURCE" "${LEECHBLOCK_INSTALL_DIR}/package.json"
		echo -e "${BLUE}Installing Node.js deps in ${LEECHBLOCK_INSTALL_DIR}...${NC}"
		npm install --prefix "$LEECHBLOCK_INSTALL_DIR" 2>&1 | grep -v '^npm warn' || true
	fi
}

# Install VirtualBox enforcement script if available
install_vbox_enforcement() {
	if [ -f "$VBOX_ENFORCE_SOURCE" ]; then
		echo -e "${BLUE}Installing VirtualBox hosts enforcement script...${NC}"
		mkdir -p "$VBOX_INSTALL_DIR"
		cp "$VBOX_ENFORCE_SOURCE" "$VBOX_ENFORCE_DEST"
		chmod +x "$VBOX_ENFORCE_DEST"
		echo -e "${GREEN}VirtualBox enforcement script installed to ${VBOX_ENFORCE_DEST}${NC}"
	else
		echo -e "${YELLOW}VirtualBox enforcement script not found, skipping...${NC}"
	fi
}
