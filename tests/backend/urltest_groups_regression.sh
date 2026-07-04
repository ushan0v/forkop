#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
PARSER_UC="$PODKOP_LIB/subscription/parser.uc"
GENERATOR_UC="$PODKOP_LIB/singbox/generator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

normalize_subscription() {
  local input="$1"
  local output="$2"
  ucode -L "$PODKOP_LIB" "$PARSER_UC" normalize-content "$input" "$output"
}

prepare_subscription_cache() {
  local section="$1"
  local index="$2"
  local url="$3"
  local normalized_json="$4"
  local source="$WORK_DIR/subscriptions/${section}-subscription-${index}"

  mkdir -p "$WORK_DIR/subscriptions"
  cp "$normalized_json" "${source}.json"
  printf '%s\n' "$url" >"${source}.url"
  : >"${source}.user_agent"
}

generate_config() {
  local fixture="$1"
  local output="$2"
  mkdir -p "${output}.section-cache"
  TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions" \
    ucode -L "$PODKOP_LIB" "$GENERATOR_UC" generate-config-fixture \
      "$fixture" "$output" "127.0.0.1"
}

cat >"$WORK_DIR/xray.json" <<'JSON'
{
  "remarks": "Latvia group",
  "burstObservatory": {
    "pingConfig": {
      "destination": "https://probe.example/204",
      "interval": "45s",
      "timeout": "3s",
      "sampling": 2
    }
  },
  "routing": {
    "balancers": [
      {
        "tag": "latvia-balancer",
        "selector": [ "lv-" ]
      }
    ]
  },
  "outbounds": [
    {
      "protocol": "vless",
      "tag": "lv-🇱🇻 Riga A",
      "settings": {
        "vnext": [
          {
            "address": "riga-a.example",
            "port": 443,
            "users": [
              {
                "id": "00000000-0000-4000-8000-000000000001",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "security": "tls",
        "tlsSettings": {
          "serverName": "riga-a.example"
        }
      }
    },
    {
      "protocol": "vless",
      "tag": "lv-🇱🇻 Riga B",
      "settings": {
        "vnext": [
          {
            "address": "riga-b.example",
            "port": 443,
            "users": [
              {
                "id": "00000000-0000-4000-8000-000000000002",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "security": "tls",
        "tlsSettings": {
          "serverName": "riga-b.example"
        }
      }
    }
  ]
}
JSON

xray_normalized="$WORK_DIR/xray-normalized.json"
normalize_subscription "$WORK_DIR/xray.json" "$xray_normalized"

ucode -e '
let fs = require("fs");
let value = json(fs.readfile(ARGV[0]));
let group = null;
for (let outbound in value.outbounds || [])
    if (outbound.type == "urltest")
        group = outbound;
if (!group)
    die("missing xray urltest group\n");
if (group.url != "https://probe.example/204")
    die("xray urltest url was not preserved\n");
if (group.interval != "45s")
    die("xray urltest interval was not preserved\n");
if (group.tolerance != null)
    die("xray urltest should not receive hardcoded tolerance\n");
for (let child in group.outbounds || [])
    if (substr(child, 0, 5) == "xray-")
        die("xray urltest child tags should preserve source names when unique\n");
' "$xray_normalized" || fail "xray normalized URLTest fields"

prepare_subscription_cache proxy 1 "https://xray.example/sub" "$xray_normalized"
cat >"$WORK_DIR/xray-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "log_level": "warn"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "urltest_enabled": "1",
      "urltest_check_interval": "3m",
      "urltest_tolerance": "50",
      "urltest_filter_mode": "include",
      "urltest_include_outbounds": [ "Latvia group" ],
      "detect_server_country": "flag_emoji",
      "subscription_urls": [ "https://xray.example/sub" ]
    }
  ]
}
JSON

xray_config="$WORK_DIR/xray-config.json"
generate_config "$WORK_DIR/xray-fixture.json" "$xray_config"

cat >"$WORK_DIR/xray-reveal-urltest-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "log_level": "warn"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "urltest_enabled": "1",
      "urltest_check_interval": "3m",
      "urltest_tolerance": "50",
      "urltest_filter_mode": "include",
      "urltest_include_outbounds": [ "Latvia group" ],
      "detect_server_country": "flag_emoji",
      "subscription_urls": [ "https://xray.example/sub" ],
      "subscription_url_settings": "{\"https://xray.example/sub\":{\"hide_urltest_group_outbounds\":\"0\"}}"
    }
  ]
}
JSON

xray_reveal_urltest_config="$WORK_DIR/xray-reveal-urltest-config.json"
generate_config "$WORK_DIR/xray-reveal-urltest-fixture.json" "$xray_reveal_urltest_config"

ucode -e '
let fs = require("fs");
function object_or_empty(value) { return type(value) == "object" ? value : {}; }
let config = json(fs.readfile(ARGV[0]));
let cache = json(fs.readfile(ARGV[1]));
let reveal_config = json(fs.readfile(ARGV[2]));
let imported = null;
let builtin = null;
let reveal_selector = null;
for (let outbound in config.outbounds || []) {
    if (outbound.type == "urltest" && outbound.tag == "Latvia group")
        imported = outbound;
    if (outbound.type == "urltest" && outbound.tag == "proxy-urltest-out")
        builtin = outbound;
}
for (let outbound in reveal_config.outbounds || [])
    if (outbound.type == "selector" && outbound.tag == "proxy-out")
        reveal_selector = outbound;
if (!imported || imported.url != "https://probe.example/204" || imported.interval != "45s")
    die("generated xray imported URLTest did not preserve subscription params\n");
if (!builtin || length(builtin.outbounds || []) != 2)
    die("built-in URLTest should expand matched xray group to two child outbounds\n");
for (let child in builtin.outbounds || [])
    if (child == "Latvia group")
        die("built-in URLTest must not use the xray group tag as a child\n");
for (let child in builtin.outbounds || [])
    if (substr(child, 0, 5) == "xray-")
        die("built-in URLTest must not use artificial xray child tag prefixes\n");
if (object_or_empty(cache.urltestGroups)["Latvia group"].url != "https://probe.example/204")
    die("section cache is missing imported xray URLTest params\n");
if (length(object_or_empty(cache.urltestGroups)["proxy-urltest-out"].outbounds || []) != 2)
    die("section cache is missing built-in URLTest membership\n");
if (!reveal_selector || length(reveal_selector.outbounds || []) != 4)
    die("xray URLTest children should become visible when subscription hiding is disabled\n");
' "$xray_config" "$xray_config.section-cache/proxy.json" "$xray_reveal_urltest_config" || fail "xray generated URLTest behavior"

cat >"$WORK_DIR/singbox.json" <<'JSON'
{
  "outbounds": [
    {
      "type": "urltest",
      "tag": "Native Group",
      "outbounds": [ "Native A" ],
      "url": "https://native.example/ping",
      "interval": "1m",
      "tolerance": 80
    },
    {
      "type": "vless",
      "tag": "Native A",
      "server": "native-a.example",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000003",
      "tls": {
        "enabled": true,
        "server_name": "native-a.example"
      }
    },
    {
      "type": "vless",
      "tag": "Detour Only",
      "server": "detour.example",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000004",
      "tls": {
        "enabled": true,
        "server_name": "detour.example"
      }
    },
    {
      "type": "vless",
      "tag": "Uses Detour",
      "server": "uses-detour.example",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000005",
      "detour": "Detour Only",
      "tls": {
        "enabled": true,
        "server_name": "uses-detour.example"
      }
    }
  ]
}
JSON

singbox_normalized="$WORK_DIR/singbox-normalized.json"
normalize_subscription "$WORK_DIR/singbox.json" "$singbox_normalized"

ucode -e '
let fs = require("fs");
let value = json(fs.readfile(ARGV[0]));
let flags = {};
for (let outbound in value.outbounds || [])
    flags[outbound.tag] = {
        allow: outbound.__podkop_allow_group === true,
        hidden: outbound.__podkop_hidden === true
    };
if (!flags["Native Group"].allow)
    die("native sing-box URLTest group was not allowed\n");
if (!flags["Native A"].hidden)
    die("native sing-box URLTest child was not hidden\n");
if (!flags["Detour Only"].hidden)
    die("native sing-box detour-only outbound was not hidden\n");
if (flags["Uses Detour"].hidden)
    die("visible outbound using detour should stay visible\n");
' "$singbox_normalized" || fail "native sing-box normalized URLTest fields"

rm -rf "$WORK_DIR/subscriptions"
prepare_subscription_cache proxy 1 "https://singbox.example/sub" "$singbox_normalized"
cat >"$WORK_DIR/singbox-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "log_level": "warn"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "urltest_enabled": "1",
      "urltest_check_interval": "3m",
      "urltest_tolerance": "50",
      "urltest_filter_mode": "include",
      "urltest_include_regex": [ "^Native" ],
      "detect_server_country": "country_is",
      "subscription_urls": [ "https://singbox.example/sub" ]
    }
  ]
}
JSON

