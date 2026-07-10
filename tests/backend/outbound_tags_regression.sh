#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
GENERATOR_UC="$PODKOP_LIB/singbox/generator.uc"
PARSER_UC="$PODKOP_LIB/subscription/parser.uc"
VALIDATOR_UC="$PODKOP_LIB/config/validator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/subscriptions"
cat >"$WORK_DIR/subscriptions/proxy-subscription-1.json" <<'JSON'
{
  "outbounds": [
    { "type": "socks", "tag": "germany", "server": "127.0.0.1", "server_port": 1101 },
    { "type": "socks", "tag": "germany", "server": "127.0.0.1", "server_port": 1102 },
    { "type": "socks", "tag": "bypass-out", "server": "127.0.0.1", "server_port": 1103 },
    { "type": "socks", "tag": "proxy-urltest-ut_name-out", "server": "127.0.0.1", "server_port": 1104 },
    { "type": "socks", "tag": "json-hop", "server": "127.0.0.1", "server_port": 1105 },
    { "type": "socks", "tag": "proxy-priority-pg_main-out", "server": "127.0.0.1", "server_port": 1106 },
    { "type": "socks", "tag": "dns-server", "server": "127.0.0.1", "server_port": 1107 }
  ]
}
JSON
printf '%s\n' 'https://duplicate.example/sub' >"$WORK_DIR/subscriptions/proxy-subscription-1.url"
: >"$WORK_DIR/subscriptions/proxy-subscription-1.user_agent"

cat >"$WORK_DIR/runtime-tags.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "log_level": "warn" },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "subscription_urls": [ "https://duplicate.example/sub" ],
      "interfaces": [ "wg0" ],
      "outbound_jsons": [
        "{\"type\":\"socks\",\"tag\":\"germany\",\"server\":\"127.0.0.1\",\"server_port\":1201}",
        "{\"type\":\"socks\",\"tag\":\"germany\",\"server\":\"127.0.0.1\",\"server_port\":1203}",
        "{\"type\":\"direct\",\"tag\":\"direct-out\"}",
        "{\"type\":\"socks\",\"tag\":\"json-hop\",\"server\":\"127.0.0.1\",\"server_port\":1202}",
        "{\"type\":\"selector\",\"tag\":\"json-group\",\"outbounds\":[\"proxy-json-4-out\",\"direct-out\"],\"default\":\"json-hop\"}",
        "{\"type\":\"direct\",\"tag\":\"service-mixed-in\"}"
      ],
      "domain_suffix": [ "example.org" ]
    },
    {
      ".name": "backup",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [
        "{\"type\":\"socks\",\"tag\":\"json-hop\",\"server\":\"127.0.0.1\",\"server_port\":1301}"
      ],
      "domain_suffix": [ "backup.example.org" ]
    }
  ],
  "urltest": [
    {
      ".name": "ut_name",
      ".type": "urltest",
      "section": "proxy",
      "name": "By name",
      "filter_mode": "include",
      "include_outbounds": [ "germany", "wg0", "json-hop" ]
    },
    {
      ".name": "ut_regex",
      ".type": "urltest",
      "section": "proxy",
      "name": "By regex",
      "filter_mode": "include",
      "include_regex": [ "^germany$" ]
    }
  ],
  "priority_group": [
    {
      ".name": "pg_main",
      ".type": "priority_group",
      "section": "proxy",
      "name": "Priority"
    }
  ],
  "priority_level": [
    {
      ".name": "pl_main",
      ".type": "priority_level",
      "group": "pg_main",
      "name": "All",
      "order": "0",
      "filter_mode": "disabled"
    }
  ]
}
JSON

runtime_config="$WORK_DIR/runtime-config.json"
mkdir -p "$runtime_config.section-cache"
TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions" \
  ucode -L "$PODKOP_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$WORK_DIR/runtime-tags.json" "$runtime_config" "127.0.0.1" "0"

ucode -e '
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));
let proxy_cache = json(fs.readfile(ARGV[1]));
let backup_cache = json(fs.readfile(ARGV[2]));
let by_tag = {};
let count = 0;
for (let outbound in config.outbounds || []) {
    if (by_tag[outbound.tag])
        die("duplicate generated outbound tag: " + outbound.tag + "\n");
    by_tag[outbound.tag] = outbound;
    count++;
}
if (length(keys(by_tag)) != count)
    die("generated outbound tags are not globally unique\n");

for (let tag in [
    "direct-out", "bypass-out", "proxy-out", "backup-out",
    "germany", "germany-1", "germany-2", "germany-3",
    "bypass-out-1", "dns-server-1", "service-mixed-in-1",
    "proxy-urltest-ut_name-out-1", "proxy-priority-pg_main-out-1",
    "proxy-interface-1-out", "direct-out-1", "json-hop", "json-hop-1", "json-hop-2",
    "json-group", "proxy-urltest-ut_name-out", "proxy-urltest-ut_regex-out",
    "proxy-priority-pg_main-out"
])
    if (!by_tag[tag])
        die("missing allocated outbound tag: " + tag + "\n");

