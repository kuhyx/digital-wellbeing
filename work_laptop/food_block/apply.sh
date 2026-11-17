#!/bin/bash
# food-block enforcer: (re)applies the food-delivery block on the work laptop.
# Run as root by food-block.service (timer every 5 min, on boot, and on any
# /etc/hosts change). Every layer is rebuilt from domains.txt on each run and
# only rewritten on drift, so manual edits are reverted within minutes.
#
# Layers: /etc/hosts block (lib/fb_hosts.sh), Chromium-family managed
# policies and Firefox policies.json (lib/fb_policies.sh).
#
# Failure mode: fail loudly. Any layer error exits non-zero and shows up as a
# failed unit in the journal; the other layers already written stay in place.
#
# FOOD_BLOCK_ROOT  prefix for every system path (tests use a scratch dir);
#                  empty = the real /. chattr runs only on the real root.

set -euo pipefail

readonly ROOT="${FOOD_BLOCK_ROOT:-}"
SHARE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
readonly SHARE

# shellcheck source=lib/fb_common.sh
source "$SHARE/lib/fb_common.sh"
# shellcheck source=lib/fb_hosts.sh
source "$SHARE/lib/fb_hosts.sh"
# shellcheck source=lib/fb_policies.sh
source "$SHARE/lib/fb_policies.sh"

command -v jq >/dev/null || die "jq is missing (install.sh installs it)"

mapfile -t DOMAINS < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$SHARE/domains.txt" | grep -v '^$')
((${#DOMAINS[@]} > 0)) || die "domain list $SHARE/domains.txt is empty"

apply_hosts
apply_chromium_policies
apply_firefox_policy
log "ok: ${#DOMAINS[@]} domains enforced"
