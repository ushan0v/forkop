#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATOR="$ROOT_DIR/podkop/files/usr/lib/config/validator.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

rows() {
  printf '%s\t%s\t%s\n' "$@"
}

assert_accepts() {
  local target="$1"
  local byedpi="$2"
  local zapret="$3"
  local zapret2="$4"
  shift 4

  rows "$@" | ucode "$VALIDATOR" validate-download-section "$target" "$byedpi" "$zapret" "$zapret2"
}

assert_rejects() {
  local label="$1"
  local expected="$2"
  local target="$3"
  local byedpi="$4"
  local zapret="$5"
  local zapret2="$6"
  shift 6
  local output

  if output="$(rows "$@" | ucode "$VALIDATOR" validate-download-section "$target" "$byedpi" "$zapret" "$zapret2" 2>/dev/null)"; then
    fail "$label should be rejected"
  fi

  printf '%s\n' "$output" | grep -Fq "$expected" ||
    fail "$label: expected message containing '$expected', got '$output'"
}

assert_accepts proxy 0 0 0 proxy 1 proxy
assert_accepts outbound 0 0 0 outbound 1 outbound
assert_accepts vpn 0 0 0 vpn 1 vpn
assert_accepts zap 0 1 0 zap 1 zapret
assert_accepts zap2 0 0 1 zap2 1 zapret2
assert_accepts bye 1 0 0 bye 1 byedpi

assert_rejects "empty target" "no download section is selected" "" 0 0 0 proxy 1 proxy
assert_rejects "missing target" "references missing rule 'missing'" missing 0 0 0 proxy 1 proxy
assert_rejects "disabled target" "references disabled rule 'proxy'" proxy 0 0 0 proxy 0 proxy
assert_rejects "provider missing" "cannot provide an outbound" zap 0 0 0 zap 1 zapret
assert_rejects "unsupported action" "cannot provide an outbound" bypass 0 0 0 bypass 1 bypass

printf 'config validator download section regression checks passed\n'
