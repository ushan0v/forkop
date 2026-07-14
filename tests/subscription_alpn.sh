#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSER="$ROOT_DIR/forkop/files/usr/lib/subscription/parser.uc"
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

cat >"$WORK_DIR/valid-reality.json" <<'JSON'
{"outbounds":[{"type":"vless","tag":"valid-reality","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0"}}}]}
JSON
ucode "$PARSER" validate-subscription "$WORK_DIR/valid-reality.json" ||
  fail "valid REALITY public key must pass subscription validation"
cat >"$WORK_DIR/invalid-reality.json" <<'JSON'
{"outbounds":[{"type":"vless","tag":"invalid-reality","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abc"}}}]}
JSON
if ucode "$PARSER" validate-subscription "$WORK_DIR/invalid-reality.json"; then
  fail "invalid REALITY public key must fail before cache promotion"
fi

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

vless_encrypted_output="$(normalize_link "vless-encryption" "vless://$UUID@example.com:443?type=xhttp&encryption=mlkem768x25519plus.native.test&security=tls&fp=chrome&sni=example.com&path=%2Fxhttp#vless-encryption")"
assert_contains "$vless_encrypted_output" '"encryption": "mlkem768x25519plus.native.test"' "vless-encryption"

vless_none_output="$(normalize_link "vless-encryption-none" "vless://$UUID@example.com:443?type=xhttp&encryption=none&security=tls&fp=chrome&sni=example.com&path=%2Fxhttp#vless-encryption-none")"
assert_not_contains "$vless_none_output" '"encryption": "none"' "vless-encryption-none"

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
    encryption: mlkem768x25519plus.native.test
    tls: true
    network: ws
    alpn: [h2, http/1.1]
    ws-opts:
      path: /ws
YAML
ucode "$PARSER" normalize-clash-yaml "$clash_input" "$clash_output"
assert_contains "$clash_output" '"alpn": [ "http/1.1" ]' "clash-vless-ws"
assert_contains "$clash_output" '"encryption": "mlkem768x25519plus.native.test"' "clash-vless-ws"

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
                "encryption": "mlkem768x25519plus.native.test"
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
assert_contains "$xray_output" '"encryption": "mlkem768x25519plus.native.test"' "xray-vless-ws"

gzip_plain="$WORK_DIR/gzip-subscription.txt"
gzip_input="$WORK_DIR/gzip-subscription.txt.gz"
gzip_decoded="$WORK_DIR/gzip-decoded.txt.gz"
gzip_output="$WORK_DIR/gzip-normalized.json"
printf 'vless://%s@example.com:443?type=ws&%s&path=%%2Fws#gzip-vless\n' "$UUID" "$BASE_QUERY" > "$gzip_plain"
gzip -c "$gzip_plain" > "$gzip_input"
cp "$gzip_input" "$gzip_decoded"
ucode "$PARSER" try-decode-gzip-content "$gzip_decoded"
assert_contains "$gzip_decoded" 'gzip-vless' "gzip decode in place"
ucode "$PARSER" normalize-content-validated "$gzip_input" "$gzip_output"
assert_contains "$gzip_output" '"tag": "gzip-vless"' "gzip normalize validated"
assert_contains "$gzip_output" '"alpn": [ "http/1.1" ]' "gzip normalized ALPN"

printf 'subscription ALPN checks passed\n'
