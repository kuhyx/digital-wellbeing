#!/bin/bash
# Install Focus Mode Daemon
# Sets up Steam/Browser mutual exclusion as a systemd user service

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_SCRIPT="$SCRIPT_DIR/focus_mode_daemon.py"
INSTALL_PATH="/usr/local/bin/focus-mode-daemon"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/focus-mode.service"

msg() { printf '\e[1;32m[+]\e[0m %s\n' "$*"; }
note() { printf '\e[1;34m[i]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[!]\e[0m %s\n' "$*"; }
err() { printf '\e[1;31m[x]\e[0m %s\n' "$*" >&2; }

usage() {
	cat <<EOF
Focus Mode Daemon Installer

Usage: $0 [install|uninstall|status]

Commands:
  install   - Install and enable the focus mode daemon
  uninstall - Remove the daemon and disable the service
  status    - Show current daemon status

The daemon enforces mutual exclusion between Steam and web browsers:
- If Steam starts first: browsers are blocked/killed
- If browser starts first: Steam is blocked/killed
- Whichever started first "wins" until it exits
EOF
}

check_deps() {
	local missing=0

	if ! command -v python3 &>/dev/null; then
		err "python3 is required but not installed"
		missing=1
	fi

	if ! command -v systemctl &>/dev/null; then
		err "systemd is required but systemctl not found"
		missing=1
	fi

	if [[ $missing -eq 1 ]]; then
		exit 1
	fi
}

install_daemon() {
	msg "Installing Focus Mode Daemon..."

	check_deps

	if [[ ! -f "$DAEMON_SCRIPT" ]]; then
		err "Daemon script not found: $DAEMON_SCRIPT"
		exit 1
	fi

	# Install the daemon script
	msg "Installing daemon script to $INSTALL_PATH"
	if [[ $EUID -eq 0 ]]; then
		install -m 755 "$DAEMON_SCRIPT" "$INSTALL_PATH"
	else
		sudo install -m 755 "$DAEMON_SCRIPT" "$INSTALL_PATH"
	fi

	# Create systemd user directory
	mkdir -p "$SERVICE_DIR"

	# Create the systemd user service
	msg "Creating systemd user service: $SERVICE_FILE"
	cat >"$SERVICE_FILE" <<'EOF'
[Unit]
Description=Focus Mode Daemon (Steam/Browser mutual exclusion)
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/local/bin/focus-mode-daemon
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

# Don't allow easy stopping (psychological friction)
RefuseManualStop=false

[Install]
WantedBy=default.target
EOF

	# Reload systemd user daemon
	msg "Reloading systemd user daemon..."
	systemctl --user daemon-reload

	# Enable and start the service
	msg "Enabling and starting focus-mode.service..."
	systemctl --user enable focus-mode.service
	systemctl --user start focus-mode.service

	msg "Focus Mode Daemon installed successfully!"
	echo ""
	echo "The daemon is now running and will:"
	echo "  🎮 Block browsers when Steam is running"
	echo "  🌐 Block Steam when a browser is running"
	echo ""
	echo "Status: $(systemctl --user is-active focus-mode.service 2>/dev/null || echo 'unknown')"
	echo ""
	echo "Commands:"
	echo "  systemctl --user status focus-mode   - Check daemon status"
	echo "  journalctl --user -u focus-mode -f   - View daemon logs"
	echo "  cat ~/.local/state/focus-mode/status - View current mode"
	echo ""
}

uninstall_daemon() {
	msg "Uninstalling Focus Mode Daemon..."

	# Stop and disable service
	if systemctl --user is-active focus-mode.service &>/dev/null; then
		msg "Stopping focus-mode.service..."
		systemctl --user stop focus-mode.service || true
	fi

	if systemctl --user is-enabled focus-mode.service &>/dev/null; then
		msg "Disabling focus-mode.service..."
		systemctl --user disable focus-mode.service || true
	fi

	# Remove service file
	if [[ -f "$SERVICE_FILE" ]]; then
		msg "Removing service file..."
		rm -f "$SERVICE_FILE"
	fi

	# Reload daemon
	systemctl --user daemon-reload 2>/dev/null || true

	# Remove installed script
	if [[ -f "$INSTALL_PATH" ]]; then
		msg "Removing daemon script..."
		if [[ $EUID -eq 0 ]]; then
			rm -f "$INSTALL_PATH"
		else
			sudo rm -f "$INSTALL_PATH"
		fi
	fi

	msg "Focus Mode Daemon uninstalled"
	note "State files in ~/.local/state/focus-mode/ were NOT removed"
}

show_status() {
	echo "Focus Mode Daemon Status"
	echo "========================"
	echo ""

	# Service status
	if systemctl --user is-active focus-mode.service &>/dev/null; then
		echo "Service: ✓ Running"
	else
		echo "Service: ✗ Not running"
	fi

	if systemctl --user is-enabled focus-mode.service &>/dev/null; then
		echo "Enabled: ✓ Yes"
	else
		echo "Enabled: ✗ No"
	fi

	echo ""

	# Current mode
	local status_file="$HOME/.local/state/focus-mode/status"
	if [[ -f "$status_file" ]]; then
		echo "Current Mode:"
		cat "$status_file"
	else
		echo "Current Mode: Unknown (status file not found)"
	fi

	echo ""
	echo "Recent Logs:"
	journalctl --user -u focus-mode --no-pager -n 10 2>/dev/null || echo "  (no logs available)"
}

# Main
case "${1:-install}" in
install)
	install_daemon
	;;
uninstall)
	uninstall_daemon
	;;
status)
	show_status
	;;
-h | --help | help)
	usage
	;;
*)
	err "Unknown command: $1"
	usage
	exit 1
	;;
esac
