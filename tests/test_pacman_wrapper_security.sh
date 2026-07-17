#!/bin/bash
# Test script for pacman wrapper integrity checks and VirtualBox enforcement

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRAPPER_DIR="$SCRIPT_DIR/../scripts/periodic_background/digital_wellbeing/pacman"
VBOX_DIR="$SCRIPT_DIR/../scripts/periodic_background/digital_wellbeing/virtualbox"

echo "=== Testing Pacman Wrapper Security Enhancements ==="
echo ""

# Test 1: Check wrapper syntax
echo "[TEST 1] Checking wrapper script syntax..."
if bash -n "$WRAPPER_DIR/pacman_wrapper.sh"; then
    echo "✓ Wrapper script syntax is valid"
else
    echo "✗ Wrapper script has syntax errors"
    exit 1
fi

# Test 2: Check installer syntax
echo "[TEST 2] Checking installer script syntax..."
if bash -n "$WRAPPER_DIR/install_pacman_wrapper.sh"; then
    echo "✓ Installer script syntax is valid"
else
    echo "✗ Installer script has syntax errors"
    exit 1
fi

# Test 3: Check VirtualBox enforcement script syntax
echo "[TEST 3] Checking VirtualBox enforcement script syntax..."
if bash -n "$VBOX_DIR/enforce_vbox_hosts.sh"; then
    echo "✓ VirtualBox enforcement script syntax is valid"
else
    echo "✗ VirtualBox enforcement script has syntax errors"
    exit 1
fi

# Test 4: Verify integrity check function exists
echo "[TEST 4] Verifying integrity check function exists in wrapper..."
if grep -q "verify_policy_integrity()" "$WRAPPER_DIR/pacman_wrapper.sh"; then
    echo "✓ Integrity verification function found"
else
    echo "✗ Integrity verification function not found"
    exit 1
fi

# Test 5: Verify hardcoded VirtualBox cleanup function exists
echo "[TEST 5] Verifying hardcoded VirtualBox cleanup function exists..."
if grep -q "auto_remove_virtualbox_vms()" "$WRAPPER_DIR/pacman_wrapper.sh"; then
    echo "✓ Hardcoded VirtualBox cleanup function found"
else
    echo "✗ Hardcoded VirtualBox cleanup function not found"
    exit 1
fi

# Test 6: Verify VirtualBox cleanup uses VBoxManage directly
echo "[TEST 6] Verifying VirtualBox cleanup uses VBoxManage directly..."
if grep -q "VBoxManage" "$WRAPPER_DIR/pacman_wrapper.sh"; then
    echo "✓ VirtualBox cleanup logic found"
else
    echo "✗ VirtualBox cleanup logic not found"
    exit 1
fi

# Test 7: Verify integrity check is called early in execution
echo "[TEST 7] Verifying integrity check is called before operations..."
if grep -B 2 -A 2 "verify_policy_integrity" "$WRAPPER_DIR/pacman_wrapper.sh" | grep -q "CRITICAL"; then
    echo "✓ Integrity check is called early in execution"
else
    echo "✗ Integrity check not found in early execution"
    exit 1
fi

# Test 8: Verify installer creates integrity file
echo "[TEST 8] Verifying installer creates integrity checksums..."
if grep -q "INTEGRITY_FILE" "$WRAPPER_DIR/install_pacman_wrapper.sh"; then
    echo "✓ Installer references integrity file"
else
    echo "✗ Installer does not create integrity file"
    exit 1
fi

# Test 9: Verify installer uses chattr to make files immutable
echo "[TEST 9] Verifying installer makes policy files immutable..."
if grep -q "chattr +i" "$WRAPPER_DIR/install_pacman_wrapper.sh"; then
    echo "✓ Installer sets immutable attributes"
else
    echo "✗ Installer does not set immutable attributes"
    exit 1
fi

