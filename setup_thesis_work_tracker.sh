#!/bin/bash
# Bachelor Thesis Work Tracker - One-Shot Installer
#
# This script installs a system that:
# 1. Monitors active windows for thesis-related work (Unreal Engine, Unity, Nvidia Omniverse, VS Code with specific repo)
# 2. Tracks accumulated work time with protection against tampering
# 3. Blocks Steam and other distractions via /etc/hosts until work quota is met
# 4. Provides psychological friction against circumvention
#
# The system is designed to be as hard to circumvent as possible:
# - State files are immutable (chattr +i)
# - Runs as a systemd service that auto-restarts
# - Integrated with hosts guard system
# - Protected against easy time manipulation
#
# Usage:
#   sudo ./setup_thesis_work_tracker.sh [options]
#
# Options:
#   --work-quota MINUTES       Set required work time in minutes (default: 120 = 2 hours)
#   --decay-rate MINUTES       Set decay rate per hour of distraction usage (default: 30)
#   --vscode-repo NAME         Set required VS Code repository name (default: praca_magisterska)
#   --dry-run                  Show what would be done without making changes
#   --uninstall                Remove the thesis work tracker system
#   -h|--help                  Show this help
#
# Exit codes:
#   0 = success
#   1 = general failure
#   2 = argument error

set -euo pipefail

######################################################################
# Configuration Defaults
######################################################################
WORK_QUOTA_MINUTES=120 # 2 hours of work required
DECAY_RATE_MINUTES=30  # Lose 30 minutes per hour of Steam usage
VSCODE_REPO="praca_magisterska"
DRY_RUN=0
UNINSTALL=0

######################################################################
# Paths
######################################################################
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
TRACKER_SCRIPT="$SCRIPT_DIR/thesis_work_tracker.sh"
STATUS_SCRIPT="$SCRIPT_DIR/thesis_work_status.sh"
SERVICE_FILE="$SCRIPT_DIR/systemd/thesis-work-tracker@.service"
INSTALL_BIN="/usr/local/bin/thesis_work_tracker.sh"
INSTALL_STATUS="/usr/local/bin/thesis_work_status"
INSTALL_SERVICE="/etc/systemd/system/thesis-work-tracker@.service"
STATE_DIR="/var/lib/thesis-work-tracker"
LOG_DIR="/var/log/thesis-work-tracker"

######################################################################
# Colors and Logging
######################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

