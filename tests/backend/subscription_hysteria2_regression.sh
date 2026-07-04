#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
PARSER="$ROOT_DIR/podkop/files/usr/lib/subscription/parser.uc"
GENERATOR="$ROOT_DIR/podkop/files/usr/lib/singbox/generator.uc"
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

normalize_link() {
  local label="$1"
  local link="$2"
  local input="$WORK_DIR/$label.in"
  local output="$WORK_DIR/$label.json"

  printf '%s\n' "$link" >"$input"
  ucode "$PARSER" normalize-uri-list "$input" "$output"
  printf '%s\n' "$output"
}

allow_insecure_output="$(
  normalize_link \
    "hy2-allow-insecure" \
    "hysteria2://pa%3Ass@example.com:443?allowInsecure=1&sni=example.com&obfs=salamander&obfs-password=obf#hy2-allow"
)"
assert_contains "$allow_insecure_output" '"type": "hysteria2"' "hy2 allowInsecure type"
assert_contains "$allow_insecure_output" '"password": "pa:ss"' "hy2 allowInsecure password"
assert_contains "$allow_insecure_output" '"server_name": "example.com"' "hy2 allowInsecure SNI"
assert_contains "$allow_insecure_output" '"insecure": true' "hy2 allowInsecure TLS"
assert_contains "$allow_insecure_output" '"obfs": { "type": "salamander", "password": "obf" }' "hy2 allowInsecure obfs"

insecure_output="$(
  normalize_link \
    "hy2-insecure" \
    "hy2://pw@example.com:443?insecure=1#hy2-insecure"
)"
assert_contains "$insecure_output" '"insecure": true' "hy2 insecure TLS"

singbox_input="$WORK_DIR/sing-box-hy2.json"
singbox_output="$WORK_DIR/sing-box-hy2-normalized.json"
cat >"$singbox_input" <<'JSON'
{
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "sing-box-hy2",
      "server": "example.com",
      "server_port": 443,
      "password": "pw",
      "tls": {
        "enabled": true,
        "server_name": "example.com",
        "alpn": [ "h3" ],
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        }
      }
    }
  ]
}
JSON
ucode "$PARSER" normalize-content "$singbox_input" "$singbox_output"
assert_contains "$singbox_output" '"type": "hysteria2"' "sing-box HY2 type"
assert_contains "$singbox_output" '"alpn": [ "h3" ]' "sing-box HY2 ALPN"
if grep -Fq '"utls"' "$singbox_output"; then
  cat "$singbox_output" >&2
  fail "sing-box Hysteria2 normalization must drop TLS uTLS"
fi

mkdir -p "$WORK_DIR/subscriptions"
cp "$singbox_output" "$WORK_DIR/subscriptions/proxy-subscription-1.json"
printf '%s' 'https://example.com/sub.json' >"$WORK_DIR/subscriptions/proxy-subscription-1.url"
printf '%s' 'Happ' >"$WORK_DIR/subscriptions/proxy-subscription-1.user_agent"

generator_fixture="$WORK_DIR/generator-fixture.json"
generator_output="$WORK_DIR/generator-config.json"
cat >"$generator_fixture" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_path": "/tmp/sing-box/config.json",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "subscription_urls": [ "https://example.com/sub.json" ],
      "domain_suffix": [ "example.org" ]
    }
  ]
}
JSON
TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions" \
  ucode -L "$PODKOP_LIB" "$GENERATOR" generate-config-fixture \
    "$generator_fixture" "$generator_output" "127.0.0.1" "0"
assert_contains "$generator_output" '"type": "hysteria2"' "generated stale HY2 type"
if grep -Fq '"utls"' "$generator_output"; then
  cat "$generator_output" >&2
  fail "sing-box generator must drop stale Hysteria2 TLS uTLS from subscription cache"
fi

printf 'subscription Hysteria2 regression checks passed\n'
