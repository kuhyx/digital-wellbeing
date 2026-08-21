#!/bin/bash

# ============================================================================
# setup_night_lockdown.sh
#
# Installs the "night lockdown" action that REPLACES the midnight power-off.
#
# This machine is a 24/7 home server (Gitea, the Caddy TLS edge, SyncYomi, the
# personal website, Open WebUI, Joplin, dufs, ollama, dnsmasq, wg-quick@wg0,
# nftables, sshd). The old digital-wellbeing curfew powered the PC off at night,
# which also took every server down. Night lockdown keeps the curfew's lockout
# intent but leaves the machine ON: it tears down the user GUI and masks the
# TTY login surface so the machine is unusable from the keyboard, while every
# background server keeps running. At 05:00 a morning timer restores the desktop.
#
# The evening/morning SCHEDULE and its anti-tamper guards still live in
# setup_midnight_shutdown.sh; that script's terminal action is swapped to call
# night-lockdown-enter.sh instead of powering off. This installer owns only the
# lock/unlock action and the morning-unlock timer, and is deliberately NOT made
# immutable so the reversal path can always be iterated and can never be taken
# down by a bug in the (guarded) lock path.
#
# HARD LOCKOUT: the only recovery path once locked is SSH (WireGuard / LAN).
# `setup_night_lockdown.sh unlock` restores the GUI immediately over SSH.
#
# Usage:
#   sudo ./setup_night_lockdown.sh setup     # install / re-install (idempotent)
#   ./setup_night_lockdown.sh status         # show current state
#   sudo ./setup_night_lockdown.sh unlock    # emergency: lift lockdown now (SSH)
#   ./setup_night_lockdown.sh help
# ============================================================================

set -euo pipefail

# shellcheck source=lib/nl_commands.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/nl_commands.sh"

# shellcheck source=lib/nl_config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/nl_config.sh"

# shellcheck source=lib/nl_units.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/nl_units.sh"

# shellcheck source=lib/nl_unlock.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/nl_unlock.sh"

# shellcheck source=lib/nl_enter.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/nl_enter.sh"

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/../../lib/common.sh"

# --- Installed artifact locations -------------------------------------------
readonly ENTER_SCRIPT="/usr/local/bin/night-lockdown-enter.sh"
readonly UNLOCK_SCRIPT="/usr/local/bin/night-lockdown-unlock.sh"
readonly CONF_FILE="/etc/night-lockdown.conf"
readonly STATE_DIR="/var/lib/night-lockdown"
readonly STATE_FILE="$STATE_DIR/state"
readonly I2C_MODULES_FILE="/etc/modules-load.d/night-lockdown-i2c.conf"
readonly UNLOCK_SERVICE="/etc/systemd/system/night-lockdown-unlock.service"
readonly UNLOCK_TIMER="/etc/systemd/system/night-lockdown-unlock.timer"
readonly RGB_OFF_SERVICE="/etc/systemd/system/rgb-off.service"
readonly OVERRIDE_MANAGER="/usr/local/bin/shutdown-override-manager.sh"
# HOME openrgb runs with; must match RGB_HOME in the generated config.
readonly RGB_HOME_DEFAULT="/root"
readonly MANAGED_BANNER="# Managed by setup_night_lockdown.sh — do not edit by hand."

# =============================================================================
# Hardware / environment detection (run at install time, written into the conf)
# =============================================================================

# =============================================================================
# The lock action — installed to $ENTER_SCRIPT
# =============================================================================

# =============================================================================
# The reversal — installed to $UNLOCK_SCRIPT
# =============================================================================

# =============================================================================
# Morning-unlock systemd timer family (outside the shutdown fortress)
# =============================================================================

install_i2c_modules() {
	log_info "Installing i2c module-load for future RGB support"
	cat >"$I2C_MODULES_FILE" <<EOF
$MANAGED_BANNER
# SMBus/i2c so OpenRGB can eventually reach motherboard/RAM RGB controllers.
i2c-dev
i2c-piix4
EOF
	chmod 0644 "$I2C_MODULES_FILE"
	# Load now too (harmless if already loaded); ignore failure on odd hardware.
	modprobe i2c-dev 2>/dev/null || true
	modprobe i2c-piix4 2>/dev/null || true
}

# =============================================================================
# Install verification
# =============================================================================

# =============================================================================
# Subcommands
# =============================================================================

main() {
	local cmd="${1:-setup}"
	# Elevate BEFORE shifting so the subcommand survives the sudo re-exec.
	case "$cmd" in
	setup | unlock) require_root "$@" ;;
	esac
	shift || true
	case "$cmd" in
	setup) cmd_setup "$@" ;;
	status) cmd_status "$@" ;;
	unlock) cmd_unlock "$@" ;;
	help | -h | --help) usage ;;
	*)
		log_error "Unknown command: $cmd"
		usage
		exit 1
		;;
	esac
}

main "$@"
