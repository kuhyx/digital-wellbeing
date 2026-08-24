# Pacman Wrapper Security System - LLM Reference Guide

> **For AI assistants**: This document explains the pacman wrapper architecture so you can make correct modifications.

## System Purpose

Intercept all `pacman` commands to:

1. Block installation of restricted packages (browsers, games, etc.)
2. Require challenges for greylisted packages
3. Enforce hosts file sharing on VirtualBox VMs
4. Auto-setup maintenance services if missing
5. Handle stale database locks gracefully

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         PACMAN WRAPPER                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  User runs: pacman -S firefox                                       │
│                    ↓                                                │
│  /usr/bin/pacman (symlink) → pacman_wrapper.sh                      │
│                    ↓                                                │
│  1. Verify policy file integrity (SHA256)                           │
│  2. Check if package matches blocked keywords                       │
│  3. Check if package requires challenge (greylist)                  │
│  4. Run hosts-guard pre-unlock hook                                 │
│  5. Execute real pacman: /usr/bin/pacman.orig                       │
│  6. Run hosts-guard post-relock hook                                │
│  7. Remove any blocked packages that slipped through                │
│  8. Enforce VirtualBox hosts if vbox detected                       │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## File Locations

| File                                    | Purpose                            |
| --------------------------------------- | ---------------------------------- |
| `/usr/bin/pacman`                       | Symlink to wrapper                 |
| `/usr/bin/pacman.orig`                  | Real pacman binary                 |
| `pacman_wrapper.sh`                     | Main wrapper script (823 lines)    |
| `install_pacman_wrapper.sh`             | Installer script                   |
| `pacman_blocked_keywords.txt`           | Substrings that cause blocking     |
| `pacman_whitelist.txt`                  | Exact names that bypass blocking   |
| `pacman_greylist.txt`                   | Packages requiring challenge       |
| `words.txt`                             | Word scramble challenge dictionary |
| `/var/lib/pacman-wrapper/policy.sha256` | Integrity checksums                |

## Policy Files Explained

### pacman_blocked_keywords.txt

```
# Lines starting with # are comments
# Any package containing these substrings is BLOCKED
firefox
brave
chromium
youtube
stremio
```

If user tries `pacman -S firefox-developer-edition`, it's blocked because it contains "firefox".

### pacman_whitelist.txt

```
# Exact package names that bypass keyword blocking
minizip          # Contains nothing bad but might match a pattern
python-requests  # Safe despite containing blocked substrings
```

### pacman_greylist.txt

```
# Packages requiring word scramble challenge
# Currently empty - add packages here for challenge requirement
```

## Hardcoded Security Checks

These checks are in the script itself and **cannot be bypassed by editing policy files**:

### VirtualBox Check

```bash
function is_virtualbox_package() {
  local pkg_lower="${1,,}"
  [[ $pkg_lower == *"virtualbox"* || $pkg_lower == *"vbox"* ]]
}
```

- Detects any package with "virtualbox" or "vbox" in name
- Requires word scramble challenge (7-letter words, 120s timeout)
- Auto-enforces hosts file sharing on all VMs after install

### Steam Check

```bash
function is_steam_package() {
  [[ $1 == "steam" ]]
}
```

- Only exact match "steam" (not steam-native-runtime etc.)
- **Weekend only** - blocked Monday through Friday 4PM
- Requires word scramble challenge (5-letter words, 60s timeout)

## Word Scramble Challenge

Used for Steam, VirtualBox, and greylisted packages:

```
Challenge: Words with 5 letters
Here are 160 random words. Remember them:
APPLE   BRAVE   CHAIR   DANCE   ...

One of those words has been scrambled to: ELPPA
Unscramble the word to proceed (you have 60 seconds):
```

Parameters vary by package type:

| Package Type | Word Length | Words Shown | Timeout | Initial Delay |
| ------------ | ----------- | ----------- | ------- | ------------- |
| Steam        | 5           | 160         | 60s     | 0-20s         |
| VirtualBox   | 7           | 150         | 120s    | 0-45s         |
| Greylist     | 6           | 120         | 90s     | 0-30s         |

## More detail

Split out to stay under the 250-line cap.

- [Integrity verification, cleanup and stale locks](llm-notes/verification-and-cleanup.md)
- [Maintenance auto-setup, known gaps and debugging](llm-notes/maintenance-and-debugging.md)
