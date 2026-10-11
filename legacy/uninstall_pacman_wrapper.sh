#!/bin/bash
# Uninstall script for pacman wrapper

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit 1
fi

echo -e "${BLUE}Uninstalling pacman wrapper...${NC}"

# Remove alias if exists
if [ -f /etc/profile.d/pacman-wrapper.sh ]; then
  echo -e "${YELLOW}Removing alias file...${NC}"
  rm /etc/profile.d/pacman-wrapper.sh
fi

# Restore original pacman if needed
if [ -L /usr/bin/pacman ] && [ -f /usr/bin/pacman.orig ]; then
  echo -e "${YELLOW}Restoring original pacman...${NC}"
  rm /usr/bin/pacman
  cp /usr/bin/pacman.orig /usr/bin/pacman
fi

# Remove wrapper
if [ -f "/usr/local/bin/pacman_wrapper" ]; then
  echo -e "${YELLOW}Removing wrapper script...${NC}"
  rm "/usr/local/bin/pacman_wrapper"
fi

echo -e "${GREEN}Pacman wrapper has been uninstalled.${NC}"
echo -e "${YELLOW}Note:${NC} You may need to log out and log back in for changes to take effect."

# Self-destruct
rm "$0"
