# Midnight Shutdown System - LLM Reference Guide

> **For AI assistants**: This document explains the automatic shutdown system so you can make correct modifications.

## System Purpose

Automatically shut down the PC during configured time windows to enforce healthy sleep schedules:

- **Monday-Wednesday**: Shutdown at 24:00 (midnight)
- **Thursday-Sunday**: Shutdown at 24:00 (midnight)
- **Morning**: Safe time starts at 00:00 (effectively no morning block)

The times above are defaults; actual values in `/etc/shutdown-schedule.conf`.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SHUTDOWN SYSTEM LAYERS                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Layer 1: Systemd Timer                                             │
│  ─────────────────────                                              │
│  day-specific-shutdown.timer fires every minute IN the window       │
│  day-specific-shutdown.service runs the check script                │
│                                                                     │
│  Layer 2: Check Script                                              │
│  ────────────────────                                               │
│  /usr/local/bin/day-specific-shutdown-check.sh                      │
│  Reads config, checks current time, initiates shutdown if in window │
│                                                                     │
│  Layer 3: Config Protection                                         │
│  ────────────────────────                                           │
│  /etc/shutdown-schedule.conf has chattr +i                          │
│  Canonical copy at /usr/local/share/locked-shutdown-schedule.conf   │
│  Path watcher auto-restores if tampered                             │
│                                                                     │
│  Layer 4: Timer Monitor                                             │
│  ─────────────────────                                              │
│  shutdown-timer-monitor.service watches timer status                │
│  Re-enables timer if user tries to disable it                       │
│                                                                     │
│  Layer 5: Script Protection                                         │
│  ────────────────────────                                           │
│  Setup script blocks making schedule MORE LENIENT                   │
│  Can only make it STRICTER without the unlock script                │
│                                                                     │
│  Layer 6: Power-Cycle Resistance                                    │
│  ──────────────────────────────                                     │
│  Lockdown MASKS getty@ and the display manager, it does not just    │
│  stop them. Masks are /dev/null symlinks, so they outlive a reboot. │
│  The enter script also re-checks those effects instead of trusting  │
│  its own state file.                                                │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Why the lockdown re-checks reality (2026-09-12)

`night-lockdown-enter.sh` used to treat `/var/lib/night-lockdown/state` ==
`LOCKED` as proof it had nothing to do. The token survives a power-cycle; the
lockdown did not, because `lightdm` is an enabled unit and came straight back
at boot. Locked 00:00:04, powered off and on at 00:01, and from then on every
curfew tick logged "already LOCKED — nothing to do" against a fully usable
desktop, right through to the 05:00 unlock.

Two changes close it, and they only work together:

- `lockdown_effective()` checks the observable effects (state token **and**
  `getty@` masked **and** the display manager masked **and** not running) and
  re-applies on any mismatch. Fail closed, never on a stale promise.
- The display manager is masked as well as stopped, so a reboot no longer hands
  the desktop back. `night-lockdown-unlock.sh` unmasks it — never ship one
  without the other, or the GUI never returns.

### Timer hours come from the live config

