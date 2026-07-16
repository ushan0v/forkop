#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIAGNOSTICS="$ROOT_DIR/forkop/files/usr/lib/diagnostics/status.uc"
DIAGNOSTICS_RUNTIME="$ROOT_DIR/forkop/files/usr/lib/diagnostics/runtime.uc"
FORKOP_BIN="$ROOT_DIR/forkop/files/usr/bin/forkop"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
CLI_UC="$FORKOP_BIN"
WORK_DIR="$(mktemp -d)"

status_ucode() {
  ucode -L "$FORKOP_LIB" "$DIAGNOSTICS" "$@"
}

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_status() {
  local running="$1"
  local enabled="$2"
  local dns="$3"
  local expected="$4"
  local json

  json="$(status_ucode service-status-json "$running" "$enabled" "$dns")"
  JSON_VALUE="$json" node - "$expected" "$dns" <<'NODE'
const expected = process.argv[2];
const expectedDns = Number(process.argv[3]);
const value = JSON.parse(process.env.JSON_VALUE);
if (value.status !== expected || value.dns_configured !== expectedDns) {
  console.error(`expected ${expected}/${expectedDns}, got ${value.status}/${value.dns_configured}`);
  process.exit(1);
}
NODE
}

assert_status 1 1 1 "running & enabled"
assert_status 1 0 0 "running but disabled"
assert_status 0 1 1 "stopped but enabled"
assert_status 0 0 0 "stopped & disabled"

[ ! -e "$FORKOP_LIB/status_diagnostics.sh" ] ||
  fail "status_diagnostics.sh shell owner must be removed"
grep -Fq 'get_system_info: [ "diagnostics/runtime.uc", "get-system-info", 0 ]' "$CLI_UC" ||
  fail "service/cli.uc must dispatch get_system_info through diagnostics/runtime.uc"
[ "$(FORKOP_VERSION=runtime-test ucode -L "$FORKOP_LIB" "$DIAGNOSTICS_RUNTIME" show-version)" = "runtime-test" ] ||
  fail "diagnostics/runtime.uc show-version mode failed"
if grep -n -E 'require\("uci"\)\.cursor|uci -q|uci", "show"|uci", "-q"' "$DIAGNOSTICS_RUNTIME" >/dev/null 2>&1; then
  fail "diagnostics/runtime.uc must use core.uci instead of owning direct UCI cursor or CLI calls"
fi
grep -Fq '"forkop-stably-running", RT_TABLE_NAME, NFT_TABLE_NAME, NFT_FAKEIP_MARK, RUNTIME_STABLE_MIN_AGE' "$DIAGNOSTICS_RUNTIME" ||
  fail "diagnostics Forkop status must use stable runtime state to avoid crash-loop flicker"
grep -Fq '"sing-box-service-stable",' "$DIAGNOSTICS_RUNTIME" ||
  fail "diagnostics sing-box status must use stable runtime state to avoid crash-loop flicker"

capabilities="$(
  FORKOP_DIAGNOSTICS_SING_BOX_BIN_PATH="$WORK_DIR/missing-sing-box" \
  FORKOP_LIB="$FORKOP_LIB" \
    ucode -L "$FORKOP_LIB" "$DIAGNOSTICS_RUNTIME" get-server-capabilities
)"
JSON_VALUE="$capabilities" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.sing_box_extended !== 0 || value.sing_box_tiny !== 0 || value.sing_box_tailscale !== 0) {
  console.error('missing sing-box must not expose stale capabilities');
  process.exit(1);
}
NODE

masked_config="$WORK_DIR/forkop-masked"
cat >"$masked_config" <<'EOF'
config settings 'main'
        option hwid 'device-secret'
        option proxy_string 'vless://secret@example.com:443'
config subscription_url 'sub1'
        option url 'https://user:password@example.com/subscription?token=secret'
EOF
masked_output="$(status_ucode forkop-config-masked "$masked_config")"
case "$masked_output" in
  *device-secret*|*vless://secret*|*token=secret*|*user:password*) fail "masked Forkop config leaked a secret" ;;
