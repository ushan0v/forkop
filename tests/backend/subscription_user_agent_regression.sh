#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CACHE_UC="$ROOT_DIR/podkop/files/usr/lib/subscription/cache.uc"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_file() {
  local path="$1"
  local expected="$2"
  local actual

  actual="$(cat "$path")"
  [ "$actual" = "$expected" ] || fail "expected candidates '$expected', got '$actual'"
}

default_ua="sing-box/1.12.0"
default_candidates="$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
  "$default_ua" \
  Happ \
  v2rayN \
  v2rayNG \
  Mihomo \
  Clash.Meta)"
preferred_candidates="$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
  "$default_ua" \
  Mihomo \
  Happ \
  v2rayN \
  v2rayNG \
  Clash.Meta)"

cache_ucode() {
  ucode -L "$PODKOP_LIB" "$CACHE_UC" "$@"
}

cache_ucode write-user-agent-candidates "$WORK_DIR/default.txt" "" "" "$default_ua"
assert_file "$WORK_DIR/default.txt" "$default_candidates"

cache_ucode write-user-agent-candidates "$WORK_DIR/preferred.txt" "" Mihomo "$default_ua"
assert_file "$WORK_DIR/preferred.txt" "$preferred_candidates"

cache_ucode write-user-agent-candidates "$WORK_DIR/unsupported-preferred.txt" "" Hiddify "$default_ua"
assert_file "$WORK_DIR/unsupported-preferred.txt" "$default_candidates"

cache_ucode write-user-agent-candidates "$WORK_DIR/custom.txt" "Custom/1.0" Hiddify "$default_ua"
assert_file "$WORK_DIR/custom.txt" "Custom/1.0"

cache_ucode user-agent-matches-config "" "$default_ua" "$default_ua" >/dev/null ||
  fail "default UA should match automatic config"
cache_ucode user-agent-matches-config "" Mihomo "$default_ua" >/dev/null ||
  fail "known fallback UA should match automatic config"
if cache_ucode user-agent-matches-config "" "Unknown" "$default_ua" >/dev/null 2>&1; then
  fail "unknown cached UA should not match automatic config"
fi
cache_ucode user-agent-matches-config "Custom/1.0" "Custom/1.0" "$default_ua" >/dev/null ||
  fail "configured UA should match exact cached UA"
if cache_ucode user-agent-matches-config "Custom/1.0" Hiddify "$default_ua" >/dev/null 2>&1; then
  fail "configured UA should reject fallback cached UA"
fi

printf 'subscription user-agent regression checks passed\n'
