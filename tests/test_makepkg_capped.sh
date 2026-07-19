#!/bin/bash
# Regression checks for makepkg_capped wrapper.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
WRAPPER="$REPO_DIR/scripts/periodic_background/digital_wellbeing/pacman/makepkg_capped.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

printf 'Checking makepkg_capped exists...\n'
[[ -f "$WRAPPER" ]] || fail 'makepkg_capped.sh is missing'

printf 'Checking makepkg_capped syntax...\n'
bash -n "$WRAPPER"

printf 'Checking systemd scope limits are present...\n'
grep -Fq 'CPUQuota=' "$WRAPPER" || fail 'CPUQuota setting missing'
grep -Fq 'MemoryMax=' "$WRAPPER" || fail 'MemoryMax setting missing'
grep -Fq 'MemorySwapMax=0' "$WRAPPER" || fail 'MemorySwapMax=0 setting missing'
grep -Fq 'TasksMax=' "$WRAPPER" || fail 'TasksMax setting missing'

printf 'Checking graceful fallback path exists...\n'
grep -Fq 'run_makepkg_fallback' "$WRAPPER" || fail 'fallback function missing'
grep -Fq 'systemd-run --user --scope --quiet true' "$WRAPPER" || fail 'user-scope probe missing'

printf 'makepkg_capped regression checks passed.\n'
