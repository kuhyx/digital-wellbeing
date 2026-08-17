#!/bin/bash
# filepath: enforce_vbox_hosts.sh
# Enforce host machine's /etc/hosts file on all VirtualBox VMs
# This prevents VMs from bypassing host-level content filtering

set -euo pipefail

# shellcheck source=lib/vbox_disk_inject.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/vbox_disk_inject.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Auto-sudo functionality with confirmation
if [ "$EUID" -ne 0 ]; then
	echo -e "${YELLOW}This script requires root privileges to configure VirtualBox VMs.${NC}"
	echo -e "${CYAN}Executing with sudo...${NC}"
	exec sudo bash "$0" "$@"
fi

# Determine the real (non-root) user who invoked this script.
# VBoxManage must run as this user because VMs are registered per-user.
REAL_USER="${SUDO_USER:-$USER}"
if [[ $REAL_USER == "root" ]]; then
	echo -e "${RED}Cannot determine the real user. Do not run this script as root directly.${NC}"
	echo -e "${RED}Run it as a normal user (it will auto-sudo as needed).${NC}"
	exit 1
fi

# Check if VBoxManage is available
if ! command -v VBoxManage >/dev/null 2>&1; then
	echo -e "${RED}VBoxManage not found. VirtualBox may not be installed.${NC}"
	exit 1
fi

# Run VBoxManage as the real user so it sees their registered VMs
vboxmanage_as_user() {
	sudo -u "$REAL_USER" VBoxManage "$@"
}

# Configuration
VBOX_SHARED_FOLDER_NAME="host_etc"
HOSTS_ENFORCEMENT_MARKER="/var/lib/vbox-hosts-enforced"

# Get list of all VMs
get_all_vms() {
	vboxmanage_as_user list vms | awk -F'"' '{print $2}'
}

# Get list of running VMs
get_running_vms() {
	vboxmanage_as_user list runningvms | awk -F'"' '{print $2}'
}

# Configure a VM to use host DNS (NAT network)
configure_vm_dns() {
	local vm_name="$1"
	echo -e "${BLUE}Configuring DNS for VM: ${vm_name}${NC}"

	# Enable DNS proxy for NAT adapter (adapter 1 by default)
	# This makes the VM use the host's DNS resolution
	vboxmanage_as_user modifyvm "$vm_name" --natdnshostresolver1 on 2>/dev/null || true
	vboxmanage_as_user modifyvm "$vm_name" --natdnsproxy1 on 2>/dev/null || true

	echo -e "${GREEN}DNS configuration applied to ${vm_name}${NC}"
}

# Add shared folder for /etc directory (read-only)
configure_hosts_shared_folder() {
	local vm_name="$1"
	echo -e "${BLUE}Setting up /etc/hosts sharing for VM: ${vm_name}${NC}"

	# Remove existing shared folder if present
	vboxmanage_as_user sharedfolder remove "$vm_name" --name "$VBOX_SHARED_FOLDER_NAME" 2>/dev/null || true

	# Add /etc as a shared folder (read-only)
	vboxmanage_as_user sharedfolder add "$vm_name" \
		--name "$VBOX_SHARED_FOLDER_NAME" \
		--hostpath "/etc" \
		--readonly \
		--automount 2>/dev/null || {
		echo -e "${YELLOW}Could not add shared folder to ${vm_name} (VM may be running)${NC}"
		return 1
	}

	echo -e "${GREEN}Shared folder configured for ${vm_name}${NC}"
	return 0
}

# Create a startup script that can be placed in VMs
generate_vm_startup_script() {
	local output_file="${1:-/tmp/vbox_hosts_sync.sh}"

	cat >"$output_file" <<'EOF'
#!/bin/bash
# VirtualBox VM startup script to sync /etc/hosts from host machine
# This should be placed in the VM and run at startup

set -e

SHARED_FOLDER_MOUNT="/mnt/host_etc"
HOST_HOSTS_FILE="${SHARED_FOLDER_MOUNT}/hosts"
VM_HOSTS_FILE="/etc/hosts"
BACKUP_HOSTS_FILE="/etc/hosts.pre-vbox-sync"

# Function to check if running in VirtualBox
is_virtualbox() {
  # First try systemd-detect-virt (no root required)
  if command -v systemd-detect-virt > /dev/null 2>&1; then
    if systemd-detect-virt 2>/dev/null | grep -qi "oracle"; then
      return 0
    fi
  fi

  # Then try dmidecode (requires root, but script should already be running as root)
  if command -v dmidecode > /dev/null 2>&1; then
    if dmidecode -s system-product-name 2>/dev/null | grep -qi "VirtualBox"; then
      return 0
    fi
  fi

  return 1
}

# Only run if we're in VirtualBox
if ! is_virtualbox; then
  exit 0
fi

# Create mount point if it doesn't exist
mkdir -p "$SHARED_FOLDER_MOUNT"

# Try to mount the shared folder (if Guest Additions are installed)
if ! mountpoint -q "$SHARED_FOLDER_MOUNT"; then
  if command -v mount.vboxsf > /dev/null 2>&1; then
    mount -t vboxsf -o ro host_etc "$SHARED_FOLDER_MOUNT" 2>/dev/null || {
      echo "Could not mount VirtualBox shared folder"
      exit 0
    }
  else
    echo "VirtualBox Guest Additions not installed, cannot sync hosts file"
    exit 0
  fi
fi

# Sync hosts file if the shared one exists
if [ -f "$HOST_HOSTS_FILE" ]; then
  # Backup current hosts file if not already backed up
  if [ ! -f "$BACKUP_HOSTS_FILE" ]; then
    cp "$VM_HOSTS_FILE" "$BACKUP_HOSTS_FILE"
  fi

  # Copy host's hosts file to VM
  cp "$HOST_HOSTS_FILE" "$VM_HOSTS_FILE"
  echo "Synced /etc/hosts from host machine"

  # Make it harder to modify (though not impossible in VM)
  chmod 444 "$VM_HOSTS_FILE"
fi
EOF

	chmod +x "$output_file"
	echo -e "${GREEN}Generated VM startup script at ${output_file}${NC}"
	echo -e "${CYAN}Copy this script to your VMs and add it to their startup (e.g., /etc/rc.local or systemd)${NC}"
}







# Main function
main() {
	local action="${1:-enforce}"

	case "$action" in
	enforce | apply)
		enforce_all_vms
		;;
	check)
		if check_enforcement_status; then
			exit 0
		else
			exit 1
		fi
		;;
	status)
		show_status
		;;
	generate-script)
		local output="${2:-/tmp/vbox_hosts_sync.sh}"
		generate_vm_startup_script "$output"
		;;
	*)
		echo -e "${CYAN}VirtualBox /etc/hosts Enforcement Tool${NC}"
		echo ""
		echo "Usage: $0 [command]"
		echo ""
		echo "Commands:"
		echo "  enforce        Apply /etc/hosts enforcement to all VMs (default)"
		echo "  check          Check if enforcement has been applied"
		echo "  status         Show current enforcement status"
		echo "  generate-script [path]  Generate a script to place in VMs for hosts sync"
		echo ""
		echo "This tool configures VirtualBox VMs to:"
		echo "  1. Use host's DNS resolution (via NAT DNS proxy)"
		echo "  2. Share /etc from host (read-only) for hosts file access"
		echo ""
		exit 0
		;;
	esac
}

main "$@"
