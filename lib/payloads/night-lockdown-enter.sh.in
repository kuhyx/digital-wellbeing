#!/bin/bash
# Managed by setup_night_lockdown.sh — do not edit by hand.
#
# Enter night lockdown: tear down the user GUI and mask the TTY login surface so
# the machine is unusable from the keyboard, while every background server keeps
# running. Reversed by night-lockdown-unlock.sh (05:00 timer or SSH recovery).
#
# ORDER IS THE GUARANTEE. Enforcement (state, masks, GUI stop, blank) runs
# FIRST and calls nothing that can block. Everything cosmetic (RGB, power caps,
# audio, tray apps) runs AFTER it, in a separate script, under a hard timeout.
# On 2026-09-12 the RGB step (openrgb 1.0-2) hung forever BEFORE the teardown:
# the curfew logged "entering night lockdown" and then never enforced anything,
# and because the oneshot unit never exited, every later per-minute tick was a
# no-op until morning. A hang in a cosmetic step must never cost the curfew.
#
# All steps are best-effort and logged; DRY_RUN=1 logs intended actions only.
set -euo pipefail

readonly CONF_FILE="/etc/night-lockdown.conf"
readonly STATE_DIR="/var/lib/night-lockdown"
readonly STATE_FILE="$STATE_DIR/state"
readonly COSMETICS_SCRIPT="/usr/local/bin/night-lockdown-cosmetics.sh"

# shellcheck source=/dev/null
[[ -r "$CONF_FILE" ]] && source "$CONF_FILE"
MIN_WAKE_AFTER_LOCKDOWN_HOURS="${MIN_WAKE_AFTER_LOCKDOWN_HOURS:-8}"
CONSOLE_TTY="${CONSOLE_TTY:-/dev/tty1}"
CONSOLE_BLANK_MODE="${CONSOLE_BLANK_MODE:-1}"
# Upper bound for the whole cosmetic phase. Generous: openrgb detection alone
# takes ~2s, nvidia-smi a few more. It only matters when something wedges.
COSMETICS_TIMEOUT="${COSMETICS_TIMEOUT:-120}"
# Display-manager unit to mask + stop. Mask the CONCRETE unit name
# (lightdm.service), never the display-manager.service alias: that alias is a
# symlink in /etc/systemd/system, so `systemctl mask display-manager.service`
# fails exactly the way masking autovt@.service does. Verified on this host:
# masking lightdm.service makes `systemctl is-enabled display-manager.service`
# report "masked" too, because they are two Names= of one unit.
DISPLAY_MANAGER_UNIT="${DISPLAY_MANAGER_UNIT:-lightdm.service}"
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

