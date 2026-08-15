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

generate_config() {
  local fixture="$1"
  local output="$2"

  mkdir -p "${output}.section-cache"
  ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/generator.uc" generate-config-fixture \
    "$fixture" "$output" "127.0.0.1"
}

# sing-box rejects a URLTest group whose interval exceeds its idle_timeout and
# substitutes its own 30m default when the option is omitted, so the generator
# has to raise idle_timeout to the check interval whenever it would be smaller.
cat >"$WORK_DIR/children.json" <<'JSON'
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
      "name": "Hourly",
      "check_interval": "1h",
      "tolerance": "50",
      "testing_url": "https://www.gstatic.com/generate_204",
      "idle_timeout": "30m",
      "interrupt_exist_connections": "1"
    },
    {
      ".name": "cfg010002",
      ".type": "urltest",
      "section": "proxy",
      "name": "Compound",
      "check_interval": "1h30m",
      "tolerance": "50",
      "testing_url": "https://www.gstatic.com/generate_204",
      "interrupt_exist_connections": "1"
    },
    {
      ".name": "cfg010003",
      ".type": "urltest",
      "section": "proxy",
      "name": "Short idle",
      "check_interval": "3m",
      "tolerance": "50",
      "testing_url": "https://www.gstatic.com/generate_204",
      "idle_timeout": "1m",
      "interrupt_exist_connections": "1"
    },
    {
      ".name": "cfg010004",
      ".type": "urltest",
      "section": "proxy",
      "name": "Explicit idle",
      "check_interval": "3m",
      "tolerance": "50",
      "testing_url": "https://www.gstatic.com/generate_204",
      "idle_timeout": "45m",
      "interrupt_exist_connections": "1"
    },
    {
      ".name": "cfg010005",
      ".type": "urltest",
      "section": "proxy",
      "name": "Default idle",
      "check_interval": "3m",
      "tolerance": "50",
      "testing_url": "https://www.gstatic.com/generate_204",
      "interrupt_exist_connections": "1"
    }
  ]
}
JSON

children_output="$WORK_DIR/children-config.json"
generate_config "$WORK_DIR/children.json" "$children_output"

ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let groups = {};
for (let outbound in cfg.outbounds || [])
    if (outbound && outbound.type == "urltest")
        groups[outbound.tag] = outbound;

let expected = {
    "proxy-urltest-cfg010001-out": [ "1h", "1h" ],
    "proxy-urltest-cfg010002-out": [ "1h30m", "1h30m" ],
    "proxy-urltest-cfg010003-out": [ "3m", "3m" ],
    "proxy-urltest-cfg010004-out": [ "3m", "45m" ]
};

for (let tag, values in expected) {
    let group = groups[tag];
    if (!group)
        die(sprintf("missing URLTest outbound %s\n", tag));
    if (group.interval != values[0])
        die(sprintf("%s: expected interval %s, got %s\n", tag, values[0], group.interval));
    if (group.idle_timeout != values[1])
        die(sprintf("%s: expected idle_timeout %s, got %s\n", tag, values[1], group.idle_timeout));
}

let relaxed = groups["proxy-urltest-cfg010005-out"];
if (!relaxed)
    die("missing URLTest outbound proxy-urltest-cfg010005-out\n");
if (relaxed.idle_timeout != null)
    die(sprintf("expected no idle_timeout below the sing-box default, got %s\n", relaxed.idle_timeout));
' "$children_output" || fail "URLTest child idle_timeout regression"

# Legacy section-level URLTest without child sections.
cat >"$WORK_DIR/legacy.json" <<'JSON'
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
      "urltest_check_interval": "1h30m",
      "urltest_tolerance": "50",
      "urltest_testing_url": "https://www.gstatic.com/generate_204",
      "urltest_filter_mode": "disabled",
      "selector_proxy_links": [
        "vless://00000000-0000-4000-8000-000000000001@example.com:443?encryption=none&security=tls&sni=example.com#first",
        "vless://00000000-0000-4000-8000-000000000002@example.org:443?encryption=none&security=tls&sni=example.org#second"
      ]
    }
  ]
}
JSON

legacy_output="$WORK_DIR/legacy-config.json"
generate_config "$WORK_DIR/legacy.json" "$legacy_output"

ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let group = null;
for (let outbound in cfg.outbounds || [])
    if (outbound && outbound.tag == "proxy-urltest-out")
        group = outbound;

if (!group)
    die("missing legacy URLTest outbound\n");
if (group.interval != "1h30m")
    die(sprintf("expected legacy interval 1h30m, got %s\n", group.interval));
if (group.idle_timeout != "1h30m")
    die(sprintf("expected legacy idle_timeout 1h30m, got %s\n", group.idle_timeout));
' "$legacy_output" || fail "legacy URLTest idle_timeout regression"

printf 'URLTest idle timeout checks passed\n'
