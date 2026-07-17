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
|--------------|-------------|-------------|---------|---------------|
| Steam | 5 | 160 | 60s | 0-20s |
| VirtualBox | 7 | 150 | 120s | 0-45s |
| Greylist | 6 | 120 | 90s | 0-30s |

## Integrity Verification

On every invocation, the wrapper verifies policy files haven't been tampered with:

```bash
verify_policy_integrity() {
  # Reads /var/lib/pacman-wrapper/policy.sha256
  # Compares SHA256 of each policy file
  # If mismatch: BLOCKS all operations
}
```

If tampering detected:

```
SECURITY WARNING: Policy file integrity check failed!
CRITICAL: Policy files have been tampered with!
Wrapper operation DENIED. Please reinstall using: sudo install_pacman_wrapper.sh
```

## Hosts Integration

The wrapper integrates with the hosts guard system:

```bash
pre_unlock_hosts() {
  # Called before any transaction (-S, -U, -R)
  /usr/local/share/hosts-guard/pacman-pre-unlock-hosts.sh
}

post_relock_hosts() {
  # Called after transaction completes
  /usr/local/share/hosts-guard/pacman-post-relock-hosts.sh
}
```

This allows package installations to modify `/etc/hosts` temporarily (e.g., for network setup) while maintaining protection.

## Common Tasks

### Adding a Blocked Package

1. Edit `pacman_blocked_keywords.txt`:

```bash
echo "newkeyword" >> pacman_blocked_keywords.txt
```

2. Reinstall wrapper to update checksums:

```bash
sudo ./install_pacman_wrapper.sh
```

### Whitelisting a Package

If a legitimate package is being blocked (e.g., `python-firefox-sync` blocked by "firefox" keyword):

1. Edit `pacman_whitelist.txt`:

```bash
echo "python-firefox-sync" >> pacman_whitelist.txt
```

2. Reinstall wrapper:

```bash
sudo ./install_pacman_wrapper.sh
```

### Adding a Challenge Requirement

1. Edit `pacman_greylist.txt`:

```bash
echo "suspicious-package" >> pacman_greylist.txt
```

2. Reinstall wrapper.

### Bypassing the Wrapper (Emergency)

If wrapper is broken and you need real pacman:

```bash
sudo /usr/bin/pacman.orig -S package
```

**Warning**: This bypasses all security checks.

## Post-Transaction Cleanup

After every transaction, the wrapper:

1. Scans installed packages for blocked keywords
2. Removes any that match (shouldn't happen normally)
3. Scans for greylisted packages and removes them
4. Checks if VirtualBox is installed and enforces hosts

```bash
remove_installed_blocked_packages() {
  mapfile -t installed_names < <("$PACMAN_BIN" -Qq)
  for name in "${installed_names[@]}"; do
    if is_blocked_package_name "$name"; then
      pacman -Rns --noconfirm "$name"
    fi
  done
}
```

## Stale Lock Handling

The stale-lock logic lives in **`pacman_lock_lib.sh`** (shared, sourced by both
`pacman_wrapper.sh` and `makepkg_wrapper.sh` — single source of truth). The
wrapper sources it only AFTER `verify_policy_integrity`, and the lib is listed in
the integrity manifest, so a tampered lib is rejected before it runs.

If `/var/lib/pacman/db.lck` exists but no pacman is running:

- Interactive: Prompts user to remove (15s timeout)
- Non-interactive (`--noconfirm`): Auto-removes; also auto-removes if lock is
  > 10 minutes old
- If a real pacman/pamac process is running: Blocks with error. Detection uses
  `fuser`/`lsof` on the lock file AND a system-wide `pgrep -x pacman` guard
  (`pacman_process_running`) so an UNPRIVILEGED caller (makepkg is never root)
  can still see a ROOT `pacman -Syu` that its own `fuser` cannot.

### Makepkg wrapper

`/usr/bin/makepkg` is symlinked to `makepkg_wrapper` (real binary at
`/usr/bin/makepkg.orig`). Vendored `makepkg`'s `run_pacman()` has its own
lock-wait that checks ONLY file existence with no timeout, so an orphaned
`db.lck` hangs `makepkg -i` forever ("Pacman is currently in use, please
wait...") _before_ pacman is ever called — the pacman wrapper's cleanup never
gets a turn. `makepkg_wrapper` closes this: for install-bound invocations
(`-i`/`--install`) it clears an orphaned lock up front, then execs real makepkg.
It bypasses (execs real makepkg unchanged) inside a fakeroot build sandbox
(`FAKEROOTKEY` set) or for non-install invocations, and **fails open** — if the
shared lib is missing it execs real makepkg rather than break all builds.

### Upgrade survival

A `pacman-git` upgrade reinstalls `/usr/bin/pacman` and `/usr/bin/makepkg` as
stock binaries, clobbering the wrapper symlinks. Two mechanisms restore them:

- **PostTransaction hook** `/etc/pacman.d/hooks/96-restore-pkg-wrappers.hook`
  (Target = pacman/pacman-git) runs `rewrap_pkg_managers.sh` (file-ops only,
  never calls pacman) to re-establish both symlinks and refresh the `.orig`
  backups. NOTE: alpm `Operation` accepts only Install/Upgrade/Remove — an
  invalid value aborts EVERY transaction; validate with a real `-S` install.
- **Drift verifier** `check_makepkg_wrapper()` in `check_and_enable_services.sh`
  plus the hourly periodic driver re-running both installers.

## Maintenance Auto-Setup

On first run, wrapper checks if periodic maintenance services exist:

```bash
ensure_periodic_maintenance() {
  # Checks: periodic-system-maintenance.timer
  #         periodic-system-startup.service
  #         hosts-file-monitor.service
  # If missing: runs setup_periodic_system.sh
}
```

## Known Gaps (TODO)

1. ❌ `google-chrome` and `google-chrome-stable` not in blocked list
2. ❌ No automatic LeechBlock installation when browsers detected
3. ❌ User can download and install `.deb`/`.tar.gz` manually
4. ❌ AUR packages bypass wrapper (yay/paru call pacman internally)

## Debugging

### Check if wrapper is installed

```bash
ls -la /usr/bin/pacman
# Should show: /usr/bin/pacman -> /path/to/pacman_wrapper.sh

ls -la /usr/bin/pacman.orig
# Should exist and be the real binary
```

### Test policy integrity

```bash
cat /var/lib/pacman-wrapper/policy.sha256
sha256sum /path/to/pacman_blocked_keywords.txt
# Hashes should match
```

### Verbose mode

The wrapper outputs colored status messages to stderr. To see them:

```bash
pacman -S package 2>&1 | cat
```

## DO NOT

1. ❌ Edit policy files without reinstalling wrapper (breaks integrity check)
2. ❌ Remove `/usr/bin/pacman.orig` (breaks all pacman operations)
3. ❌ Symlink pacman to something other than the wrapper
4. ❌ Clear `/var/lib/pacman-wrapper/` without understanding consequences
