#!/bin/bash
# Convenience wrapper for constrained Arch package builds.

set -euo pipefail

PACMAN_WRAPPER_BIN="/usr/bin/pacman"

exec "$PACMAN_WRAPPER_BIN" --makepkg-capped "$@"
