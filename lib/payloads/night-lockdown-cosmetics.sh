#!/bin/bash
# Managed by setup_night_lockdown.sh — do not edit by hand.
#
# Night-lockdown COSMETICS: RGB off, CPU/GPU power caps, audio mute, tray-app
# teardown, optional GPU unbind. Called by night-lockdown-enter.sh AFTER the
# curfew is already enforced, as one child under `timeout`, so nothing in
# here can ever delay or defeat the lockout. Every external call is bounded
# again individually, because one wedged tool must not starve the others of
# the parent's budget (openrgb 1.0-2 hung forever in a hidraw read, 2026-09-12).
#
# All steps are best-effort and logged; DRY_RUN=1 logs intended actions only.
set -euo pipefail

readonly CONF_FILE="/etc/night-lockdown.conf"
readonly STATE_DIR="/var/lib/night-lockdown"

# shellcheck source=/dev/null
[[ -r "$CONF_FILE" ]] && source "$CONF_FILE"
LOCK_USER="${LOCK_USER:-}"
LOCK_UID="${LOCK_UID:-}"
ALSA_CARDS="${ALSA_CARDS:-}"
RGB_ENABLE="${RGB_ENABLE:-1}"
RGB_OFF_MODE="${RGB_OFF_MODE:-static}"
RGB_OFF_COLOR="${RGB_OFF_COLOR:-000000}"
RGB_HOME="${RGB_HOME:-/root}"
MONITORED_USER_UNITS="${MONITORED_USER_UNITS:-}"
MONITORED_PROCS="${MONITORED_PROCS:-}"
POWER_SAVE_ENABLE="${POWER_SAVE_ENABLE:-1}"
CPU_EPP_NIGHT="${CPU_EPP_NIGHT:-power}"
GPU_POWER_LIMIT_NIGHT_WATTS="${GPU_POWER_LIMIT_NIGHT_WATTS:-100}"
GPU_UNBIND_ENABLE="${GPU_UNBIND_ENABLE:-0}"
CONSOLE_BLANK_MODE="${CONSOLE_BLANK_MODE:-1}"
# Per-tool ceiling. openrgb needs ~2s to detect, nvidia-smi ~1s; anything past
# this is a hang, and a hang here is worth a WARN, not a wait.
TOOL_TIMEOUT="${TOOL_TIMEOUT:-30}"
DRY_RUN="${DRY_RUN:-}"

logg() { logger -t night-lockdown "$*"; printf 'night-lockdown: %s\n' "$*"; }

if [[ "$DRY_RUN" == "1" ]]; then
	logg "DRY_RUN NOTE: The CPU EPP write, nvidia-smi power-limit cap, and (if"
	logg "DRY_RUN NOTE: enabled) GPU PCI-unbind are never actually applied under"
	logg "DRY_RUN NOTE: DRY_RUN — real-hardware timing/driver behavior for those"
	logg "DRY_RUN NOTE: is unverified until a real run."
fi

# Run a command best-effort: log-only under DRY_RUN, never abort the script.
run() {
	if [[ "$DRY_RUN" == "1" ]]; then
		logg "DRY_RUN: would run: $*"
		return 0
	fi
	if ! "$@"; then
		logg "WARN: command failed (continuing): $*"
	fi
}

# Same, but with a hard ceiling: TERM at TOOL_TIMEOUT, KILL 5s later.
# --foreground keeps the tool in THIS script's process group. Without it,
# timeout(1) moves its child into a fresh group, and when the parent's outer
# `timeout` (in night-lockdown-enter.sh) kills this script's group on expiry,
# the tool would survive as an orphan still holding the journal pipe.
bounded() {
	run timeout --foreground --kill-after=5 "$TOOL_TIMEOUT" "$@"
}

# Run a command as the desktop user inside their session bus. After the GUI
# teardown /run/user/UID is usually gone already, which makes this a no-op —
# the units die with X anyway; this only tidies the case where they did not.
run_as_user() {
	[[ -n "$LOCK_USER" && -n "$LOCK_UID" && -d "/run/user/$LOCK_UID" ]] || return 0
	bounded sudo -u "$LOCK_USER" env "XDG_RUNTIME_DIR=/run/user/$LOCK_UID" "$@"
}

mkdir -p "$STATE_DIR"

# 1. RGB off (RAM + board + GPU).
#
#    Do NOT gate this on `openrgb --list-devices`: that call is broken in the
#    openrgb-git build — it returns in ~70ms, before async detection finishes,
#    so it always reports zero devices. Stable openrgb detects properly (~2s)
#    before acting. Bounded: openrgb 1.0-2 never returns on this hardware.
if [[ "$RGB_ENABLE" == "1" ]] && command -v openrgb >/dev/null 2>&1; then
	bounded env HOME="$RGB_HOME" openrgb --mode "$RGB_OFF_MODE" --color "$RGB_OFF_COLOR"
