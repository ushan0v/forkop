#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
GENERATOR_UC="$FORKOP_LIB/singbox/generator.uc"
VALIDATOR_UC="$FORKOP_LIB/config/validator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

generate_config() {
  local fixture="$1"
  local output="$2"
  mkdir -p "${output}.section-cache"
  ucode -L "$FORKOP_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$fixture" "$output" "127.0.0.1"
}

validate_fixture() {
  local fixture="$1"
  FORKOP_LIB="$FORKOP_LIB" ucode -L "$FORKOP_LIB" "$VALIDATOR_UC" \
    validate-runtime-fixture "$fixture" "{}"
}

cat >"$WORK_DIR/mixed.json" <<'JSON'
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
        "{\"type\":\"vless\",\"tag\":\"Alpha\",\"server\":\"alpha.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000001\",\"tls\":{\"enabled\":true}}",
        "{\"type\":\"vless\",\"tag\":\"Beta\",\"server\":\"beta.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000002\",\"transport\":{\"type\":\"ws\"},\"tls\":{\"enabled\":true,\"reality\":{\"enabled\":true}}}",
        "{\"type\":\"vmess\",\"tag\":\"Gamma\",\"server\":\"gamma.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000003\",\"transport\":{\"type\":\"grpc\"}}",
        "{\"type\":\"trojan\",\"tag\":\"Delta\",\"server\":\"delta.example\",\"server_port\":443,\"password\":\"secret\",\"transport\":{\"type\":\"xhttp\"},\"tls\":{\"enabled\":true}}",
        "{\"type\":\"http\",\"tag\":\"Echo\",\"server\":\"echo.example\",\"server_port\":8080}"
      ],
      "dashboard_filter_mode": "mixed",
      "dashboard_include_proxy_parameters": "1",
      "dashboard_include_protocols": [ "http" ],
      "dashboard_include_groups": [ "Shared group" ],
      "dashboard_exclude_groups": [ "Blocked group" ]
    }
  ],
  "urltest": [
    {
      ".name": "ut_main",
      ".type": "urltest",
      "section": "proxy",
      "name": "Shared group",
      "filter_mode": "include",
      "include_outbounds": [ "Alpha", "Beta" ]
    }
  ],
  "priority_group": [
    {
      ".name": "pg_shared",
      ".type": "priority_group",
      "section": "proxy",
      "name": "Shared group"
    },
    {
      ".name": "pg_main",
      ".type": "priority_group",
      "section": "proxy",
      "name": "Blocked group"
    }
  ],
  "priority_level": [
    {
      ".name": "pl_shared",
      ".type": "priority_level",
      "group": "pg_shared",
      "name": "Shared members",
      "order": "0",
      "filter_mode": "include",
      "include_outbounds": [ "Gamma" ]
    },
    {
      ".name": "pl_main",
      ".type": "priority_level",
      "group": "pg_main",
      "name": "Blocked members",
      "order": "0",
      "filter_mode": "include",
      "include_outbounds": [ "Beta", "Gamma" ]
    }
  ]
}
JSON

node - "$WORK_DIR/mixed.json" "$WORK_DIR" <<'JS'
const fs = require('fs');
const path = require('path');
const source = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const outputDir = process.argv[3];

for (const mode of ['disabled', 'include', 'exclude']) {
  const fixture = structuredClone(source);
  const section = fixture.section[0];
  section.dashboard_filter_mode = mode;
  if (mode === 'disabled') {
    delete section.dashboard_include_proxy_parameters;
    delete section.dashboard_include_protocols;
    delete section.dashboard_include_groups;
    delete section.dashboard_exclude_groups;
  } else if (mode === 'include') {
    delete section.dashboard_include_proxy_parameters;
    delete section.dashboard_include_protocols;
    delete section.dashboard_exclude_groups;
  } else {
    delete section.dashboard_include_proxy_parameters;
    delete section.dashboard_include_protocols;
    delete section.dashboard_include_groups;
  }
  fs.writeFileSync(path.join(outputDir, `${mode}.json`), JSON.stringify(fixture));
}

const invalid = structuredClone(source);
invalid.section[0].dashboard_include_groups = ['missing_group'];
fs.writeFileSync(path.join(outputDir, 'invalid-group.json'), JSON.stringify(invalid));

const invalidMode = structuredClone(source);
invalidMode.section[0].dashboard_filter_mode = 'unknown';
fs.writeFileSync(path.join(outputDir, 'invalid-mode.json'), JSON.stringify(invalidMode));
JS

for mode in disabled include exclude mixed; do
  validate_fixture "$WORK_DIR/$mode.json" >/dev/null || fail "$mode dashboard filter validation"
  generate_config "$WORK_DIR/$mode.json" "$WORK_DIR/$mode-config.json"
done

if validate_fixture "$WORK_DIR/invalid-group.json" >/dev/null 2>&1; then
  fail "unknown dashboard group should be rejected"
fi

if validate_fixture "$WORK_DIR/invalid-mode.json" >/dev/null 2>&1; then
  fail "unknown dashboard filter mode should be rejected"
fi

ucode -e '
let fs = require("fs");
function fail(message) { die(message + "\n"); }
function outbound_by_tag(config, tag) {
    for (let outbound in config.outbounds || [])
        if (outbound && outbound.tag == tag)
            return outbound;
    return null;
}
function assert_array(value, expected, label) {
    value = value || [];
    if (length(value) != length(expected))
        fail(label + " length mismatch: " + sprintf("%J", value));
    for (let i = 0; i < length(expected); i++)
        if (value[i] != expected[i])
            fail(label + " mismatch: " + sprintf("%J", value));
}
let disabled = outbound_by_tag(json(fs.readfile(ARGV[0])), "proxy-out");
let include = outbound_by_tag(json(fs.readfile(ARGV[1])), "proxy-out");
let exclude = outbound_by_tag(json(fs.readfile(ARGV[2])), "proxy-out");
let mixed = outbound_by_tag(json(fs.readfile(ARGV[3])), "proxy-out");
assert_array(disabled.outbounds, [ "Alpha", "Beta", "Gamma", "Delta", "Echo", "proxy-urltest-ut_main-out", "proxy-priority-pg_shared-out", "proxy-priority-pg_main-out" ], "all dashboard servers");
assert_array(include.outbounds, [ "Alpha", "Beta", "Gamma", "proxy-urltest-ut_main-out", "proxy-priority-pg_shared-out", "proxy-priority-pg_main-out" ], "same-name URLTest and Priority groups");
assert_array(exclude.outbounds, [ "Alpha", "Delta", "Echo", "proxy-urltest-ut_main-out", "proxy-priority-pg_shared-out", "proxy-priority-pg_main-out" ], "excluded Priority group");
assert_array(mixed.outbounds, [ "Alpha", "Echo", "proxy-urltest-ut_main-out", "proxy-priority-pg_shared-out", "proxy-priority-pg_main-out" ], "mixed group and proxy filters");
if (mixed.default != "proxy-urltest-ut_main-out")
    fail("section selector should still default to the first URLTest group");
' "$WORK_DIR/disabled-config.json" "$WORK_DIR/include-config.json" \
  "$WORK_DIR/exclude-config.json" "$WORK_DIR/mixed-config.json" ||
  fail "dashboard server filter regression"

printf 'dashboard server filter checks passed\n'
