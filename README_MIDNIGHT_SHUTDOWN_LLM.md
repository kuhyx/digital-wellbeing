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
│  day-specific-shutdown.timer fires every minute                     │
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
└─────────────────────────────────────────────────────────────────────┘
```

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
