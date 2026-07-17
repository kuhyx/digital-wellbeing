#!/bin/bash
# filepath: /home/kuhy/linux-configuration/scripts/install_pacman_wrapper.sh

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

# Script locations
WRAPPER_SOURCE="$(dirname "$0")/pacman_wrapper.sh"
LOCK_LIB_SOURCE="$(dirname "$0")/pacman_lock_lib.sh"
WORDS_SOURCE="$(dirname "$0")/words.txt"
BLOCKED_SOURCE="$(dirname "$0")/pacman_blocked_keywords.txt"
WHITELIST_SOURCE="$(dirname "$0")/pacman_whitelist.txt"
GREYLIST_SOURCE="$(dirname "$0")/pacman_greylist.txt"
MAKEPKG_CAPPED_SOURCE="$(dirname "$0")/makepkg_capped.sh"
MKPKG_SOURCE="$(dirname "$0")/mkpkg.sh"
INSTALL_DIR="/usr/local/bin"
WRAPPER_DEST="${INSTALL_DIR}/pacman_wrapper"
LOCK_LIB_DEST="${INSTALL_DIR}/pacman_lock_lib.sh"
WORDS_DEST="${INSTALL_DIR}/words.txt"
BLOCKED_DEST="${INSTALL_DIR}/pacman_blocked_keywords.txt"
WHITELIST_DEST="${INSTALL_DIR}/pacman_whitelist.txt"
GREYLIST_DEST="${INSTALL_DIR}/pacman_greylist.txt"
MAKEPKG_CAPPED_DEST="${INSTALL_DIR}/makepkg_capped"
MKPKG_DEST="${INSTALL_DIR}/mkpkg"
INTEGRITY_DIR="/var/lib/pacman-wrapper"
INTEGRITY_FILE="${INTEGRITY_DIR}/policy.sha256"
LEECHBLOCK_INSTALLER_SOURCE="$(dirname "$0")/../install_leechblock.sh"
LEECHBLOCK_DEFAULTS_SOURCE="$(dirname "$0")/../leechblock_defaults.json"
LEECHBLOCK_SEEDER_SOURCE="$(dirname "$0")/../seed_leechblock_storage.js"
LEECHBLOCK_PKG_SOURCE="$(dirname "$0")/../package.json"
LEECHBLOCK_INSTALL_DIR="/usr/local/share/digital_wellbeing"
LEECHBLOCK_INSTALLER_DEST="${LEECHBLOCK_INSTALL_DIR}/install_leechblock.sh"
LEECHBLOCK_DEFAULTS_DEST="${LEECHBLOCK_INSTALL_DIR}/leechblock_defaults.json"
LEECHBLOCK_SEEDER_DEST="${LEECHBLOCK_INSTALL_DIR}/seed_leechblock_storage.js"
VBOX_ENFORCE_SOURCE="$(dirname "$0")/../virtualbox/enforce_vbox_hosts.sh"
VBOX_INSTALL_DIR="/usr/local/share/digital_wellbeing/virtualbox"
VBOX_ENFORCE_DEST="${VBOX_INSTALL_DIR}/enforce_vbox_hosts.sh"

declare -a RELock_FILES=()

is_immutable_file() {
  local file_path="$1"
  [[ -e "$file_path" ]] || return 1
  [[ $(lsattr -d "$file_path" 2>/dev/null | awk '{print $1}') == *i* ]]
}

unlock_immutable_file_if_needed() {
  local file_path="$1"
  if ! command -v chattr >/dev/null 2>&1; then
    return 0
  fi
  if is_immutable_file "$file_path"; then
    chattr -i "$file_path"
    RELock_FILES+=("$file_path")
  fi
}

relock_files_on_exit() {
  if ! command -v chattr >/dev/null 2>&1; then
    return
  fi
  for file_path in "${RELock_FILES[@]}"; do
    [[ -e "$file_path" ]] || continue
    chattr +i "$file_path" 2>/dev/null || true
  done
}

copy_managed_file() {
  local source_file="$1"
  local dest_file="$2"
  local required="$3"
  local label="$4"

  if [[ ! -f "$source_file" ]]; then
    if [[ "$required" == "required" ]]; then
      echo -e "${RED}Error:${NC} Missing required ${label} at ${source_file}" >&2
      exit 1
    fi
    echo -e "${YELLOW}Warning:${NC} Missing ${label} at ${source_file}" >&2
    return
  fi

  unlock_immutable_file_if_needed "$dest_file"
  cp "$source_file" "$dest_file"
}

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
chmod 644 "$WORDS_DEST" "$BLOCKED_DEST" "$WHITELIST_DEST" "$GREYLIST_DEST" 2> /dev/null || true

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

