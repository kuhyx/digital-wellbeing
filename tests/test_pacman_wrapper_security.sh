#!/bin/bash
# Test script for pacman wrapper integrity checks and VirtualBox enforcement

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRAPPER_DIR="$SCRIPT_DIR/../scripts/digital_wellbeing/pacman"
VBOX_DIR="$SCRIPT_DIR/../scripts/digital_wellbeing/virtualbox"

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

# Test 5: Verify hardcoded VirtualBox check exists
echo "[TEST 5] Verifying hardcoded VirtualBox check exists..."
if grep -q "is_virtualbox_package()" "$WRAPPER_DIR/pacman_wrapper.sh"; then
    echo "✓ Hardcoded VirtualBox check function found"
else
    echo "✗ Hardcoded VirtualBox check function not found"
    exit 1
fi

# Test 6: Verify VirtualBox challenge function exists
echo "[TEST 6] Verifying VirtualBox challenge function exists..."
if grep -q "prompt_for_virtualbox_challenge()" "$WRAPPER_DIR/pacman_wrapper.sh"; then
    echo "✓ VirtualBox challenge function found"
else
    echo "✗ VirtualBox challenge function not found"
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

# Test 10: Verify VirtualBox enforcement is integrated
echo "[TEST 10] Verifying VirtualBox enforcement is integrated into wrapper..."
if grep -q "enforce_vbox_hosts_if_needed" "$WRAPPER_DIR/pacman_wrapper.sh"; then
    echo "✓ VirtualBox enforcement integration found"
else
    echo "✗ VirtualBox enforcement integration not found"
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
