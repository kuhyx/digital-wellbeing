#!/bin/bash
# nmap (nonfree NPSL licence) must never be installed again: the pacman wrapper
# refuses any install/upgrade transaction naming it, and a /usr/local/bin/nmap
# shim points callers at rustscan. Removals and queries stay untouched.
#
# Pure function-level checks (no root, no pacman): the wrapper libs are sourced
# and check_for_nmap is driven with argument vectors. The end-to-end run in a
# real wrapper lives in the vmbox procedure (see DOCS-pacman-wrapper-reference.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_DIR="$(dirname "$SCRIPT_DIR")/pacman"

failed=0
pass() { printf '✓ %s\n' "$1"; }
fail() {
	printf '✗ %s\n' "$1"
	failed=1
}

RED='' YELLOW='' GREEN='' BLUE='' CYAN='' NC=''
# shellcheck source=../pacman/pw_policy.sh
source "$WRAPPER_DIR/pw_policy.sh"
# shellcheck source=../pacman/pw_challenge.sh
source "$WRAPPER_DIR/pw_challenge.sh"

if ! declare -F check_for_nmap >/dev/null; then
	fail "check_for_nmap is not defined in pw_policy.sh"
	exit 1
fi

echo "[TEST] Transactions naming nmap are refused..."
blocked=(
	"-S nmap" "-Sy nmap" "-Syu nmap" "-Syyu nmap" "-Sdd nmap"
	"-S --needed nmap" "-S --noconfirm --asdeps nmap" "-S extra/nmap"
	"-S rustscan nmap" "--sync nmap" "-U /tmp/nmap-7.99-1-x86_64.pkg.tar.zst"
	"-U nmap" "--upgrade /var/cache/pacman/pkg/nmap-7.99-1-x86_64.pkg.tar.zst"
)
for line in "${blocked[@]}"; do
	read -r -a args <<<"$line"
	if check_for_nmap "${args[@]}"; then pass "blocked: pacman $line"; else fail "NOT blocked: pacman $line"; fi
done

echo "[TEST] Everything else passes..."
allowed=(
	"-Rns nmap" "-R nmap" "-Rs nmap" "-S rustscan" "-Syu" "-Ss nmap"
	"-Si nmap" "-Sg nmap" "-Qi nmap" "-Q nmap" "-S python-nmap" "-S nmapsi4"
	"-U /tmp/rustscan-2.3.0-1-x86_64.pkg.tar.zst" "-T nmap" "--version"
)
for line in "${allowed[@]}"; do
	read -r -a args <<<"$line"
	if check_for_nmap "${args[@]}"; then fail "wrongly blocked: pacman $line"; else pass "allowed: pacman $line"; fi
done
if check_for_nmap; then fail "wrongly blocked: pacman (no args)"; else pass "allowed: pacman (no args)"; fi

echo "[TEST] The refusal names rustscan and fails..."
if ! declare -F refuse_nmap_install >/dev/null; then
	fail "refuse_nmap_install is not defined"
else
	rc=0
	out="$(refuse_nmap_install 2>&1)" || rc=$?
	if [[ $rc -ne 0 ]]; then pass "refusal returns non-zero"; else fail "refusal returned 0"; fi
	if [[ $out == *rustscan* ]]; then pass "refusal points at rustscan"; else fail "refusal does not mention rustscan: $out"; fi
fi

echo "[TEST] The wrapper wires the check in, after the integrity check..."
if awk '/verify_policy_integrity/{v=NR} /check_for_nmap/{n=NR} END{exit !(v && n && n>v)}' "$WRAPPER_DIR/pacman_wrapper.sh"; then
	pass "wrapper calls check_for_nmap after verify_policy_integrity"
else
	fail "wrapper does not call check_for_nmap after verify_policy_integrity"
fi

echo "[TEST] The nmap shim points at rustscan and exits 1..."
shim="$WRAPPER_DIR/nmap_shim.sh"
if [[ -f $shim ]]; then
	rc=0
	out="$(bash "$shim" -sn 192.168.1.0/24 2>&1)" || rc=$?
	if [[ $rc -eq 1 ]]; then pass "shim exits 1"; else fail "shim exit code $rc, want 1"; fi
	if [[ $out == *"rustscan -a"* && $out == *"-g"* ]]; then pass "shim prints the rustscan equivalent"; else fail "shim output: $out"; fi
else
	fail "nmap_shim.sh missing"
fi

echo "[TEST] The installer deploys the shim to /usr/local/bin/nmap..."
if grep -q 'nmap_shim.sh' "$WRAPPER_DIR/install_pacman_wrapper.sh" &&
	grep -q 'NMAP_SHIM_DEST' "$WRAPPER_DIR/lib/install_files.sh"; then
	pass "installer copies the shim"
else
	fail "installer does not deploy nmap_shim.sh"
fi

if [[ $failed -ne 0 ]]; then
	echo "FAILED"
	exit 1
fi
echo "All nmap block tests passed"
