#!/bin/bash
# Test script for pacman wrapper integrity checks and VirtualBox enforcement

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRAPPER_DIR="$SCRIPT_DIR/../scripts/periodic_background/digital_wellbeing/pacman"
VBOX_DIR="$SCRIPT_DIR/../scripts/periodic_background/digital_wellbeing/virtualbox"

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

# Test: strip_pkgfile_suffix + is_blocked_package_name correctly recognise a
# whitelisted package even when passed as a full `-U <path>.pkg.tar.zst`
# argument. Regression test for the 2026-08-12 bug: `yay` always installs a
# package it just built via `pacman -U <path>/<pkg>-<ver>-<rel>-<arch>.pkg.tar.zst`,
# not the bare name — an exact-match whitelist entry could never match that
# filename, silently blocking every AUR package the whitelist was meant to
# allow the moment it went through a real `-U` install rather than `-S`.
echo "[TEST] Verifying strip_pkgfile_suffix + is_blocked_package_name handle -U package-file arguments..."
PACMAN_WRAPPER_FUNC_TEST_SCRIPT="$(mktemp)"
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -f "$PACMAN_WRAPPER_FUNC_TEST_SCRIPT"; rm -rf "$FIXTURE_DIR"' EXIT

printf 'chromium\n' >"$FIXTURE_DIR/pacman_blocked_keywords.txt"
printf 'ungoogled-chromium-bin\n' >"$FIXTURE_DIR/pacman_whitelist.txt"
printf '\n' >"$FIXTURE_DIR/pacman_greylist.txt"

{
	# Both functions moved to pw_policy.sh when the wrapper was split under the
	# 250-line cap; they are extracted from there now.
	cat <<'HEADER'
#!/bin/bash
set -u
load_policy_lists() { :; } # is_blocked_package_name calls this; arrays are pre-seeded below instead
HEADER
	sed -n '/^function strip_pkgfile_suffix/,/^}/p' "$WRAPPER_DIR/pw_policy.sh"
	sed -n '/^function is_blocked_package_name/,/^}/p' "$WRAPPER_DIR/pw_policy.sh"
	printf 'BLOCKED_KEYWORDS_LIST=(%s)\n' "$(printf "'%s' " "$(cat "$FIXTURE_DIR/pacman_blocked_keywords.txt")")"
	printf 'WHITELISTED_NAMES_LIST=(%s)\n' "$(printf "'%s' " "$(cat "$FIXTURE_DIR/pacman_whitelist.txt")")"
	printf 'GREYLISTED_KEYWORDS_LIST=()\n'
	cat <<'BODY'
echo "$(strip_pkgfile_suffix "ungoogled-chromium-bin-150.0.7871.186-1-x86_64.pkg.tar.zst")"
if is_blocked_package_name "ungoogled-chromium-bin-150.0.7871.186-1-x86_64.pkg.tar.zst"; then echo BLOCKED; else echo ALLOWED; fi
if is_blocked_package_name "chromium-151.0.7922.108-1-x86_64.pkg.tar.zst"; then echo BLOCKED; else echo ALLOWED; fi
BODY
} >"$PACMAN_WRAPPER_FUNC_TEST_SCRIPT"

FUNC_TEST_OUTPUT="$(bash "$PACMAN_WRAPPER_FUNC_TEST_SCRIPT")"
EXPECTED_FUNC_TEST_OUTPUT="ungoogled-chromium-bin
ALLOWED
BLOCKED"

if [[ "$FUNC_TEST_OUTPUT" == "$EXPECTED_FUNC_TEST_OUTPUT" ]]; then
	echo "✓ strip_pkgfile_suffix bares -U filenames; whitelisted packages are allowed via -U, non-whitelisted blocked keywords still blocked"
else
	echo "✗ Mismatch:"
	echo "  expected: $EXPECTED_FUNC_TEST_OUTPUT"
	echo "  got:      $FUNC_TEST_OUTPUT"
	exit 1
fi
rm -f "$PACMAN_WRAPPER_FUNC_TEST_SCRIPT"
rm -rf "$FIXTURE_DIR"
trap - EXIT

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
