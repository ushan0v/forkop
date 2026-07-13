#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
GENERATOR_UC="$FORKOP_LIB/singbox/generator.uc"
VALIDATOR_UC="$FORKOP_LIB/config/validator.uc"
PRIORITY_UC="$FORKOP_LIB/singbox/priority.uc"
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
  local source="$1"
  local normalized="$WORK_DIR/validator-$(basename "$source")"
  node - "$source" "$normalized" <<'JS'
const fs = require('fs');
const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
input.settings ??= { '.name': 'settings', '.type': 'settings' };
input.settings.dns_server ??= ['77.88.8.8'];
input.settings.bootstrap_dns_server ??= ['77.88.8.8'];
fs.writeFileSync(process.argv[3], JSON.stringify(input));
JS
  FORKOP_LIB="$FORKOP_LIB" ucode -L "$FORKOP_LIB" "$VALIDATOR_UC" \
    validate-runtime-fixture "$normalized" "{}"
}

assert_rejects() {
  local label="$1"
  local fixture="$2"
  local expected="$3"
  local output

  if output="$(validate_fixture "$fixture" 2>/dev/null)"; then
    fail "$label should be rejected"
  fi

  printf '%s\n' "$output" | grep -Fq "$expected" ||
    fail "$label: expected message containing '$expected', got '$output'"
}

cat >"$WORK_DIR/fixture.json" <<'JSON'
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
      "selector_proxy_links": [
        "vless://00000000-0000-4000-8000-000000000001@alpha.example:443?encryption=none&security=tls&sni=alpha.example#Alpha",
        "vless://00000000-0000-4000-8000-000000000002@beta.example:443?encryption=none&security=tls&sni=beta.example#Beta",
        "vless://00000000-0000-4000-8000-000000000003@gamma.example:443?encryption=none&security=tls&sni=gamma.example#Gamma"
      ]
    }
  ],
  "priority_group": [
    {
      ".name": "pg_main",
      ".type": "priority_group",
      "section": "proxy",
      "name": "Main priority",
      "health_url": "https://health.example/generate_204",
      "active_check_interval": "5s",
      "check_timeout": "2s",
      "recovery_check_interval": "15s",
      "pick_fastest": "1",
      "switch_to_faster_same_priority": "1",
      "fastest_check_interval": "3m",
      "pin_dashboard": "1"
    },
    {
      ".name": "pg_backup",
      ".type": "priority_group",
      "section": "proxy",
      "name": "Backup priority",
      "health_url": "https://backup.example/generate_204",
      "active_check_interval": "10s",
      "check_timeout": "4s",
      "recovery_check_interval": "30s",
      "interrupt_exist_connections": "0"
    }
  ],
  "priority_level": [
    {
      ".name": "pl_lower",
      ".type": "priority_level",
      "group": "pg_main",
      "name": "Lower level",
      "order": "10",
      "regex": [ "Beta|Gamma" ]
    },
    {
      ".name": "pl_upper",
      ".type": "priority_level",
      "group": "pg_main",
      "name": "Upper level",
      "order": "0",
      "detect_server_country": "country_is",
      "server_name": [ "Beta" ]
    },
    {
      ".name": "pl_backup",
      ".type": "priority_level",
      "group": "pg_backup",
      "name": "Backup level",
      "order": "0",
      "regex": [ "Gamma" ]
    }
  ]
}
JSON

validate_fixture "$WORK_DIR/fixture.json"

output="$WORK_DIR/config.json"
generate_config "$WORK_DIR/fixture.json" "$output"

ucode -e '
let fs = require("fs");

function fail(message) {
    die(message + "\n");
}

