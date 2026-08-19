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

servers='[
  "{\"type\":\"vless\",\"tag\":\"🇳🇱 Amsterdam\",\"server\":\"nl.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000001\",\"tls\":{\"enabled\":true}}",
  "{\"type\":\"vless\",\"tag\":\"🇷🇺 Moscow\",\"server\":\"ru1.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000002\",\"tls\":{\"enabled\":true}}",
  "{\"type\":\"vless\",\"tag\":\"🇩🇪 Berlin\",\"server\":\"de.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000003\",\"tls\":{\"enabled\":true}}",
  "{\"type\":\"vless\",\"tag\":\"🇷🇺 Piter\",\"server\":\"ru2.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000004\",\"tls\":{\"enabled\":true}}",
  "{\"type\":\"vless\",\"tag\":\"Relay\",\"server\":\"relay.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000005\",\"tls\":{\"enabled\":true}}"
]'

cat >"$WORK_DIR/exclude.json" <<JSON
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
      "outbound_jsons": $servers,
      "dashboard_filter_mode": "exclude",
      "dashboard_detect_server_country": "flag_emoji",
      "dashboard_exclude_countries": [ "RU" ],
      "dashboard_exclude_regex": [ "^Relay\$" ]
    }
  ],
  "urltest": [
    {
      ".name": "ut_main",
      ".type": "urltest",
      "section": "proxy",
      "name": "Main",
      "filter_mode": "disabled"
    },
    {
      ".name": "ut_nl",
      ".type": "urltest",
      "section": "proxy",
      "name": "Only NL",
      "filter_mode": "include",
      "detect_server_country": "flag_emoji",
      "include_countries": [ "NL" ]
    }
  ],
  "priority_group": [
    {
      ".name": "pg_main",
      ".type": "priority_group",
      "section": "proxy",
      "name": "Failover"
    }
  ],
  "priority_level": [
    {
      ".name": "pl_main",
      ".type": "priority_level",
      "group": "pg_main",
      "name": "Primary",
      "order": "0",
      "filter_mode": "include",
      "include_outbounds": [ "🇷🇺 Moscow", "🇩🇪 Berlin" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/mixed.json" <<JSON
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
      "outbound_jsons": $servers,
      "dashboard_filter_mode": "mixed",
      "dashboard_detect_server_country": "flag_emoji",
      "dashboard_include_countries": [ "NL" ],
      "dashboard_exclude_countries": [ "RU" ]
    }
  ],
  "urltest": [
    {
      ".name": "ut_main",
      ".type": "urltest",
      "section": "proxy",
      "name": "Main",
      "filter_mode": "disabled"
    }
  ]
}
JSON

cat >"$WORK_DIR/groups.json" <<JSON
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
      "outbound_jsons": $servers,
      "dashboard_filter_mode": "exclude",
      "dashboard_exclude_groups": [ "Main" ]
    }
  ],
  "urltest": [
    {
      ".name": "ut_main",
      ".type": "urltest",
      "section": "proxy",
      "name": "Main",
      "filter_mode": "disabled"
    }
  ]
}
JSON

for fixture in exclude mixed groups; do
  validate_fixture "$WORK_DIR/$fixture.json" >/dev/null ||
    fail "$fixture fixture validation"
  generate_config "$WORK_DIR/$fixture.json" "$WORK_DIR/$fixture-config.json"
done

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

let exclude = json(fs.readfile(ARGV[0]));
assert_array(outbound_by_tag(exclude, "proxy-urltest-ut_main-out").outbounds,
    [ "🇳🇱 Amsterdam", "🇩🇪 Berlin" ],
    "section exclusions must reach an unfiltered URLTest group");
assert_array(outbound_by_tag(exclude, "proxy-urltest-ut_nl-out").outbounds,
    [ "🇳🇱 Amsterdam" ],
    "URLTest group filter still applies on top of section exclusions");
assert_array(outbound_by_tag(exclude, "proxy-priority-pg_main-out").outbounds,
    [ "🇩🇪 Berlin" ],
    "section exclusions must reach Priority levels");
assert_array(outbound_by_tag(exclude, "proxy-out").outbounds,
    [ "🇳🇱 Amsterdam", "🇩🇪 Berlin", "proxy-urltest-ut_main-out",
      "proxy-urltest-ut_nl-out", "proxy-priority-pg_main-out" ],
    "section selector servers");

let mixed = json(fs.readfile(ARGV[1]));
assert_array(outbound_by_tag(mixed, "proxy-urltest-ut_main-out").outbounds,
    [ "🇳🇱 Amsterdam", "🇩🇪 Berlin", "Relay" ],
    "only the exclude half of a mixed section filter reaches groups");
assert_array(outbound_by_tag(mixed, "proxy-out").outbounds,
    [ "🇳🇱 Amsterdam", "proxy-urltest-ut_main-out" ],
    "mixed section selector servers");

let groups = json(fs.readfile(ARGV[2]));
assert_array(outbound_by_tag(groups, "proxy-urltest-ut_main-out").outbounds,
    [ "🇳🇱 Amsterdam", "🇷🇺 Moscow", "🇩🇪 Berlin", "🇷🇺 Piter", "Relay" ],
    "group based exclusions stay selector only");
assert_array(outbound_by_tag(groups, "proxy-out").outbounds,
    [ "proxy-urltest-ut_main-out" ],
    "group based exclusion selector servers");
' "$WORK_DIR/exclude-config.json" "$WORK_DIR/mixed-config.json" \
  "$WORK_DIR/groups-config.json" ||
  fail "section filter propagation regression"

printf 'section filter propagation checks passed\n'
