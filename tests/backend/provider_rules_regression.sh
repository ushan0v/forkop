#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RULES_UC="$ROOT_DIR/podkop/files/usr/lib/providers/rules.uc"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

rows() {
  printf '%s\t%s\t%s\n' \
    "alpha" "1" "zapret" \
    "beta" "0" "zapret" \
    "gamma" "1" "byedpi" \
    "delta" "1" "zapret" \
    "zeta" "1" "zapret2"
}

rules_ucode() {
  ucode -L "$PODKOP_LIB" "$RULES_UC" "$@"
}

if grep -n -E 'require\("uci"\)\.cursor|cursor\.foreach' "$RULES_UC" >/dev/null 2>&1; then
  fail "providers/rules.uc must use core.uci instead of owning direct UCI cursor"
fi

assert_eq "2" "$(rows | rules_ucode count zapret)" "enabled zapret count"
assert_eq "1" "$(rows | rules_ucode count byedpi)" "enabled byedpi count"
assert_eq "1" "$(rows | rules_ucode count zapret2)" "enabled zapret2 count"
assert_eq "0" "$(rows | rules_ucode count bypass)" "non-provider action count"

assert_eq "1" "$(rows | rules_ucode index zapret alpha)" "first zapret index"
assert_eq "2" "$(rows | rules_ucode index zapret delta)" "second zapret index skips disabled rows"
assert_eq "0" "$(rows | rules_ucode index zapret beta)" "disabled zapret section has no index"
assert_eq "1" "$(rows | rules_ucode index byedpi gamma)" "byedpi index"

assert_eq "16777217" "$(rules_ucode mark-value 0x01000000 1)" "hex mark value"
assert_eq "0x01000002" "$(rules_ucode mark-hex 0x01000000 2)" "hex mark formatting"
assert_eq "4001" "$(rules_ucode queue-number 4000 2)" "queue number offset"
assert_eq "1081" "$(rules_ucode port-number 1080 2)" "port number offset"

if rules_ucode mark-value invalid 1 >/dev/null 2>&1; then
  fail "invalid base should be rejected"
fi

printf 'Provider rule regression checks passed\n'