fi

# 2. Cap CPU/GPU power draw for the night. Save the pre-lockdown values first
#    so unlock restores exactly what was there, not a hardcoded "default" —
#    the user may have changed either away from factory settings.
#    Capture is guarded on the .prev file NOT already existing: a re-run
#    (enter is idempotent and re-applies on any mismatch) would otherwise
#    recapture "prev" from the already-applied NIGHT value and permanently
#    strand the machine in night power-save mode. unlock deletes the .prev
#    file after a successful restore, so a normal cycle captures fresh nightly.
if [[ "$POWER_SAVE_ENABLE" == "1" ]]; then
	if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]]; then
		if [[ "$DRY_RUN" != "1" && ! -f "$STATE_DIR/cpu_epp.prev" ]]; then
			cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference \
				>"$STATE_DIR/cpu_epp.prev" 2>/dev/null || true
		fi
		for epp_file in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
			[[ -e "$epp_file" ]] || continue
			if [[ "$DRY_RUN" == "1" ]]; then
				logg "DRY_RUN: would write $CPU_EPP_NIGHT > $epp_file"
			else
				echo "$CPU_EPP_NIGHT" >"$epp_file" 2>/dev/null || logg "WARN: could not set EPP on $epp_file"
			fi
		done
	fi

	if command -v nvidia-smi >/dev/null 2>&1; then
		if [[ "$DRY_RUN" != "1" && ! -f "$STATE_DIR/gpu_power_limit_watts.prev" ]]; then
			timeout "$TOOL_TIMEOUT" nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits \
				>"$STATE_DIR/gpu_power_limit_watts.prev" 2>/dev/null || true
		fi
		bounded nvidia-smi -pl "$GPU_POWER_LIMIT_NIGHT_WATTS"
	fi
fi

# 3. Mute audio (best-effort). The session teardown silences apps anyway; this
#    covers any direct-ALSA sound. PipeWire is intentionally NOT touched, so
#    the morning unlock cannot be defeated by a persisted wireplumber mute.
for card in $ALSA_CARDS; do
	command -v amixer >/dev/null 2>&1 && bounded amixer -c "$card" -q set Master mute
done

# 4. Stop GUI-bound user units + tray apps (they die with X anyway; be tidy).
for unit in $MONITORED_USER_UNITS; do
	run_as_user systemctl --user stop "$unit"
done
for proc in $MONITORED_PROCS; do
	# Only kill if actually running — pkill exits 1 on no-match, which would log
	# a misleading "command failed" WARN every night for an app that isn't up.
	if [[ -n "$LOCK_USER" ]] && pgrep -u "$LOCK_USER" -x "$proc" >/dev/null 2>&1; then
		run pkill -u "$LOCK_USER" -x "$proc"
	fi
done

# 5. Optionally unbind the GPU entirely (default OFF — see GPU_UNBIND_ENABLE
#    comment in night-lockdown.conf for the risk tradeoff). Only ever runs
#    after the GUI is torn down, since nothing interactive needs the GPU at
#    this point. Timeout-guarded: modprobe -r can hang if anything still
#    references the device, and a hang here must not block the rest.
if [[ "$GPU_UNBIND_ENABLE" == "1" ]] && command -v nvidia-smi >/dev/null 2>&1; then
	gpu_pci="$(lspci -d 10de: 2>/dev/null | grep -i 'VGA\|3D' | awk '{print $1}' | head -1)"
	if [[ -z "$gpu_pci" ]]; then
		logg "WARN: GPU_UNBIND_ENABLE=1 but no nvidia PCI device found"
	elif [[ "$DRY_RUN" == "1" ]]; then
		logg "DRY_RUN: would unload nvidia modules and remove PCI device 0000:$gpu_pci"
	elif timeout 20 modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>&1 | logger -t night-lockdown; then
		if echo 1 >"/sys/bus/pci/devices/0000:$gpu_pci/remove" 2>/dev/null; then
			logg "GPU unbound (0000:$gpu_pci removed from PCI bus)"
			# Unloading nvidia_drm / the PCI remove can surface a fallback
			# framebuffer that is not blanked — re-blank, same as enter does
			# after the VT switch, so the console stays dark.
			for fb in /sys/class/graphics/fb*/blank; do
				[[ -e "$fb" ]] && echo "$CONSOLE_BLANK_MODE" >"$fb" 2>/dev/null
			done
		else
			logg "WARN: modules unloaded but PCI remove failed for 0000:$gpu_pci"
		fi
	else
		logg "WARN: modprobe -r timed out or failed -- GPU left bound, skipping unbind"
	fi
fi

logg "cosmetics done — RGB off, power capped, audio muted"
