#!/bin/bash
# filepath: /home/kuhy/linux-configuration/scripts/install_pacman_wrapper.sh

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
WORDS_SOURCE="$(dirname "$0")/words.txt"
BLOCKED_SOURCE="$(dirname "$0")/pacman_blocked_keywords.txt"
WHITELIST_SOURCE="$(dirname "$0")/pacman_whitelist.txt"
GREYLIST_SOURCE="$(dirname "$0")/pacman_greylist.txt"
INSTALL_DIR="/usr/local/bin"
WRAPPER_DEST="${INSTALL_DIR}/pacman_wrapper"
WORDS_DEST="${INSTALL_DIR}/words.txt"
BLOCKED_DEST="${INSTALL_DIR}/pacman_blocked_keywords.txt"
WHITELIST_DEST="${INSTALL_DIR}/pacman_whitelist.txt"
GREYLIST_DEST="${INSTALL_DIR}/pacman_greylist.txt"
INTEGRITY_DIR="/var/lib/pacman-wrapper"
INTEGRITY_FILE="${INTEGRITY_DIR}/policy.sha256"
VBOX_ENFORCE_SOURCE="$(dirname "$0")/../virtualbox/enforce_vbox_hosts.sh"
VBOX_INSTALL_DIR="/usr/local/share/digital_wellbeing/virtualbox"
VBOX_ENFORCE_DEST="${VBOX_INSTALL_DIR}/enforce_vbox_hosts.sh"
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
cp "$WRAPPER_SOURCE" "$WRAPPER_DEST"
cp "$WORDS_SOURCE" "$WORDS_DEST"
if [ -f "$BLOCKED_SOURCE" ]; then
  cp "$BLOCKED_SOURCE" "$BLOCKED_DEST"
else
  echo -e "${YELLOW}Warning:${NC} Missing blocked keywords source at ${BLOCKED_SOURCE}${NC}"
fi

if [ -f "$WHITELIST_SOURCE" ]; then
  cp "$WHITELIST_SOURCE" "$WHITELIST_DEST"
else
  echo -e "${YELLOW}Warning:${NC} Missing whitelist source at ${WHITELIST_SOURCE}${NC}"
fi

if [ -f "$GREYLIST_SOURCE" ]; then
  cp "$GREYLIST_SOURCE" "$GREYLIST_DEST"
else
  echo -e "${YELLOW}Warning:${NC} Missing greylist source at ${GREYLIST_SOURCE}${NC}"
fi
chmod +x "$WRAPPER_DEST"
chmod 644 "$WORDS_DEST" "$BLOCKED_DEST" "$WHITELIST_DEST" "$GREYLIST_DEST" 2> /dev/null || true

# Automatically use symbolic link installation method
echo -e "${YELLOW}Installing using symbolic link method...${NC}"

# Backup original pacman
if [ ! -f "/usr/bin/pacman.orig" ]; then
  echo -e "${BLUE}Backing up original pacman to /usr/bin/pacman.orig...${NC}"
  cp /usr/bin/pacman /usr/bin/pacman.orig
fi

# Update the PACMAN_BIN variable in the wrapper to point to the original
sed -i 's|PACMAN_BIN="\/usr\/bin\/pacman"|PACMAN_BIN="\/usr\/bin\/pacman.orig"|g' "$WRAPPER_DEST"

# Create integrity directory if it doesn't exist
mkdir -p "$INTEGRITY_DIR"
chmod 755 "$INTEGRITY_DIR"

# Generate checksums of policy files for integrity verification
echo -e "${BLUE}Generating integrity checksums for policy files...${NC}"

# Ensure all critical policy files exist before checksumming
missing_files=()
[[ ! -f "$BLOCKED_DEST" ]] && missing_files+=("$BLOCKED_DEST")
[[ ! -f "$GREYLIST_DEST" ]] && missing_files+=("$GREYLIST_DEST")

if [[ ${#missing_files[@]} -gt 0 ]]; then
  echo -e "${RED}Error: Critical policy files are missing:${NC}"
  printf '%s\n' "${missing_files[@]}" >&2
  echo -e "${RED}Installation incomplete. Cannot create integrity file.${NC}"
  exit 1
fi

{
  sha256sum "$BLOCKED_DEST" || { echo -e "${RED}Failed to checksum blocked list${NC}" >&2; exit 1; }
  sha256sum "$GREYLIST_DEST" || { echo -e "${RED}Failed to checksum greylist${NC}" >&2; exit 1; }
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
  # Note: whitelist is intentionally left modifiable for user convenience
else
  echo -e "${YELLOW}Warning: chattr not available, policy files will not be immutable${NC}"
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
echo -e "${CYAN}Policy files are now protected with immutable attributes.${NC}"
if [ -f "$VBOX_ENFORCE_DEST" ]; then
  echo -e "${CYAN}VirtualBox VMs will automatically be configured to use host's /etc/hosts.${NC}"
fi