function outbound_by_tag(config, tag_name) {
    for (let outbound in config.outbounds || [])
        if (outbound && outbound.tag == tag_name)
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

function contains(values, needle) {
    for (let value in values || [])
        if (value == needle)
            return true;
    return false;
}

let config = json(fs.readfile(ARGV[0]));
let cache = json(fs.readfile(ARGV[1]));
let main = outbound_by_tag(config, "proxy-priority-pg_main-out");
let backup = outbound_by_tag(config, "proxy-priority-pg_backup-out");
let selector = outbound_by_tag(config, "proxy-out");

if (!main || !backup)
    fail("expected one selector per priority group");
if (main.type != "selector" || backup.type != "selector")
    fail("priority groups must be sing-box selectors");
if (main.interrupt_exist_connections !== true)
    fail("main priority interrupt flag should default to true");
if (backup.interrupt_exist_connections !== false)
    fail("backup priority interrupt flag should be false");
assert_array(main.outbounds, [ "proxy-2-out", "proxy-3-out" ], "main priority outbounds");
assert_array(backup.outbounds, [ "proxy-3-out" ], "backup priority outbounds");
if (main.default != "proxy-2-out")
    fail("main priority selector should default to the first upper-level outbound");
if (!selector || selector.default != "proxy-priority-pg_main-out")
    fail("section selector should default to the first priority group when URLTest is absent");
if (!contains(selector.outbounds, "proxy-2-out") || !contains(selector.outbounds, "proxy-3-out"))
    fail("section selector should keep individual priority members by default");
if (selector.outbounds[length(selector.outbounds || []) - 2] != "proxy-priority-pg_main-out" ||
    selector.outbounds[length(selector.outbounds || []) - 1] != "proxy-priority-pg_backup-out")
    fail("section selector should include priority groups in order");

let groups = cache.priorityGroups || {};
let cached = groups["proxy-priority-pg_main-out"];
if (!cached)
    fail("main priority group was not cached");
if (cached.displayName != "Main priority" || cached.health_url != "https://health.example/generate_204")
    fail("priority group display metadata was not cached");
if (cached.check_timeout != "2s" || cached.fastest_check_interval != "3m")
    fail("priority group timing metadata was not cached");
if (cached.pick_fastest !== true || cached.switch_to_faster_same_priority !== true)
    fail("priority boolean metadata was not cached");
if (cached.interrupt_exist_connections !== true || cached.pin_dashboard !== true)
    fail("priority dashboard/default metadata was not cached");
assert_array(cached.outbounds, [ "proxy-2-out", "proxy-3-out" ], "cached priority outbounds");
if (length(cached.levels || []) != 2 || cached.levels[0].id != "pl_upper" || cached.levels[1].id != "pl_lower")
    fail("priority levels should be sorted by order in cache");
if (cached.levels[0].detect_server_country != "country_is" || cached.levels[1].detect_server_country != "flag_emoji")
    fail("priority level country detection metadata was not cached");
assert_array(cached.levels[0].outbounds, [ "proxy-2-out" ], "upper level outbounds");
assert_array(cached.levels[1].outbounds, [ "proxy-3-out" ], "lower level outbounds");
' "$output" "$output.section-cache/proxy.json" || fail "priority selector generation"

cat >"$WORK_DIR/group-no-levels.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "selector_proxy_links": [
        "vless://00000000-0000-4000-8000-000000000001@alpha.example:443?encryption=none&security=tls&sni=alpha.example#Alpha"
      ]
    }
  ],
  "priority_group": [
    { ".name": "pg_empty", ".type": "priority_group", "section": "proxy", "name": "Empty" }
  ]
}
JSON
validate_fixture "$WORK_DIR/group-no-levels.json"
group_no_levels_output="$WORK_DIR/group-no-levels-config.json"
generate_config "$WORK_DIR/group-no-levels.json" "$group_no_levels_output"
ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let cache = json(fs.readfile(ARGV[1]));
for (let outbound in cfg.outbounds || [])
    if (outbound && outbound.tag == "proxy-priority-pg_empty-out")
        die("empty priority group must not be added to sing-box config\n");
let cached = (cache.priorityGroups || {})["proxy-priority-pg_empty-out"];
if (!cached || cached.displayName != "Empty")
    die("empty priority group should be cached for dashboard\n");
if (length(cached.outbounds || []) != 0 || length(cached.levels || []) != 0)
    die("empty priority group cache should have no outbounds or levels\n");
' "$group_no_levels_output" "$group_no_levels_output.section-cache/proxy.json" ||
  fail "empty priority group should be dashboard-only"

cat >"$WORK_DIR/level-no-criteria.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "selector_proxy_links": [
        "vless://00000000-0000-4000-8000-000000000001@alpha.example:443?encryption=none&security=tls&sni=alpha.example#Alpha"
      ]
    }
  ],
  "priority_group": [
    { ".name": "pg_main", ".type": "priority_group", "section": "proxy", "name": "Main" }
  ],
  "priority_level": [
    { ".name": "pl_empty", ".type": "priority_level", "group": "pg_main", "name": "Empty", "order": "0" }
  ]
}
JSON
validate_fixture "$WORK_DIR/level-no-criteria.json"
level_no_criteria_output="$WORK_DIR/level-no-criteria-config.json"
generate_config "$WORK_DIR/level-no-criteria.json" "$level_no_criteria_output"
ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let cache = json(fs.readfile(ARGV[1]));
for (let outbound in cfg.outbounds || [])
    if (outbound && outbound.tag == "proxy-priority-pg_main-out")
        die("priority group with no matched outbounds must not be added to sing-box config\n");
