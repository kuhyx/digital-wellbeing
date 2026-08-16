# Integrity verification, cleanup and stale locks

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
