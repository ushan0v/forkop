#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_RUNTIME="$ROOT_DIR/forkop/files/usr/lib/server/service.uc"
UCODE_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
STATE="$WORK_DIR/uci.state"
LOG="$WORK_DIR/uci.log"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'UCI state:\n' >&2
  cat "$STATE" >&2 2>/dev/null || true
  printf 'UCI log:\n' >&2
  cat "$LOG" >&2 2>/dev/null || true
  exit 1
}

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/sing-box" <<'SINGBOX'
#!/usr/bin/env bash
set -eo pipefail

case "$*" in
  "generate uuid")
    printf '%s\n' '33333333-3333-4333-8333-333333333333'
    ;;
  "generate rand --base64 18")
    printf '%s\n' 'generated-password'
    ;;
  "generate rand --hex 4")
    printf '%s\n' 'abcd1234'
    ;;
  "generate rand --hex 16")
    printf '%s\n' '11111111111111111111111111111111'
    ;;
  "generate reality-keypair")
    printf 'PrivateKey: private-key\nPublicKey: public-key\n'
    ;;
  *)
    printf 'unsupported sing-box command: %s\n' "$*" >&2
    exit 2
    ;;
esac
SINGBOX
chmod 0755 "$WORK_DIR/bin/sing-box"

cat >"$WORK_DIR/bin/logger" <<'LOGGER'
#!/usr/bin/env bash
set -eo pipefail
exit 0
LOGGER
chmod 0755 "$WORK_DIR/bin/logger"

export PATH="$WORK_DIR/bin:$PATH"
export FORKOP_UCI_STATE_FILE="$STATE"
export FORKOP_UCI_LOG_FILE="$LOG"
export FORKOP_CONFIG_NAME="forkop"
export FORKOP_SERVER_RUNTIME_UC="$SERVER_RUNTIME"

if grep -E 'uci -q|command -v uci' "$SERVER_RUNTIME" >/dev/null; then
  fail "server/service.uc must use ucode UCI access instead of shelling out to uci"
fi
if grep -F 'output("ucode "' "$SERVER_RUNTIME" >/dev/null; then
  fail "server defaults must not spawn service.uc without the Forkop module path"
fi

cat >"$STATE" <<'EOF_STATE'
forkop.vless=server
forkop.vless.protocol=vless
forkop.vless.server_users=client|22222222-2222-4222-8222-222222222222|xtls-rprx-vision
forkop.socks=server
forkop.socks.protocol=socks
forkop.socks.label=desk
forkop.tailscale=server
forkop.tailscale.protocol=tailscale
forkop.json=server
forkop.json.protocol=json_inbound
forkop.mtproto=server
forkop.mtproto.protocol=mtproto
forkop.mtproto.mtproto_secret=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
forkop.mtproto_legacy=server
forkop.mtproto_legacy.protocol=mtproto
forkop.mtproto_legacy.server_users=client|eebbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb676f6f676c652e636f6d
EOF_STATE

ucode -L "$UCODE_LIB" "$SERVER_RUNTIME" prepare-all-defaults

uci_get() {
  awk -F= -v key="$1" '$1 == key { print substr($0, length($1) + 2); found = 1 } END { exit found ? 0 : 1 }' "$STATE"
}

assert_value() {
  local path="$1" expected="$2" actual
  actual="$(uci_get "$path" 2>/dev/null || true)"
  [ "$actual" = "$expected" ] || fail "$path: expected '$expected', got '$actual'"
}

assert_value forkop.vless.security reality
assert_value forkop.vless.listen 0.0.0.0
assert_value forkop.vless.listen_port 443
assert_value forkop.vless.server_uuid 22222222-2222-4222-8222-222222222222
assert_value forkop.vless.vless_flow xtls-rprx-vision
assert_value forkop.vless.reality_short_id abcd1234
assert_value forkop.vless.reality_private_key private-key
assert_value forkop.vless.reality_public_key public-key
assert_value forkop.socks.security none
assert_value forkop.socks.server_username desk
assert_value forkop.socks.server_password generated-password
assert_value forkop.tailscale.security none
assert_value forkop.tailscale.tailscale_control_url https://controlplane.tailscale.com
assert_value forkop.tailscale.tailscale_hostname forkop-tailscale
assert_value forkop.tailscale.tailscale_advertise_exit_node 1
assert_value forkop.json.security none
assert_value forkop.mtproto.mtproto_secret aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
assert_value forkop.mtproto_legacy.mtproto_secret bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
assert_value forkop.mtproto_legacy.mtproto_faketls google.com
grep -Fxq 'commit forkop' "$LOG" || fail 'expected config commit'

: >"$LOG"
ucode -L "$UCODE_LIB" "$SERVER_RUNTIME" prepare-all-defaults
[ ! -s "$LOG" ] || fail 'unchanged MTProto defaults must not rewrite or commit configuration on every reload'

printf 'server runtime checks passed\n'