# Silence everything that prints to the text console. Once lightdm stops, the VT
# reverts to fbcon and any kernel/systemd message lights the screen back up.
silence_console() {
	# systemd status messages ("Starting/Stopped ...") -> off. RTMIN+20 re-enables.
	run kill -s RTMIN+21 1
	# Kernel messages -> console. Save the current printk so unlock can restore
	# it. Guarded on the .prev file not already existing, for the same reason
	# cpu_epp.prev and gpu_power_limit_watts.prev are guarded: re-entry is
	# possible (see lockdown_effective below), and an unguarded recapture while
	# printk is already lowered would record the SILENCED value as "prev" and
	# make the morning restore permanent. unlock deletes the file after a
	# successful restore, so each normal night still captures fresh.
	if [[ "$DRY_RUN" != "1" && ! -f "$STATE_DIR/printk.prev" ]]; then
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

# 1. Idempotency — entering lockdown when already locked is a safe no-op. But
#    "already locked" has to mean the machine is ACTUALLY locked, not merely
#    that some earlier run wrote the intent down. The state token survives a
#    power-cycle; the lockdown itself did not. lightdm is an enabled unit, so a
#    reboot brought the GUI straight back while state still read LOCKED, and
#    every later curfew tick then short-circuited on "already LOCKED — nothing
#    to do". Observed 2026-09-12: locked at 00:00:04, power-cycled at 00:01,
#    and the desktop was then unenforced until the 05:00 unlock. Verify the
#    observable effects instead of the token, and re-apply on any mismatch —
#    fail closed, never on a stale promise.
lockdown_effective() {
	[[ "$(cat "$STATE_FILE" 2>/dev/null || echo UNLOCKED)" == "LOCKED" ]] || return 1
	[[ "$(systemctl is-enabled getty@.service 2>/dev/null)" == "masked" ]] || return 1
	[[ "$(systemctl is-enabled "$DISPLAY_MANAGER_UNIT" 2>/dev/null)" == "masked" ]] || return 1
	# A masked-but-still-running DM means the mask landed after the GUI came
	# back up; that is not enforcement either.
	! systemctl is-active --quiet "$DISPLAY_MANAGER_UNIT"
}

if lockdown_effective; then
	logg "already LOCKED and enforced — nothing to do"
	exit 0
fi

if [[ "$(cat "$STATE_FILE" 2>/dev/null || echo UNLOCKED)" == "LOCKED" ]]; then
	logg "state says LOCKED but enforcement is NOT in effect (GUI up or masks gone) — re-applying"
fi

logg "entering night lockdown"

# 2. Persist the LOCKED intent BEFORE the session-killing teardown. If state
#    were written after it, a kill mid-teardown would leave it at UNLOCKED —
#    and the unlock path (which no-ops when UNLOCKED) would then fail to
#    restore, stranding the machine. Write intent first; any unlock (05:00
#    timer, dead-man, or manual) then correctly restores.
if [[ "$DRY_RUN" != "1" ]]; then
	echo LOCKED >"$STATE_FILE"
	lockdown_epoch="$(date +%s)"
	echo "$lockdown_epoch" >"$STATE_DIR/locked_at_epoch"

	# 2a. Schedule a one-shot wake-floor trigger for exactly
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
	#     --collect reaps the SERVICE after it runs; the transient TIMER stays
	#     loaded until it fires. Re-entry before the floor (a power-cycle, a
	#     re-apply after a failed lock — now a routine path) therefore hit
	#     "already loaded or has a fragment file" and the floor was never
	#     rescheduled for the new lockdown (seen in the vmbox e2e, 2026-09-13).
	#     Drop any previous floor first; this lockdown's is the one that counts.
	run systemctl stop night-lockdown-wake-floor.timer
	floor_epoch=$((lockdown_epoch + MIN_WAKE_AFTER_LOCKDOWN_HOURS * 3600))
	floor_cal="$(date -d "@$floor_epoch" '+%Y-%m-%d %H:%M:%S')"
	run systemd-run --unit=night-lockdown-wake-floor --collect \
		--on-calendar="$floor_cal" /usr/local/bin/night-lockdown-unlock.sh
else
	logg "DRY_RUN: would schedule a one-shot wake-floor trigger ~${MIN_WAKE_AFTER_LOCKDOWN_HOURS}h from now"
fi

# 3. Silence the console BEFORE stopping the GUI, so the teardown itself
#    ("Stopping Light Display Manager...") does not print onto the VT.
silence_console

# 4. Mask the login surface BEFORE stopping the GUI, so logind cannot spawn a
#    getty into the gap. Mask ONLY getty@.service: autovt@.service is an alias
#    symlink to it, so masking getty@ already makes autovt@ttyN resolve to
#    masked ("Unit autovt@ttyN.service is masked" — logind cannot spawn a VT
#    login). Passing autovt@ to mask instead FAILS ("File
#    /etc/systemd/system/autovt@.service already exists and is a symlink"),
#    which is what produced the nightly WARN. Masks are /dev/null symlinks that
#    persist across reboot; the unlock path unmasks them.
run systemctl mask getty@.service
run systemctl stop 'getty@*.service'

# 5. Mask the display manager too, for exactly the same reason: a mask is a
#    /dev/null symlink that survives a reboot, a stopped unit does not.
#    lightdm is enabled, so before this the power button was a complete
#    bypass — hold it down, boot back up, and graphical.target handed the
#    desktop back with the curfew still nominally "active". Masking must
#    happen BEFORE the stop below so nothing (graphical.target, logind) can
#    race a restart into the gap. night-lockdown-unlock.sh unmasks it.
run systemctl mask "$DISPLAY_MANAGER_UNIT"

# 6. Stop the GUI while continuously re-blanking the console in the
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
run systemctl stop "$DISPLAY_MANAGER_UNIT"
if [[ -n "${BLANK_POLLER_PID:-}" ]]; then
	kill "$BLANK_POLLER_PID" 2>/dev/null || true
	wait "$BLANK_POLLER_PID" 2>/dev/null || true
	unset BLANK_POLLER_PID
fi

# 7. Final guaranteed blank now that the GUI is fully down.
blank_console

logg "enforcement in effect — GUI down, login surface masked, console dark"

# 8. Cosmetics LAST, as one bounded child: RGB off, CPU/GPU power caps, audio
#    mute, tray apps, optional GPU unbind. `timeout` is the whole point — a
#    wedged openrgb or nvidia-smi now costs at most COSMETICS_TIMEOUT seconds
#    and a WARN, never the curfew. --kill-after handles a child that ignores
#    TERM (openrgb 1.0-2 sat in a futex/hidraw read and needed KILL).
#    The child is itself DRY_RUN-aware (log-only), so it runs through the same
#    bounded path in both modes and a dry run exercises the timeout wiring.
if [[ -x "$COSMETICS_SCRIPT" ]]; then
	if ! timeout --kill-after=10 "$COSMETICS_TIMEOUT" env DRY_RUN="$DRY_RUN" "$COSMETICS_SCRIPT"; then
		logg "WARN: cosmetics failed or timed out after ${COSMETICS_TIMEOUT}s (continuing)"
	fi
else
	logg "WARN: $COSMETICS_SCRIPT missing — skipping RGB/power/audio cosmetics"
fi

logg "night lockdown active — servers up, GUI down, login surface masked, console dark"
