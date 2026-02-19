#!/bin/bash
# filepath: enforce_vbox_hosts.sh
# Enforce host machine's /etc/hosts file on all VirtualBox VMs
# This prevents VMs from bypassing host-level content filtering

set -euo pipefail

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

# Get the disk image path for a VM (first SATA/IDE .vdi/.vmdk/.vhd)
get_vm_disk_path() {
	local vm_name="$1"
	vboxmanage_as_user showvminfo "$vm_name" --machinereadable 2>/dev/null |
		grep -E '^"(SATA|IDE|SCSI|NVMe)-[0-9]+-[0-9]+"=' |
		grep -vE '="none"$' |
		grep -vE '\.iso"$' |
		head -1 |
		sed 's/^[^=]*="//; s/"$//'
}

# Inject host's /etc/hosts directly into a VM disk image using qemu-nbd.
# This is the only reliable way to enforce blocking, because NAT DNS proxy
# alone does not work when the guest browser uses DNS-over-HTTPS (DoH).
inject_hosts_into_vm_disk() {
	local vm_name="$1"
	local disk_path
	disk_path="$(get_vm_disk_path "$vm_name")"

	if [[ -z $disk_path || ! -f $disk_path ]]; then
		echo -e "${YELLOW}Could not find disk image for VM '${vm_name}', skipping hosts injection${NC}"
		return 1
	fi

	# Ensure VM is not running
	if vboxmanage_as_user list runningvms 2>/dev/null | grep -q "\"${vm_name}\""; then
		echo -e "${YELLOW}VM '${vm_name}' is running, cannot inject hosts file. Stop it first.${NC}"
		return 1
	fi

	# Check for qemu-nbd
	if ! command -v qemu-nbd >/dev/null 2>&1; then
		echo -e "${YELLOW}qemu-nbd not found. Install qemu-base to enable hosts file injection.${NC}"
		return 1
	fi

	echo -e "${BLUE}Injecting /etc/hosts into disk image for VM: ${vm_name}${NC}"

	# Load nbd module if needed
	if [[ ! -e /dev/nbd0 ]]; then
		modprobe nbd max_part=8 2>/dev/null || {
			echo -e "${YELLOW}Could not load nbd kernel module${NC}"
			return 1
		}
	fi

	# Find a free nbd device
	local nbd_dev=""
	for dev in /dev/nbd{0..15}; do
		if [[ -e $dev ]] && ! lsblk "$dev" >/dev/null 2>&1; then
			nbd_dev="$dev"
			break
		fi
	done
	# Fallback: try /dev/nbd0 if no device was found via lsblk check
	if [[ -z $nbd_dev ]]; then
		nbd_dev="/dev/nbd0"
	fi

	local mount_point="/tmp/vbox_hosts_inject_$$"

	# Connect disk image
	qemu-nbd --connect="$nbd_dev" "$disk_path" 2>/dev/null || {
		echo -e "${YELLOW}Could not connect disk image via qemu-nbd${NC}"
		return 1
	}

	# Wait for partitions to appear
	sleep 1
	partprobe "$nbd_dev" 2>/dev/null || true

	# Find the root partition (first Linux partition)
	local part=""
	for p in "${nbd_dev}p1" "${nbd_dev}p2" "${nbd_dev}p3"; do
		if [[ -b $p ]]; then
			part="$p"
			break
		fi
	done

	if [[ -z $part ]]; then
		echo -e "${YELLOW}No partitions found on disk image${NC}"
		qemu-nbd --disconnect "$nbd_dev" 2>/dev/null || true
		return 1
	fi

	# Mount the partition
	mkdir -p "$mount_point"
	if ! mount "$part" "$mount_point" 2>/dev/null; then
		# Journal may need recovery — run e2fsck then retry
		e2fsck -y "$part" >/dev/null 2>&1 || true
		if ! mount "$part" "$mount_point" 2>/dev/null; then
			echo -e "${YELLOW}Could not mount partition $part${NC}"
			qemu-nbd --disconnect "$nbd_dev" 2>/dev/null || true
			rmdir "$mount_point" 2>/dev/null || true
			return 1
		fi
	fi

	# Check if this partition has /etc/hosts (i.e., it's the root fs)
	if [[ ! -f "$mount_point/etc/hosts" ]]; then
		echo -e "${YELLOW}Partition does not appear to be root filesystem (no /etc/hosts)${NC}"
		umount "$mount_point" 2>/dev/null || true
		qemu-nbd --disconnect "$nbd_dev" 2>/dev/null || true
		rmdir "$mount_point" 2>/dev/null || true
		return 1
	fi

	# Backup original if not already backed up
	if [[ ! -f "$mount_point/etc/hosts.original" ]]; then
		cp "$mount_point/etc/hosts" "$mount_point/etc/hosts.original"
		echo -e "${CYAN}Backed up original hosts file${NC}"
	fi

	# Copy host's /etc/hosts into VM
	cp /etc/hosts "$mount_point/etc/hosts"
	chmod 444 "$mount_point/etc/hosts"

	local blocked_count
	blocked_count="$(grep -c '0.0.0.0' "$mount_point/etc/hosts")"

	# Cleanup: unmount and disconnect
	umount "$mount_point" 2>/dev/null || true
	qemu-nbd --disconnect "$nbd_dev" 2>/dev/null || true
	rmdir "$mount_point" 2>/dev/null || true

	echo -e "${GREEN}Hosts file injected into VM '${vm_name}' (${blocked_count} domains blocked)${NC}"
	return 0
}

