#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
PARSER_UC="$PODKOP_LIB/subscription/parser.uc"
GENERATOR_UC="$PODKOP_LIB/singbox/generator.uc"
CACHE_UC="$PODKOP_LIB/subscription/cache.uc"
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
      "urltest_include_regex": [ "Riga" ],
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
      "urltest_include_regex": [ "Riga" ],
      "detect_server_country": "flag_emoji",
      "subscription_urls": [ "https://xray.example/sub" ],
      "subscription_url_settings": "{\"https://xray.example/sub\":{\"hide_urltest_group_outbounds\":\"0\"}}"
    }
  ]
}
JSON

xray_reveal_urltest_config="$WORK_DIR/xray-reveal-urltest-config.json"
generate_config "$WORK_DIR/xray-reveal-urltest-fixture.json" "$xray_reveal_urltest_config"

cat >"$WORK_DIR/xray-group-name-filter-fixture.json" <<'JSON'
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

xray_group_name_filter_config="$WORK_DIR/xray-group-name-filter-config.json"
generate_config "$WORK_DIR/xray-group-name-filter-fixture.json" "$xray_group_name_filter_config"

ucode -e '
let fs = require("fs");
function object_or_empty(value) { return type(value) == "object" ? value : {}; }
let config = json(fs.readfile(ARGV[0]));
let cache = json(fs.readfile(ARGV[1]));
let reveal_config = json(fs.readfile(ARGV[2]));
let group_name_filter_config = json(fs.readfile(ARGV[3]));
let imported = null;
let builtin = null;
let reveal_selector = null;
let group_name_builtin = null;
function contains(values, needle) {
    for (let value in values || [])
        if (value == needle)
            return true;
    return false;
}
for (let outbound in config.outbounds || []) {
    if (outbound.type == "urltest" && outbound.tag == "Latvia group")
        imported = outbound;
    if (outbound.type == "urltest" && outbound.tag == "proxy-urltest-out")
        builtin = outbound;
}
for (let outbound in reveal_config.outbounds || [])
    if (outbound.type == "selector" && outbound.tag == "proxy-out")
        reveal_selector = outbound;
for (let outbound in group_name_filter_config.outbounds || [])
    if (outbound.type == "urltest" && outbound.tag == "proxy-urltest-out")
        group_name_builtin = outbound;
if (!imported || imported.url != "https://probe.example/204" || imported.interval != "45s")
    die("generated xray imported URLTest did not preserve subscription params\n");
if (!builtin || length(builtin.outbounds || []) != 2)
    die("built-in URLTest should include two matched xray leaf outbounds\n");
for (let child in builtin.outbounds || [])
    if (child == "Latvia group")
        die("built-in URLTest must not use the xray group tag as a child\n");
if (group_name_builtin)
    die("built-in URLTest must not match subscription URLTest group names as servers\n");
for (let child in builtin.outbounds || [])
    if (substr(child, 0, 5) == "xray-")
        die("built-in URLTest must not use artificial xray child tag prefixes\n");
if (object_or_empty(cache.urltestGroups)["Latvia group"].url != "https://probe.example/204")
    die("section cache is missing imported xray URLTest params\n");
if (length(object_or_empty(cache.urltestGroups)["proxy-urltest-out"].outbounds || []) != 2)
    die("section cache is missing built-in URLTest membership\n");
let candidates = cache.urltestCandidateTags || [];
if (contains(candidates, "Latvia group") || contains(candidates, "proxy-urltest-out"))
    die("section cache URLTest candidates must not include URLTest groups\n");
if (length(candidates) != length(builtin.outbounds || []))
    die("section cache URLTest candidates should include only xray leaf outbounds\n");
for (let child in builtin.outbounds || [])
    if (!contains(candidates, child))
        die("section cache URLTest candidates are missing a matched xray leaf outbound\n");
if (!reveal_selector || length(reveal_selector.outbounds || []) != 4)
    die("xray URLTest children should become visible when subscription hiding is disabled\n");
' "$xray_config" "$xray_config.section-cache/proxy.json" "$xray_reveal_urltest_config" "$xray_group_name_filter_config" || fail "xray generated URLTest behavior"

xray_metadata="$WORK_DIR/xray-ui-outbound-metadata.json"
ucode -L "$PODKOP_LIB" "$CACHE_UC" get-outbound-metadata "$xray_config.section-cache" proxy "$WORK_DIR/missing-outbound-metadata.json" >"$xray_metadata"

ucode -e '
let fs = require("fs");
let metadata = json(fs.readfile(ARGV[0]));
let names = type(metadata.names) == "object" ? metadata.names : {};
if (names["Latvia group"] != null || names["proxy-urltest-out"] != null)
    die("UI outbound metadata must not include URLTest group names\n");
if (length(keys(names)) != 2)
    die("UI outbound metadata should contain only xray leaf outbound names\n");
' "$xray_metadata" || fail "xray UI outbound metadata filtering"

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

cat >"$WORK_DIR/singbox-prefix-fixture.json" <<'JSON'
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
      "urltest_include_regex": [ "^Provider " ],
      "detect_server_country": "country_is",
      "subscription_urls": [ "https://singbox.example/sub" ],
      "subscription_url_settings": "{\"https://singbox.example/sub\":{\"prefix_nodes\":\"1\",\"node_prefix\":\"Provider\"}}"
    }
  ]
}
JSON

singbox_prefix_config="$WORK_DIR/singbox-prefix-config.json"
generate_config "$WORK_DIR/singbox-prefix-fixture.json" "$singbox_prefix_config"

