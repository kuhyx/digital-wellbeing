#!/bin/bash
# Install Focus Mode Daemon
# Sets up Steam/Browser mutual exclusion as a systemd user service

set -euo pipefail

# This script manages a systemd USER unit, so every `systemctl --user` call needs
# the invoking user's session bus. When run via `sudo -u <user> ...` — which is
# exactly how check_and_enable_services.sh repairs this service — sudo changes the
# UID but grants NO session: XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS stay
# unset and systemctl dies with "Failed to connect to user scope bus via local
# transport". That killed this installer at its daemon-reload step on every
# automated run, which is why focus-mode was never actually installed. Derive the
# session paths from the effective UID when they are not already provided.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

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
- Use "focus-mode-daemon whitelist" to temporarily allow browsers for auth flows
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

	# Symlink rather than copy. A copy goes stale the instant the repo file is
	# edited, so the daemon being run silently stops matching the daemon being
	# read - which is exactly how a fix for phantom Steam detection sat in the
	# repo while the months-old copy at $INSTALL_PATH went on killing browsers.
	# A link means editing the repo file IS deploying it.
	#
	# The target lives in the user's checkout, so $INSTALL_PATH is only as
	# trustworthy as that path. That is fine here: focus-mode runs as a systemd
	# *user* service, so no privilege boundary is crossed.
	chmod +x "$DAEMON_SCRIPT"
	msg "Linking $INSTALL_PATH -> $DAEMON_SCRIPT"
	if [[ $EUID -eq 0 ]]; then
		ln -sfn "$DAEMON_SCRIPT" "$INSTALL_PATH"
	else
		sudo ln -sfn "$DAEMON_SCRIPT" "$INSTALL_PATH"
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
	echo "  systemctl --user status focus-mode       - Check daemon status"
	echo "  journalctl --user -u focus-mode -f       - View daemon logs"
	echo "  cat ~/.local/state/focus-mode/status     - View current mode"
	echo ""
	echo "Browser Whitelist (for auth/verification flows):"
	echo "  focus-mode-daemon whitelist               - Allow browsers for 5 minutes"
	echo "  focus-mode-daemon whitelist 10            - Allow browsers for 10 minutes"
	echo "  focus-mode-daemon cancel-whitelist        - Cancel whitelist early"
	echo "  focus-mode-daemon status                  - Check whitelist status"
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

	# Remove installed script. -L as well as -e: $INSTALL_PATH is a symlink into
	# the checkout, and -e alone reports false for one whose target is gone -
	# exactly the case (repo moved or deleted) where the stale link most needs
	# clearing.
	if [[ -e "$INSTALL_PATH" || -L "$INSTALL_PATH" ]]; then
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