# Apply enforcement to all VMs
enforce_all_vms() {
	local -a vms
	mapfile -t vms < <(get_all_vms)

	if [[ ${#vms[@]} -eq 0 ]]; then
		echo -e "${YELLOW}No VirtualBox VMs found.${NC}"
		return 0
	fi

	echo -e "${CYAN}Found ${#vms[@]} VM(s). Applying /etc/hosts enforcement...${NC}"

	local success=0
	local failed=0

	for vm in "${vms[@]}"; do
		echo -e "\n${BLUE}Processing VM: ${vm}${NC}"

		# Configure DNS settings (works even when VM is running)
		configure_vm_dns "$vm"

		# Try to configure shared folder (only works when VM is stopped)
		if configure_hosts_shared_folder "$vm"; then
			((++success))
		else
			((++failed))
			echo -e "${YELLOW}Note: Stop the VM and run this script again to add shared folder${NC}"
		fi

		# Inject hosts file directly into VM disk (the actual enforcement)
		inject_hosts_into_vm_disk "$vm" || true
	done

	echo -e "\n${GREEN}Enforcement complete!${NC}"
	echo -e "Successfully configured: ${success} VM(s)"
	[[ $failed -gt 0 ]] && echo -e "${YELLOW}Needs VM shutdown for full config: ${failed} VM(s)${NC}"

	# Mark that enforcement has been applied
	touch "$HOSTS_ENFORCEMENT_MARKER"
}

# Check if a single VM has the shared folder configured
vm_has_shared_folder() {
	local vm_name="$1"
	vboxmanage_as_user showvminfo "$vm_name" --machinereadable 2>/dev/null |
		grep -q "SharedFolderNameMachineMapping.*=\"${VBOX_SHARED_FOLDER_NAME}\""
}

# Check if enforcement is applied to ALL registered VMs
check_enforcement_status() {
	local -a vms
	mapfile -t vms < <(get_all_vms)

	if [[ ${#vms[@]} -eq 0 ]]; then
		echo -e "${GREEN}No VMs to enforce.${NC}"
		return 0
	fi

	for vm in "${vms[@]}"; do
		if ! vm_has_shared_folder "$vm"; then
			echo -e "${YELLOW}VM '${vm}' is missing hosts enforcement.${NC}"
			return 1
		fi
	done

	echo -e "${GREEN}All ${#vms[@]} VM(s) have hosts enforcement applied.${NC}"
	return 0
}

# Show status
show_status() {
	echo -e "${CYAN}VirtualBox Hosts Enforcement Status${NC}"
	echo -e "${CYAN}====================================${NC}\n"

	local -a all_vms running_vms
	mapfile -t all_vms < <(get_all_vms)
	mapfile -t running_vms < <(get_running_vms)

	echo -e "Total VMs: ${#all_vms[@]}"
	echo -e "Running VMs: ${#running_vms[@]}"

	if check_enforcement_status >/dev/null 2>&1; then
		echo -e "Enforcement status: ${GREEN}Applied to all VMs${NC}"
	else
		echo -e "Enforcement status: ${RED}Not fully applied${NC}"
	fi

	echo -e "\n${CYAN}VMs:${NC}"
	for vm in "${all_vms[@]}"; do
		local flags=""
		if printf '%s\n' "${running_vms[@]}" | grep -qx "$vm"; then
			flags+=" ${GREEN}[RUNNING]${NC}"
		fi
		if vm_has_shared_folder "$vm"; then
			flags+=" ${GREEN}[ENFORCED]${NC}"
		else
			flags+=" ${RED}[NOT ENFORCED]${NC}"
		fi
		echo -e "  - ${vm}${flags}"
	done
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