`create_shutdown_timer` reads `/etc/shutdown-schedule.conf`, not the
`SCHEDULE_*` constants in `setup_midnight_shutdown.sh`. Those drift: anything
that edits the config in place (screen_locker's sick-day feature does) left the
unit waking on the old hours. On this machine the config said 23:00 while the
timer's earliest entry was 00:00, so 23:00–00:00 went unenforced nightly.

After anything changes that config, run:

```bash
sudo ./setup_midnight_shutdown.sh sync-timer
```

It regenerates only the unit, changes no schedule value, and therefore never
goes through the ratchet — a full `enable` re-run would compare the repo
constants against the live config and silently accept the stricter of the two.

## File Locations

| File                                                  | Purpose             | Protection              |
| ----------------------------------------------------- | ------------------- | ----------------------- |
| `/etc/shutdown-schedule.conf`                         | Runtime config      | chattr +i, path watcher |
| `/usr/local/share/locked-shutdown-schedule.conf`      | Canonical copy      | chattr +i               |
| `/usr/local/bin/day-specific-shutdown-check.sh`       | Shutdown logic      | None                    |
| `/usr/local/bin/day-specific-shutdown-manager.sh`     | Status/management   | None                    |
| `/usr/local/bin/shutdown-timer-monitor.sh`            | Timer re-enabler    | None                    |
| `/usr/local/sbin/enforce-shutdown-schedule.sh`        | Config restoration  | None                    |
| `/usr/local/sbin/unlock-shutdown-schedule`            | Delayed config edit | None                    |
| `/etc/systemd/system/day-specific-shutdown.timer`     | Timer unit          | systemd                 |
| `/etc/systemd/system/day-specific-shutdown.service`   | Service unit        | systemd                 |
| `/etc/systemd/system/shutdown-schedule-guard.path`    | Config watcher      | systemd                 |
| `/etc/systemd/system/shutdown-schedule-guard.service` | Enforcement         | systemd                 |
| `/etc/systemd/system/shutdown-timer-monitor.service`  | Timer guardian      | systemd                 |
| `/var/log/shutdown-schedule-guard.log`                | Tampering log       | None                    |

## Config File Format

```bash
# /etc/shutdown-schedule.conf

# Shutdown hour for Monday-Wednesday (24-hour format)
MON_WED_HOUR=21

# Shutdown hour for Thursday-Sunday (24-hour format)
THU_SUN_HOUR=22

# Morning end hour (shutdown window ends at this hour)
MORNING_END_HOUR=5
```

**Interpretation**:

- Mon-Wed: Shutdown if current hour >= 21 OR current hour < 5
- Thu-Sun: Shutdown if current hour >= 22 OR current hour < 5

## Schedule Protection Logic

The setup script (`setup_midnight_shutdown.sh`) has constants at the top:

```bash
SCHEDULE_MON_WED_HOUR=24
SCHEDULE_THU_SUN_HOUR=24
SCHEDULE_MORNING_END_HOUR=0
```

When re-run, it compares these to the canonical config:

| Change Type                | Action                               |
| -------------------------- | ------------------------------------ |
| Making shutdown EARLIER    | ✅ Allowed without unlock            |
| Making shutdown LATER      | ❌ Blocked, requires unlock          |
| Making morning end EARLIER | ❌ Always blocked                    |
| Making morning end LATER   | ✅ Allowed (extends shutdown window) |

Example blocked attempt:

```
╔══════════════════════════════════════════════════════════════════╗
║     ❌ SCHEDULE MODIFICATION BLOCKED - CHEATING DETECTED! ❌     ║
╚══════════════════════════════════════════════════════════════════╝

You modified the script to make the shutdown schedule MORE LENIENT:
  • Mon-Wed shutdown: 21:00 → 23:00 (later)

Nice try! But this is exactly the kind of late-night bargaining
that this protection is designed to prevent. 😉
```

## Unlock Script Behavior

`/usr/local/sbin/unlock-shutdown-schedule`:

1. Stops `shutdown-schedule-guard.path`
2. Removes chattr from both config files
3. Opens editor on temp copy
4. Checks what changed:
   - **Stricter (earlier)**: No delay, applies immediately
   - **Lenient (later)**: 45-second countdown, then applies
   - **Lower morning end**: **ALWAYS BLOCKED** (cannot shorten window)
5. Updates both config and canonical
6. Re-applies chattr +i
7. Restarts path watcher

## Integration Points

### i3blocks Countdown

`i3blocks/shutdown_countdown.sh` reads the config to show time remaining:

```bash
source /etc/shutdown-schedule.conf
# Calculates and displays "Shutdown in X:XX"
```

### Screen Locker

`screen_lock.py` can adjust shutdown time:

- **Sick day**: Moves shutdown 1.5 hours EARLIER (penalty)
- **Workout completed**: Moves shutdown 1.5 hours LATER (reward)

Uses `adjust_shutdown_schedule.sh` helper script.

## More detail

Split out to stay under the 250-line cap.

- [Systemd units, check-script logic and common tasks](llm-notes/units-and-tasks.md)
- [Known vulnerabilities, troubleshooting and hard stops](llm-notes/vulns-and-troubleshooting.md)
