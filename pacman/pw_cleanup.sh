#!/usr/bin/env bash
# Helpers sourced by the entry script.

# Generic function to remove installed packages matching a filter
# Args: check_function label_prefix
function remove_installed_packages_matching() {
	local check_function="$1"
	local label="$2"

	mapfile -t installed_names < <("$PACMAN_BIN" -Qq 2>/dev/null)
	local to_remove=()
	for name in "${installed_names[@]}"; do
		if "$check_function" "$name"; then
			to_remove+=("$name")
		fi
	done

	if [[ ${#to_remove[@]} -eq 0 ]]; then
		return 0
	fi

	echo -e "${YELLOW}${label} cleanup:${NC} Removing packages: ${BOLD}${to_remove[*]}${NC}" >&2
	"$PACMAN_BIN" -Rns --noconfirm "${to_remove[@]}"
	local rc=$?
	if [[ $rc -ne 0 ]]; then
		echo -e "${RED}${label} cleanup removal failed with exit code ${rc}.${NC}" >&2
	else
		echo -e "${GREEN}${label} cleanup removal completed for: ${to_remove[*]}${NC}" >&2
	fi
	return $rc
}

# Cleanup: remove any installed blocked packages
function remove_installed_blocked_packages() {
	remove_installed_packages_matching is_blocked_package_name "Policy"
}

# Cleanup: remove any installed greylisted packages
function remove_installed_greylisted_packages() {
	remove_installed_packages_matching is_greylisted_package_name "Greylist"
}

# Auto-install LeechBlock if a browser is detected
auto_install_leechblock() {
	# Only check after install operations
	if [[ -z ${1:-} ]] || [[ $1 != "-S"* && $1 != "-U"* ]]; then
		return 0
	fi

	# List of browser packages to check for
	local browsers=("firefox" "librewolf" "chromium" "brave" "vivaldi" "google-chrome" "ungoogled-chromium")
	local browser_found=0

	for browser in "${browsers[@]}"; do
		if "$PACMAN_BIN" -Qq "$browser" 2>/dev/null; then
			browser_found=1
			break
		fi
	done

	if [[ $browser_found -eq 0 ]]; then
		return 0
	fi

	# Find the LeechBlock installer
	local script_dir
	script_dir="$(dirname "$(readlink -f "$0")")"
	local leechblock_installer=""

	if [[ -f "/usr/local/share/digital_wellbeing/install_leechblock.sh" ]]; then
		leechblock_installer="/usr/local/share/digital_wellbeing/install_leechblock.sh"
	elif [[ -f "$script_dir/../install_leechblock.sh" ]]; then
		leechblock_installer="$script_dir/../install_leechblock.sh"
	fi

	if [[ -z $leechblock_installer ]]; then
		echo -e "${YELLOW}Browser detected but LeechBlock installer not found.${NC}" >&2
		return 0
	fi

	# Check if LeechBlock is already installed (by looking for the extension directory)
	if [[ -d "$HOME/.local/share/leechblockng" ]]; then
		return 0
	fi

	echo -e "${CYAN}Browser detected. Installing LeechBlock extension for website blocking...${NC}" >&2

	# Run the LeechBlock installer (as current user, not root)
	if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
		sudo -u "$SUDO_USER" bash "$leechblock_installer" --install-firefox 2>&1 || {
			echo -e "${YELLOW}LeechBlock auto-install failed. Please install manually:${NC}" >&2
			echo -e "${YELLOW}  $leechblock_installer${NC}" >&2
		}
	else
		bash "$leechblock_installer" --install-firefox 2>&1 || {
			echo -e "${YELLOW}LeechBlock auto-install failed. Please install manually:${NC}" >&2
			echo -e "${YELLOW}  $leechblock_installer${NC}" >&2
		}
	fi
}

# If VirtualBox is installed, automatically remove all VMs
auto_remove_virtualbox_vms() {
	# Check if VBoxManage is available
	if ! command -v VBoxManage &>/dev/null; then
		return 0
	fi

	# Determine real user (wrapper may run as root via sudo)
	local real_user="${SUDO_USER:-$USER}"

	# Get list of registered VMs (run as real user since VMs are per-user)
	local vm_list
	vm_list=$(sudo -u "$real_user" VBoxManage list vms 2>/dev/null) || return 0

	if [[ -z $vm_list ]]; then
		return 0
	fi

	echo -e "${RED}═══════════════════════════════════════════════════════${NC}" >&2
	echo -e "${RED}     VIRTUALBOX VMs DETECTED - AUTO-REMOVING           ${NC}" >&2
	echo -e "${RED}═══════════════════════════════════════════════════════${NC}" >&2

	local vm_name
	local success=0
	local failed=0

	while IFS= read -r line; do
		# VBoxManage list vms output format: "VM Name" {uuid}
		vm_name="${line#\"}"
		vm_name="${vm_name%%\"*}"
		if [[ -z $vm_name ]]; then
			continue
		fi

		echo -e "${YELLOW}Removing VM: ${vm_name}${NC}" >&2

		# Power off the VM if it's running
		sudo -u "$real_user" VBoxManage controlvm "$vm_name" poweroff 2>/dev/null || true
		sleep 1

		# Unregister and delete all files
		if sudo -u "$real_user" VBoxManage unregistervm "$vm_name" --delete 2>/dev/null; then
			echo -e "${GREEN}  Removed: ${vm_name}${NC}" >&2
			((++success))
		else
			echo -e "${RED}  Failed to remove: ${vm_name}${NC}" >&2
			((++failed))
		fi
	done <<<"$vm_list"

	echo -e "${CYAN}VM removal complete: ${success} removed, ${failed} failed.${NC}" >&2
}