msg() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
note() { printf "${BLUE}[i]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err() { printf "${RED}[x]${NC} %s\n" "$*" >&2; }

run() {
	if [[ $DRY_RUN -eq 1 ]]; then
		printf '%s[DRY-RUN]%s ' "${CYAN}" "${NC}"
		printf '%q ' "$@"
		printf '\n'
	else
		"$@"
	fi
}

######################################################################
# Helpers
######################################################################
require_root() {
	if [[ $EUID -ne 0 ]]; then
		exec sudo -E bash "$0" "$@"
	fi
}

usage() {
	head -n 31 "$0" | tail -n +2 | sed 's/^# \{0,1\}//'
}

check_dependencies() {
	local missing=()

	for cmd in xdotool systemctl; do
		if ! command -v "$cmd" &>/dev/null; then
			missing+=("$cmd")
		fi
	done

	if [[ ${#missing[@]} -gt 0 ]]; then
		err "Missing required dependencies: ${missing[*]}"
		note "Install them with: sudo pacman -S ${missing[*]}"
		return 1
	fi
}

get_current_user() {
	# Get the user who invoked sudo, or current user if not using sudo
	if [[ -n ${SUDO_USER:-} ]]; then
		echo "$SUDO_USER"
	else
		whoami
	fi
}

######################################################################
# Parse Arguments
######################################################################
while [[ $# -gt 0 ]]; do
	case "$1" in
	--work-quota)
		WORK_QUOTA_MINUTES="${2:-}"
		[[ -z $WORK_QUOTA_MINUTES ]] && {
			err "--work-quota requires a value"
			exit 2
		}
		if ! [[ $WORK_QUOTA_MINUTES =~ ^[0-9]+$ ]] || [[ $WORK_QUOTA_MINUTES -le 0 ]]; then
			err "--work-quota must be a positive integer (got: $WORK_QUOTA_MINUTES)"
			exit 2
		fi
		shift 2
		;;
	--decay-rate)
		DECAY_RATE_MINUTES="${2:-}"
		[[ -z $DECAY_RATE_MINUTES ]] && {
			err "--decay-rate requires a value"
			exit 2
		}
		if ! [[ $DECAY_RATE_MINUTES =~ ^[0-9]+$ ]] || [[ $DECAY_RATE_MINUTES -lt 0 ]]; then
			err "--decay-rate must be a non-negative integer (got: $DECAY_RATE_MINUTES)"
			exit 2
		fi
		shift 2
		;;
	--vscode-repo)
		VSCODE_REPO="${2:-}"
		[[ -z $VSCODE_REPO ]] && {
			err "--vscode-repo requires a value"
			exit 2
		}
		shift 2
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--uninstall)
		UNINSTALL=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		err "Unknown option: $1"
		usage
		exit 2
		;;
	esac
done

######################################################################
# Main Functions
######################################################################

uninstall_tracker() {
	msg "Uninstalling thesis work tracker..."

	# Get current user for service name
	local user
	user=$(get_current_user)

	# Stop and disable service
	if systemctl is-active --quiet "thesis-work-tracker@$user.service" 2>/dev/null; then
		run systemctl stop "thesis-work-tracker@$user.service"
	fi

	if systemctl is-enabled --quiet "thesis-work-tracker@$user.service" 2>/dev/null; then
		run systemctl disable "thesis-work-tracker@$user.service"
	fi

	# Remove service file
	if [[ -f $INSTALL_SERVICE ]]; then
		run rm -f "$INSTALL_SERVICE"
		run systemctl daemon-reload
	fi

	# Remove tracker script
	if [[ -f $INSTALL_BIN ]]; then
		run rm -f "$INSTALL_BIN"
	fi

	# Remove status script
	if [[ -f $INSTALL_STATUS ]]; then
		run rm -f "$INSTALL_STATUS"
	fi

	# Remove state directory (with immutable flags removed)
	if [[ -d $STATE_DIR ]]; then
		run chattr -i -R "$STATE_DIR" 2>/dev/null || true
		note "State directory preserved at: $STATE_DIR"
		note "To completely remove state: sudo rm -rf $STATE_DIR"
	fi

	msg "Thesis work tracker uninstalled successfully"
	note "Log files preserved at: $LOG_DIR"
}

install_tracker() {
	msg "Installing thesis work tracker..."

	# Check dependencies
	check_dependencies || exit 1

	# Verify source files exist
	if [[ ! -f $TRACKER_SCRIPT ]]; then
		err "Tracker script not found: $TRACKER_SCRIPT"
		exit 1
	fi

	if [[ ! -f $STATUS_SCRIPT ]]; then
		err "Status script not found: $STATUS_SCRIPT"
		exit 1
	fi

	if [[ ! -f $SERVICE_FILE ]]; then
		err "Service file not found: $SERVICE_FILE"
		exit 1
	fi

	# Create directories
	msg "Creating directories..."
	run mkdir -p "$LOG_DIR"
	run chmod 755 "$LOG_DIR"

	# Install tracker script with configuration
	msg "Installing tracker script to $INSTALL_BIN..."

	# Copy script and update configuration values
	run cp "$TRACKER_SCRIPT" "$INSTALL_BIN"

	# Update configuration in the installed script
	local work_quota_seconds=$((WORK_QUOTA_MINUTES * 60))
	local decay_rate_seconds=$((DECAY_RATE_MINUTES * 60))

	run sed -i "s/^WORK_QUOTA_REQUIRED=.*/WORK_QUOTA_REQUIRED=$work_quota_seconds  # $WORK_QUOTA_MINUTES minutes/" "$INSTALL_BIN"
	run sed -i "s/^WORK_DECAY_PER_HOUR=.*/WORK_DECAY_PER_HOUR=$decay_rate_seconds  # $DECAY_RATE_MINUTES minutes/" "$INSTALL_BIN"
	run sed -i "s/^VSCODE_REQUIRED_REPO=.*/VSCODE_REQUIRED_REPO=\"$VSCODE_REPO\"/" "$INSTALL_BIN"

	run chmod 755 "$INSTALL_BIN"

	# Install status script
	msg "Installing status script to $INSTALL_STATUS..."
	run cp "$STATUS_SCRIPT" "$INSTALL_STATUS"

	# Update quota in status script to match
	run sed -i "s/^WORK_QUOTA_REQUIRED=.*/WORK_QUOTA_REQUIRED=$work_quota_seconds  # $WORK_QUOTA_MINUTES minutes/" "$INSTALL_STATUS"

	run chmod 755 "$INSTALL_STATUS"

	# Install systemd service
	msg "Installing systemd service..."
	run cp "$SERVICE_FILE" "$INSTALL_SERVICE"
	run chmod 644 "$INSTALL_SERVICE"
	run systemctl daemon-reload

	# Get current user for service enablement
	local user
	user=$(get_current_user)

	# Enable and start service
	msg "Enabling and starting service for user: $user..."
	run systemctl enable "thesis-work-tracker@$user.service"
	run systemctl restart "thesis-work-tracker@$user.service"

	# Wait a moment for service to start
	sleep 2

	# Check service status
	if systemctl is-active --quiet "thesis-work-tracker@$user.service"; then
		msg "Service started successfully!"
	else
		warn "Service may not have started properly. Check status with:"
		warn "  systemctl status thesis-work-tracker@$user.service"
	fi

	# Display configuration summary
	echo ""
	echo "╔════════════════════════════════════════════════════════════════╗"
	echo "║         Bachelor Thesis Work Tracker - Installation           ║"
	echo "╚════════════════════════════════════════════════════════════════╝"
	echo ""
	echo "Configuration:"
	echo "  • Work quota required: ${BOLD}${WORK_QUOTA_MINUTES} minutes${NC}"
	echo "  • Decay rate (per hour of Steam): ${BOLD}${DECAY_RATE_MINUTES} minutes${NC}"
	echo "  • VS Code repository: ${BOLD}${VSCODE_REPO}${NC}"
	echo ""
	echo "Tracked Applications:"
	echo "  ✓ Unreal Engine (all versions)"
	echo "  ✓ Unity Editor"
	echo "  ✓ Nvidia Omniverse"
	echo "  ✓ Visual Studio Code (only when working on '$VSCODE_REPO')"
	echo ""
	echo "Blocked Sites (until quota met):"
	echo "  ⛔ Steam (all domains)"
	echo "  ⛔ Social media (Reddit, Twitter, Facebook, Instagram)"
	echo "  ⛔ Video sites (YouTube, Twitch)"
	echo "  ⛔ Other distractions (9gag, Imgur)"
	echo ""
	echo "System Protection Features:"
	echo "  🔒 State files protected with immutable flags"
	echo "  🔒 Auto-restart on failure"
	echo "  🔒 Integrated with hosts guard system"
	echo "  🔒 Continuous monitoring every 5 seconds"
	echo ""
	echo "How it works:"
	echo "  1. Work on your thesis using the approved applications"
	echo "  2. Time accumulates in the background"
	echo "  3. After ${WORK_QUOTA_MINUTES} minutes of work, Steam is unblocked"
	echo "  4. Steam usage decays your work time at ${DECAY_RATE_MINUTES} min/hour"
	echo "  5. When work time drops below quota, Steam is blocked again"
	echo ""
	echo "Useful Commands:"
	echo "  • Check progress: thesis_work_status"
	echo "  • Check status:   systemctl status thesis-work-tracker@$user.service"
	echo "  • View logs:      tail -f $LOG_DIR/tracker.log"
	echo "  • View state:     sudo cat $STATE_DIR/work-time.state"
	echo "  • Restart:        sudo systemctl restart thesis-work-tracker@$user.service"
	echo "  • Uninstall:      sudo $0 --uninstall"
	echo ""
	echo "⚠️  IMPORTANT: This system is designed to be hard to circumvent!"
	echo "    State files are immutable and the service auto-restarts."
	echo "    To legitimately modify settings, uninstall and reinstall."
	echo ""
	echo "Good luck with your bachelor thesis! 🎓"
	echo ""
}

######################################################################
# Main
######################################################################
require_root "$@"

if [[ $UNINSTALL -eq 1 ]]; then
	uninstall_tracker
else
	install_tracker
fi

exit 0
