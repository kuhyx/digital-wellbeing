#!/bin/bash
# Managed by setup_night_lockdown.sh — do not edit by hand.
#
# Bring the display manager up and make sure it STAYS up. Called by
# night-lockdown-unlock.sh both on the normal lift and on any later morning
# trigger that finds state UNLOCKED but the GUI down.
#
# Why this exists (2026-11-20): the nightly auto-update installed a new NVIDIA
# userspace + kernel while the PC sat in lockdown. At 05:00 lightdm started,
# Xorg died on "NVRM: API mismatch", lightdm hit its start limit and the PC sat
# on the text console all morning. A plain `systemctl start` cannot fix that.
#
# Exit status: 0 = GUI up (or nothing more to try this tick);
#              75 = the driver cannot load on the running kernel and no reboot
#                   happened yet today: the caller must reboot (after it has
#                   recorded its own state, which is why we do not do it here).
set -euo pipefail

readonly CONF_FILE="/etc/night-lockdown.conf"
readonly STATE_DIR="/var/lib/night-lockdown"
readonly REBOOT_MARKER="$STATE_DIR/gui_recover_reboot_day"
readonly EX_REBOOT=75

# shellcheck source=/dev/null
[[ -r "$CONF_FILE" ]] && source "$CONF_FILE"
DISPLAY_MANAGER_UNIT="${DISPLAY_MANAGER_UNIT:-lightdm.service}"
# How long the display manager must survive after start. Xorg dies within ~1 s
# on a driver mismatch, and systemd reports "active" in between restarts.
DM_SETTLE_SECONDS="${DM_SETTLE_SECONDS:-8}"
# Missing after pacman upgraded the kernel without a reboot: no module of the
# running kernel can be loaded any more, so only a reboot helps.
KERNEL_MODULES_DIR="${KERNEL_MODULES_DIR:-/usr/lib/modules/$(uname -r)}"
DRY_RUN="${DRY_RUN:-}"

logg() { logger -t night-lockdown "$*"; printf 'night-lockdown: %s\n' "$*"; }
run() {
	if [[ "$DRY_RUN" == "1" ]]; then
		logg "DRY_RUN: would run: $*"
		return 0
	fi
	"$@" || logg "WARN: command failed (continuing): $*"
}

# No nvidia-smi = no NVIDIA stack to check. A failing one means the loaded
# kernel module and the installed userspace disagree (or no module is loaded).
driver_ok() {
	command -v nvidia-smi >/dev/null 2>&1 || return 0
	timeout 15 nvidia-smi >/dev/null 2>&1
}

reload_driver() {
	logg "NVIDIA driver/library mismatch — reloading the kernel modules"
	run systemctl stop nvidia-persistenced.service
	run modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia
	run modprobe nvidia_drm
	run modprobe nvidia_uvm
}

if ! driver_ok; then
	[[ -d "$KERNEL_MODULES_DIR" ]] && reload_driver
	if ! driver_ok; then
		today="$(date +%F)"
		if [[ "$(cat "$REBOOT_MARKER" 2>/dev/null || true)" == "$today" ]]; then
			logg "WARN: NVIDIA driver still unusable after today's reboot — GUI left down"
			exit 0
		fi
		logg "NVIDIA driver cannot load on the running kernel — reboot required"
		[[ "$DRY_RUN" == "1" ]] || echo "$today" >"$REBOOT_MARKER"
		exit "$EX_REBOOT"
	fi
	logg "NVIDIA driver usable again"
fi

# A unit that hit start-limit-hit refuses a plain start until reset.
run systemctl reset-failed "$DISPLAY_MANAGER_UNIT"
run systemctl start "$DISPLAY_MANAGER_UNIT"
[[ "$DRY_RUN" == "1" ]] && exit 0
sleep "$DM_SETTLE_SECONDS"
if systemctl is-active --quiet "$DISPLAY_MANAGER_UNIT"; then
	logg "$DISPLAY_MANAGER_UNIT is up"
else
	logg "WARN: $DISPLAY_MANAGER_UNIT did not stay up — the next morning trigger retries"
fi
