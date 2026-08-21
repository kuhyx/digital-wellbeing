#!/bin/bash
# Pacman wrapper security: syntax, integrity and VirtualBox enforcement checks (tests 1-12).
# Sourced by test_pacman_wrapper_security.sh; inherits its strict mode
# (set -e) and its SCRIPT_DIR / WRAPPER_DIR / VBOX_DIR paths.

pac_tests_wrapper_and_vbox() {
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

	# The wrapper was split into flat pw_*.sh libs under the 250-line cap, so
	# these definition checks search the entry script AND its libs: the
	# functions moved one file over, they did not disappear.
	# Test 4: Verify integrity check function exists
	echo "[TEST 4] Verifying integrity check function exists in wrapper..."
	if grep -q "verify_policy_integrity()" "$WRAPPER_DIR/pacman_wrapper.sh" "$WRAPPER_DIR"/pw_*.sh; then
		echo "✓ Integrity verification function found"
	else
		echo "✗ Integrity verification function not found"
		exit 1
	fi

	# Test 5: Verify hardcoded VirtualBox cleanup function exists
	echo "[TEST 5] Verifying hardcoded VirtualBox cleanup function exists..."
	if grep -q "auto_remove_virtualbox_vms()" "$WRAPPER_DIR/pacman_wrapper.sh" "$WRAPPER_DIR"/pw_*.sh; then
		echo "✓ Hardcoded VirtualBox cleanup function found"
	else
		echo "✗ Hardcoded VirtualBox cleanup function not found"
		exit 1
	fi

	# Test 6: Verify VirtualBox cleanup uses VBoxManage directly
	echo "[TEST 6] Verifying VirtualBox cleanup uses VBoxManage directly..."
	if grep -q "VBoxManage" "$WRAPPER_DIR/pacman_wrapper.sh" "$WRAPPER_DIR"/pw_*.sh; then
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
	if grep -qr "INTEGRITY_FILE" "$WRAPPER_DIR/install_pacman_wrapper.sh" "$WRAPPER_DIR/lib"; then
		echo "✓ Installer references integrity file"
	else
		echo "✗ Installer does not create integrity file"
		exit 1
	fi

	# Test 9: Verify installer uses chattr to make files immutable
	echo "[TEST 9] Verifying installer makes policy files immutable..."
	if grep -qr "chattr +i" "$WRAPPER_DIR/install_pacman_wrapper.sh" "$WRAPPER_DIR/lib"; then
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
	if grep -qr "VBOX_ENFORCE" "$WRAPPER_DIR/install_pacman_wrapper.sh" "$WRAPPER_DIR/lib"; then
		echo "✓ Installer includes VirtualBox enforcement script"
	else
		echo "✗ Installer does not include VirtualBox enforcement script"
		exit 1
	fi

}
