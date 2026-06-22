#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PARSER="$ROOT_DIR/podkop/files/usr/lib/subscription_parser.uc"
FACADE="$ROOT_DIR/podkop/files/usr/lib/sing_box_config_facade.uc"
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

normalize_link() {
  local label="$1"
  local link="$2"
  local input="$WORK_DIR/$label.in"
  local output="$WORK_DIR/$label.json"

  printf '%s\n' "$link" > "$input"
  ucode "$PARSER" normalize-uri-list "$input" "$output"
  printf '%s\n' "$output"
}

assert_alpn() {
  local label="$1"
  local link="$2"
  local expected="$3"
  local output

  output="$(normalize_link "$label" "$link")"
  assert_contains "$output" "$expected" "$label"
}

UUID='00000000-0000-4000-8000-000000000001'
BASE_QUERY='encryption=none&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=example.com'

ws_output="$(normalize_link "vless-ws" "vless://$UUID@example.com:443?type=ws&$BASE_QUERY&path=%2Fws#vless-ws")"
assert_contains "$ws_output" '"transport": { "type": "ws"' "vless-ws"
assert_contains "$ws_output" '"alpn": [ "http/1.1" ]' "vless-ws"
assert_not_contains "$ws_output" '"alpn": [ "h2", "http/1.1" ]' "vless-ws"

assert_alpn \
  "vless-httpupgrade" \
  "vless://$UUID@example.com:443?type=httpupgrade&$BASE_QUERY&path=%2Fupgrade#vless-httpupgrade" \
  '"alpn": [ "http/1.1" ]'

assert_alpn \
  "vless-tcp" \
  "vless://$UUID@example.com:443?type=tcp&$BASE_QUERY#vless-tcp" \
  '"alpn": [ "h2", "http/1.1" ]'

assert_alpn \
  "vless-xhttp-default" \
  "vless://$UUID@example.com:443?type=xhttp&encryption=none&security=tls&fp=chrome&sni=example.com&path=%2Fxhttp#vless-xhttp-default" \
  '"alpn": [ "h2", "http/1.1" ]'

assert_alpn \
  "trojan-ws" \
  "trojan://password@example.com:443?type=ws&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=example.com&path=%2Fws#trojan-ws" \
  '"alpn": [ "http/1.1" ]'

vmess_json='{"v":"2","ps":"vmess-ws","add":"example.com","port":"443","id":"00000000-0000-4000-8000-000000000001","aid":"0","scy":"auto","net":"ws","type":"none","host":"example.com","path":"/ws","tls":"tls","sni":"example.com","alpn":"h2,http/1.1","fp":"chrome"}'
vmess_link="vmess://$(printf '%s' "$vmess_json" | base64 -w0)"
assert_alpn "vmess-ws" "$vmess_link" '"alpn": [ "http/1.1" ]'

clash_input="$WORK_DIR/clash.yaml"
clash_output="$WORK_DIR/clash.json"
cat > "$clash_input" <<'YAML'
proxies:
  - name: clash-vless-ws
    type: vless
    server: example.com
    port: 443
    uuid: 00000000-0000-4000-8000-000000000001
    tls: true
    network: ws
    alpn: [h2, http/1.1]
    ws-opts:
      path: /ws
YAML
ucode "$PARSER" normalize-clash-yaml "$clash_input" "$clash_output"
assert_contains "$clash_output" '"alpn": [ "http/1.1" ]' "clash-vless-ws"

xray_input="$WORK_DIR/xray.json"
xray_output="$WORK_DIR/xray-normalized.json"
cat > "$xray_input" <<'JSON'
{
  "outbounds": [
    {
      "protocol": "vless",
      "tag": "xray-vless-ws",
      "settings": {
        "vnext": [
          {
            "address": "example.com",
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
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "example.com",
          "alpn": [
            "h2",
            "http/1.1"
          ],
          "fingerprint": "chrome"
        },
        "wsSettings": {
          "path": "/ws",
          "headers": {
            "Host": "example.com"
          }
        }
      }
    }
  ]
}
JSON
ucode "$PARSER" normalize-content "$xray_input" "$xray_output"
assert_contains "$xray_output" '"alpn": [ "http/1.1" ]' "xray-vless-ws"
assert_not_contains "$xray_output" '"alpn": [ "h2", "http/1.1" ]' "xray-vless-ws"

facade_ws="$(ucode "$FACADE" tls-alpn-json-array "h2,http/1.1" ws)"
[ "$facade_ws" = '["http/1.1"]' ] || fail "facade ws: got $facade_ws"

facade_httpupgrade="$(ucode "$FACADE" tls-alpn-json-array "h2,http/1.1" httpupgrade)"
[ "$facade_httpupgrade" = '["http/1.1"]' ] || fail "facade httpupgrade: got $facade_httpupgrade"

facade_xhttp="$(ucode "$FACADE" tls-alpn-json-array "" xhttp)"
[ "$facade_xhttp" = '["h2","http/1.1"]' ] || fail "facade xhttp: got $facade_xhttp"

facade_grpc="$(ucode "$FACADE" tls-alpn-json-array "h2,http/1.1" grpc)"
[ "$facade_grpc" = '["h2","http/1.1"]' ] || fail "facade grpc: got $facade_grpc"

export PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
# shellcheck source=/dev/null
. "$PODKOP_LIB/helpers.sh"
# shellcheck source=/dev/null
. "$PODKOP_LIB/sing_box_config_manager.sh"
# shellcheck source=/dev/null
. "$PODKOP_LIB/sing_box_config_facade.sh"

manual_config='{"outbounds":[]}'
manual_ws="$(
  sing_box_cf_add_proxy_outbound \
    "$manual_config" \
    "manual" \
    "vless://$UUID@example.com:443?type=ws&$BASE_QUERY&path=%2Fws#manual-ws" \
    0
)"
manual_ws_output="$WORK_DIR/manual-ws.json"
printf '%s\n' "$manual_ws" > "$manual_ws_output"
assert_contains "$manual_ws_output" '"alpn": [ "http/1.1" ]' "manual-vless-ws"
assert_not_contains "$manual_ws_output" '"alpn": [ "h2", "http/1.1" ]' "manual-vless-ws"

manual_httpupgrade="$(
  sing_box_cf_add_proxy_outbound \
    "$manual_config" \
    "manual" \
    "vless://$UUID@example.com:443?type=httpupgrade&$BASE_QUERY&path=%2Fupgrade#manual-httpupgrade" \
    0
)"
manual_httpupgrade_output="$WORK_DIR/manual-httpupgrade.json"
printf '%s\n' "$manual_httpupgrade" > "$manual_httpupgrade_output"
assert_contains "$manual_httpupgrade_output" '"alpn": [ "http/1.1" ]' "manual-vless-httpupgrade"

printf 'subscription ALPN regression checks passed\n'