# Create integrity directory if it doesn't exist
mkdir -p "$INTEGRITY_DIR"
chmod 755 "$INTEGRITY_DIR"

# Generate checksums of policy files for integrity verification
echo -e "${BLUE}Generating integrity checksums for policy files...${NC}"
unlock_immutable_file_if_needed "$INTEGRITY_FILE"

# Ensure all critical policy files exist before checksumming
missing_files=()
[[ ! -f "$BLOCKED_DEST" ]] && missing_files+=("$BLOCKED_DEST")
[[ ! -f "$GREYLIST_DEST" ]] && missing_files+=("$GREYLIST_DEST")
[[ ! -f "$LOCK_LIB_DEST" ]] && missing_files+=("$LOCK_LIB_DEST")

if [[ ${#missing_files[@]} -gt 0 ]]; then
  echo -e "${RED}Error: Critical policy files are missing:${NC}"
  printf '%s\n' "${missing_files[@]}" >&2
  echo -e "${RED}Installation incomplete. Cannot create integrity file.${NC}"
  exit 1
fi

{
  sha256sum "$BLOCKED_DEST" || { echo -e "${RED}Failed to checksum blocked list${NC}" >&2; exit 1; }
  sha256sum "$GREYLIST_DEST" || { echo -e "${RED}Failed to checksum greylist${NC}" >&2; exit 1; }
  # The shared stale-lock library is executed (sourced) by the wrapper, so it is
  # integrity-checked too: pacman_wrapper.sh sources it only AFTER
  # verify_policy_integrity passes, so a tampered lib is rejected before it runs.
  sha256sum "$LOCK_LIB_DEST" || { echo -e "${RED}Failed to checksum lock library${NC}" >&2; exit 1; }
  # Whitelist is optional
  if [[ -f "$WHITELIST_DEST" ]]; then
    sha256sum "$WHITELIST_DEST" || { echo -e "${RED}Failed to checksum whitelist${NC}" >&2; exit 1; }
  fi
} > "$INTEGRITY_FILE"

# Verify integrity file was created and has content
if [[ ! -s "$INTEGRITY_FILE" ]]; then
  echo -e "${RED}Error: Integrity file was not created or is empty${NC}"
  exit 1
fi

# Make integrity file immutable
chmod 400 "$INTEGRITY_FILE"
if command -v chattr > /dev/null 2>&1; then
  chattr +i "$INTEGRITY_FILE" 2>/dev/null || echo -e "${YELLOW}Warning: Could not make integrity file immutable${NC}"
fi

# Make policy files immutable to prevent easy tampering
echo -e "${BLUE}Protecting policy files from modification...${NC}"
if command -v chattr > /dev/null 2>&1; then
  chattr +i "$BLOCKED_DEST" 2>/dev/null || echo -e "${YELLOW}Warning: Could not make blocked list immutable${NC}"
  chattr +i "$GREYLIST_DEST" 2>/dev/null || echo -e "${YELLOW}Warning: Could not make greylist immutable${NC}"
  chattr +i "$LOCK_LIB_DEST" 2>/dev/null || echo -e "${YELLOW}Warning: Could not make lock library immutable${NC}"
  # Note: whitelist is intentionally left modifiable for user convenience
else
  echo -e "${YELLOW}Warning: chattr not available, policy files will not be immutable${NC}"
fi

# Install LeechBlock installer and defaults if available
mkdir -p "$LEECHBLOCK_INSTALL_DIR"
if [ -f "$LEECHBLOCK_INSTALLER_SOURCE" ]; then
  echo -e "${BLUE}Installing LeechBlock installer to ${LEECHBLOCK_INSTALLER_DEST}...${NC}"
  cp "$LEECHBLOCK_INSTALLER_SOURCE" "$LEECHBLOCK_INSTALLER_DEST"
  chmod +x "$LEECHBLOCK_INSTALLER_DEST"
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

# Install VirtualBox enforcement script if available
if [ -f "$VBOX_ENFORCE_SOURCE" ]; then
  echo -e "${BLUE}Installing VirtualBox hosts enforcement script...${NC}"
  mkdir -p "$VBOX_INSTALL_DIR"
  cp "$VBOX_ENFORCE_SOURCE" "$VBOX_ENFORCE_DEST"
  chmod +x "$VBOX_ENFORCE_DEST"
  echo -e "${GREEN}VirtualBox enforcement script installed to ${VBOX_ENFORCE_DEST}${NC}"
else
  echo -e "${YELLOW}VirtualBox enforcement script not found, skipping...${NC}"
fi

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
