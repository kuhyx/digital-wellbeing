# Pacman Wrapper Security System - LLM Reference Guide

> **For AI assistants**: This document explains the pacman wrapper architecture so you can make correct modifications.

## System Purpose

Intercept all `pacman` commands to:

1. Require a weekend-only word challenge for Steam
2. Remove VirtualBox VMs after every transaction (they bypass /etc/hosts)
3. Auto-setup maintenance services if missing
4. Handle stale database locks gracefully

There is no package policy list any more: the blocked-keyword, allow and
challenge lists were retired on 2026-10-17 because hosts/DNS blocking now
covers what they guarded. Re-running the installer deletes any deployed copies.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         PACMAN WRAPPER                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  User runs: pacman -S steam                                         │
│                    ↓                                                │
│  /usr/bin/pacman (symlink) → pacman_wrapper.sh                      │
│                    ↓                                                │
│  1. Verify wrapper library integrity (SHA256)                       │
│  2. Steam word challenge if requested                               │
│  3. Run hosts-guard pre-unlock hook                                 │
│  4. Execute real pacman: /usr/bin/pacman.orig                       │
│  5. Run hosts-guard post-relock hook                                │
│  6. Remove VirtualBox VMs if vbox detected                          │
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
| `words.txt`                             | Word scramble challenge dictionary |
| `/var/lib/pacman-wrapper/policy.sha256` | Integrity checksums                |

## Hardcoded Security Checks

These checks are in the script itself:

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

Used for Steam:

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

## More detail

Split out to stay under the 250-line cap.

- [Integrity verification, cleanup and stale locks](llm-notes/verification-and-cleanup.md)
- [Maintenance auto-setup, known gaps and debugging](llm-notes/maintenance-and-debugging.md)
