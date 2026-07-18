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

# Morning wake alarm. The always-on lockdown removes the hibernate/resume event
# that used to start the alarm, so the unlock re-fires it on alarm days. Days are
# date(1) %u values: 1=Mon .. 7=Sun. Mon/Fri/Sat/Sun matches screen_locker's
# ALARM_DAYS. The alarm's own gate fires every day, so the day-gate lives here.
ALARM_DAYS_DOW="1 5 6 7"
# User systemd unit that runs the morning routine (wake alarm + workout lock).
MORNING_ROUTINE_UNIT="morning-routine.service"

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

# =============================================================================
# The lock action — installed to $ENTER_SCRIPT
# =============================================================================

install_enter_script() {
	log_info "Installing lock action to $ENTER_SCRIPT"
	cat >"$ENTER_SCRIPT" <<'ENTER_EOF'
#!/bin/bash
# Managed by setup_night_lockdown.sh — do not edit by hand.
#
# Enter night lockdown: tear down the user GUI and mask the TTY login surface so
# the machine is unusable from the keyboard, while every background server keeps
# running. Reversed by night-lockdown-unlock.sh (05:00 timer or SSH recovery).
# All steps are best-effort and logged; DRY_RUN=1 logs intended actions only.
set -euo pipefail

readonly CONF_FILE="/etc/night-lockdown.conf"
readonly STATE_DIR="/var/lib/night-lockdown"
readonly STATE_FILE="$STATE_DIR/state"

# shellcheck source=/dev/null
[[ -r "$CONF_FILE" ]] && source "$CONF_FILE"
LOCK_USER="${LOCK_USER:-}"
LOCK_UID="${LOCK_UID:-}"
ALSA_CARDS="${ALSA_CARDS:-}"
RGB_ENABLE="${RGB_ENABLE:-1}"
MONITORED_USER_UNITS="${MONITORED_USER_UNITS:-}"
MONITORED_PROCS="${MONITORED_PROCS:-}"
MIN_WAKE_AFTER_LOCKDOWN_HOURS="${MIN_WAKE_AFTER_LOCKDOWN_HOURS:-8}"
CONSOLE_TTY="${CONSOLE_TTY:-/dev/tty1}"
CONSOLE_BLANK_MODE="${CONSOLE_BLANK_MODE:-1}"
DRY_RUN="${DRY_RUN:-}"

logg() { logger -t night-lockdown "$*"; printf 'night-lockdown: %s\n' "$*"; }

if [[ "$DRY_RUN" == "1" ]]; then
	logg "DRY_RUN NOTE: log-only — lightdm is never actually stopped and the"
	logg "DRY_RUN NOTE: console framebuffer is never actually touched. This CANNOT"
	logg "DRY_RUN NOTE: exercise the blank-vs-VT-switch timing race (bug: visible"
	logg "DRY_RUN NOTE: console text). A clean DRY_RUN run is NOT proof that fix"
	logg "DRY_RUN NOTE: works — only a real run (DRY_RUN unset) validates it."
fi

# Run a command best-effort: log-only under DRY_RUN, never abort the lockdown.
run() {
	if [[ "$DRY_RUN" == "1" ]]; then
		logg "DRY_RUN: would run: $*"
		return 0
	fi
	if ! "$@"; then
		logg "WARN: command failed (continuing): $*"
	fi
}

# Run a command as the desktop user inside their session bus.
run_as_user() {
	[[ -n "$LOCK_USER" && -n "$LOCK_UID" && -d "/run/user/$LOCK_UID" ]] || return 0
	run sudo -u "$LOCK_USER" env "XDG_RUNTIME_DIR=/run/user/$LOCK_UID" "$@"
}

# Silence everything that prints to the text console. Once lightdm stops, the VT
# reverts to fbcon and any kernel/systemd message lights the screen back up.
silence_console() {
	# systemd status messages ("Starting/Stopped ...") -> off. RTMIN+20 re-enables.
	run kill -s RTMIN+21 1
	# Kernel messages -> console. Save the current printk so unlock can restore it.
	if [[ "$DRY_RUN" != "1" ]]; then
		cat /proc/sys/kernel/printk >"$STATE_DIR/printk.prev" 2>/dev/null || true
	fi
	run sysctl -q -w "kernel.printk=1 4 1 4"
}

# Force the console dark — black screen, but WITHOUT DPMS power management.
# Powering the output down (FB_BLANK_POWERDOWN / setterm --powersave powerdown)
# makes DisplayPort drop its link; the GPU then reports the connector
# disconnected and never re-trains it, so the monitor is gone from xrandr until
# the cable is physically re-plugged. Blanking alone is enough to go black.
blank_console() {
	local fb
	for fb in /sys/class/graphics/fb*/blank; do
		[[ -e "$fb" ]] || continue
		if [[ "$DRY_RUN" == "1" ]]; then
			logg "DRY_RUN: would write $CONSOLE_BLANK_MODE (blank) > $fb"
			continue
		fi
		echo "$CONSOLE_BLANK_MODE" >"$fb" 2>/dev/null || logg "WARN: could not blank $fb"
	done
	# setterm emits escape sequences on stdout; from a systemd service stdout is
	# the journal, so aim it at the VT explicitly. --powersave off keeps DPMS out
	# of it so the DP link survives.
	if [[ "$DRY_RUN" == "1" ]]; then
		logg "DRY_RUN: would force console blank (no DPMS) on $CONSOLE_TTY"
	elif [[ -w "$CONSOLE_TTY" ]]; then
		setterm --term linux --blank force --powersave off \
			>"$CONSOLE_TTY" 2>/dev/null || logg "WARN: setterm blank failed"
	fi
}

mkdir -p "$STATE_DIR"

# 1. Idempotency — entering lockdown when already locked is a safe no-op.
if [[ "$(cat "$STATE_FILE" 2>/dev/null || echo UNLOCKED)" == "LOCKED" ]]; then
	logg "already LOCKED — nothing to do"
	exit 0
fi

logg "entering night lockdown"

# 2. RGB off (RAM + board + GPU), remembering the current lighting first.
#
#    Do NOT gate this on `openrgb --list-devices`: that call is broken in the
#    installed openrgb-git build — it returns in ~70ms, before async detection
#    finishes, so it always reports zero devices. (That false "no controllers"
#    reading is why this step silently no-op'd.) The fix was to install stable
#    openrgb 1.0rc3 from extra, whose CLI detects properly (~1.9s) before acting.
if [[ "$RGB_ENABLE" == "1" ]] && command -v openrgb >/dev/null 2>&1; then
	run env HOME="$RGB_HOME" openrgb --mode "$RGB_OFF_MODE" --color "$RGB_OFF_COLOR"
fi

# 3. Mute audio (best-effort). The session teardown below silences apps anyway;
#    this covers any direct-ALSA sound. PipeWire is intentionally NOT touched, so
#    the morning unlock cannot be defeated by a persisted wireplumber mute.
for card in $ALSA_CARDS; do
	command -v amixer >/dev/null 2>&1 && run amixer -c "$card" -q set Master mute
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

# 5. Persist the LOCKED intent BEFORE the session-killing teardown. Stopping
#    lightdm tears down the graphical session that this very process runs in, so
#    if we wrote state AFTER the teardown, a kill mid-teardown would leave state
#    at UNLOCKED — and the unlock path (which no-ops when UNLOCKED) would then
#    fail to restore, stranding the machine. Write intent first; any unlock
#    (05:00 timer, dead-man, or manual) then correctly restores.
if [[ "$DRY_RUN" != "1" ]]; then
	echo LOCKED >"$STATE_FILE"
	lockdown_epoch="$(date +%s)"
	echo "$lockdown_epoch" >"$STATE_DIR/locked_at_epoch"

	# 5a. Schedule a one-shot wake-floor trigger for exactly
	#     lockdown_epoch + MIN_WAKE_AFTER_LOCKDOWN_HOURS. The staggered
	#     05:00/05:15/05:30/06:00/07:00 unlock triggers are a fixed list sized
	#     for the usual shutdown hours (~21:00-23:00), but the shutdown hour
	#     itself is configurable (/etc/shutdown-schedule.conf) and changes
	#     dynamically (see the sick-day feature). If lockdown ever starts late
	#     enough that the floor lands after every remaining fixed trigger, the
	#     alarm would otherwise silently never fire that morning. This
	#     transient timer fires at the exact floor moment for THIS lockdown
	#     regardless of what time it actually started, re-running the
	#     (idempotent, self-dedup'd) unlock script, which is where the alarm
	#     is actually attempted.
	floor_epoch=$((lockdown_epoch + MIN_WAKE_AFTER_LOCKDOWN_HOURS * 3600))
	floor_cal="$(date -d "@$floor_epoch" '+%Y-%m-%d %H:%M:%S')"
	run systemd-run --unit=night-lockdown-wake-floor --collect \
		--on-calendar="$floor_cal" /usr/local/bin/night-lockdown-unlock.sh
else
	logg "DRY_RUN: would schedule a one-shot wake-floor trigger ~${MIN_WAKE_AFTER_LOCKDOWN_HOURS}h from now"
fi

# 6a. Silence the console BEFORE stopping the GUI, so the teardown itself
#     ("Stopping Light Display Manager...") does not print onto the VT.
silence_console

# 6. Mask the login surface BEFORE stopping the GUI, so logind cannot spawn a
#    getty into the gap. Mask ONLY getty@.service: autovt@.service is an alias
#    symlink to it, so masking getty@ already makes autovt@ttyN resolve to
#    masked ("Unit autovt@ttyN.service is masked" — logind cannot spawn a VT
#    login). Passing autovt@ to mask instead FAILS ("File
#    /etc/systemd/system/autovt@.service already exists and is a symlink"),
#    which is what produced the nightly WARN. Masks are /dev/null symlinks that
#    persist across reboot; the unlock path unmasks them.
run systemctl mask getty@.service
run systemctl stop 'getty@*.service'

# 7. Stop the GUI while continuously re-blanking the console in the
#    background. Activating a VT (which happens somewhere mid-way through the
#    GUI stop, not only once "systemctl stop" fully returns) makes fbcon
#    redraw/unblank as part of the switch, so a single blank-after-the-fact
#    call leaves a gap showing whatever was last on the console (old
#    kernel/systemd text) for however long the rest of the stop sequence
#    takes. Keep forcing it dark for the whole teardown instead of waiting.
if [[ "$DRY_RUN" != "1" ]]; then
	(
		while :; do
			blank_console
			sleep 0.1
		done
	) &
	BLANK_POLLER_PID=$!
fi
run systemctl stop lightdm.service
if [[ -n "${BLANK_POLLER_PID:-}" ]]; then
	kill "$BLANK_POLLER_PID" 2>/dev/null || true
	wait "$BLANK_POLLER_PID" 2>/dev/null || true
	unset BLANK_POLLER_PID
fi

# 8. Final guaranteed blank now that the GUI is fully down.
blank_console

logg "night lockdown active — servers up, GUI down, login surface masked, console dark"
ENTER_EOF
	chmod 0755 "$ENTER_SCRIPT"
}

