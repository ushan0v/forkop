#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
VALIDATOR="$ROOT_DIR/podkop/files/usr/lib/config/validator.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

rows() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@"
}

assert_rejects() {
  local label="$1"
  local expected="$2"
  shift 2
  local output

  if output="$(rows "$@" | ucode -L "$PODKOP_LIB" "$VALIDATOR" validate-outbound-detours 2>/dev/null)"; then
    fail "$label should be rejected"
  fi

  printf '%s\n' "$output" | grep -Fq "$expected" ||
    fail "$label: expected message containing '$expected', got '$output'"
}

rows \
  source 1 proxy 1 target '' \
  target 1 vpn 0 '' '' |
  ucode -L "$PODKOP_LIB" "$VALIDATOR" validate-outbound-detours

rows \
  source 1 outbound 1 target '{"type":"direct"}' \
  target 1 proxy 0 '' '' |
  ucode -L "$PODKOP_LIB" "$VALIDATOR" validate-outbound-detours

assert_rejects "unsupported source action" "supported only for proxy and JSON outbound rules" \
  source 1 vpn 1 target '' \
  target 1 proxy 0 '' ''

assert_rejects "missing target" "references missing rule 'missing'" \
  source 1 proxy 1 missing ''

assert_rejects "disabled target" "references disabled rule 'target'" \
  source 1 proxy 1 target '' \
  target 0 proxy 0 '' ''

assert_rejects "wrong target action" "but it is not a proxy/VPN/JSON outbound rule" \
  source 1 proxy 1 target '' \
  target 1 zapret 0 '' ''

assert_rejects "self target" "cannot point to itself" \
  source 1 proxy 1 source ''

assert_rejects "cycle" "creates a cycle through 'second'" \
  first 1 proxy 1 second '' \
  second 1 proxy 1 first ''

assert_rejects "unsupported json outbound" "does not support Dial Fields" \
  source 1 outbound 1 target '{"type":"selector"}' \
  target 1 proxy 0 '' ''

printf 'config validator detour regression checks passed\n'
