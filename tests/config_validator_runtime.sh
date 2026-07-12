#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
VALIDATOR="$FORKOP_LIB/config/validator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cat >"$WORK_DIR/context.json" <<'JSON'
{}
JSON

context="$(cat "$WORK_DIR/context.json")"

validate_fixture() {
  local source="$1"
  local normalized="$WORK_DIR/normalized-$(basename "$source")"
  node - "$source" "$normalized" <<'JS'
const fs = require('fs');
const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
input.settings ??= { '.name': 'settings', '.type': 'settings' };
if (input.settings.dns_server === undefined) input.settings.dns_server = ['77.88.8.8'];
if (input.settings.bootstrap_dns_server === undefined) input.settings.bootstrap_dns_server = ['77.88.8.8'];
fs.writeFileSync(process.argv[3], JSON.stringify(input));
JS
  FORKOP_LIB="$FORKOP_LIB" ucode -L "$FORKOP_LIB" "$VALIDATOR" validate-runtime-fixture "$normalized" "$context"
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

cat >"$WORK_DIR/valid.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "list_update_enabled": "1",
    "update_interval": "1d",
    "latency_test_url": "https://latency.example/generate_204",
    "dns_type": "doh",
    "dns_server": [ "dns.google/dns-query", "cloudflare-dns.com/dns-query" ],
    "bootstrap_dns_server": [ "1.1.1.1", "8.8.8.8" ],
    "dns_check_interval": "10s",
    "dns_recovery_check_interval": "60s",
    "dns_check_timeout": "2s",
    "dns_strategy": "prefer_ipv6",
    "dns_detour_enabled": "1",
    "dns_detour_section": "proxy",
    "download_lists_via_proxy": "1",
    "download_lists_via_proxy_section": "proxy"
  },
  "section": [
    {
      ".name": "detour",
      ".type": "section",
      "enabled": "1",
      "action": "outbound",
      "outbound_json": "{\"type\":\"direct\"}",
      "domain_suffix": [ "detour.example" ]
    },
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "ports": [ "80", "1000-2000" ],
      "subscription_urls": [ "https://example.com/sub.txt" ],
      "subscription_url_settings": "{\"https://example.com/sub.txt\":{\"user_agent\":\"Agent/1.0\"}}",
      "subscription_update_enabled": "1",
      "subscription_update_interval": "12h",
      "urltest_enabled": "1",
      "urltest_check_interval": "3m",
      "urltest_filter_mode": "mixed",
      "urltest_tolerance": "10000",
      "urltest_testing_url": "https://urltest.example/generate_204",
      "urltest_include_countries": [ "US" ],
      "urltest_exclude_regex": [ "bad.*" ],
      "detect_server_country": "flag_emoji",
      "domain": "commented.example # keep this note\nfull:exact-comment.example // and this note\nkeyword:clip",
      "domain_suffix": [ "example.org", "сайт.рф", "full:exact.example", "full:full:legacy.example", "full:пример.испытание", "keyword:video", "keyword:пример", "regex:^api[.]example$", "regex:^сайт[.]рф$" ],
      "domain_suffix_text": "text.example\nmünich.example\nkeyword:stream",
      "community_lists": [ "discord" ],
      "rule_set": [ "https://example.com/rules.srs" ],
      "rule_set_with_subnets": [ "/tmp/local.json" ],
      "domain_ip_lists": [ "https://example.com/mixed.lst" ],
      "outbound_detour_enabled": "1",
      "outbound_detour_section": "detour"
    },
    {
      ".name": "bypass",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "domain_suffix": [ "bypass.example" ]
    },
    {
      ".name": "zap",
      ".type": "section",
      "enabled": "1",
      "action": "zapret",
      "domain_ip_lists": [ "https://example.com/provider.lst" ]
    }
  ],
  "server": [
    {
      ".name": "srv",
      ".type": "server",
      "enabled": "1",
      "routing_mode": "section",
      "routing_section": "proxy"
    }
  ]
}
JSON

validate_fixture "$WORK_DIR/valid.json"

cat >"$WORK_DIR/bad-dns-duration.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "1.1.1.1", "8.8.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ],
    "dns_check_interval": "ten seconds"
  },
  "section": []
}
JSON
assert_rejects "bad DNS interval" "$WORK_DIR/bad-dns-duration.json" "settings.dns_check_interval"

cat >"$WORK_DIR/bad-dns-server.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "1.1.1.1", "bad value" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": []
}
JSON
assert_rejects "bad DNS server" "$WORK_DIR/bad-dns-server.json" "Invalid main DNS server"

cat >"$WORK_DIR/bad-dns-strategy.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_strategy": "auto"
  },
  "section": []
}
JSON
assert_rejects "bad DNS strategy" "$WORK_DIR/bad-dns-strategy.json" "Unsupported DNS strategy 'auto'"