# =============================================================================
# The reversal — installed to $UNLOCK_SCRIPT
# =============================================================================

install_unlock_script() {
	log_info "Installing reversal to $UNLOCK_SCRIPT"
	cat >"$UNLOCK_SCRIPT" <<'UNLOCK_EOF'
#!/bin/bash
# Managed by setup_night_lockdown.sh — do not edit by hand.
#
# Lift night lockdown: unmask the login surface, restart the GUI, unmute audio.
# Idempotent (safe to fire from the 5 staggered morning triggers and manual runs)
# and deliberately independent of the shutdown fortress, so it can always run.
set -euo pipefail

readonly CONF_FILE="/etc/night-lockdown.conf"
readonly STATE_DIR="/var/lib/night-lockdown"
readonly STATE_FILE="$STATE_DIR/state"

# shellcheck source=/dev/null
[[ -r "$CONF_FILE" ]] && source "$CONF_FILE"
ALSA_CARDS="${ALSA_CARDS:-}"
LOCK_USER="${LOCK_USER:-}"
LOCK_UID="${LOCK_UID:-}"
ALARM_DAYS_DOW="${ALARM_DAYS_DOW:-}"
MORNING_ROUTINE_UNIT="${MORNING_ROUTINE_UNIT:-}"
MIN_WAKE_AFTER_LOCKDOWN_HOURS="${MIN_WAKE_AFTER_LOCKDOWN_HOURS:-8}"
AUTORANDR_PROFILE="${AUTORANDR_PROFILE:-default}"
CONSOLE_TTY="${CONSOLE_TTY:-/dev/tty1}"
RGB_ENABLE="${RGB_ENABLE:-1}"
RGB_OFF_MODE="${RGB_OFF_MODE:-static}"
RGB_OFF_COLOR="${RGB_OFF_COLOR:-000000}"
RGB_HOME="${RGB_HOME:-/root}"
DRY_RUN="${DRY_RUN:-}"

logg() { logger -t night-lockdown "$*"; printf 'night-lockdown: %s\n' "$*"; }

if [[ "$DRY_RUN" == "1" ]]; then
	logg "DRY_RUN NOTE: log-only — lightdm is never actually started and"
	logg "DRY_RUN NOTE: autorandr is never actually invoked. This CANNOT exercise"
	logg "DRY_RUN NOTE: the real DisplayPort reconnect or graphical-session wait."
	logg "DRY_RUN NOTE: A clean DRY_RUN run is NOT proof those work — only a real"
	logg "DRY_RUN NOTE: run (DRY_RUN unset) validates them. The alarm floor/dedup"
	logg "DRY_RUN NOTE: logic (locked_at_epoch, alarm_started_date) IS exercised"
	logg "DRY_RUN NOTE: faithfully here, since that part is pure calculation."
fi

run() {
	if [[ "$DRY_RUN" == "1" ]]; then
		logg "DRY_RUN: would run: $*"
		return 0
	fi
	if ! "$@"; then
		logg "WARN: command failed (continuing): $*"
	fi
}

# Fire the morning wake alarm on alarm days. The always-on lockdown removed the
# hibernate/resume event that used to start morning-routine.service, so we start
# it here once the desktop session is back. Called on every staggered trigger
# (not just the one that performs the console/GUI restore), because
# MIN_WAKE_AFTER_LOCKDOWN_HOURS below may push the actual alarm start past the
# trigger that unlocked the screen — dedup is its own alarm_started_date marker,
# independent of the LOCKED/UNLOCKED state file.
maybe_start_morning_alarm() {
	[[ -n "$LOCK_USER" && -n "$LOCK_UID" && -n "$MORNING_ROUTINE_UNIT" ]] || return 0
	local dow today_is_alarm_day=false d today
	dow="$(date +%u)" # 1=Mon .. 7=Sun
	for d in $ALARM_DAYS_DOW; do
		[[ "$d" == "$dow" ]] && today_is_alarm_day=true
	done
	if [[ "$today_is_alarm_day" != true ]]; then
		logg "not an alarm day (dow=$dow) — skipping morning alarm"
		return 0
	fi
	today="$(date +%F)"
	if [[ "$(cat "$STATE_DIR/alarm_started_date" 2>/dev/null || echo '')" == "$today" ]]; then
		logg "morning alarm already started today — skipping"
		return 0
	fi
	# Never wake earlier than lockdown-entry + MIN_WAKE_AFTER_LOCKDOWN_HOURS. A
	# late lockdown entry (e.g. 23:00 instead of the usual 21:00) must not still
	# fire the alarm at the normal 05:00 trigger; wait for a later staggered
	# trigger (05:15/05:30/06:00/07:00) that clears the floor instead.
	local locked_at now min_wake
	locked_at="$(cat "$STATE_DIR/locked_at_epoch" 2>/dev/null || echo 0)"
	now="$(date +%s)"
	min_wake=$((locked_at + MIN_WAKE_AFTER_LOCKDOWN_HOURS * 3600))
	if ((locked_at > 0 && now < min_wake)); then
		logg "too soon since lockdown entry ($(( (min_wake - now) / 60 ))m remaining) — skipping alarm this trigger"
		return 0
	fi
	if [[ "$DRY_RUN" == "1" ]]; then
		logg "DRY_RUN: would wait for graphical session then start $MORNING_ROUTINE_UNIT"
		return 0
	fi
	# Bounded wait (≤60s) for the user graphical session to come up after lightdm.
	local i
	for ((i = 0; i < 60; i++)); do
		if sudo -u "$LOCK_USER" env "XDG_RUNTIME_DIR=/run/user/$LOCK_UID" \
			systemctl --user is-active graphical-session.target >/dev/null 2>&1; then
			break
		fi
		sleep 1
	done
	logg "alarm day (dow=$dow) — starting $MORNING_ROUTINE_UNIT"
	run sudo -u "$LOCK_USER" env "XDG_RUNTIME_DIR=/run/user/$LOCK_UID" \
		systemctl --user start --no-block "$MORNING_ROUTINE_UNIT"
	echo "$today" >"$STATE_DIR/alarm_started_date"
}

mkdir -p "$STATE_DIR"

# Idempotency — lifting when already unlocked is a safe no-op for the
# console/GUI restore, but a still-pending morning alarm (delayed past this
# trigger by MIN_WAKE_AFTER_LOCKDOWN_HOURS) gets one more chance to fire.
if [[ "$(cat "$STATE_FILE" 2>/dev/null || echo UNLOCKED)" == "UNLOCKED" ]]; then
	maybe_start_morning_alarm
	logg "already UNLOCKED — nothing else to do"
	exit 0
fi

logg "lifting night lockdown"

# 0. Restore the console: unblank it and let kernel/systemd talk to it again.
#    Must happen even if everything below fails, or the machine would stay
#    permanently silent on the console after any unlock.
restore_console() {
	local fb prev
	for fb in /sys/class/graphics/fb*/blank; do
		[[ -e "$fb" ]] || continue
		if [[ "$DRY_RUN" == "1" ]]; then
			logg "DRY_RUN: would write 0 (unblank) > $fb"
			continue
		fi
		echo 0 >"$fb" 2>/dev/null || true
	done
	if [[ "$DRY_RUN" == "1" ]]; then
		logg "DRY_RUN: would restore printk + systemd status messages"
		return 0
	fi
	[[ -w "$CONSOLE_TTY" ]] && setterm --term linux --blank poke --powersave off \
		>"$CONSOLE_TTY" 2>/dev/null
	if [[ -r "$STATE_DIR/printk.prev" ]]; then
		prev="$(cat "$STATE_DIR/printk.prev")"
		[[ -n "$prev" ]] && sysctl -q -w "kernel.printk=$prev" 2>/dev/null
	fi
	kill -s RTMIN+20 1 2>/dev/null || true # systemd: status messages back on
}
restore_console

# 1. Unmask the login surface (undo the persistent /dev/null mask). Only
#    getty@.service is ever masked; autovt@.service is just an alias to it.
run systemctl unmask getty@.service

# 2. Start the GUI — lightdm autologins back into i3/dwm.
run systemctl start lightdm.service

# 2a. Reconnect/reconfigure displays. A DisplayPort link does not always
#     re-enumerate cleanly on its own after the console teardown, leaving a
#     monitor disconnected until someone runs xrandr by hand. Retry autorandr
#     for a bit while the session comes up instead. Requires a saved profile
#     ('autorandr --save default' run once while all monitors are connected).
if [[ -n "$LOCK_USER" && -n "$LOCK_UID" ]] && command -v autorandr >/dev/null 2>&1; then
	if [[ "$DRY_RUN" == "1" ]]; then
		logg "DRY_RUN: would run autorandr --change as $LOCK_USER"
	else
		autorandr_ok=false
		for ((i = 0; i < 15; i++)); do
			if sudo -u "$LOCK_USER" env "XDG_RUNTIME_DIR=/run/user/$LOCK_UID" DISPLAY=:0 \
				autorandr --change --default "$AUTORANDR_PROFILE" >/dev/null 2>&1; then
				autorandr_ok=true
				break
			fi
			sleep 1
		done
		if [[ "$autorandr_ok" == true ]]; then
			logg "autorandr: displays restored (profile '$AUTORANDR_PROFILE')"
		else
			logg "WARN: autorandr did not settle after retries — displays may need manual xrandr"
		fi
	fi
fi

# 3. Restore audio (unmute the cards muted at lockdown).
for card in $ALSA_CARDS; do
	command -v amixer >/dev/null 2>&1 && run amixer -c "$card" -q set Master unmute
done

# 4. Re-assert lights-off rather than restoring anything: the preference is no
#    lighting at all, ever, so the morning must not turn the RGB back on.
if [[ "$RGB_ENABLE" == "1" ]] && command -v openrgb >/dev/null 2>&1; then
	run env HOME="$RGB_HOME" openrgb --mode "$RGB_OFF_MODE" --color "$RGB_OFF_COLOR"
fi

# 5. Record state BEFORE the (possibly long) alarm wait, so re-fired unlock
#    triggers dedupe on the state token instead of double-starting things.
if [[ "$DRY_RUN" != "1" ]]; then
	echo UNLOCKED >"$STATE_FILE"
fi

# 6. On alarm days, re-fire the morning wake alarm the always-on lockdown
#    displaced (it used to start on the hibernate/resume event we removed).
maybe_start_morning_alarm

logg "night lockdown lifted — GUI restored, login surface unmasked"
UNLOCK_EOF
	chmod 0755 "$UNLOCK_SCRIPT"
}