let cached = (cache.priorityGroups || {})["proxy-priority-pg_main-out"];
if (!cached || length(cached.levels || []) != 1)
    die("priority group with empty level should be cached for dashboard\n");
if (length(cached.levels[0].outbounds || []) != 0)
    die("priority level without criteria should have no matched outbounds\n");
' "$level_no_criteria_output" "$level_no_criteria_output.section-cache/proxy.json" ||
  fail "priority level without criteria should be dashboard-only"

cat >"$WORK_DIR/empty-urltest.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "selector_proxy_links": [
        "vless://00000000-0000-4000-8000-000000000001@alpha.example:443?encryption=none&security=tls&sni=alpha.example#Alpha"
      ]
    }
  ],
  "urltest": [
    {
      ".name": "cfg_empty",
      ".type": "urltest",
      "section": "proxy",
      "name": "Empty URLTest",
      "filter_mode": "include",
      "include_regex": [ "NoSuchServer" ]
    }
  ]
}
JSON
validate_fixture "$WORK_DIR/empty-urltest.json"
empty_urltest_output="$WORK_DIR/empty-urltest-config.json"
generate_config "$WORK_DIR/empty-urltest.json" "$empty_urltest_output"
ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let cache = json(fs.readfile(ARGV[1]));
for (let outbound in cfg.outbounds || [])
    if (outbound && outbound.tag == "proxy-urltest-cfg_empty-out")
        die("empty URLTest group must not be added to sing-box config\n");
let cached = (cache.urltestGroups || {})["proxy-urltest-cfg_empty-out"];
if (!cached || cached.displayName != "Empty URLTest")
    die("empty URLTest group should be cached for dashboard\n");
if (length(cached.outbounds || []) != 0)
    die("empty URLTest cache should have no outbounds\n");
' "$empty_urltest_output" "$empty_urltest_output.section-cache/proxy.json" ||
  fail "empty URLTest should be dashboard-only"

cat >"$WORK_DIR/bad-order.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "proxy", ".type": "section", "enabled": "1", "action": "proxy" }
  ],
  "priority_group": [
    { ".name": "pg_main", ".type": "priority_group", "section": "proxy", "name": "Main" }
  ],
  "priority_level": [
    { ".name": "pl_bad", ".type": "priority_level", "group": "pg_main", "name": "Bad", "order": "first", "regex": [ ".*" ] }
  ]
}
JSON
assert_rejects "priority level bad order" "$WORK_DIR/bad-order.json" "Invalid priority level order"

cat >"$WORK_DIR/select-first-live-group.json" <<'JSON'
{
  "tag": "fixture",
  "pick_fastest": false,
  "levels": [
    { "id": "top", "outbounds": [ "a", "b" ] },
    { "id": "fallback", "outbounds": [ "c" ] }
  ]
}
JSON
cat >"$WORK_DIR/select-first-live-latency.json" <<'JSON'
{ "a": -1, "b": 200, "c": 50 }
JSON
first_live="$(ucode -L "$FORKOP_LIB" "$PRIORITY_UC" select-fixture \
  "$WORK_DIR/select-first-live-group.json" "$WORK_DIR/select-first-live-latency.json" 0 1)"
printf '%s\n' "$first_live" | grep -Fq '"tag": "b"' ||
  fail "priority selection should choose the first live outbound when pick_fastest=0"

cat >"$WORK_DIR/select-fastest-group.json" <<'JSON'
{
  "tag": "fixture",
  "pick_fastest": true,
  "levels": [
    { "id": "top", "outbounds": [ "a", "b", "c" ] }
  ]
}
JSON
cat >"$WORK_DIR/select-fastest-latency.json" <<'JSON'
{ "a": 80, "b": 20, "c": 50 }
JSON
fastest="$(ucode -L "$FORKOP_LIB" "$PRIORITY_UC" select-fixture \
  "$WORK_DIR/select-fastest-group.json" "$WORK_DIR/select-fastest-latency.json" 0 0)"
printf '%s\n' "$fastest" | grep -Fq '"tag": "b"' ||
  fail "priority selection should choose the fastest live outbound when pick_fastest=1"

