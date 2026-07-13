#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  local label="$3"

  if ! grep -Fq "$expected" "$file"; then
    printf 'Output for %s:\n' "$label" >&2
    cat "$file" >&2
    fail "$label: expected to find $expected"
  fi
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  local label="$3"

  if grep -Fq "$unexpected" "$file"; then
    printf 'Output for %s:\n' "$label" >&2
    cat "$file" >&2
    fail "$label: did not expect to find $unexpected"
  fi
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
      "urltest_enabled": "1",
      "urltest_check_interval": "3m",
      "urltest_tolerance": "50",
      "urltest_testing_url": "https://www.gstatic.com/generate_204",
      "urltest_filter_mode": "disabled",
      "detect_server_country": "flag_emoji",
      "selector_proxy_links": [
        "vless://00000000-0000-4000-8000-000000000001@example.com:443?encryption=none&security=tls&sni=example.com#first",
        "vless://00000000-0000-4000-8000-000000000002@example.org:443?encryption=none&security=tls&sni=example.org#second"
      ]
    }
  ]
}
JSON

output="$WORK_DIR/config.json"
mkdir -p "$output.section-cache"
ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/generator.uc" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$output" "127.0.0.1"

urltest_count="$(ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let count = 0;
for (let outbound in cfg.outbounds || [])
    if (outbound && outbound.type == "urltest" && outbound.interrupt_exist_connections === true)
        count++;
print(count, "\n");
' "$output")"
[ "$urltest_count" = "1" ] ||
  fail "expected exactly one URLTest outbound with interrupt_exist_connections=true, got $urltest_count"

selector_count="$(ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let count = 0;
for (let outbound in cfg.outbounds || [])
    if (outbound && outbound.type == "selector" && outbound.interrupt_exist_connections === true)
        count++;
print(count, "\n");
' "$output")"
[ "$selector_count" = "1" ] ||
  fail "expected exactly one selector outbound with interrupt_exist_connections=true, got $selector_count"

assert_contains "$output" '"tag": "proxy-urltest-out"' "generated config"
assert_contains "$output" '"url": "https://www.gstatic.com/generate_204"' "generated config"
assert_contains "$output" '"interval": "3m"' "generated config"
assert_not_contains "$output" '"idle_timeout":' "generated config"

cat >"$WORK_DIR/multi-fixture.json" <<'JSON'
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
        "vless://00000000-0000-4000-8000-000000000001@example.com:443?encryption=none&security=tls&sni=example.com#first",
        "vless://00000000-0000-4000-8000-000000000002@example.org:443?encryption=none&security=tls&sni=example.org#second"
      ]
    }
  ],
  "urltest": [
    {
      ".name": "cfg010001",
      ".type": "urltest",
      "section": "proxy",
      "name": "Fast URLTest",
      "check_interval": "30s",
      "tolerance": "50",
      "testing_url": "https://fast.example/204",
      "idle_timeout": "45s",
      "interrupt_exist_connections": "0"
    },
    {
      ".name": "cfg010002",
      ".type": "urltest",
      "section": "proxy",
      "name": "Stable URLTest",
      "check_interval": "5m",
      "tolerance": "120",
      "testing_url": "https://stable.example/204",
      "interrupt_exist_connections": "1"
    }
  ]
}
JSON

multi_output="$WORK_DIR/multi-config.json"
mkdir -p "$multi_output.section-cache"
ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/generator.uc" generate-config-fixture \
  "$WORK_DIR/multi-fixture.json" "$multi_output" "127.0.0.1"

ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let cache = json(fs.readfile(ARGV[1]));
let fast = null;
let stable = null;
let selector = null;
for (let outbound in cfg.outbounds || []) {
    if (outbound && outbound.tag == "proxy-urltest-cfg010001-out")
        fast = outbound;
    if (outbound && outbound.tag == "proxy-urltest-cfg010002-out")
        stable = outbound;
    if (outbound && outbound.tag == "proxy-out")
        selector = outbound;
}
if (!fast || !stable)
    die("expected both configured URLTest outbounds\n");
if (fast.url != "https://fast.example/204" || fast.interval != "30s" || fast.idle_timeout != "45s")
    die("fast URLTest settings were not generated\n");
if (fast.interrupt_exist_connections !== false)
    die("fast URLTest interrupt flag should be false\n");
if (stable.url != "https://stable.example/204" || stable.interval != "5m" || stable.tolerance != 120)
    die("stable URLTest settings were not generated\n");
if (stable.interrupt_exist_connections !== true)
    die("stable URLTest interrupt flag should be true\n");
if (!selector || selector.outbounds[length(selector.outbounds || []) - 2] != "proxy-urltest-cfg010001-out" ||
    selector.outbounds[length(selector.outbounds || []) - 1] != "proxy-urltest-cfg010002-out")
    die("selector should include configured URLTests in list order\n");
if (cache.urltestGroups["proxy-urltest-cfg010001-out"].displayName != "Fast URLTest")
    die("fast URLTest display name was not cached\n");
if (cache.urltestGroups["proxy-urltest-cfg010002-out"].displayName != "Stable URLTest")
    die("stable URLTest display name was not cached\n");
' "$multi_output" "$multi_output.section-cache/proxy.json" || fail "multi URLTest settings regression"

printf 'URLTest interrupt checks passed\n'
