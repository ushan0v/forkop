#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULESETS_UC="$ROOT_DIR/nexroute/files/usr/lib/singbox/rulesets.uc"
NEXROUTE_LIB="$ROOT_DIR/nexroute/files/usr/lib"

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

assert_eq srs \
  "$(ucode -L "$NEXROUTE_LIB" "$RULESETS_UC" file-extension 'https://example.com/path/rule.srs?token=1#x')" \
  "ruleset file extension"
ucode -L "$NEXROUTE_LIB" "$RULESETS_UC" is-community youtube >/dev/null ||
  fail "youtube should be a community ruleset"
if ucode -L "$NEXROUTE_LIB" "$RULESETS_UC" is-community unknown_service >/dev/null 2>&1; then
  fail "unknown service should not be a community ruleset"
fi
assert_eq domains \
  "$(ucode -L "$NEXROUTE_LIB" "$RULESETS_UC" kind-from-reference-hint 'https://example.com/geosite-custom.srs')" \
  "domain ruleset hint"
assert_eq subnets \
  "$(ucode -L "$NEXROUTE_LIB" "$RULESETS_UC" kind-from-reference-hint '/tmp/geoip-cidr.json')" \
  "subnet ruleset hint"
assert_eq unknown \
  "$(ucode -L "$NEXROUTE_LIB" "$RULESETS_UC" kind-from-reference-hint '/tmp/custom.srs')" \
  "unknown ruleset hint"
assert_eq source \
  "$(ucode -L "$NEXROUTE_LIB" "$RULESETS_UC" remote-format 'https://example.com/rules.json')" \
  "json remote ruleset format"
assert_eq binary \
  "$(ucode -L "$NEXROUTE_LIB" "$RULESETS_UC" remote-format 'https://example.com/rules.srs')" \
  "srs remote ruleset format"
assert_eq binary \
  "$(ucode -L "$NEXROUTE_LIB" "$RULESETS_UC" remote-format 'https://example.com/rules.unknown')" \
  "unknown remote ruleset format"

ucode -L "$NEXROUTE_LIB" -e 'let rulesets = require("singbox.rulesets"); if (rulesets.kind_from_reference_hint("geoip") != "subnets") exit(1);'

printf 'singbox rulesets checks passed\n'
