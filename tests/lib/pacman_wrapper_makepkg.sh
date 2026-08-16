#!/bin/bash
# Pacman wrapper security: makepkg capped runner, mkpkg helper and installer hardening (tests 13-19).
# Sourced by test_pacman_wrapper_security.sh; inherits its strict mode
# (set -e) and its SCRIPT_DIR / WRAPPER_DIR / VBOX_DIR paths.

pac_tests_makepkg_and_installer() {
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

}
