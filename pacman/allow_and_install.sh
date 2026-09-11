#!/bin/bash

# ============================================================================
# allow_and_install.sh -- ship a pacman_whitelist.txt change end to end.
#
# The whitelist is policy: editing the file in this repo does nothing until
# install_pacman_wrapper.sh redeploys it to /usr/local/bin and refreshes the
# integrity manifest. Forgetting that step is how "I allowed it, why is it
# still BLOCKED" happens. This does every step in order, and fails closed:
#
#   1. the package must already be an exact-name entry in pacman_whitelist.txt
#      (with its dated rationale -- this script never edits policy itself);
#   2. commit + push the whitelist if it is dirty, so the deployed policy and
#      main never drift apart;
#   3. sudo install_pacman_wrapper.sh (redeploys lists + integrity manifest);
#   4. yay -S <pkg>, non-interactively;
#   5. if the package is a browser install_leechblock.sh knows about, wrap it
#      -- an allowed browser is only allowed BECAUSE LeechBlock is enforced in it.
#
# Usage: pacman/allow_and_install.sh <package> [<package>...]
# ============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_DIR
readonly WHITELIST="${REPO_DIR}/pacman/pacman_whitelist.txt"
readonly WRAPPER_INSTALLER="${REPO_DIR}/pacman/install_pacman_wrapper.sh"
readonly LEECHBLOCK_INSTALLER="${REPO_DIR}/install_leechblock.sh"
readonly LEECHBLOCK_BROWSERS="${REPO_DIR}/lib/leechblock_browsers.sh"

log() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf 'allow_and_install: FAILED -- %s\n' "$1" >&2; exit 1; }

usage() {
    sed -n '3,21p' "$0"
    exit 0
}

require_whitelisted() {
    local pkg
    for pkg in "$@"; do
        grep -qxF "$pkg" "$WHITELIST" \
            || fail "$pkg is not an exact-name entry in $WHITELIST -- add it WITH a dated rationale first"
    done
}

commit_whitelist() {
    if git -C "$REPO_DIR" diff --quiet -- pacman/pacman_whitelist.txt \
        && git -C "$REPO_DIR" diff --cached --quiet -- pacman/pacman_whitelist.txt; then
        log "whitelist already committed"
        return
    fi
    log "committing + pushing the whitelist change"
    git -C "$REPO_DIR" add pacman/pacman_whitelist.txt
    git -C "$REPO_DIR" commit -q -m "pacman whitelist: allow $*"
    git -C "$REPO_DIR" push -q origin HEAD
}

redeploy_policy() {
    log "redeploying the pacman wrapper policy (sudo)"
    sudo "$WRAPPER_INSTALLER"
}

install_packages() {
    log "installing: $*"
    yay -S --noconfirm --needed --answerclean None --answerdiff None "$@"
}

is_leechblock_browser() {
    # The BROWSERS map in lib/leechblock_browsers.sh is the single source of
    # truth for "which packages are browsers LeechBlock can be wired into".
    grep -qE "^\s*\[\"$1\"\]=" "$LEECHBLOCK_BROWSERS"
}

wrap_browsers() {
    local pkg any=0
    for pkg in "$@"; do
        is_leechblock_browser "$pkg" && any=1
    done
    [[ $any == 1 ]] || return 0
    log "browser installed -- wiring LeechBlock into it (sudo)"
    sudo "$LEECHBLOCK_INSTALLER"
}

main() {
    [[ $# -ge 1 ]] || usage
    require_whitelisted "$@"
    commit_whitelist "$@"
    redeploy_policy
    install_packages "$@"
    wrap_browsers "$@"
    log "done: $*"
}

case "${1:-}" in
    -h|--help) usage ;;
esac

main "$@"