esac
case "$masked_output" in
  *"option hwid 'MASKED'"*) ;;
  *) fail "masked Forkop config must preserve the HWID option shape" ;;
esac
case "$masked_output" in
  *"option url 'MASKED'"*) ;;
  *) fail "masked Forkop config must mask subscription section URLs" ;;
esac

wan_wireguard="$WORK_DIR/network-wireguard"
cat >"$wan_wireguard" <<'EOF'
config interface 'wan'
        option proto 'wireguard'
        option private_key 'wireguard-private-secret'
        option addresses '192.0.2.2/32'
config interface 'lan'
        option private_key 'not-in-wan'
EOF
wan_output="$(status_ucode wan-config-masked "$wan_wireguard")"
case "$wan_output" in
  *wireguard-private-secret*) fail "masked WAN config leaked the WireGuard private key" ;;
esac
case "$wan_output" in
  *"option private_key '******'"*) ;;
  *) fail "masked WAN config must preserve a masked WireGuard private key option" ;;
esac

legacy_json="$(status_ucode service-status-json 1 0 ignored 1)"
JSON_VALUE="$legacy_json" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.status !== "running but disabled" || value.dns_configured !== 1) {
  console.error("legacy service-status-json call shape changed");
  process.exit(1);
}
NODE

{
  printf 'Tue Jun 30 11:00:00 2026 user.notice forkop: [info] Starting Forkop\n'
  for i in $(seq 1 4500); do
    printf 'Tue Jun 30 11:00:%02d 2026 daemon.info unrelated[%04d]: filler filler filler filler filler filler filler filler filler filler\n' "$((i % 60))" "$i"
  done
  printf 'Tue Jun 30 11:01:00 2026 user.notice forkop: [info] large logread marker survived stdin transport\n'
} >"$WORK_DIR/large-logread.txt"
large_logs="$(FORKOP_LIB="$FORKOP_LIB" ucode -L "$FORKOP_LIB" "$DIAGNOSTICS_RUNTIME" forkop-logs-fixture <"$WORK_DIR/large-logread.txt")" ||
  fail "diagnostics/runtime.uc must process large logread payloads through stdin without shell argument limits"
case "$large_logs" in
  *"large logread marker survived stdin transport"*) ;;
  *) fail "large logread marker missing from rendered logs" ;;
esac

fake_bin="$WORK_DIR/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/curl" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
case "$*" in
  *'127.0.0.1:9090/proxies') printf '%s\n' '{"proxies":{"urltest":{"type":"URLTest"},"provider-urltest":{"type":"urltest"},"proxy-a":{"type":"VLESS"},"proxy-b":{"type":"Trojan"}}}' ;;
  *) printf '%s\n' '{"delay":1}' ;;
esac
SH
chmod +x "$fake_bin/curl"
uci_state="$WORK_DIR/uci-state.txt"
cat >"$uci_state" <<'EOF'
forkop.settings=settings
forkop.settings.latency_test_url=https://latency.example/generate_204
EOF
FAKE_CURL_LOG="$WORK_DIR/fake-curl.log" \
FORKOP_UCI_STATE_FILE="$uci_state" \
FORKOP_LIB="$FORKOP_LIB" \
PATH="$fake_bin:$PATH" \
  ucode -L "$FORKOP_LIB" "$DIAGNOSTICS_RUNTIME" clash-api get_proxy_latency proxy-out 5000 >/dev/null ||
  fail "clash-api get_proxy_latency should use fake curl successfully"
grep -Fq "url=https://latency.example/generate_204" "$WORK_DIR/fake-curl.log" ||
  fail "clash-api latency check must use settings.latency_test_url"