cat >"$WORK_DIR/empty-main-dns.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": []
}
JSON
assert_rejects "empty main DNS list" "$WORK_DIR/empty-main-dns.json" "At least one main DNS server is required"

cat >"$WORK_DIR/empty-bootstrap-dns.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": []
  },
  "section": []
}
JSON
assert_rejects "empty Bootstrap DNS list" "$WORK_DIR/empty-bootstrap-dns.json" "At least one Bootstrap DNS server is required"

cat >"$WORK_DIR/bad-dns-detour-bypass.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_detour_enabled": "1",
    "dns_detour_section": "bypass"
  },
  "section": [
    { ".name": "bypass", ".type": "section", "enabled": "1", "action": "bypass" }
  ]
}
JSON
assert_rejects "DNS detour bypass" "$WORK_DIR/bad-dns-detour-bypass.json" "unsupported action 'bypass'"

cat >"$WORK_DIR/bad-direct-action.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "old", ".type": "section", "enabled": "1", "action": "direct" }
  ]
}
JSON
assert_rejects "bad direct action" "$WORK_DIR/bad-direct-action.json" "unsupported action 'direct'"

cat >"$WORK_DIR/bad-port.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "proxy", ".type": "section", "enabled": "1", "action": "proxy", "ports": [ "70000" ] }
  ]
}
JSON
assert_rejects "bad port" "$WORK_DIR/bad-port.json" "Invalid port condition '70000'"

cat >"$WORK_DIR/bad-subscription.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "proxy", ".type": "section", "enabled": "1", "action": "proxy", "subscription_urls": [ "https://example.com/a| Agent" ] }
  ]
}
JSON
assert_rejects "bad subscription" "$WORK_DIR/bad-subscription.json" "Configure User-Agent in the subscription item settings"

cat >"$WORK_DIR/bad-manual-hwid.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "proxy", ".type": "section", "enabled": "1", "action": "connection" }
  ],
  "subscription_url": [
    {
      ".name": "proxy_sub_1",
      ".type": "subscription_url",
      "section": "proxy",
      "url": "https://example.com/sub.txt",
      "auto_hwid": "0"
    }
  ]
}
JSON
assert_rejects "bad manual HWID" "$WORK_DIR/bad-manual-hwid.json" "manual HWID enabled but HWID is empty"

cat >"$WORK_DIR/bad-latency-url.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "latency_test_url": "ftp://example.com/ping"
  },
  "section": []
}
JSON
assert_rejects "bad latency URL" "$WORK_DIR/bad-latency-url.json" "settings.latency_test_url"

cat >"$WORK_DIR/bad-urltest-tolerance.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "urltest_enabled": "1",
      "urltest_tolerance": "10001"
    }
  ]
}
JSON
assert_rejects "bad URLTest tolerance" "$WORK_DIR/bad-urltest-tolerance.json" "Use a number from 0 to 10000"

cat >"$WORK_DIR/bad-server-routing-bypass.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "bypass", ".type": "section", "enabled": "1", "action": "bypass" }
  ],
  "server": [
    { ".name": "srv", ".type": "server", "enabled": "1", "routing_mode": "section", "routing_section": "bypass" }
  ]
}
JSON
assert_rejects "bad server routing bypass" "$WORK_DIR/bad-server-routing-bypass.json" "unsupported action 'bypass'"

cat >"$WORK_DIR/bad-server-routing-block.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "block", ".type": "section", "enabled": "1", "action": "block" }
  ],
  "server": [
    { ".name": "srv", ".type": "server", "enabled": "1", "routing_mode": "section", "routing_section": "block" }
  ]
}
JSON
assert_rejects "bad server routing block" "$WORK_DIR/bad-server-routing-block.json" "unsupported action 'block'"

cat >"$WORK_DIR/bad-detour.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "first", ".type": "section", "enabled": "1", "action": "proxy", "outbound_detour_enabled": "1", "outbound_detour_section": "second" },
    { ".name": "second", ".type": "section", "enabled": "1", "action": "proxy", "outbound_detour_enabled": "1", "outbound_detour_section": "first" }
  ]
}
JSON
assert_rejects "bad detour" "$WORK_DIR/bad-detour.json" "creates a cycle"

cat >"$WORK_DIR/bad-list-reference.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "proxy", ".type": "section", "enabled": "1", "action": "proxy", "domain_ip_lists": [ "ftp://example.com/list.lst" ] }
  ]
}
JSON
assert_rejects "bad list reference" "$WORK_DIR/bad-list-reference.json" "Unknown plain list reference"

cat >"$WORK_DIR/bad-country.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "urltest_enabled": "1",
      "urltest_filter_mode": "include",
      "urltest_include_countries": [ "USA" ]
    }
  ]
}
JSON
assert_rejects "bad country" "$WORK_DIR/bad-country.json" "Invalid country code 'USA'"

