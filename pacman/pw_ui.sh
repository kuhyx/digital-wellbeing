#!/usr/bin/env bash
# Helpers sourced by the entry script.

# Function to display help
function show_help() {
	echo -e "${BOLD}Pacman Wrapper Help${NC}"
	echo "This wrapper adds helpful features while preserving all pacman functionality."
	echo ""
	echo "Additional commands:"
	echo "  --help-wrapper    Show this help message"
	echo "  --makepkg-capped  Run makepkg in a constrained systemd user scope"
	echo "                   (forward remaining args to makepkg)"
}

run_makepkg_capped() {
	if [[ ! -x $MAKEPKG_CAPPED_BIN ]]; then
		echo -e "${RED}makepkg capped wrapper not found at ${MAKEPKG_CAPPED_BIN}${NC}" >&2
		echo -e "${YELLOW}Run install_pacman_wrapper.sh to install it.${NC}" >&2
		return 1
	fi

	if [[ $EUID -eq 0 && -n ${SUDO_USER:-} ]]; then
		exec sudo -u "$SUDO_USER" "$MAKEPKG_CAPPED_BIN" "$@"
	fi

	exec "$MAKEPKG_CAPPED_BIN" "$@"
}

# Function to display a message before executing
function display_operation() {
	case "$1" in
	-S)
		echo -e "${BLUE}Installing packages...${NC}" >&2
		;;
	-Sy)
		echo -e "${BLUE}Installing packages...${NC}" >&2
		;;
	-S\ *)
		echo -e "${BLUE}Installing packages...${NC}" >&2
		;;
	-Syu | -Syyu)
		echo -e "${BLUE}Updating system...${NC}" >&2
		;;
	-R)
		echo -e "${YELLOW}Removing packages...${NC}" >&2
		;;
	-Rs)
		echo -e "${YELLOW}Removing packages...${NC}" >&2
		;;
	-Rns)
		echo -e "${YELLOW}Removing packages...${NC}" >&2
		;;
	-R\ *)
		echo -e "${YELLOW}Removing packages...${NC}" >&2
		;;
	-Ss)
		echo -e "${CYAN}Searching for packages...${NC}" >&2
		;;
	-Ss\ *)
		echo -e "${CYAN}Searching for packages...${NC}" >&2
		;;
	-Q)
		echo -e "${CYAN}Querying package database...${NC}" >&2
		;;
	-Qs)
		echo -e "${CYAN}Querying package database...${NC}" >&2
		;;
	-Qi)
		echo -e "${CYAN}Querying package database...${NC}" >&2
		;;
	-Ql)
		echo -e "${CYAN}Querying package database...${NC}" >&2
		;;
	-Q\ *)
		echo -e "${CYAN}Querying package database...${NC}" >&2
		;;
	-U)
		echo -e "${BLUE}Installing local packages...${NC}" >&2
		;;
	-U\ *)
		echo -e "${BLUE}Installing local packages...${NC}" >&2
		;;
	-Scc)
		echo -e "${YELLOW}Cleaning package cache...${NC}" >&2
		;;
	*)
		echo -e "${CYAN}Executing pacman command...${NC}" >&2
		;;
	esac
}
