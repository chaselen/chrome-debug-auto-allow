#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="$ROOT_DIR/scripts/debug-auto-allow.applescript"
FIXTURE_DIR="$ROOT_DIR/test/fixtures"
failures=0

assert_match() {
	local fixture_path="$1"
	local expected="$2"
	local text actual
	text="$(cat "$fixture_path")"
	actual="$(/usr/bin/osascript "$SCRIPT_PATH" --match "$text")"
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL %s: expected %s, got %s\n' "$(basename "$fixture_path")" "$expected" "$actual" >&2
		failures=$((failures + 1))
	else
		printf 'PASS %s -> %s\n' "$(basename "$fixture_path")" "$actual"
	fi
}

assert_match "$FIXTURE_DIR/positive-en.txt" match
assert_match "$FIXTURE_DIR/positive-zh-cn.txt" match
assert_match "$FIXTURE_DIR/positive-zh-tw.txt" match
assert_match "$FIXTURE_DIR/negative-web-alert.txt" no-match
assert_match "$FIXTURE_DIR/negative-extension.txt" no-match
assert_match "$FIXTURE_DIR/negative-required-only.txt" no-match
assert_match "$FIXTURE_DIR/negative-confirmation-only.txt" no-match

assert_button_label() {
	local label="$1"
	local expected="$2"
	local actual
	actual="$(/usr/bin/osascript "$SCRIPT_PATH" --allow-button "$label")"
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL button %s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
		failures=$((failures + 1))
	else
		printf 'PASS button %s -> %s\n' "$label" "$actual"
	fi
}

assert_button_label Allow match
assert_button_label "允许" match
assert_button_label "OK" match
assert_button_label Bookmark no-match
assert_button_label Allowed no-match
assert_button_label "OK is fine" no-match

if [[ "$failures" -ne 0 ]]; then
	printf '%s matcher test(s) failed.\n' "$failures" >&2
	exit 1
fi
printf 'All matcher fixtures passed.\n'
