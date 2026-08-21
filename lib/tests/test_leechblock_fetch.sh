#!/usr/bin/env bash
# Covers lib/leechblock_fetch.sh's tag resolution and version normalisation.
#
# get_latest_tag has three fallbacks in priority order (releases API → tags
# API → redirect-header parse). A silent failure there installs the WRONG
# version of a blocking extension, so each fallback is exercised separately,
# including the path where jq is absent entirely.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=leechblock_harness.sh
source "$HERE/leechblock_harness.sh"
# shellcheck source=../leechblock_fetch.sh
source "$LEECHBLOCK_LIB_DIR/leechblock_fetch.sh"

# Exported because get_latest_tag reads them from the environment of the
# sourced lib rather than taking them as arguments; a plain assignment reads as
# unused here (SC2034) even though the code under test depends on it.
export REPO_OWNER="proginosko"
export REPO_NAME="LeechBlockNG-chrome"

_t_setup_shims
trap _t_teardown EXIT

printf 'get_latest_tag: releases API wins when it answers\n'
printf '{"tag_name":"v1.2.3"}\n' >"$TEST_TMPDIR/curl.releases"
# A subshell would strand nothing here (the value is echoed), but the call is
# routed through a file so a future assertion on side effects still works.
get_latest_tag "$REPO_NAME" >"$TEST_TMPDIR/out"
_t_eq "v1.2.3" "$(cat "$TEST_TMPDIR/out")" "the releases endpoint supplies the tag"
_t_has "$(cat "$TEST_TMPDIR/curl.calls")" "releases/latest" "it queried the releases endpoint"

printf '\nget_latest_tag: falls back to the tags API when releases is empty\n'
: >"$TEST_TMPDIR/curl.calls"
printf '{}\n' >"$TEST_TMPDIR/curl.releases"
printf '[{"name":"v9.9.9"}]\n' >"$TEST_TMPDIR/curl.tags"
get_latest_tag "$REPO_NAME" >"$TEST_TMPDIR/out"
_t_eq "v9.9.9" "$(cat "$TEST_TMPDIR/out")" "an empty releases reply falls through to tags"
_t_has "$(cat "$TEST_TMPDIR/curl.calls")" "tags?per_page=1" "it queried the tags endpoint"

printf '\nget_latest_tag: a literal null is treated as absent, not as a tag\n'
printf '{"tag_name":null}\n' >"$TEST_TMPDIR/curl.releases"
printf '[{"name":"v4.5.6"}]\n' >"$TEST_TMPDIR/curl.tags"
get_latest_tag "$REPO_NAME" >"$TEST_TMPDIR/out"
_t_eq "v4.5.6" "$(cat "$TEST_TMPDIR/out")" "a JSON null does not become the version"

printf '\nget_latest_tag: redirect-header fallback when jq is unavailable\n'
_t_hide_jq
printf 'location: https://github.com/x/y/releases/tag/v7.7.7\r\n' >"$TEST_TMPDIR/curl.head"
get_latest_tag "$REPO_NAME" >"$TEST_TMPDIR/out"
_t_eq "v7.7.7" "$(cat "$TEST_TMPDIR/out")" "the Location header supplies the tag without jq"

printf '\nget_latest_tag: reports failure when every source is exhausted\n'
# Still inside the hidden-jq PATH: with no Location header either, all three
# fallbacks are exhausted. The caller aborts the install on this non-zero
# status, so returning 0 with an empty tag would install a bogus version.
: >"$TEST_TMPDIR/curl.head"
if get_latest_tag "$REPO_NAME" >"$TEST_TMPDIR/out" 2>&1; then
	_t_fail "an exhausted lookup must return non-zero"
else
	_t_pass "an exhausted lookup returns non-zero rather than an empty version"
fi
_t_show_jq

printf '\nresolve_version: normalises the tag and derives the install layout\n'
VERSION="v2.0.1"
HOME="$TEST_TMPDIR/home"
XDG_DATA_HOME="$TEST_TMPDIR/home/.local/share"
resolve_version
_t_eq "2.0.1" "$VERSION" "the leading v is stripped for directory names"
_t_eq "v2.0.1" "$TAG" "the tag keeps its leading v"
_t_eq "$XDG_DATA_HOME/leechblockng/2.0.1" "$VERSION_DIR" "VERSION_DIR is derived from the stripped version"
_t_eq "$XDG_DATA_HOME/leechblockng/current" "$CURRENT_LINK" "CURRENT_LINK is the stable wrapper path"

printf '\nresolve_version: a non-standard tag warns but still installs\n'
VERSION="nightly-build"
# warn() prints to stdout, not stderr, so redirect stdout to capture it.
resolve_version >"$TEST_TMPDIR/warn" 2>&1
_t_has "$(cat "$TEST_TMPDIR/warn")" "doesn't look like" "an odd tag produces a warning"
_t_eq "nightly-build" "$VERSION" "an odd tag is still honoured rather than rejected"

printf '\nresolve_version: an unset VERSION resolves from GitHub\n'
printf '{"tag_name":"v3.3.3"}\n' >"$TEST_TMPDIR/curl.releases"
VERSION=""
resolve_version >/dev/null
_t_eq "3.3.3" "$VERSION" "an empty VERSION is filled from the releases endpoint"

_t_report "test_leechblock_fetch"