cat >"$WORK_DIR/filter-modes.json" <<'JSON'
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
        "vless://00000000-0000-4000-8000-000000000002@beta.example:443?encryption=none&security=tls&sni=beta.example#Beta",
        "vless://00000000-0000-4000-8000-000000000003@gamma.example:443?encryption=none&security=tls&sni=gamma.example#Gamma",
        "vless://00000000-0000-4000-8000-000000000004@delta.example:443?encryption=none&security=tls&sni=delta.example#Delta"
      ]
    }
  ],
  "priority_group": [
    { ".name": "pg_modes", ".type": "priority_group", "section": "proxy", "name": "Modes" }
  ],
  "priority_level": [
    {
      ".name": "pl_include",
      ".type": "priority_level",
      "group": "pg_modes",
      "name": "Include",
      "order": "0",
      "filter_mode": "include",
      "server_name": [ "Beta" ]
    },
    {
      ".name": "pl_mixed",
      ".type": "priority_level",
      "group": "pg_modes",
      "name": "Mixed",
      "order": "1",
      "filter_mode": "mixed",
      "regex": [ "Alpha|Gamma" ],
      "exclude_outbounds": [ "Gamma" ]
    },
    {
      ".name": "pl_direct",
      ".type": "priority_level",
      "group": "pg_modes",
      "name": "Direct",
      "order": "2",
      "direct": "1"
    },
    {
      ".name": "pl_exclude",
      ".type": "priority_level",
      "group": "pg_modes",
      "name": "Exclude",
      "order": "3",
      "filter_mode": "exclude",
      "exclude_outbounds": [ "Delta" ]
    },
    {
      ".name": "pl_remaining",
      ".type": "priority_level",
      "group": "pg_modes",
      "name": "Remaining",
      "order": "4",
      "filter_mode": "disabled"
    }
  ]
}
JSON
validate_fixture "$WORK_DIR/filter-modes.json"
filter_modes_output="$WORK_DIR/filter-modes-config.json"
generate_config "$WORK_DIR/filter-modes.json" "$filter_modes_output"
ucode -e '
let fs = require("fs");
function fail(message) { die(message + "\n"); }
function assert_array(value, expected, label) {
    value = value || [];
    if (length(value) != length(expected))
        fail(label + " length mismatch: " + sprintf("%J", value));
    for (let i = 0; i < length(expected); i++)
        if (value[i] != expected[i])
            fail(label + " mismatch: " + sprintf("%J", value));
}
let config = json(fs.readfile(ARGV[0]));
let cache = json(fs.readfile(ARGV[1]));
let selector = null;
for (let outbound in config.outbounds || [])
    if (outbound && outbound.tag == "proxy-priority-pg_modes-out")
        selector = outbound;
if (!selector)
    fail("filter-mode priority selector is missing");
assert_array(selector.outbounds, [ "proxy-2-out", "proxy-1-out", "direct-out", "proxy-3-out", "proxy-4-out" ], "filter-mode selector");
let levels = ((cache.priorityGroups || {})["proxy-priority-pg_modes-out"] || {}).levels || [];
if (length(levels) != 5 || levels[2].direct !== true || levels[4].filter_mode != "disabled")
    fail("priority level filter/direct metadata is missing");
assert_array(levels[0].outbounds, [ "proxy-2-out" ], "include level");
assert_array(levels[1].outbounds, [ "proxy-1-out" ], "mixed level");
assert_array(levels[2].outbounds, [ "direct-out" ], "direct level");
assert_array(levels[3].outbounds, [ "proxy-3-out" ], "exclude level");
assert_array(levels[4].outbounds, [ "proxy-4-out" ], "remaining level");
' "$filter_modes_output" "$filter_modes_output.section-cache/proxy.json" ||
  fail "priority filter modes and direct level"

cat >"$WORK_DIR/country-filter.json" <<'JSON'
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
  "priority_group": [
    { ".name": "pg_country", ".type": "priority_group", "section": "proxy", "name": "Country" }
  ],
  "priority_level": [
    {
      ".name": "pl_de",
      ".type": "priority_level",
      "group": "pg_country",
      "name": "Germany",
      "order": "0",
      "filter_mode": "include",
      "detect_server_country": "country_is",
      "country": [ "DE" ]
    }
  ]
}
JSON
country_output="$WORK_DIR/country-filter-config.json"
mkdir -p "$country_output.section-cache"
cat >"$country_output.section-cache/proxy.json" <<'JSON'
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
generate_config "$WORK_DIR/country-filter.json" "$country_output"
ucode -e '
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));
let selector = null;
for (let outbound in config.outbounds || [])
    if (outbound && outbound.tag == "proxy-priority-pg_country-out")
        selector = outbound;
if (!selector || length(selector.outbounds || []) != 1 || selector.outbounds[0] != "proxy-1-out")
    die("cached country.is metadata was not applied to Priority filtering\n");
' "$country_output" || fail "Priority country.is cached filtering"

