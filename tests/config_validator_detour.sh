#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEXROUTE_LIB="$ROOT_DIR/nexroute/files/usr/lib"
VALIDATOR="$ROOT_DIR/nexroute/files/usr/lib/config/validator.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

rows() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$@"
}

assert_rejects() {
  local label="$1"
  local expected="$2"
  shift 2
  local output

  if output="$(rows "$@" | ucode -L "$NEXROUTE_LIB" "$VALIDATOR" validate-outbound-detours 2>/dev/null)"; then
    fail "$label should be rejected"
  fi

  printf '%s\n' "$output" | grep -Fq "$expected" ||
    fail "$label: expected message containing '$expected', got '$output'"
}

rows \
  source 1 connection 1 target \
  target 1 connection 0 '' |
  ucode -L "$NEXROUTE_LIB" "$VALIDATOR" validate-outbound-detours

assert_rejects "unsupported source action" "supported only for Connection rules" \
  source 1 zapret 1 target \
  target 1 connection 0 ''

assert_rejects "missing target" "references missing rule 'missing'" \
  source 1 connection 1 missing

assert_rejects "disabled target" "references disabled rule 'target'" \
  source 1 connection 1 target \
  target 0 connection 0 ''

assert_rejects "wrong target action" "but it is not a Connection rule" \
  source 1 connection 1 target \
  target 1 zapret 0 ''

assert_rejects "self target" "cannot point to itself" \
  source 1 connection 1 source

assert_rejects "cycle" "creates a cycle through 'second'" \
  first 1 connection 1 second \
  second 1 connection 1 first

printf 'config validator detour checks passed\n'
