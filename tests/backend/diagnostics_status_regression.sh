#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIAGNOSTICS="$ROOT_DIR/podkop/files/usr/lib/diagnostics/status.uc"
DIAGNOSTICS_RUNTIME="$ROOT_DIR/podkop/files/usr/lib/diagnostics/runtime.uc"
PODKOP_BIN="$ROOT_DIR/podkop/files/usr/bin/podkop"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
CLI_UC="$PODKOP_BIN"
WORK_DIR="$(mktemp -d)"

status_ucode() {
  ucode -L "$PODKOP_LIB" "$DIAGNOSTICS" "$@"
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

[ ! -e "$PODKOP_LIB/status_diagnostics.sh" ] ||
  fail "status_diagnostics.sh shell owner must be removed"
grep -Fq 'get_system_info: [ "diagnostics/runtime.uc", "get-system-info", 0 ]' "$CLI_UC" ||
  fail "service/cli.uc must dispatch get_system_info through diagnostics/runtime.uc"
[ "$(PODKOP_VERSION=runtime-test ucode -L "$PODKOP_LIB" "$DIAGNOSTICS_RUNTIME" show-version)" = "runtime-test" ] ||
  fail "diagnostics/runtime.uc show-version mode failed"
if grep -n -E 'require\("uci"\)\.cursor|uci -q|uci", "show"|uci", "-q"' "$DIAGNOSTICS_RUNTIME" >/dev/null 2>&1; then
  fail "diagnostics/runtime.uc must use core.uci instead of owning direct UCI cursor or CLI calls"
fi

legacy_json="$(status_ucode service-status-json 1 0 ignored 1)"
JSON_VALUE="$legacy_json" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.status !== "running but disabled" || value.dns_configured !== 1) {
  console.error("legacy service-status-json call shape changed");
  process.exit(1);
}
NODE

{
  printf 'Tue Jun 30 11:00:00 2026 user.notice podkop-plus: [info] Starting Podkop Plus\n'
  for i in $(seq 1 4500); do
    printf 'Tue Jun 30 11:00:%02d 2026 daemon.info unrelated[%04d]: filler filler filler filler filler filler filler filler filler filler\n' "$((i % 60))" "$i"
  done
  printf 'Tue Jun 30 11:01:00 2026 user.notice podkop-plus: [info] large logread marker survived stdin transport\n'
} >"$WORK_DIR/large-logread.txt"
large_logs="$(PODKOP_LIB="$PODKOP_LIB" ucode -L "$PODKOP_LIB" "$DIAGNOSTICS_RUNTIME" podkop-logs-fixture <"$WORK_DIR/large-logread.txt")" ||
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
printf '%s\n' '{"delay":1}'
SH
chmod +x "$fake_bin/curl"
uci_state="$WORK_DIR/uci-state.txt"
cat >"$uci_state" <<'EOF'
podkop-plus.settings=settings
podkop-plus.settings.latency_test_url=https://latency.example/generate_204
EOF
FAKE_CURL_LOG="$WORK_DIR/fake-curl.log" \
PODKOP_UCI_STATE_FILE="$uci_state" \
PODKOP_LIB="$PODKOP_LIB" \
PATH="$fake_bin:$PATH" \
  ucode -L "$PODKOP_LIB" "$DIAGNOSTICS_RUNTIME" clash-api get_proxy_latency proxy-out 5000 >/dev/null ||
  fail "clash-api get_proxy_latency should use fake curl successfully"
grep -Fq "url=https://latency.example/generate_204" "$WORK_DIR/fake-curl.log" ||
  fail "clash-api latency check must use settings.latency_test_url"

latency_action_dir="$WORK_DIR/ui-state/latency-actions"
mkdir -p "$latency_action_dir"
latency_state="$latency_action_dir/latency-1.json"
printf '%s\n' '{"success":true,"running":true,"kind":"latency","latency_type":"proxy_list","section":"main","tag":"[]","started_at":100}' >"$latency_state"
FAKE_CURL_LOG="$WORK_DIR/fake-curl-latencies.log" \
PODKOP_UCI_STATE_FILE="$uci_state" \
PODKOP_LIB="$PODKOP_LIB" \
PODKOP_UI_LATENCY_ACTION_DIR="$latency_action_dir" \
PATH="$fake_bin:$PATH" \
  ucode -L "$PODKOP_LIB" "$DIAGNOSTICS_RUNTIME" clash-api get_proxy_latencies '["proxy-a","proxy-b"]' 5000 "$latency_state" >/dev/null ||
  fail "clash-api get_proxy_latencies should update latency progress"
JOB_STATE="$latency_state" node - <<'NODE'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.env.JOB_STATE, "utf8"));
if (!value.progress || value.progress.completed !== 2 || value.progress.total !== 2 || value.progress.failed !== 0) {
  console.error("latency progress after proxy list mismatch");
  process.exit(1);
}
NODE

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
  PODKOP_LIB="$PODKOP_LIB" ucode -L "$PODKOP_LIB" "$DIAGNOSTICS_RUNTIME" sing-box-standard-ports-listening-fixture >/dev/null ||
  fail "sing-box standard listeners should satisfy diagnostics"
if printf '%s\n' "$sing_box_netstat" | sed '/0.0.0.0:1602/d' |
  PODKOP_LIB="$PODKOP_LIB" ucode -L "$PODKOP_LIB" "$DIAGNOSTICS_RUNTIME" sing-box-standard-ports-listening-fixture >/dev/null 2>&1; then
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

printf 'diagnostics status regression checks passed\n'
