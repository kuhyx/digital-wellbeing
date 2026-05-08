#!/bin/bash
# Run makepkg inside a constrained user scope to protect desktop responsiveness.

set -euo pipefail

CPU_QUOTA="${MAKEPKG_CPU_QUOTA:-70%}"
MEMORY_MAX="${MAKEPKG_MEMORY_MAX:-12G}"
TASKS_MAX="${MAKEPKG_TASKS_MAX:-2048}"
NICE_LEVEL="${MAKEPKG_NICE_LEVEL:-10}"
IONICE_CLASS="${MAKEPKG_IONICE_CLASS:-2}"
IONICE_LEVEL="${MAKEPKG_IONICE_LEVEL:-7}"

if ! command -v makepkg >/dev/null 2>&1; then
  echo "makepkg_capped: makepkg not found in PATH" >&2
  exit 127
fi

run_makepkg_fallback() {
  exec ionice -c "$IONICE_CLASS" -n "$IONICE_LEVEL" \
    nice -n "$NICE_LEVEL" \
    makepkg "$@"
}

if ! command -v systemd-run >/dev/null 2>&1; then
  echo "makepkg_capped: systemd-run unavailable, falling back to local limits" >&2
  run_makepkg_fallback "$@"
fi

# Keep builds in the user manager scope. If this fails (no user manager),
# gracefully fall back to ionice+nice only.
if ! systemd-run --user --scope --quiet true 2>/dev/null; then
  echo "makepkg_capped: user systemd scope unavailable, falling back" >&2
  run_makepkg_fallback "$@"
fi

exec systemd-run --user --scope --quiet --same-dir --collect \
  -p "CPUQuota=${CPU_QUOTA}" \
  -p "MemoryMax=${MEMORY_MAX}" \
  -p "MemorySwapMax=0" \
  -p "TasksMax=${TASKS_MAX}" \
  ionice -c "$IONICE_CLASS" -n "$IONICE_LEVEL" \
  nice -n "$NICE_LEVEL" \
  makepkg "$@"
