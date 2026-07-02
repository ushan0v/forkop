#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
VALIDATOR="$ROOT_DIR/podkop/files/usr/lib/config/validator.uc"
COMMUNITY_SERVICES="youtube twitter telegram"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_accepts() {
  local label="$1"
  shift

  ucode -L "$PODKOP_LIB" "$VALIDATOR" "$@" >/dev/null ||
    fail "$label should be accepted"
}

assert_rejects() {
  local label="$1"
  shift

  if ucode -L "$PODKOP_LIB" "$VALIDATOR" "$@" >/dev/null 2>&1; then
    fail "$label should be rejected"
  fi
}

assert_accepts "known community service" community-service-valid twitter "$COMMUNITY_SERVICES"
assert_rejects "unknown community service" community-service-valid unknown "$COMMUNITY_SERVICES"

assert_accepts "empty ruleset reference" ruleset-reference-valid "" "$COMMUNITY_SERVICES"
assert_accepts "community ruleset reference" ruleset-reference-valid telegram "$COMMUNITY_SERVICES"
assert_accepts "https ruleset reference" ruleset-reference-valid https://example.com/rule.srs "$COMMUNITY_SERVICES"
assert_accepts "absolute srs ruleset reference" ruleset-reference-valid /tmp/rule.srs "$COMMUNITY_SERVICES"
assert_accepts "absolute json ruleset reference" ruleset-reference-valid /tmp/rule.json "$COMMUNITY_SERVICES"
assert_rejects "relative ruleset reference" ruleset-reference-valid relative/rule.srs "$COMMUNITY_SERVICES"
assert_rejects "plain list as ruleset reference" ruleset-reference-valid /tmp/rule.lst "$COMMUNITY_SERVICES"

assert_accepts "empty plain list reference" plain-domain-ip-list-reference-valid ""
assert_accepts "https plain list reference" plain-domain-ip-list-reference-valid https://example.com/list.lst
assert_accepts "absolute plain list reference" plain-domain-ip-list-reference-valid /tmp/list.lst
assert_rejects "ruleset as plain list reference" plain-domain-ip-list-reference-valid /tmp/rule.srs
assert_rejects "relative plain list reference" plain-domain-ip-list-reference-valid relative/list.lst

printf 'config validator reference regression checks passed\n'
