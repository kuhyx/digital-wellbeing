# Maintenance auto-setup, known gaps and debugging

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