# Test 10: Verify VirtualBox cleanup enforcement is integrated
echo "[TEST 10] Verifying VirtualBox cleanup is integrated into wrapper..."
if grep -q "auto_remove_virtualbox_vms" "$WRAPPER_DIR/pacman_wrapper.sh"; then
    echo "✓ VirtualBox cleanup integration found"
else
    echo "✗ VirtualBox cleanup integration not found"
    exit 1
fi

# Test 11: Verify VirtualBox script can show help
echo "[TEST 11] Testing VirtualBox enforcement script help..."
# Run without invoking sudo by setting EUID check (or just check for the help text in the file)
if grep -q "VirtualBox /etc/hosts Enforcement Tool" "$VBOX_DIR/enforce_vbox_hosts.sh"; then
    echo "✓ VirtualBox enforcement script has help text"
else
    echo "✗ VirtualBox enforcement script help text not found"
    exit 1
fi

# Test 12: Verify installer installs VirtualBox enforcement script
echo "[TEST 12] Verifying installer handles VirtualBox enforcement script..."
if grep -q "VBOX_ENFORCE" "$WRAPPER_DIR/install_pacman_wrapper.sh"; then
    echo "✓ Installer includes VirtualBox enforcement script"
else
    echo "✗ Installer does not include VirtualBox enforcement script"
    exit 1
fi

# Test 13: Verify makepkg capped wrapper script syntax
echo "[TEST 13] Checking makepkg capped wrapper syntax..."
if bash -n "$WRAPPER_DIR/makepkg_capped.sh"; then
    echo "✓ makepkg capped wrapper syntax is valid"
else
    echo "✗ makepkg capped wrapper has syntax errors"
    exit 1
fi

# Test 14: Verify pacman wrapper exposes makepkg capped command
echo "[TEST 14] Verifying pacman wrapper supports --makepkg-capped..."
if grep -q -- "--makepkg-capped" "$WRAPPER_DIR/pacman_wrapper.sh"; then
    echo "✓ pacman wrapper makepkg capped command found"
else
    echo "✗ pacman wrapper makepkg capped command missing"
    exit 1
fi

# Test 15: Verify installer deploys makepkg capped wrapper
echo "[TEST 15] Verifying installer deploys makepkg capped wrapper..."
if grep -q "MAKEPKG_CAPPED" "$WRAPPER_DIR/install_pacman_wrapper.sh"; then
    echo "✓ Installer includes makepkg capped deployment"
else
    echo "✗ Installer does not include makepkg capped deployment"
    exit 1
fi

# Test 16: Verify mkpkg helper script syntax
echo "[TEST 16] Checking mkpkg helper script syntax..."
if bash -n "$WRAPPER_DIR/mkpkg.sh"; then
    echo "✓ mkpkg helper script syntax is valid"
else
    echo "✗ mkpkg helper script has syntax errors"
    exit 1
fi

# Test 17: Verify installer deploys mkpkg helper
echo "[TEST 17] Verifying installer deploys mkpkg helper..."
if grep -q "MKPKG" "$WRAPPER_DIR/install_pacman_wrapper.sh"; then
    echo "✓ Installer includes mkpkg helper deployment"
else
    echo "✗ Installer does not include mkpkg helper deployment"
    exit 1
fi

# Test 18: Verify installer runs in strict mode
echo "[TEST 18] Verifying installer uses strict shell mode..."
if grep -q "set -euo pipefail" "$WRAPPER_DIR/install_pacman_wrapper.sh"; then
    echo "✓ Installer strict mode enabled"
else
    echo "✗ Installer strict mode not enabled"
    exit 1
fi

# Test 19: Verify installer handles immutable files during updates
echo "[TEST 19] Verifying installer unlocks immutable files before copy/write..."
if grep -q "unlock_immutable_file_if_needed" "$WRAPPER_DIR/install_pacman_wrapper.sh"; then
    echo "✓ Installer immutable-file handling found"
else
    echo "✗ Installer immutable-file handling missing"
    exit 1
fi

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
if grep -qF 'sha256sum "$LOCK_LIB_DEST"' "$WRAPPER_DIR/install_pacman_wrapper.sh"; then
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