provider_context="$(node -e 'const fs=require("fs"); const c=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); c.byedpi_installed=true; process.stdout.write(JSON.stringify(c));' "$WORK_DIR/context.json")"
cat >"$WORK_DIR/bad-byedpi.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": [ "77.88.8.8" ], "bootstrap_dns_server": [ "77.88.8.8" ] },
  "section": [
    { ".name": "bye", ".type": "section", "enabled": "1", "action": "byedpi", "byedpi_cmd_opts": "--port 1080 --disorder 3" }
  ]
}
JSON
if output="$(FORKOP_LIB="$FORKOP_LIB" ucode -L "$FORKOP_LIB" "$VALIDATOR" validate-runtime-fixture "$WORK_DIR/bad-byedpi.json" "$provider_context" 2>/dev/null)"; then
  fail "bad byedpi should be rejected"
fi
printf '%s\n' "$output" | grep -Fq "ByeDPI listen address and port are assigned" ||
  fail "bad byedpi: unexpected message '$output'"

runtime_lib="$WORK_DIR/runtime-lib"
mkdir -p "$runtime_lib"
ln -s "$FORKOP_LIB/core" "$runtime_lib/core"
ln -s "$FORKOP_LIB/config" "$runtime_lib/config"
ln -s "$FORKOP_LIB/subscription" "$runtime_lib/subscription"
ln -s "$FORKOP_LIB/providers" "$runtime_lib/providers"
touch "$WORK_DIR/ciadpi-provider"
cat >"$WORK_DIR/bad-byedpi-runtime-state.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": [ "77.88.8.8" ], "bootstrap_dns_server": [ "77.88.8.8" ] },
  "section": [
    { ".name": "bye", ".type": "section", "enabled": "1", "action": "byedpi", "byedpi_cmd_opts": "--port 1080 --disorder 3" }
  ]
}
JSON

env \
  COMMUNITY_SERVICES="discord" \
  BYEDPI_DEFAULT_CMD_OPTS="" \
  ZAPRET_DEFAULT_NFQWS_OPT="" \
  ZAPRET_LEGACY_DEFAULT_NFQWS_OPT="" \
  ZAPRET2_DEFAULT_NFQWS2_OPT="" \
  BYEDPI_BIN="$WORK_DIR/ciadpi-provider" \
  ZAPRET_PROVIDER_NFQWS_BIN="$WORK_DIR/missing-nfqws" \
  ZAPRET2_PROVIDER_NFQWS2_BIN="$WORK_DIR/missing-nfqws2" \
  ZAPRET_ROUTE_MARK_BASE="0x01000000" \
  ZAPRET_QUEUE_RANGE_SIZE="16" \
  ZAPRET2_ROUTE_MARK_BASE="0x02000000" \
  ZAPRET2_QUEUE_RANGE_SIZE="16" \
  NFT_FAKEIP_MARK="0x00000800" \
  NFT_OUTBOUND_MARK="0x00000400" \
  FORKOP_LIB="$runtime_lib" \
  ucode -L "$runtime_lib" "$VALIDATOR" validate-runtime-fixture "$WORK_DIR/bad-byedpi-runtime-state.json" "{}"
chmod 755 "$WORK_DIR/ciadpi-provider"
if output="$(env \
  COMMUNITY_SERVICES="discord" \
  BYEDPI_DEFAULT_CMD_OPTS="" \
  ZAPRET_DEFAULT_NFQWS_OPT="" \
  ZAPRET_LEGACY_DEFAULT_NFQWS_OPT="" \
  ZAPRET2_DEFAULT_NFQWS2_OPT="" \
  BYEDPI_BIN="$WORK_DIR/ciadpi-provider" \
  ZAPRET_PROVIDER_NFQWS_BIN="$WORK_DIR/missing-nfqws" \
  ZAPRET2_PROVIDER_NFQWS2_BIN="$WORK_DIR/missing-nfqws2" \
  ZAPRET_ROUTE_MARK_BASE="0x01000000" \
  ZAPRET_QUEUE_RANGE_SIZE="16" \
  ZAPRET2_ROUTE_MARK_BASE="0x02000000" \
  ZAPRET2_QUEUE_RANGE_SIZE="16" \
  NFT_FAKEIP_MARK="0x00000800" \
  NFT_OUTBOUND_MARK="0x00000400" \
  FORKOP_LIB="$runtime_lib" \
  ucode -L "$runtime_lib" "$VALIDATOR" validate-runtime-fixture "$WORK_DIR/bad-byedpi-runtime-state.json" "{}" 2>/dev/null)"; then
  fail "executable byedpi provider should enable strategy validation"
fi
printf '%s\n' "$output" | grep -Fq "ByeDPI listen address and port are assigned" ||
  fail "executable byedpi provider: unexpected message '$output'"

printf 'config validator runtime checks passed\n'
