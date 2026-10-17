#!/bin/bash
# Test script for pacman wrapper integrity checks and VirtualBox enforcement

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRAPPER_DIR="$SCRIPT_DIR/../pacman"
VBOX_DIR="$SCRIPT_DIR/../virtualbox"

echo "=== Testing Pacman Wrapper Security Enhancements ==="
echo ""

# The bulk of the checks live in libs to keep this file under the 250-line cap.
# They are functions, but they run in this shell and use the paths above
# exactly as the former top-level blocks did.
LIB_DIR="$SCRIPT_DIR/lib"
# shellcheck source=lib/pacman_wrapper_syntax.sh
source "$LIB_DIR/pacman_wrapper_syntax.sh"
# shellcheck source=lib/pacman_wrapper_makepkg.sh
source "$LIB_DIR/pacman_wrapper_makepkg.sh"

# Order matters: it is the order the checks ran in before the split.
pac_tests_wrapper_and_vbox
pac_tests_makepkg_and_installer

# Test: shared lock library syntax
echo "[TEST] Checking shared lock library syntax..."
if bash -n "$WRAPPER_DIR/pacman_lock_lib.sh"; then
	echo "✓ pacman_lock_lib.sh syntax is valid"
else
	echo "✗ pacman_lock_lib.sh has syntax errors"
	exit 1
fi

# Test: wrapper sources the shared lock library
echo "[TEST] Verifying wrapper sources the shared lock library..."
if grep -q 'source .*pacman_lock_lib.sh' "$WRAPPER_DIR/pacman_wrapper.sh"; then
	echo "✓ Wrapper sources pacman_lock_lib.sh"
else
	echo "✗ Wrapper does not source pacman_lock_lib.sh"
	exit 1
fi

# Test: the lock library is covered by the integrity manifest
echo "[TEST] Verifying installer checksums the lock library..."
# Literal source text being searched for; expanding $SCRIPT_DIR /
# $LOCK_LIB_DEST here would search for this machine's values instead.
# shellcheck disable=SC2016
if grep -qF 'sha256sum "$LOCK_LIB_DEST"' "$WRAPPER_DIR/lib/integrity.sh"; then
	echo "✓ Lock library is included in the integrity manifest"
else
	echo "✗ Lock library not checksummed by installer"
	exit 1
fi

# Test: lib is sourced AFTER integrity verification (tamper caught before source)
echo "[TEST] Verifying lock library is sourced after integrity check..."
if awk '/verify_policy_integrity/{v=NR} /source .*pacman_lock_lib.sh/{s=NR} END{exit !(v && s && s>v)}' "$WRAPPER_DIR/pacman_wrapper.sh"; then
	echo "✓ Lock library sourced after verify_policy_integrity"
else
	echo "✗ Lock library not sourced after integrity verification"
	exit 1
fi

echo ""
echo "=== All Tests Passed! ==="
echo ""
echo "Summary of security enhancements:"
echo "  ✓ Policy files are protected with SHA256 checksums"
echo "  ✓ Integrity checks run on every wrapper invocation"
echo "  ✓ Policy files are made immutable with chattr +i"
echo "  ✓ VirtualBox has hardcoded restrictions (cannot bypass via file editing)"
echo "  ✓ VirtualBox VMs are automatically configured to use host's /etc/hosts"
echo "  ✓ Difficult word challenge for VirtualBox installation (7-letter words, 150 words, 120s)"
echo "  ✓ makepkg capped runner is integrated via wrapper and installer"
echo "  ✓ mkpkg convenience helper is deployed by installer"
echo "  ✓ installer fails fast and handles immutable policy files safely"
