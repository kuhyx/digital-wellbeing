# Pacman Wrapper Security System - LLM Reference Guide

> **For AI assistants**: This document explains the pacman wrapper architecture so you can make correct modifications.

## System Purpose

Intercept all `pacman` commands to:

1. Remove VirtualBox VMs after every transaction (they bypass /etc/hosts)
2. Auto-setup maintenance services if missing
3. Handle stale database locks gracefully

There is no package policy list any more: the blocked-keyword, allow and
challenge lists were retired on 2026-10-17 because hosts/DNS blocking now
covers what they guarded. Re-running the installer deletes any deployed copies.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         PACMAN WRAPPER                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  User runs: pacman -S <package>                                      │
│                    ↓                                                │
│  /usr/bin/pacman (symlink) → pacman_wrapper.sh                      │
│                    ↓                                                │
│  1. Verify wrapper library integrity (SHA256)                       │
│  2. Run hosts-guard pre-unlock hook                                 │
│  3. Execute real pacman: /usr/bin/pacman.orig                       │
│  4. Run hosts-guard post-relock hook                                │
│  5. Remove VirtualBox VMs if vbox detected                          │
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
| `/var/lib/pacman-wrapper/policy.sha256` | Integrity checksums                |

## Hardcoded Security Checks

These checks are in the script itself:

### Steam

The wrapper does not gate Steam. Since 2026-11-16 steam-backlog-enforcer is the
only thing that blocks, removes or allows Steam.

## More detail

Split out to stay under the 250-line cap.

- [Integrity verification, cleanup and stale locks](llm-notes/verification-and-cleanup.md)
- [Maintenance auto-setup, known gaps and debugging](llm-notes/maintenance-and-debugging.md)
