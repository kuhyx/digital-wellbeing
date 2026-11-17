#!/bin/bash
# Work-laptop food-delivery block (work_laptop/food_block): apply.sh must
# write the /etc/hosts block and every browser policy, stay idempotent, and
# restore anything a user deletes or edits.
#
# Runs apply.sh against a scratch root (FOOD_BLOCK_ROOT), so it never touches
# this machine's /etc: Helium here reads /etc/chromium/policies, which is live.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY="$(dirname "$SCRIPT_DIR")/work_laptop/food_block/apply.sh"

failed=0
pass() { printf '✓ %s\n' "$1"; }
fail() {
	printf '✗ %s\n' "$1"
	failed=1
}
check() { # check <label> <command...>
	local label="$1"
	shift
	if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/etc/firefox/policies" "$ROOT/opt/fakebrowser"
printf '127.0.0.1 localhost\n' >"$ROOT/etc/hosts"
# A user's own Firefox policy must survive the merge.
printf '{"policies":{"DisableTelemetry":true}}\n' >"$ROOT/etc/firefox/policies/policies.json"
# Fake browser binary: big enough to pass the size filter, with an embedded
# policy path no fixed list knows about (stands in for Thorium-style forks).
truncate -s 60M "$ROOT/opt/fakebrowser/fakebrowser"
printf 'xx/etc/fakebrowser/policies\0' >>"$ROOT/opt/fakebrowser/fakebrowser"
chmod +x "$ROOT/opt/fakebrowser/fakebrowser"

run_apply() { FOOD_BLOCK_ROOT="$ROOT" bash "$APPLY"; }

if [[ ! -f $APPLY ]]; then
	fail "apply.sh exists at $APPLY"
	exit 1
fi
check "apply.sh exits 0 on a scratch root" run_apply

hosts="$ROOT/etc/hosts"
check "hosts keeps the original localhost line" grep -qx '127.0.0.1 localhost' "$hosts"
check "hosts blocks ubereats.com over IPv4" grep -qx '0.0.0.0 ubereats.com' "$hosts"
check "hosts blocks ubereats.com over IPv6" grep -qx ':: ubereats.com' "$hosts"
check "hosts blocks www.wolt.com variant" grep -qx '0.0.0.0 www.wolt.com' "$hosts"
check "hosts blocks jush.pl" grep -qx '0.0.0.0 jush.pl' "$hosts"
check "uber.com (rides) stays reachable" bash -c "! grep -qE ' (www\\.)?uber\\.com\$' '$hosts'"
check "bolt.eu (rides) stays reachable" bash -c "! grep -qE ' (www\\.)?bolt\\.eu\$' '$hosts'"

before="$(sha256sum "$hosts")"
run_apply
check "second run leaves hosts byte-identical" test "$before" = "$(sha256sum "$hosts")"
check "block marker appears once" test "$(grep -c '>>> food-block' "$hosts")" -eq 1

sed -i '/ ubereats\.com$/d' "$hosts"
run_apply
check "deleted hosts line is restored" grep -qx '0.0.0.0 ubereats.com' "$hosts"

check_policy() { # check_policy <label> <file>
	if jq -e '(.URLBlocklist | index("ubereats.com")) and .DnsOverHttpsMode == "off"' "$2" >/dev/null 2>&1; then
		pass "$1"
	else
		fail "$1"
	fi
}
for dir in /etc/opt/chrome /etc/chromium /etc/chromium-browser /etc/brave /etc/fakebrowser; do
	check_policy "chromium policy valid in $dir" "$ROOT$dir/policies/managed/food_block.json"
done

rm "$ROOT/etc/opt/chrome/policies/managed/food_block.json"
run_apply
check_policy "deleted Chrome policy is restored" "$ROOT/etc/opt/chrome/policies/managed/food_block.json"

ff="$ROOT/etc/firefox/policies/policies.json"
check "firefox blocks ubereats.com subdomains" jq -e '.policies.WebsiteFilter.Block | index("*://*.ubereats.com/*")' "$ff"
check "firefox blocks bare ubereats.com" jq -e '.policies.WebsiteFilter.Block | index("*://ubereats.com/*")' "$ff"
check "firefox DoH off and locked" jq -e '.policies.DNSOverHTTPS == {"Enabled":false,"Locked":true}' "$ff"
check "firefox keeps the user's own policy" jq -e '.policies.DisableTelemetry == true' "$ff"
n1="$(jq '.policies.WebsiteFilter.Block | length' "$ff")"
run_apply
check "firefox block list does not grow on rerun" test "$n1" = "$(jq '.policies.WebsiteFilter.Block | length' "$ff")"

empty="$(mktemp -d)"
cp -r "$(dirname "$APPLY")/." "$empty/"
printf '# nothing\n' >"$empty/domains.txt"
check "empty domain list fails loudly (non-zero)" bash -c "! FOOD_BLOCK_ROOT='$ROOT' bash '$empty/apply.sh'"
rm -rf "$empty"

exit "$failed"