let json_group = by_tag["json-group"];
if (length(json_group.outbounds || []) != 2 ||
    json_group.outbounds[0] != "json-hop-1" || json_group.outbounds[1] != "direct-out-1")
    die("JSON outbound references were not rewritten to allocated tags\n");
if (json_group.default != "json-hop-1")
    die("JSON selector default was not rewritten to its allocated tag\n");

let name_group = by_tag["proxy-urltest-ut_name-out"];
let regex_group = by_tag["proxy-urltest-ut_regex-out"];
if (length(name_group.outbounds || []) != 7)
    die("display-name filter did not select duplicate subscription, JSON and interface outbounds\n");
for (let tag in [ "germany", "germany-1", "germany-2", "germany-3", "proxy-interface-1-out", "json-hop", "json-hop-1" ])
    if (index(name_group.outbounds, tag) < 0)
        die("display-name filter is missing " + tag + "\n");
if (length(regex_group.outbounds || []) != 4)
    die("display-name regex did not collapse runtime suffixes\n");
for (let tag in [ "germany", "germany-1", "germany-2", "germany-3" ])
    if (index(regex_group.outbounds, tag) < 0)
        die("display-name regex is missing " + tag + "\n");

let names = proxy_cache.outboundMetadata.names || {};
for (let tag in [ "germany", "germany-1", "germany-2", "germany-3" ])
    if (names[tag] != "germany")
        die("runtime suffix leaked into display name for " + tag + "\n");
if (names["proxy-interface-1-out"] != "wg0" ||
    names["json-hop"] != "json-hop" || names["json-hop-1"] != "json-hop")
    die("interface or JSON display tag metadata is missing\n");
if (names["bypass-out-1"] != "bypass-out" ||
    names["dns-server-1"] != "dns-server" ||
    names["service-mixed-in-1"] != "service-mixed-in" ||
    names["proxy-urltest-ut_name-out-1"] != "proxy-urltest-ut_name-out" ||
    names["proxy-priority-pg_main-out-1"] != "proxy-priority-pg_main-out")
    die("system-tag collision suffix leaked into display metadata\n");
if ((backup_cache.outboundMetadata.names || {})["json-hop-2"] != "json-hop")
    die("cross-section JSON tag allocation or display metadata is invalid\n");
' "$runtime_config" "$runtime_config.section-cache/proxy.json" \
  "$runtime_config.section-cache/backup.json" || fail "runtime outbound tag allocation"

cat >"$WORK_DIR/duplicate-json-tags.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [
        "{\"type\":\"direct\",\"tag\":\"same\"}",
        "{\"type\":\"direct\",\"tag\":\"same\"}"
      ],
      "domain_suffix": [ "example.org" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/tagless-json.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ],
      "domain_suffix": [ "example.org" ]
    }
  ]
}
JSON

validate_rejects() {
  local fixture="$1"
  local expected="$2"
  local output
  if output="$(PODKOP_LIB="$PODKOP_LIB" ucode -L "$PODKOP_LIB" "$VALIDATOR_UC" \
      validate-runtime-fixture "$fixture" '{}' 2>/dev/null)"; then
    fail "validator accepted $fixture"
  fi
  printf '%s\n' "$output" | grep -Fq "$expected" ||
    fail "validator message for $fixture does not contain: $expected"
}

validate_rejects "$WORK_DIR/duplicate-json-tags.json" "duplicate JSON outbound tag 'same'"
validate_rejects "$WORK_DIR/tagless-json.json" "JSON outbound without a non-empty tag"

cat >"$WORK_DIR/xray-duplicates.json" <<'JSON'
[
  {
    "outbounds": [
      {
        "protocol": "socks",
        "tag": "germany",
        "settings": { "servers": [ { "address": "127.0.0.1", "port": 1401 } ] }
      }
    ]
  },
  {
    "outbounds": [
      {
        "protocol": "socks",
        "tag": "germany",
        "settings": { "servers": [ { "address": "127.0.0.1", "port": 1402 } ] }
      }
    ]
  }
]
JSON

ucode -L "$PODKOP_LIB" "$PARSER_UC" normalize-content \
  "$WORK_DIR/xray-duplicates.json" "$WORK_DIR/xray-normalized.json"
ucode -e '
let fs = require("fs");
let value = json(fs.readfile(ARGV[0]));
let outbounds = value.outbounds || [];
if (length(outbounds) != 2 || outbounds[0].tag != "germany" || outbounds[1].tag != "germany-1")
    die("Xray duplicate runtime tags were not allocated\n");
if (outbounds[0].remark != "germany" || outbounds[1].remark != "germany")
    die("Xray runtime suffix leaked into user-visible names\n");
' "$WORK_DIR/xray-normalized.json" || fail "Xray duplicate display names"

printf 'outbound tag regression checks passed\n'
