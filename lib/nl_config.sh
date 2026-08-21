#!/usr/bin/env bash
# Helpers sourced by the entry script.

# Detect ALSA card indices that expose a 'Master' control (space-separated).
detect_alsa_cards() {
	local card cards=""
	for card in 0 1 2 3 4 5 6; do
		if amixer -c "$card" scontrols 2>/dev/null | grep -q "'Master'"; then
			cards+="${card} "
		fi
	done
	# Trim trailing space.
	echo "${cards% }"
}

# Write /etc/night-lockdown.conf with values detected for THIS machine.
write_config() {
	local user uid alsa_cards
	user="$ACTUAL_USER"
	uid="$(id -u "$user")"
	alsa_cards="$(detect_alsa_cards)"

	log_info "Writing config to $CONF_FILE (user=$user uid=$uid alsa_cards='$alsa_cards')"
	cat >"$CONF_FILE" <<EOF
$MANAGED_BANNER
# Desktop user whose GUI session is torn down at lockdown.
LOCK_USER="$user"
LOCK_UID="$uid"

# ALSA card indices with a 'Master' control, muted at lockdown (best-effort).
ALSA_CARDS="$alsa_cards"

# Kill all RGB via OpenRGB. Detected here: 2x ENE DRAM (RGB RAM, i2c 0x71/0x73),
# ZOTAC RTX 3090 (GPU), ASRock B650M Pro RS (USB Polychrome 26ce:01a2).
RGB_ENABLE="1"

# How to turn the lighting off. Use static + black, NOT the "off" mode:
#   - the ZOTAC GPU has no "Off" mode at all (its modes are Static/Breath/...);
#   - the ASRock board lists "Off" but silently ignores it (mode stayed Rainbow),
#     while static+black moves it to Static and goes dark.
# All four devices support Static, so this one form works everywhere. Verified:
# 'openrgb --mode static --color 000000' -> all 4 devices report ACTIVE: Static.
RGB_OFF_MODE="static"
RGB_OFF_COLOR="000000"

# HOME that openrgb runs with: it keeps its config under its own HOME, and
# systemd (HOME=/root) vs sudo (HOME=/home/USER) would otherwise disagree about
# where that config lives, so pin it for both directions.
RGB_HOME="/root"

# User systemd units (graphical-session-bound) stopped at lockdown, space-sep.
MONITORED_USER_UNITS="control-from-mobile.service"

# GUI tray processes (not systemd units) killed at lockdown, space-separated.
MONITORED_PROCS="aw-qt"

# Text console to blank at lockdown. Stopping lightdm hands the VT back to fbcon,
# which unblanks and prints kernel/systemd log spam instead of showing darkness.
CONSOLE_TTY="/dev/tty1"

# How hard to blank the console (/sys/class/graphics/fbN/blank value):
#   1 = FB_BLANK_NORMAL    — screen black, monitor keeps its signal. SAFE.
#   4 = FB_BLANK_POWERDOWN — DPMS off, monitor drops to standby.
# Do NOT use 4 here: DisplayPort drops its link when powered down, and the GPU
# then sees the connector as disconnected and will not re-train it on wake —
# DP-0 vanished from xrandr and needed the cable physically re-plugged. HDMI
# tolerates it, DP does not. 1 still gives a fully black screen, which is the
# whole point, without touching the link.
CONSOLE_BLANK_MODE="1"

# Never start the morning alarm earlier than lockdown-entry + this many hours,
# even though the unlock timer itself still fires on its normal staggered
# schedule (05:00/05:15/05:30/06:00/07:00). A late lockdown entry (e.g. 23:00
# instead of the usual 21:00) must not still wake you 6h later.
MIN_WAKE_AFTER_LOCKDOWN_HOURS="8"

# autorandr profile to restore after the GUI comes back up. Create it once with
# 'autorandr --save default' while all monitors are connected and arranged the
# way you want; the unlock script re-applies it so a DisplayPort link that
# didn't re-enumerate cleanly doesn't require a manual xrandr/replug.
AUTORANDR_PROFILE="default"

# Cap CPU/GPU power draw for the night as a safety net against anything left
# running headless overnight (interactive GPU/CPU load dies with the GUI
# teardown above, but a systemd service — e.g. ollama serving a request — does
# not). Set to "0" to disable without touching the enter/unlock scripts.
POWER_SAVE_ENABLE="1"

# AMD amd-pstate-epp hint applied to every core at lockdown (this machine is
# Ryzen, not Intel, so intel_pstate/no_turbo does not apply). One of: default,
# performance, balance_performance, balance_power, power, custom.
CPU_EPP_NIGHT="power"

# nvidia-smi power limit (watts) applied at lockdown. Set to this card's
# reported power.min_limit (100W on the RTX 3090 here) so a runaway overnight
# CUDA job is bounded, not eliminated — persistence mode is deliberately left
# alone so any legitimate headless GPU service keeps working, just slower.
GPU_POWER_LIMIT_NIGHT_WATTS="100"

# Fully unbind the GPU from the PCI bus at lockdown (unload nvidia kernel
# modules + PCI remove), rescanned back at unlock. Far more aggressive than
# the power-limit cap above: recovers more idle wattage, but modprobe -r can
# hang if anything still references the device, and a botched unbind might
# need a hard power-cycle to recover -- which WOULD take every container down
# with it (the one thing night-lockdown exists to prevent). Default OFF and
# deliberately left off: the first real run of this is an uncorroborated test
# on this exact kernel/driver, not a dress rehearsal -- nothing can safely
# test it without also tearing down the GUI it runs under.
GPU_UNBIND_ENABLE="0"
EOF
	chmod 0644 "$CONF_FILE"

	# This heredoc is intentionally UNQUOTED so the detected values above
	# interpolate — which also means a stray backtick or $ anywhere in it
	# (even inside a comment) gets executed/expanded and its output injected
	# into the file. That has bitten twice, and a corrupted config makes the
	# lock script fail to source it and silently skip steps. Fail loudly here
	# instead of shipping a broken config.
	if ! bash -n "$CONF_FILE" 2>/dev/null; then
		log_error "Generated $CONF_FILE is not valid shell — refusing to continue."
		log_error "Check write_config() for backticks or \$ in the heredoc."
		bash -n "$CONF_FILE" || true
		exit 1
	fi
}
