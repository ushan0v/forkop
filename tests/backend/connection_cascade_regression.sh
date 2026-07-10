#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
GENERATOR="$PODKOP_LIB/singbox/generator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/subscriptions" "$WORK_DIR/output.json.section-cache"

cat >"$WORK_DIR/subscriptions/source-subscription-1.json" <<'JSON'
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "nested-entry",
      "server": "192.0.2.10",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000001",
      "detour": "nested-relay"
    },
    {
      "type": "socks",
      "tag": "nested-relay",
      "server": "192.0.2.11",
      "server_port": 1080,
      "version": "5"
    },
    {
      "type": "trojan",
      "tag": "independent",
      "server": "192.0.2.12",
      "server_port": 443,
      "password": "secret"
    },
    {
      "type": "urltest",
      "tag": "provider-group",
      "outbounds": [ "nested-entry", "independent" ],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "3m",
      "__podkop_allow_group": true
    }
  ]
}
JSON
printf '%s\n' 'https://subscription.example/source' >"$WORK_DIR/subscriptions/source-subscription-1.url"
: >"$WORK_DIR/subscriptions/source-subscription-1.user_agent"

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "hop",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [ "socks5://127.0.0.1:1080#Hop" ]
    },
    {
      ".name": "source",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [ "socks5://127.0.0.1:1081#Manual" ],
      "interfaces": [ "wg0" ],
      "outbound_jsons": [
        "{\"type\":\"socks\",\"tag\":\"JSON plain\",\"server\":\"127.0.0.1\",\"server_port\":1082,\"version\":\"5\"}",
        "{\"type\":\"socks\",\"tag\":\"JSON explicit\",\"server\":\"127.0.0.1\",\"server_port\":1083,\"version\":\"5\",\"detour\":\"direct-out\"}"
      ],
      "outbound_detour_enabled": "1",
      "outbound_detour_section": "hop"
    }
  ],
  "subscription_url": [
    {
      ".name": "source_subscription",
      ".type": "subscription_url",
      "section": "source",
      "url": "https://subscription.example/source"
    }
  ]
}
JSON

TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions" \
  ucode -L "$PODKOP_LIB" "$GENERATOR" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$WORK_DIR/output.json" "127.0.0.1"

ucode -e '
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));

function outbound(tag) {
    for (let item in config.outbounds || [])
        if (item && item.tag == tag)
            return item;
    return null;
}

function assert(condition, message) {
    if (!condition)
        die(message + "\n");
}

assert(outbound("source-1-out").detour == "hop-out", "manual URL did not receive the section detour");
assert(outbound("nested-entry").detour == "nested-relay", "subscription detour was overwritten");
assert(outbound("nested-relay").detour == "hop-out", "section detour was not appended to the subscription chain");
assert(outbound("independent").detour == "hop-out", "independent subscription outbound did not receive the section detour");
assert(outbound("provider-group").detour == null, "subscription URLTest group must not receive Dial Fields");
assert(outbound("source-interface-1-out").bind_interface == "wg0", "interface binding was not preserved");
assert(outbound("source-interface-1-out").detour == null, "network interface must be excluded from section cascade");
assert(outbound("JSON plain").detour == null, "plain JSON outbound must be excluded from section cascade");
assert(outbound("JSON explicit").detour == "direct-out", "explicit JSON detour was not preserved");
assert(outbound("source-out").detour == null, "section selector must not receive its own detour");
' "$WORK_DIR/output.json" || fail "section cascade generation"

printf 'connection cascade regression checks passed\n'