# =============================================================================
# Morning-unlock systemd timer family (outside the shutdown fortress)
# =============================================================================

install_unlock_units() {
	log_info "Installing morning-unlock timer family"
	cat >"$UNLOCK_SERVICE" <<EOF
$MANAGED_BANNER
[Unit]
Description=Lift night lockdown (restore GUI, unmute, unmask login surface)
DefaultDependencies=false
After=multi-user.target

[Service]
Type=oneshot
ExecStart=$UNLOCK_SCRIPT
StandardOutput=journal
StandardError=journal
EOF

	# Multiple staggered triggers + Persistent=true = dead-man robustness: a
	# single missed/failed 05:00 run cannot strand the machine, and each run is
	# idempotent so repeated firing is harmless.
	cat >"$UNLOCK_TIMER" <<EOF
$MANAGED_BANNER
[Unit]
Description=Morning triggers to lift night lockdown

[Timer]
OnCalendar=*-*-* 05:00:00
OnCalendar=*-*-* 05:15:00
OnCalendar=*-*-* 05:30:00
OnCalendar=*-*-* 06:00:00
OnCalendar=*-*-* 07:00:00
Persistent=true
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
}

# Lights stay off at ALL times, not just during lockdown. The board firmware
# re-lights RAM/board/GPU on every power-on, so without this the RGB would be
# back after each reboot and only go dark again at the next 21:00 lock.
install_rgb_off_service() {
	log_info "Installing boot-time RGB-off service"
	cat >"$RGB_OFF_SERVICE" <<EOF
$MANAGED_BANNER
[Unit]
Description=Turn all RGB lighting off (lights are meant to be off at all times)
After=multi-user.target
# The i2c DRAM/GPU controllers need their buses; the ASRock controller is USB.
Wants=systemd-modules-load.service
After=systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
# HOME pinned for the same reason as in the lock/unlock scripts: openrgb keeps
# its state under HOME and systemd would otherwise differ from an interactive
# sudo run. Detection takes ~2s before it applies. static+black rather than
# "off": the ZOTAC GPU has no Off mode and the ASRock board ignores it.
ExecStart=/usr/bin/env HOME=${RGB_HOME_DEFAULT} /usr/bin/openrgb --mode static --color 000000
SuccessExitStatus=0 1
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

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

verify_install() {
	log_info "Verifying installation"
	local ok=true
	local path
	for path in "$ENTER_SCRIPT" "$UNLOCK_SCRIPT" "$CONF_FILE" \
		"$UNLOCK_SERVICE" "$UNLOCK_TIMER" "$RGB_OFF_SERVICE" "$I2C_MODULES_FILE"; do
		if [[ -e "$path" ]]; then
			log_ok "present: $path"
		else
			log_error "missing: $path"
			ok=false
		fi
	done
	if is_service_enabled night-lockdown-unlock.timer; then
		log_ok "night-lockdown-unlock.timer is enabled"
	else
		log_error "night-lockdown-unlock.timer is NOT enabled"
		ok=false
	fi
	# The action swap in the fortress check script is what actually invokes us.
	if grep -q "$ENTER_SCRIPT" /usr/local/bin/day-specific-shutdown-check.sh 2>/dev/null; then
		log_ok "day-specific-shutdown-check.sh calls the lockdown action"
	else
		log_warn "day-specific-shutdown-check.sh does NOT call $ENTER_SCRIPT yet"
		log_warn "  → re-run setup_midnight_shutdown.sh to regenerate it (see header)"
	fi
	[[ "$ok" == true ]]
}

# =============================================================================
# Subcommands
# =============================================================================

cmd_setup() {
	set_actual_user_vars
	print_setup_header "Night Lockdown"

	ensure_dir "$STATE_DIR"
	[[ -f "$STATE_FILE" ]] || echo UNLOCKED >"$STATE_FILE"

	write_config
	install_enter_script
	install_unlock_script
	install_unlock_units
	install_rgb_off_service
	install_i2c_modules

	systemctl daemon-reload
	enable_service night-lockdown-unlock.timer
	enable_service rgb-off.service

	echo ""
	if verify_install; then
		log_ok "Night lockdown installed."
	else
		log_warn "Night lockdown installed with warnings (see above)."
	fi
	echo ""
	log_info "Next: swap the shutdown action by re-running setup_midnight_shutdown.sh"
	log_info "      (it must call $ENTER_SCRIPT instead of powering off)."
	log_info "Emergency unlock over SSH:  sudo $0 unlock"
}

cmd_status() {
	local state="unknown"
	[[ -r "$STATE_FILE" ]] && state="$(cat "$STATE_FILE")"
	echo "Night lockdown state : $state"
	echo "lightdm.service      : $(systemctl is-active lightdm.service 2>/dev/null || true)"
	echo "getty@.service mask  : $(systemctl is-enabled getty@.service 2>/dev/null || true)"
	echo "autovt@.service mask : $(systemctl is-enabled autovt@.service 2>/dev/null || true)"
	echo "unlock timer         : $(systemctl is-active night-lockdown-unlock.timer 2>/dev/null || true) / $(systemctl is-enabled night-lockdown-unlock.timer 2>/dev/null || true)"
	echo ""
	echo "Next unlock triggers:"
	systemctl list-timers night-lockdown-unlock.timer --no-pager 2>/dev/null || true
}

cmd_unlock() {
	log_info "Emergency unlock: restoring GUI now"
	DRY_RUN="" "$UNLOCK_SCRIPT"
	echo ""
	log_warn "The curfew is still armed: the next 30-min check tick will re-lock."
	log_warn "To stay unlocked until morning, register an override (friction by design):"
	if [[ -x "$OVERRIDE_MANAGER" ]]; then
		local now_h until_str
		now_h="$(date '+%Y-%m-%d %H:%M')"
		# Next 05:00 boundary (tomorrow if already past 05:00 today).
		if [[ "$(date +%H)" -lt 5 ]]; then
			until_str="$(date '+%Y-%m-%d') 05:00"
		else
			until_str="$(date -d tomorrow '+%Y-%m-%d') 05:00"
		fi
		echo "    sudo $OVERRIDE_MANAGER add '$now_h' '$until_str' 'emergency unlock'"
	else
		log_warn "  (override manager not found at $OVERRIDE_MANAGER)"
	fi
}

usage() {
	cat <<EOF
Night Lockdown — replace the midnight power-off with a GUI lockout that keeps
background servers running.

Usage:
  sudo $0 setup      Install/refresh the lock+unlock action and morning timer
       $0 status     Show current lockdown state and timer status
  sudo $0 unlock     Emergency: lift the lockdown right now (use over SSH)
       $0 help       Show this help

After 'setup', re-run setup_midnight_shutdown.sh so the scheduled check calls
$ENTER_SCRIPT instead of powering off.
EOF
}

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