latency_action_dir="$WORK_DIR/ui-state/latency-actions"
mkdir -p "$latency_action_dir"
latency_state="$latency_action_dir/latency-1.json"
printf '%s\n' '{"success":true,"running":true,"kind":"latency","latency_type":"proxy_list","section":"main","tag":"[]","started_at":100}' >"$latency_state"
FAKE_CURL_LOG="$WORK_DIR/fake-curl-latencies.log" \
FORKOP_UCI_STATE_FILE="$uci_state" \
FORKOP_LIB="$FORKOP_LIB" \
FORKOP_UI_LATENCY_ACTION_DIR="$latency_action_dir" \
PATH="$fake_bin:$PATH" \
  ucode -L "$FORKOP_LIB" "$DIAGNOSTICS_RUNTIME" clash-api get_proxy_latencies '["urltest","proxy-a","provider-urltest","proxy-b"]' 5000 "$latency_state" >/dev/null ||
  fail "clash-api get_proxy_latencies should update latency progress"
JOB_STATE="$latency_state" node - <<'NODE'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.env.JOB_STATE, "utf8"));
if (!value.progress || value.progress.completed !== 4 || value.progress.total !== 4 || value.progress.failed !== 0) {
  console.error("latency progress after proxy list mismatch");
  process.exit(1);
}
NODE
expected_latency_paths=(
  '/proxies/proxy-a/delay'
  '/proxies/proxy-b/delay'
  '/group/urltest/delay'
  '/group/provider-urltest/delay'
)
for index in "${!expected_latency_paths[@]}"; do
  sed -n "$((index + 2))p" "$WORK_DIR/fake-curl-latencies.log" |
    grep -Fq "${expected_latency_paths[$index]}" ||
    fail "bulk latency must test ordinary proxies before URLTest groups"
done

firewall_rules="$(cat <<'EOF'
firewall.@rule[0]=rule
firewall.@rule[0].enabled='1'
firewall.@rule[0].target='ACCEPT'
firewall.@rule[0].src='wan'
firewall.@rule[0].proto='tcp udp'
firewall.@rule[0].dest_port='443'
EOF
)"

printf '%s\n' "$firewall_rules" |
  status_ucode firewall-required-protocols-open 443 "tcp udp" >/dev/null ||
  fail "tcp+udp firewall rule should satisfy required protocols"
if printf '%s\n' "$firewall_rules" |
  status_ucode firewall-required-protocols-open 8443 "tcp" >/dev/null 2>&1; then
  fail "wrong firewall port should not satisfy required protocols"
fi

firewall_src_port_rule="$(cat <<'EOF'
firewall.@rule[0]=rule
firewall.@rule[0].enabled='1'
firewall.@rule[0].target='ACCEPT'
firewall.@rule[0].src='wan'
firewall.@rule[0].proto='tcp'
firewall.@rule[0].src_port='12345'
firewall.@rule[0].dest_port='443'
EOF
)"
if printf '%s\n' "$firewall_src_port_rule" |
  status_ucode firewall-required-protocols-open 443 "tcp" >/dev/null 2>&1; then
  fail "firewall rule limited by source port should not satisfy public inbound diagnostic"
fi

status_ucode server-listen-requires-firewall 0.0.0.0 "" 0 >/dev/null ||
  fail "wildcard listen should require firewall"
status_ucode server-listen-requires-firewall :: "" 0 >/dev/null ||
  fail "IPv6 wildcard listen should require firewall"
status_ucode server-listen-requires-firewall 198.51.100.2 198.51.100.2 0 >/dev/null ||
  fail "WAN listen address should require firewall"
status_ucode server-listen-requires-firewall 2001:db8::2 "198.51.100.2 2001:db8::2" 0 >/dev/null ||
  fail "IPv6 WAN listen address should require firewall"
status_ucode server-listen-requires-firewall 203.0.113.2 "" 1 >/dev/null ||
  fail "public listen address should require firewall"
if status_ucode server-listen-requires-firewall 192.168.1.2 198.51.100.2 0 >/dev/null 2>&1; then
  fail "private non-WAN listen address should not require firewall"
fi

[ "$(status_ucode public-host-flags '' '' 8.8.8.8 1)" = "-1 -1 -1" ] ||
  fail "empty public host flags changed"