singbox_config="$WORK_DIR/singbox-config.json"
generate_config "$WORK_DIR/singbox-fixture.json" "$singbox_config"

cat >"$WORK_DIR/singbox-reveal-urltest-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "log_level": "warn"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "urltest_enabled": "1",
      "urltest_check_interval": "3m",
      "urltest_tolerance": "50",
      "urltest_filter_mode": "include",
      "urltest_include_regex": [ "^Native" ],
      "detect_server_country": "country_is",
      "subscription_urls": [ "https://singbox.example/sub" ],
      "subscription_url_settings": "{\"https://singbox.example/sub\":{\"hide_urltest_group_outbounds\":\"0\"}}"
    }
  ]
}
JSON

cat >"$WORK_DIR/singbox-reveal-detour-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "log_level": "warn"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "urltest_enabled": "1",
      "urltest_check_interval": "3m",
      "urltest_tolerance": "50",
      "urltest_filter_mode": "include",
      "urltest_include_regex": [ "^Native" ],
      "detect_server_country": "country_is",
      "subscription_urls": [ "https://singbox.example/sub" ],
      "subscription_url_settings": "{\"https://singbox.example/sub\":{\"hide_detour_outbounds\":\"0\"}}"
    }
  ]
}
JSON

singbox_reveal_urltest_config="$WORK_DIR/singbox-reveal-urltest-config.json"
singbox_reveal_detour_config="$WORK_DIR/singbox-reveal-detour-config.json"
generate_config "$WORK_DIR/singbox-reveal-urltest-fixture.json" "$singbox_reveal_urltest_config"
generate_config "$WORK_DIR/singbox-reveal-detour-fixture.json" "$singbox_reveal_detour_config"