write_refresh_fixture() {
  local path="$1"
  local links="$2"

  cat >"$path" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "selector_proxy_links": $links
    }
  ],
  "urltest": [
    {
      ".name": "ut_dynamic",
      ".type": "urltest",
      "section": "proxy",
      "name": "Dynamic URLTest",
      "filter_mode": "include",
      "include_regex": [ "Beta" ]
    }
  ],
  "priority_group": [
    { ".name": "pg_dynamic", ".type": "priority_group", "section": "proxy", "name": "Dynamic Priority" }
  ],
  "priority_level": [
    {
      ".name": "pl_dynamic",
      ".type": "priority_level",
      "group": "pg_dynamic",
      "name": "Beta",
      "order": "0",
      "filter_mode": "include",
      "regex": [ "Beta" ]
    }
  ]
}
JSON
}

assert_refresh_membership() {
  local config_path="$1"
  local expected="$2"

  ucode -e '
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));
let expected = ARGV[1] == "present";
let urltest = null;
let priority = null;
for (let outbound in config.outbounds || []) {
    if (outbound && outbound.tag == "proxy-urltest-ut_dynamic-out")
        urltest = outbound;
    if (outbound && outbound.tag == "proxy-priority-pg_dynamic-out")
        priority = outbound;
}
if (expected) {
    if (!urltest || !priority || length(urltest.outbounds || []) != 1 || length(priority.outbounds || []) != 1)
        die("newly matching URLTest/Priority outbound was not added\n");
    if (urltest.outbounds[0] != "proxy-2-out" || priority.outbounds[0] != "proxy-2-out")
        die("URLTest/Priority selected the wrong refreshed outbound\n");
}
else if (urltest || priority) {
    die("empty URLTest/Priority group remained in sing-box config after membership refresh\n");
}
' "$config_path" "$expected"
}

refresh_fixture="$WORK_DIR/refresh-fixture.json"
refresh_output="$WORK_DIR/refresh-config.json"
write_refresh_fixture "$refresh_fixture" '["vless://00000000-0000-4000-8000-000000000001@alpha.example:443?encryption=none&security=tls&sni=alpha.example#Alpha"]'
generate_config "$refresh_fixture" "$refresh_output"
assert_refresh_membership "$refresh_output" absent || fail "initial empty group refresh state"

write_refresh_fixture "$refresh_fixture" '["vless://00000000-0000-4000-8000-000000000001@alpha.example:443?encryption=none&security=tls&sni=alpha.example#Alpha","vless://00000000-0000-4000-8000-000000000002@beta.example:443?encryption=none&security=tls&sni=beta.example#Beta"]'
generate_config "$refresh_fixture" "$refresh_output"
assert_refresh_membership "$refresh_output" present || fail "added outbound group refresh state"

write_refresh_fixture "$refresh_fixture" '["vless://00000000-0000-4000-8000-000000000003@gamma.example:443?encryption=none&security=tls&sni=gamma.example#Gamma"]'
generate_config "$refresh_fixture" "$refresh_output"
assert_refresh_membership "$refresh_output" absent || fail "removed outbound group refresh state"

cat >"$WORK_DIR/bad-filter-mode.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "proxy", ".type": "section", "enabled": "1", "action": "proxy" }
  ],
  "priority_group": [
    { ".name": "pg_main", ".type": "priority_group", "section": "proxy", "name": "Main" }
  ],
  "priority_level": [
    { ".name": "pl_bad", ".type": "priority_level", "group": "pg_main", "name": "Bad", "order": "0", "filter_mode": "unknown" }
  ]
}
JSON
assert_rejects "priority level bad filter mode" "$WORK_DIR/bad-filter-mode.json" "Invalid Priority filter mode"

skip_dead="$(ucode -L "$FORKOP_LIB" "$PRIORITY_UC" select-fixture \
  "$WORK_DIR/select-first-live-group.json" "$WORK_DIR/select-fastest-latency.json" 0 1 a)"
printf '%s\n' "$skip_dead" | grep -Fq '"tag": "b"' ||
  fail "replacement selection should skip the just-failed active outbound"

cat >"$WORK_DIR/select-faster-current-latency.json" <<'JSON'
{ "a": 100, "b": 50, "c": 80 }
JSON
same_level="$(ucode -L "$FORKOP_LIB" "$PRIORITY_UC" select-faster-fixture \
  "$WORK_DIR/select-fastest-group.json" "$WORK_DIR/select-faster-current-latency.json" 0 a)"
printf '%s\n' "$same_level" | grep -Fq '"tag": "b"' ||
  fail "same-level switching should compare candidates with the active delay from the same pass"

printf 'Priority failover checks passed\n'