[ "$(status_ucode public-host-flags example.com '' 8.8.8.8 1)" = "0 -1 -1" ] ||
  fail "unresolved public host flags changed"
[ "$(status_ucode public-host-flags example.com '1.1.1.1 8.8.8.8' 8.8.8.8 1)" = "1 1 1" ] ||
  fail "public host WAN match flags changed"
[ "$(status_ucode public-host-flags example.com '192.168.1.10' 8.8.8.8 1)" = "1 0 0" ] ||
  fail "private public host flags changed"
[ "$(status_ucode public-host-flags example.com '8.8.8.8' 8.8.8.8 0)" = "1 1 -1" ] ||
  fail "non-public WAN host match flags changed"
[ "$(status_ucode public-host-flags example.com '2606:4700:4700::1111' '198.51.100.2 2606:4700:4700::1111' 1)" = "1 1 1" ] ||
  fail "IPv6 public host flags changed"

netstat_listening="$(cat <<'EOF'
Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address           Foreign Address         State
tcp        0      0 0.0.0.0:443             0.0.0.0:*               LISTEN
udp        0      0 0.0.0.0:443             0.0.0.0:*
EOF
)"

printf '%s\n' "$netstat_listening" |
  status_ucode server-required-ports-listening 0.0.0.0 443 "tcp udp" >/dev/null ||
  fail "tcp+udp netstat listeners should satisfy required protocols"
if printf '%s\n' "$netstat_listening" |
  status_ucode server-required-ports-listening 0.0.0.0 8443 "tcp" >/dev/null 2>&1; then
  fail "missing netstat listener should fail"
fi

netstat_listening6="$(cat <<'EOF'
Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address           Foreign Address         State
tcp        0      0 ::1:8443                :::*                    LISTEN
EOF
)"

printf '%s\n' "$netstat_listening6" |
  status_ucode server-required-ports-listening ::1 8443 "tcp" >/dev/null ||
  fail "IPv6 tcp netstat listener should satisfy required protocols"

sing_box_netstat="$(cat <<'EOF'
Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name
tcp        0      0 127.0.0.42:53           0.0.0.0:*               LISTEN      16244/sing-box
tcp        0      0 0.0.0.0:1602            0.0.0.0:*               LISTEN      16244/sing-box
tcp        0      0 ::1:1602                :::*                    LISTEN      16244/sing-box
udp        0      0 127.0.0.42:53           0.0.0.0:*                           16244/sing-box
udp        0      0 0.0.0.0:1602            0.0.0.0:*                           16244/sing-box
udp        0      0 ::1:1602                :::*                                16244/sing-box
EOF
)"

printf '%s\n' "$sing_box_netstat" |
  FORKOP_LIB="$FORKOP_LIB" ucode -L "$FORKOP_LIB" "$DIAGNOSTICS_RUNTIME" sing-box-standard-ports-listening-fixture >/dev/null ||
  fail "sing-box standard listeners should satisfy diagnostics"
if printf '%s\n' "$sing_box_netstat" | sed '/0.0.0.0:1602/d' |
  FORKOP_LIB="$FORKOP_LIB" ucode -L "$FORKOP_LIB" "$DIAGNOSTICS_RUNTIME" sing-box-standard-ports-listening-fixture >/dev/null 2>&1; then
  fail "missing sing-box tproxy listener should fail diagnostics"
fi

netstat_owners="$(cat <<'EOF'
Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name
tcp        0      0 0.0.0.0:443             0.0.0.0:*               LISTEN      111/nginx
udp        0      0 0.0.0.0:443             0.0.0.0:*                           222/dnsmasq
tcp        0      0 0.0.0.0:443             0.0.0.0:*               LISTEN      333/sing-box
EOF
)"

owners="$(printf '%s\n' "$netstat_owners" |
  status_ucode server-required-port-conflict-owners 0.0.0.0 443 "tcp udp")"
[ "$owners" = "111/nginx 222/dnsmasq" ] ||
  fail "unexpected conflict owners: $owners"

printf 'diagnostics status checks passed\n'