ucode -e '
let fs = require("fs");
function object_or_empty(value) { return type(value) == "object" ? value : {}; }
let config = json(fs.readfile(ARGV[0]));
let cache = json(fs.readfile(ARGV[1]));
let reveal_urltest_config = json(fs.readfile(ARGV[2]));
let reveal_detour_config = json(fs.readfile(ARGV[3]));
let imported = null;
let builtin = null;
let selector = null;
let reveal_urltest_selector = null;
let reveal_detour_selector = null;
for (let outbound in config.outbounds || []) {
    if (outbound.type == "urltest" && outbound.tag == "Native Group")
        imported = outbound;
    if (outbound.type == "urltest" && outbound.tag == "proxy-urltest-out")
        builtin = outbound;
    if (outbound.type == "selector" && outbound.tag == "proxy-out")
        selector = outbound;
}
for (let outbound in reveal_urltest_config.outbounds || [])
    if (outbound.type == "selector" && outbound.tag == "proxy-out")
        reveal_urltest_selector = outbound;
for (let outbound in reveal_detour_config.outbounds || [])
    if (outbound.type == "selector" && outbound.tag == "proxy-out")
        reveal_detour_selector = outbound;
function contains(values, needle) {
    for (let value in values || [])
        if (value == needle)
            return true;
    return false;
}
if (!imported || imported.url != "https://native.example/ping" || imported.interval != "1m" || imported.tolerance != 80)
    die("generated native URLTest did not preserve subscription params\n");
if (!builtin || length(builtin.outbounds || []) != 1 || builtin.outbounds[0] != "Native A")
    die("built-in URLTest regex filter should expand Native Group to Native A only\n");
for (let tag in selector.outbounds || [])
    if (tag == "Native A")
        die("native URLTest child must not be visible in selector by default\n");
for (let tag in selector.outbounds || [])
    if (tag == "Detour Only")
        die("detour-only outbound must not be visible in selector\n");
if (!reveal_urltest_selector || !contains(reveal_urltest_selector.outbounds, "Native A"))
    die("native URLTest child should be visible when URLTest hiding is disabled\n");
if (contains(reveal_urltest_selector ? reveal_urltest_selector.outbounds : [], "Detour Only"))
    die("detour outbound should stay hidden when only URLTest hiding is disabled\n");
if (contains(reveal_detour_selector ? reveal_detour_selector.outbounds : [], "Native A"))
    die("native URLTest child should stay hidden when only detour hiding is disabled\n");
if (!reveal_detour_selector || !contains(reveal_detour_selector.outbounds, "Detour Only"))
    die("detour outbound should be visible when detour hiding is disabled\n");
if (length(object_or_empty(cache.urltestGroups)["Native Group"].outbounds || []) != 1)
    die("section cache is missing native URLTest membership\n");
' "$singbox_config" "$singbox_config.section-cache/proxy.json" "$singbox_reveal_urltest_config" "$singbox_reveal_detour_config" || fail "native sing-box generated URLTest behavior"

printf 'URLTest group regression checks passed\n'
