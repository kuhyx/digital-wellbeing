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

| File | Purpose | Protection |
|------|---------|------------|
| `/etc/shutdown-schedule.conf` | Runtime config | chattr +i, path watcher |
| `/usr/local/share/locked-shutdown-schedule.conf` | Canonical copy | chattr +i |
| `/usr/local/bin/day-specific-shutdown-check.sh` | Shutdown logic | None |
| `/usr/local/bin/day-specific-shutdown-manager.sh` | Status/management | None |
| `/usr/local/bin/shutdown-timer-monitor.sh` | Timer re-enabler | None |
| `/usr/local/sbin/enforce-shutdown-schedule.sh` | Config restoration | None |
| `/usr/local/sbin/unlock-shutdown-schedule` | Delayed config edit | None |
| `/etc/systemd/system/day-specific-shutdown.timer` | Timer unit | systemd |
| `/etc/systemd/system/day-specific-shutdown.service` | Service unit | systemd |
| `/etc/systemd/system/shutdown-schedule-guard.path` | Config watcher | systemd |
| `/etc/systemd/system/shutdown-schedule-guard.service` | Enforcement | systemd |
| `/etc/systemd/system/shutdown-timer-monitor.service` | Timer guardian | systemd |
| `/var/log/shutdown-schedule-guard.log` | Tampering log | None |

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

| Change Type | Action |
|-------------|--------|
| Making shutdown EARLIER | ✅ Allowed without unlock |
| Making shutdown LATER | ❌ Blocked, requires unlock |
| Making morning end EARLIER | ❌ Always blocked |
| Making morning end LATER | ✅ Allowed (extends shutdown window) |

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

## Systemd Units

### Timer (fires every minute)
```ini
[Timer]
OnCalendar=*:*:00
Persistent=false
AccuracySec=1s
```

### Check Service
```ini
[Service]
Type=oneshot
ExecStart=/usr/local/bin/day-specific-shutdown-check.sh
```

### Path Watcher
```ini
[Path]
PathChanged=/etc/shutdown-schedule.conf
Unit=shutdown-schedule-guard.service
```

## Check Script Logic

```bash
# Pseudocode for day-specific-shutdown-check.sh

source /etc/shutdown-schedule.conf
day=$(date +%u)  # 1=Monday, 7=Sunday
hour=$(date +%H)

if [[ $day -le 3 ]]; then
  shutdown_hour=$MON_WED_HOUR
else
  shutdown_hour=$THU_SUN_HOUR
fi

# Check if in shutdown window
if [[ $hour -ge $shutdown_hour ]] || [[ $hour -lt $MORNING_END_HOUR ]]; then
  systemctl poweroff
fi
```

## Common Tasks

### Check Current Status
```bash
/usr/local/bin/day-specific-shutdown-manager.sh status
# Or run setup script with 'status' argument
```

### Make Schedule Stricter
Edit the constants in `setup_midnight_shutdown.sh`:
```bash
SCHEDULE_MON_WED_HOUR=20  # Changed from 21 to 20 (earlier)
```
Then re-run:
```bash
sudo ./setup_midnight_shutdown.sh
```

### Make Schedule More Lenient (Requires Unlock)
```bash
sudo /usr/local/sbin/unlock-shutdown-schedule
# Wait for delay, edit config, save
```

### Disable Timer (Will Be Re-Enabled!)
```bash
sudo systemctl disable --now day-specific-shutdown.timer
# Monitor service will re-enable it automatically
```

### Check Protection Status
```bash
lsattr /etc/shutdown-schedule.conf
# Should show: ----i--------e--

systemctl status shutdown-schedule-guard.path
systemctl status shutdown-timer-monitor.service
```

## KNOWN VULNERABILITIES

1. **Information Disclosure**: Error messages tell user exactly how to bypass
2. **Unlock Script Discoverable**: Path mentioned in error messages
3. **Timer Monitor Killable**: User can stop the monitor then the timer
4. **Check Script Unprotected**: `/usr/local/bin/day-specific-shutdown-check.sh` can be edited

**TODO**: 
- Remove helpful bypass instructions from error messages
- Rename unlock script to obscure name
- Protect check script with integrity verification

## Troubleshooting

### Timer not firing
```bash
systemctl status day-specific-shutdown.timer
systemctl list-timers | grep shutdown
```

### Config not being enforced
```bash
# Check path watcher
systemctl status shutdown-schedule-guard.path

# Manually trigger enforcement
sudo /usr/local/sbin/enforce-shutdown-schedule.sh
```

### Wrong time shown in i3blocks
```bash
# Verify config
cat /etc/shutdown-schedule.conf

# Check i3blocks config
cat ~/.config/i3blocks/config | grep shutdown
```

## DO NOT

1. ❌ Edit setup script constants to make schedule later (will be blocked)
2. ❌ Delete canonical config (breaks restoration)
3. ❌ Stop `shutdown-timer-monitor.service` (timer will be re-enabled anyway)
4. ❌ Modify check script to skip shutdown (defeats purpose)
5. ❌ Lower `MORNING_END_HOUR` (always blocked, shortens shutdown window)
