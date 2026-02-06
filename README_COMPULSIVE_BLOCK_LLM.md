# Block Compulsive Opening - LLM Reference Guide

> **For AI assistants**: This document explains the compulsive opening blocker so you can make correct modifications.

## System Purpose

Limit messaging apps (Beeper, Signal, Discord) to **one launch per hour** to reduce compulsive checking behavior.

## How It Works

```
┌─────────────────────────────────────────────────────────────────────┐
│                    LAUNCH INTERCEPTION                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  User clicks "Discord" in app launcher                              │
│                    ↓                                                │
│  /usr/bin/discord (wrapper script)                                  │
│                    ↓                                                │
│  exec /usr/local/bin/block-compulsive-opening.sh wrapper discord    │
│                    ↓                                                │
│  Check: ~/.local/state/compulsive-block/discord.lastopen            │
│                    ↓                                                │
│  ┌─────────────────┴─────────────────┐                              │
│  │                                   │                              │
│  ▼ Not opened this hour              ▼ Already opened               │
│  Record opening time                 Show notification              │
│  Launch real binary                  Exit with error                │
│  /opt/discord/Discord                                               │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## File Locations

| File | Purpose |
|------|---------|
| `/usr/local/bin/block-compulsive-opening.sh` | Installed main script |
| `/usr/bin/beeper` | Wrapper (replaces original) |
| `/usr/bin/signal-desktop` | Wrapper (replaces original) |
| `/usr/bin/discord` | Wrapper (replaces original) |
| `/usr/bin/*.orig` or `SYMLINK:*` | Original binaries/links |
| `~/.local/state/compulsive-block/*.lastopen` | Per-app hour tracking |
| `~/.local/state/compulsive-block/compulsive-block.log` | Activity log |
| `/etc/pacman.d/hooks/95-compulsive-block-rewrap.hook` | Auto-rewrap hook |

## Managed Applications

```bash
declare -A APPS=(
  ["beeper"]="/usr/bin/beeper"
  ["signal-desktop"]="/usr/bin/signal-desktop"
  ["discord"]="/usr/bin/discord"
)

declare -A REAL_BINARIES=(
  ["beeper"]="/opt/beeper/beepertexts"
  ["signal-desktop"]="/usr/lib/signal-desktop/signal-desktop"
  ["discord"]="/opt/discord/Discord"
)
```

## State Tracking

Hour key format: `YYYY-MM-DD-HH` (e.g., `2026-02-02-14`)

State file content: Just the hour key string

```bash
# Check if opened this hour
cat ~/.local/state/compulsive-block/discord.lastopen
# Output: 2026-02-02-14

# Current hour
date '+%Y-%m-%d-%H'
# Output: 2026-02-02-15  (different = can open again)
```

## Wrapper Installation Process

When `install_all()` runs:

1. Copies script to `/usr/local/bin/block-compulsive-opening.sh`
2. For each app:
   - If original is a symlink: Save `SYMLINK:/target/path` to `.orig`
   - If original is a file: Move to `.orig`
   - Create wrapper script at original location:
   ```bash
   #!/bin/bash
   exec /usr/local/bin/block-compulsive-opening.sh wrapper "discord" "$@"
   ```
3. Install pacman hook for auto-rewrap

## Pacman Hook

After beeper/signal/discord package updates, the hook re-wraps them:

```ini
[Trigger]
Operation = Upgrade
Operation = Install
Type = Package
Target = beeper
Target = signal-desktop
Target = discord

[Action]
When = PostTransaction
Exec = /usr/local/bin/block-compulsive-opening.sh rewrap-quiet
```

The `rewrap-quiet` command:
- Checks if wrapper was overwritten (doesn't contain "block-compulsive-opening")
- If overwritten: removes stale `.orig`, re-installs wrapper
- Logs to activity log

## Commands

```bash
# Install all wrappers (requires root)
sudo ./block_compulsive_opening.sh install

# Uninstall all wrappers (requires root)
sudo ./block_compulsive_opening.sh uninstall

# Check status of all apps
./block_compulsive_opening.sh status

# Reset a specific app (allow opening again this hour)
./block_compulsive_opening.sh reset discord

# Reset all apps
./block_compulsive_opening.sh reset-all
```

## Log Format

```
2026-02-02 14:30:15 - ALLOWED: discord opened (first time this hour: 2026-02-02-14)
2026-02-02 14:30:15 - LAUNCHED: discord with PID 12345 (auto-close in 10m)
2026-02-02 14:38:15 - (notification: "Session will end in 2 minutes")
2026-02-02 14:40:15 - AUTO-CLOSED: discord (PID 12345) after 10m
2026-02-02 14:45:22 - BLOCKED: discord launch prevented (already opened this hour: 2026-02-02-14)
2026-02-02 15:01:03 - ALLOWED: discord opened (first time this hour: 2026-02-02-15)
2026-02-02 15:30:00 - RESET: discord state cleared by user
```

## Auto-Close Timer (Session Limit)

Apps are automatically closed after **10 minutes** to prevent indefinite usage:

1. When app launches, a background daemon is spawned
2. At **8 minutes**: Warning notification "Session will end in 2 minutes"
3. At **10 minutes**: App is closed with SIGTERM, then SIGKILL if needed
4. State file `~/.local/state/compulsive-block/<app>.running` tracks PID and start time

**Configuration variables** (in script):
```bash
AUTO_CLOSE_TIMEOUT_MINUTES=10   # Total session length
AUTO_CLOSE_WARNING_MINUTES=2     # Warning before close
```

## Adding a New App

1. Add to `APPS` associative array:
```bash
declare -A APPS=(
  # ... existing apps ...
  ["newapp"]="/usr/bin/newapp"
)
```

2. Add to `REAL_BINARIES`:
```bash
declare -A REAL_BINARIES=(
  # ... existing apps ...
  ["newapp"]="/opt/newapp/actual-binary"
)
```

3. Add to pacman hook targets (if installed via pacman):
```ini
Target = newapp
```

4. Reinstall:
```bash
sudo ./block_compulsive_opening.sh install
```

## Debugging

### Check if wrapper is installed
```bash
cat /usr/bin/discord
# Should show wrapper script, not binary

ls -la /usr/bin/discord.orig
# Should exist (or check for SYMLINK: content)
```

### Check current state
```bash
./block_compulsive_opening.sh status
# Shows: which apps are wrapped, last open times, current hour
```

### Test manually
```bash
# Simulate wrapper call
/usr/local/bin/block-compulsive-opening.sh wrapper discord
```

### View logs
```bash
tail -f ~/.local/state/compulsive-block/compulsive-block.log
```

## Notification Behavior

When blocked, shows desktop notification:
- Title: "🚫 discord Blocked"
- Message: "Already opened this hour. Wait until the next hour."
- Urgency: critical
- Timeout: 5000ms

Uses `notify-send` (falls back silently if not available).

## DO NOT

1. ❌ Delete `.orig` files (cannot restore original binaries)
2. ❌ Manually edit wrapper scripts at `/usr/bin/` (will be overwritten)
3. ❌ Assume app is "blocked" once notification shows (it ran, just not again)
4. ❌ Remove pacman hook without understanding auto-rewrap won't work