ucode -e '
let fs = require("fs");
function object_or_empty(value) { return type(value) == "object" ? value : {}; }
function outbound_by_tag(config, tag) {
    for (let outbound in config.outbounds || [])
        if (outbound && outbound.tag == tag)
            return outbound;
    return null;
}
function contains(values, needle) {
    for (let value in values || [])
        if (value == needle)
            return true;
    return false;
}
let config = json(fs.readfile(ARGV[0]));
let cache = json(fs.readfile(ARGV[1]));
let names = object_or_empty(object_or_empty(cache.outboundMetadata).names);
let groups = object_or_empty(cache.urltestGroups);
let imported = outbound_by_tag(config, "Provider Native Group");
let native = outbound_by_tag(config, "Provider Native A");
let detour = outbound_by_tag(config, "Provider Detour Only");
let uses_detour = outbound_by_tag(config, "Provider Uses Detour");
let builtin = outbound_by_tag(config, "proxy-urltest-out");
if (!imported || !native || !detour || !uses_detour)
    die("subscription prefix was not applied to every imported outbound\n");
if (length(imported.outbounds || []) != 1 || imported.outbounds[0] != "Provider Native A")
    die("subscription prefix did not rewrite imported URLTest group membership\n");
if (uses_detour.detour != "Provider Detour Only")
    die("subscription prefix did not rewrite detour references\n");
if (!builtin || length(builtin.outbounds || []) != 3)
    die("prefixed node names did not match the configured URLTest filter\n");
for (let tag in [ "Provider Native A", "Provider Detour Only", "Provider Uses Detour" ])
    if (!contains(builtin.outbounds, tag))
        die("built-in URLTest is missing a prefixed node\n");
if (contains(cache.urltestCandidateTags || [], "Provider Native Group"))
    die("prefixed imported URLTest group must not become a URLTest candidate\n");
if (object_or_empty(groups["Provider Native Group"]).displayName != "Provider Native Group")
    die("prefixed imported URLTest group display name was not retained\n");
if (names["Provider Native A"] != "Provider Native A" ||
    names["Provider Native Group"] != "Provider Native Group")
    die("prefixed outbound metadata names were not retained\n");
if (names["Native A"] != null || names["Native Group"] != null)
    die("unprefixed outbound metadata names must not remain\n");
' "$singbox_prefix_config" "$singbox_prefix_config.section-cache/proxy.json" || fail "subscription node prefix behavior"

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
let candidates = cache.urltestCandidateTags || [];
if (contains(candidates, "Native Group") || contains(candidates, "proxy-urltest-out"))
    die("section cache native URLTest candidates must not include URLTest groups\n");
if (!contains(candidates, "Native A") || !contains(candidates, "Detour Only"))
    die("section cache native URLTest candidates should include all leaf outbounds, including hidden ones\n");
' "$singbox_config" "$singbox_config.section-cache/proxy.json" "$singbox_reveal_urltest_config" "$singbox_reveal_detour_config" || fail "native sing-box generated URLTest behavior"

singbox_metadata="$WORK_DIR/singbox-ui-outbound-metadata.json"
ucode -L "$PODKOP_LIB" "$CACHE_UC" get-outbound-metadata "$singbox_config.section-cache" proxy "$WORK_DIR/missing-outbound-metadata.json" >"$singbox_metadata"

ucode -e '
let fs = require("fs");
let metadata = json(fs.readfile(ARGV[0]));
let names = type(metadata.names) == "object" ? metadata.names : {};
if (names["Native Group"] != null || names["proxy-urltest-out"] != null)
    die("UI outbound metadata must not include native URLTest group names\n");
if (names["Native A"] == null || names["Detour Only"] == null)
    die("UI outbound metadata should include all native leaf outbound names\n");
' "$singbox_metadata" || fail "native UI outbound metadata filtering"

cat >"$WORK_DIR/country-is-fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "selector_proxy_links": [
        "vless://00000000-0000-4000-8000-000000000001@alpha.example:443?encryption=none&security=tls&sni=alpha.example#Alpha",
        "vless://00000000-0000-4000-8000-000000000002@beta.example:443?encryption=none&security=tls&sni=beta.example#Beta"
      ]
    }
  ],
  "urltest": [
    {
      ".name": "ut_country",
      ".type": "urltest",
      "section": "proxy",
      "name": "Germany",
      "filter_mode": "include",
      "detect_server_country": "country_is",
      "include_countries": [ "DE" ]
    }
  ]
}
JSON
country_is_config="$WORK_DIR/country-is-config.json"
mkdir -p "$country_is_config.section-cache"
cat >"$country_is_config.section-cache/proxy.json" <<'JSON'
{
  "servers": {
    "proxy-1-out": "alpha.example",
    "proxy-2-out": "beta.example"
  },
  "outboundMetadata": {
    "countries": {
      "proxy-1-out": "DE",
      "proxy-2-out": "NL"
    }
  }
}
JSON
generate_config "$WORK_DIR/country-is-fixture.json" "$country_is_config"
ucode -e '
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));
let urltest = null;
for (let outbound in config.outbounds || [])
    if (outbound && outbound.tag == "proxy-urltest-ut_country-out")
        urltest = outbound;
if (!urltest || length(urltest.outbounds || []) != 1 || urltest.outbounds[0] != "proxy-1-out")
    die("cached country.is metadata was not applied to URLTest filtering\n");
' "$country_is_config" || fail "URLTest country.is cached filtering"

printf 'URLTest group regression checks passed\n'
