#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
GENERATOR_UC="$FORKOP_LIB/singbox/generator.uc"
LIFECYCLE_UC="$FORKOP_LIB/service/lifecycle.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

get_default_outbound() {
  ucode -e '
    let fs = require("fs");
    let d = json(fs.readfile(ARGV[0]));
    for (let o in (d.outbounds || [])) {
      if (o.tag == ARGV[1]) {
        print(o.default);
        exit(0);
      }
    }
  ' "$1" "$2"
}

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [
        "{\"type\":\"vless\",\"tag\":\"Server-Alpha\",\"server\":\"alpha.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000001\"}",
        "{\"type\":\"vless\",\"tag\":\"Server-Beta\",\"server\":\"beta.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000002\"}",
        "{\"type\":\"vless\",\"tag\":\"Server-Gamma\",\"server\":\"gamma.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000003\"}"
      ]
    }
  ]
}
JSON

STATE_FILE="$WORK_DIR/selector-state.json"

# Test 1: Without state file, default is Server-Alpha
FORKOP_SELECTOR_STATE_FILE="$STATE_FILE" \
  ucode -L "$FORKOP_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$WORK_DIR/out1.json" "127.0.0.1"

default1="$(get_default_outbound "$WORK_DIR/out1.json" "proxy-out")"
[ "$default1" = "Server-Alpha" ] || fail "Expected Server-Alpha without state file, got: $default1"

# Test 2: With state file selecting Server-Beta, default becomes Server-Beta
printf '{"proxy-out":"Server-Beta"}\n' > "$STATE_FILE"

FORKOP_SELECTOR_STATE_FILE="$STATE_FILE" \
  ucode -L "$FORKOP_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$WORK_DIR/out2.json" "127.0.0.1"

default2="$(get_default_outbound "$WORK_DIR/out2.json" "proxy-out")"
[ "$default2" = "Server-Beta" ] || fail "Expected Server-Beta with state file, got: $default2"

# Test 3: With state file pointing to non-existent server, falls back to Server-Alpha
printf '{"proxy-out":"Server-Deleted"}\n' > "$STATE_FILE"

FORKOP_SELECTOR_STATE_FILE="$STATE_FILE" \
  ucode -L "$FORKOP_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$WORK_DIR/out3.json" "127.0.0.1"

default3="$(get_default_outbound "$WORK_DIR/out3.json" "proxy-out")"
[ "$default3" = "Server-Alpha" ] || fail "Expected Server-Alpha fallback, got: $default3"

printf 'persistent selector state tests passed\n'
