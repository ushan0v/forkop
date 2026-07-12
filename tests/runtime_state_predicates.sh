#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
STATE_UC="$ROOT_DIR/forkop/files/usr/lib/service/state.uc"
NFT_UC="$ROOT_DIR/forkop/files/usr/lib/nft/apply.uc"
WORK_DIR="$(mktemp -d)"
export ZAPRET_DEFAULT_NFQWS_OPT="--default-zapret"
export ZAPRET2_DEFAULT_NFQWS2_OPT="--default-zapret2"
export BYEDPI_DEFAULT_CMD_OPTS="--default-bye"
export FORKOP_FAKE_INIT_CAPTURE="$WORK_DIR/pending-reload-init.args"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

md5_file() {
  md5sum "$1" | awk '{print $1}'
}

state_ucode() {
  ucode -L "$FORKOP_LIB" "$STATE_UC" "$@"
}

nft_ucode() {
  ucode -L "$FORKOP_LIB" "$NFT_UC" "$@"
}

state_ucode list-has-remote-references "local.lst https://example.com/list.txt" >/dev/null ||
  fail "remote reference should be detected"
if state_ucode list-has-remote-references "local.lst /tmp/list.txt" >/dev/null 2>&1; then
  fail "local-only references should not be remote"
fi

state_ucode list-has-remote-sing-box-rulesets "https://example.com/rules.srs" >/dev/null ||
  fail "remote sing-box ruleset should be detected"
if state_ucode list-has-remote-sing-box-rulesets "/tmp/rules.srs" >/dev/null 2>&1; then
  fail "local sing-box ruleset should not be remote"
fi

assert_eq "meta telegram discord" \
  "$(state_ucode filter-community-subnet-lists "geoblock meta telegram youtube discord")" \
  "community subnet list filter"

state_ucode community-service-has-subnet-list roblox >/dev/null ||
  fail "roblox should have subnet list"
if state_ucode community-service-has-subnet-list youtube >/dev/null 2>&1; then
  fail "youtube should not be a subnet-list community service"
fi

state_ucode rule-has-list-update-source 1 "youtube telegram" "" "" "" "" >/dev/null ||
  fail "community subnet service should require list update"
state_ucode rule-has-list-update-source 1 "" "https://example.com/domains.lst" "" "" "" >/dev/null ||
  fail "remote domain list should require list update"
state_ucode rule-has-list-update-source 1 "" "" "" "" "local.lst https://example.com/mixed.lst" >/dev/null ||
  fail "remote domain_ip list should require list update"
if state_ucode rule-has-list-update-source 0 "telegram" "https://example.com/domains.lst" "" "" "" >/dev/null 2>&1; then
  fail "disabled rule should not require list update"
fi

state_ucode rule-has-nft-list-update-source 1 "telegram" "" "" "" >/dev/null ||
  fail "community subnet service should require nft list update"
state_ucode rule-has-nft-list-update-source 1 "" "https://example.com/subnets.lst" "" "" >/dev/null ||
  fail "remote subnet list should require nft list update"
if state_ucode rule-has-nft-list-update-source 1 "" "" "" "local.lst" >/dev/null 2>&1; then
  fail "local-only domain_ip list should not require nft list update"
fi

state_ucode rule-has-subscription-update-source 1 "1h" >/dev/null ||
  fail "subscription proxy with update interval should require subscription update"
if state_ucode rule-has-subscription-update-source 1 "" >/dev/null 2>&1; then
  fail "empty subscription update interval should not require subscription update"
fi
if state_ucode rule-has-subscription-update-source 0 "1h" >/dev/null 2>&1; then
  fail "non-subscription proxy should not require subscription update"
fi

state_ucode time-sync-needed 2023 >/dev/null ||
  fail "time sync should be needed for invalid pre-2024 clock"
if state_ucode time-sync-needed 2024 >/dev/null 2>&1; then
  fail "time sync should not be needed for current clock"
fi

if state_ucode sing-box-pid-replaced-fixture 3285 3285 1 >/dev/null 2>&1; then
  fail "sing-box reload must not accept the old stable PID"
fi
if state_ucode sing-box-pid-replaced-fixture 3285 0 0 >/dev/null 2>&1; then
  fail "sing-box reload must not accept a missing replacement process"
fi
state_ucode sing-box-pid-replaced-fixture 3285 4127 1 >/dev/null ||
  fail "sing-box reload should accept a different live sing-box PID"
if state_ucode sing-box-pid-replaced-fixture 3285 4127 0 >/dev/null 2>&1; then
  fail "sing-box reload must reject a replacement PID owned by another executable"
fi
assert_eq "3285" \
  "$(state_ucode sing-box-reload-previous-pid-fixture 3285 old new)" \
  "changed sing-box config replacement PID"
assert_eq "0" \
  "$(state_ucode sing-box-reload-previous-pid-fixture 3285 same same)" \
  "unchanged sing-box config replacement PID"
assert_eq "0" \
  "$(state_ucode sing-box-reload-previous-pid-fixture missing old new)" \
  "missing sing-box PID replacement constraint"

PENDING_RELOAD_FILE="$WORK_DIR/reload.pending"
state_ucode mark-pending-reload "$PENDING_RELOAD_FILE" "reload_busy"
grep -Fxq "reason=reload_busy" "$PENDING_RELOAD_FILE" ||
  fail "pending reload reason should be written by ucode"
updated_at="$(sed -n 's/^updated_at=//p' "$PENDING_RELOAD_FILE")"
case "$updated_at" in
  ''|*[!0-9]*) fail "pending reload updated_at should be numeric, got '$updated_at'" ;;
esac
state_ucode consume-pending-reload "$PENDING_RELOAD_FILE" >/dev/null ||
  fail "pending reload should be consumed"
[ ! -e "$PENDING_RELOAD_FILE" ] ||
  fail "pending reload file should be removed after consume"
if state_ucode consume-pending-reload "$PENDING_RELOAD_FILE" >/dev/null 2>&1; then
  fail "missing pending reload should not be consumed"
fi

cat >"$WORK_DIR/fake-init" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >"$FORKOP_FAKE_INIT_CAPTURE"
SH
chmod +x "$WORK_DIR/fake-init"
state_ucode mark-pending-reload "$PENDING_RELOAD_FILE" "reload_busy"
state_ucode run-pending-reload-if-requested "$PENDING_RELOAD_FILE" "$WORK_DIR/fake-init"
for _ in $(seq 1 20); do
  [ -s "$FORKOP_FAKE_INIT_CAPTURE" ] && break
  sleep 0.1
done
assert_eq "reload" \
  "$(cat "$FORKOP_FAKE_INIT_CAPTURE")" \
  "pending reload should invoke init.d reload"
[ ! -e "$PENDING_RELOAD_FILE" ] ||
  fail "pending reload should be consumed when worker is started"

LOCK_DIR="$WORK_DIR/runtime.lock"
state_ucode acquire-runtime-dir-lock "$LOCK_DIR" "$$" ||
  fail "ucode should acquire runtime dir lock"
assert_eq "$$" "$(cat "$LOCK_DIR/pid")" "runtime lock owner pid"
if state_ucode acquire-runtime-dir-lock "$LOCK_DIR" "$$" >/dev/null 2>&1; then
  fail "ucode should reject a lock held by a live pid"
fi
if state_ucode acquire-runtime-dir-lock-wait "$LOCK_DIR" "$$" 0 >/dev/null 2>&1; then
  fail "ucode wait lock should time out for a live holder"
fi
state_ucode release-runtime-dir-lock "$LOCK_DIR"
[ ! -e "$LOCK_DIR" ] ||
  fail "ucode should remove runtime dir lock"

mkdir -p "$LOCK_DIR"
printf '%s\n' 999999 >"$LOCK_DIR/pid"
state_ucode acquire-runtime-dir-lock "$LOCK_DIR" "$$" ||
  fail "ucode should replace a stale runtime dir lock"
assert_eq "$$" "$(cat "$LOCK_DIR/pid")" "stale runtime lock owner pid"
state_ucode release-runtime-dir-lock "$LOCK_DIR"

SNAPSHOT_FILE="$WORK_DIR/reload-state.snapshot"
TARGET_RELOAD_STATE="$WORK_DIR/reload-state.target"
CACHE_DIR="$WORK_DIR/rule-cache"
mkdir -p "$CACHE_DIR"
printf 'format=1\nservice_trigger_signature=abc\n' >"$SNAPSHOT_FILE"
state_ucode write-captured-reload-state "$TARGET_RELOAD_STATE" "$SNAPSHOT_FILE" 1 "$CACHE_DIR" 1 1
assert_eq "format=1
service_trigger_signature=abc" "$(cat "$TARGET_RELOAD_STATE")" "captured reload state copy"
[ ! -e "$SNAPSHOT_FILE" ] ||
  fail "ucode should clear captured reload snapshot after final write"
[ ! -e "$CACHE_DIR" ] ||
  fail "ucode should clean rule condition cache after final reload state write"

printf 'format=1\n' >"$SNAPSHOT_FILE"
printf 'old=1\n' >"$TARGET_RELOAD_STATE"
printf 'stale=1\n' >"$TARGET_RELOAD_STATE.snapshot.100.200"
printf 'stale=1\n' >"$TARGET_RELOAD_STATE.snapshot.interrupted"
printf 'keep=1\n' >"$WORK_DIR/unrelated.snapshot.100.200"
state_ucode clear-reload-state "$TARGET_RELOAD_STATE" "$SNAPSHOT_FILE"
[ ! -e "$TARGET_RELOAD_STATE" ] ||
  fail "ucode should clear reload state file"
[ ! -e "$SNAPSHOT_FILE" ] ||
  fail "ucode should clear reload state snapshot file"
[ ! -e "$TARGET_RELOAD_STATE.snapshot.100.200" ] &&
  [ ! -e "$TARGET_RELOAD_STATE.snapshot.interrupted" ] ||
  fail "ucode should clear stale snapshots owned by the reload state file"
[ -e "$WORK_DIR/unrelated.snapshot.100.200" ] ||
  fail "ucode should preserve unrelated snapshot files"

cat >"$WORK_DIR/service-dns-state.json" <<'JSON'
{
  "settings": {
    "enable_badwan_interface_monitoring": "1",
    "badwan_monitored_interfaces": [ "wan", "wwan" ],
    "badwan_reload_delay": "3500",
    "dont_touch_dhcp": "1"
  },
  "dhcp_dnsmasq": {
    "server": [ "1.1.1.1#53", "8.8.8.8" ],
    "noresolv": "1",
    "cachesize": "0",
    "forkop_server": [ "127.0.0.42#53" ],
    "forkop_noresolv": "0",
    "forkop_cachesize": "1500"
  },
  "legacy_dnsmasq_present": true
}
JSON

cat >"$WORK_DIR/service-trigger.expected" <<'EOF_SERVICE_TRIGGER'
[settings.enable_badwan_interface_monitoring]
1
[settings.badwan_monitored_interfaces]
wan wwan
[settings.badwan_reload_delay]
3500
EOF_SERVICE_TRIGGER

cat >"$WORK_DIR/dnsmasq-signature.expected" <<'EOF_DNSMASQ_SIG'
[settings.dont_touch_dhcp]
1
[dhcp.@dnsmasq[0].server]
1.1.1.1#53 8.8.8.8
[dhcp.@dnsmasq[0].noresolv]
1
[dhcp.@dnsmasq[0].cachesize]
0
[dhcp.@dnsmasq[0].forkop_server]
127.0.0.42#53
[dhcp.@dnsmasq[0].forkop_noresolv]
0
[dhcp.@dnsmasq[0].forkop_cachesize]
1500
[dhcp.forkop.present]
1
EOF_DNSMASQ_SIG

assert_eq "$(md5_file "$WORK_DIR/service-trigger.expected")" \
  "$(state_ucode service-trigger-signature-fixture "$WORK_DIR/service-dns-state.json")" \
  "service trigger signature hash"
assert_eq "$(md5_file "$WORK_DIR/dnsmasq-signature.expected")" \
  "$(state_ucode dnsmasq-signature-fixture "$WORK_DIR/service-dns-state.json")" \
  "dnsmasq signature hash"
assert_eq "1" \
  "$(state_ucode dont-touch-dhcp-fixture "$WORK_DIR/service-dns-state.json")" \
  "dont_touch_dhcp value"

cat >"$WORK_DIR/service-trigger-disabled.json" <<'JSON'
{
  "settings": {
    "enable_badwan_interface_monitoring": "0",
    "badwan_monitored_interfaces": [ "wan" ],
    "badwan_reload_delay": "3500"
  }
}
JSON

cat >"$WORK_DIR/service-trigger-disabled.expected" <<'EOF_SERVICE_TRIGGER_DISABLED'
[settings.enable_badwan_interface_monitoring]
0
EOF_SERVICE_TRIGGER_DISABLED

assert_eq "$(md5_file "$WORK_DIR/service-trigger-disabled.expected")" \
  "$(state_ucode service-trigger-signature-fixture "$WORK_DIR/service-trigger-disabled.json")" \
  "disabled service trigger signature hash"
assert_eq "0" \
  "$(state_ucode dont-touch-dhcp-fixture "$WORK_DIR/service-trigger-disabled.json")" \
  "default dont_touch_dhcp value"

cat >"$WORK_DIR/service-trigger-default-delay.json" <<'JSON'
{
  "settings": {
    "enable_badwan_interface_monitoring": "1",
    "badwan_monitored_interfaces": [ "wan" ]
  }
}
JSON

cat >"$WORK_DIR/service-trigger-default-delay.expected" <<'EOF_SERVICE_TRIGGER_DEFAULT_DELAY'
[settings.enable_badwan_interface_monitoring]
1
[settings.badwan_monitored_interfaces]
wan
[settings.badwan_reload_delay]
2000
EOF_SERVICE_TRIGGER_DEFAULT_DELAY

assert_eq "$(md5_file "$WORK_DIR/service-trigger-default-delay.expected")" \
  "$(state_ucode service-trigger-signature-fixture "$WORK_DIR/service-trigger-default-delay.json")" \
  "default badwan reload delay signature hash"

cat >"$WORK_DIR/sing-box-signature.json" <<'JSON'
{
  "settings": {
    "dns_type": "tcp",
    "dns_strategy": "prefer_ipv6",
    "dns_server": "9.9.9.9",
    "bootstrap_dns_server": "1.0.0.1",
    "dns_rewrite_ttl": "120",
    "output_network_interface": "wan",
    "disable_quic": "on",
    "list_update_enabled": "1",
    "update_interval": "2h",
    "cache_path": "/tmp/cache.db",
    "config_path": "/etc/sing-box/custom.json",
    "log_level": "debug",
    "service_listen_address": "127.0.0.1",
    "enable_yacd": "yes",
    "enable_yacd_wan_access": "1",
    "yacd_secret_key": "secret",
    "download_lists_via_proxy": "0",
    "download_subscriptions_via_proxy": "on",
    "download_components_via_proxy": "0",
    "download_lists_via_proxy_section": "proxy1"
  },
  "runtime": {
    "mwan3_active": "1"
  },
  "section": [
    {
      ".name": "disabled_proxy",
      ".type": "section",
      "enabled": "0",
      "action": "proxy",
      "selector_proxy_links": [ "ignored" ]
    },
    {
      ".name": "proxy1",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "selector_proxy_links": [ "vless://one", "vless://two" ],
      "subscription_urls": [ "https://example.com/sub.txt" ],
      "subscription_url_settings": "{\"https://example.com/sub.txt\":{\"prefix_nodes\":\"1\",\"node_prefix\":\"Example\"}}",
      "urltest_enabled": "1",
      "detect_server_country": "1",
      "urltest_tolerance": "75",
      "urltest_filter_mode": "exclude",
      "urltest_exclude_countries": [ "RU" ],
      "urltest_include_outbounds": [ "node-a" ],
      "subscription_update_enabled": "1",
      "outbound_detour_enabled": "1",
      "outbound_detour_section": "out1",
      "mixed_proxy_enabled": "1",
      "mixed_proxy_port": "2080",
      "mixed_proxy_auth_enabled": "1",
      "mixed_proxy_username": "user",
      "mixed_proxy_password": "pass",
      "resolve_real_ip_for_routing": "1",
      "domain": [ "legacy.example" ],
      "domain_suffix": [ "full:full.example", "suffix.example" ],
      "domain_keyword": [ "ads" ],
      "domain_regex": [ "^foo" ],
      "ip_cidr": [ "203.0.113.1", "bad" ],
      "source_ip_cidr": [ "198.51.100.0/24" ],
      "ports": [ "443" ],
      "ports_text": "80,443-444",
      "fully_routed_ips": [ "198.51.100.2" ],
      "community_lists": [ "telegram" ],
      "rule_set": [ "https://example.com/remote.srs" ],
      "rule_set_with_subnets": [ "local.srs" ],
      "domain_ip_lists": [ "local.lst" ]
    },
    {
      ".name": "out1",
      ".type": "section",
      "enabled": "1",
      "action": "outbound",
      "outbound_json": "{\"type\":\"direct\"}",
      "outbound_detour_enabled": "0",
      "mixed_proxy_enabled": "0",
      "resolve_real_ip_for_routing": "0"
    },
    {
      ".name": "bye1",
      ".type": "section",
      "enabled": "1",
      "action": "byedpi",
      "mixed_proxy_enabled": "0"
    },
    {
      ".name": "vpn1",
      ".type": "section",
      "enabled": "1",
      "action": "vpn",
      "interface": "wg0",
      "mixed_proxy_enabled": "0",
      "resolve_real_ip_for_routing": "yes"
    }
  ],
  "section_interface": [
    {
      ".name": "vpn-interface",
      ".type": "section_interface",
      "section": "vpn1",
      "name": "wg0",
      "domain_resolver_enabled": "1",
      "domain_resolver_dns_type": "doh",
      "domain_resolver_dns_server": "https://dns.example/dns-query"
    }
  ],
  "server": [
    {
      ".name": "srv_disabled",
      ".type": "server",
      "enabled": "0",
      "label": "ignored"
    },
    {
      ".name": "srv1",
      ".type": "server",
      "enabled": "1",
      "listen_port": "8443",
      "server_users": [ "alice", "bob" ],
      "tls_server_name": "example.com",
      "transport": "ws",
      "transport_path": "/ws",
      "tailscale_accept_routes": "1"
    }
  ]
}
JSON

cat >"$WORK_DIR/sing-box-signature.expected" <<'EOF_SING_BOX_SIG'
[settings.dns_type]
tcp
[settings.dns_strategy]
prefer_ipv6
[settings.dns_server]
9.9.9.9
[settings.bootstrap_dns_server]
1.0.0.1
[settings.dns_check_interval]
10s
[settings.dns_recovery_check_interval]
60s
[settings.dns_check_timeout]
2s
[settings.dns_detour_enabled]
0
[settings.dns_rewrite_ttl]
120
[settings.output_network_interface]
wan
[settings.disable_quic]
1
[settings.update_interval]
2h
[settings.cache_path]
/tmp/cache.db
[settings.config_path]
/etc/sing-box/custom.json
[settings.log_level]
debug
[settings.service_listen_address]
127.0.0.1
[runtime.mwan3_active]
1
[settings.enable_yacd]
1
[settings.enable_yacd_wan_access]
1
[settings.yacd_secret_key]
secret
[settings.download_lists_via_proxy]
0
[settings.download_components_via_proxy]
0
[rule.proxy1.action]
proxy
[rule.proxy1.connection_urls]
[ "vless://one", "vless://two" ]
[rule.proxy1.subscription_urls]
[ { "url": "https://example.com/sub.txt", "subscription_update_enabled": "1", "subscription_update_interval": "1h", "download_via_proxy_section": "", "auto_user_agent": "1", "user_agent": "", "auto_hwid": "1", "hwid": "", "show_dashboard_metadata": "1", "prefix_nodes": "1", "node_prefix": "Example", "include_urltest_groups": "1", "hide_urltest_group_outbounds": "1", "hide_detour_outbounds": "1" } ]
[rule.proxy1.interfaces]
[ ]
[rule.proxy1.outbound_jsons]

[rule.proxy1.legacy_interface]

[rule.proxy1.legacy_outbound_json]

[rule.proxy1.urltests]
[ { "id": "urltest", "display_name": "Fastest", "check_interval": "3m", "tolerance": "75", "testing_url": "https://www.gstatic.com/generate_204", "idle_timeout": "", "interrupt_exist_connections": "1", "pin_dashboard": "1", "hide_added_outbounds": "0", "filter_mode": "exclude", "detect_server_country": "1", "include_countries": [ ], "include_outbounds": [ "node-a" ], "include_regex": [ ], "exclude_countries": [ "RU" ], "exclude_outbounds": [ ], "exclude_regex": [ ] } ]
[rule.proxy1.priority_groups]
[ ]
[rule.proxy1.urltest_enabled]
1
[rule.proxy1.detect_server_country]
flag_emoji
[rule.proxy1.urltest_check_interval]
3m
[rule.proxy1.urltest_tolerance]
75
[rule.proxy1.urltest_testing_url]
https://www.gstatic.com/generate_204
[rule.proxy1.urltest_filter_mode]
exclude
[rule.proxy1.urltest_exclude_countries]
RU
[rule.proxy1.urltest_include_countries]

[rule.proxy1.urltest_exclude_outbounds]

[rule.proxy1.urltest_exclude_regex]

[rule.proxy1.urltest_include_outbounds]
node-a
[rule.proxy1.urltest_include_regex]

[rule.proxy1.subscription_update_interval]
1h
[rule.proxy1.outbound_detour_enabled]
1
[rule.proxy1.outbound_detour_section]
out1
[rule.proxy1.mixed_proxy_enabled]
1
[rule.proxy1.mixed_proxy_port]
2080
[rule.proxy1.mixed_proxy_auth_enabled]
1
[rule.proxy1.mixed_proxy_username]
user
[rule.proxy1.mixed_proxy_password]
pass
[rule.proxy1.resolve_real_ip_for_routing]
1
[rule.proxy1.domain]
full.example,legacy.example
[rule.proxy1.domain_suffix]
suffix.example
[rule.proxy1.domain_keyword]
ads
[rule.proxy1.domain_regex]
^foo
[rule.proxy1.ip_cidr]
203.0.113.1
[rule.proxy1.source_ip_cidr]
198.51.100.0/24
[rule.proxy1.ports]
443,80,443-444
[rule.proxy1.fully_routed_ips]
198.51.100.2
[rule.proxy1.community_lists]
telegram
[rule.proxy1.rule_set]
https://example.com/remote.srs
[rule.proxy1.rule_set_with_subnets]
local.srs
[rule.proxy1.domain_ip_lists]
local.lst
[rule.out1.action]
outbound
[rule.out1.connection_urls]
[ ]
[rule.out1.subscription_urls]
[ ]
[rule.out1.interfaces]
[ ]
[rule.out1.outbound_jsons]

[rule.out1.legacy_interface]

[rule.out1.legacy_outbound_json]
{"type":"direct"}
[rule.out1.urltests]
[ ]
[rule.out1.priority_groups]
[ ]
[rule.out1.urltest_enabled]
0
[rule.out1.detect_server_country]
flag_emoji
[rule.out1.urltest_check_interval]

[rule.out1.urltest_tolerance]
50
[rule.out1.urltest_testing_url]
https://www.gstatic.com/generate_204
[rule.out1.urltest_filter_mode]
disabled
[rule.out1.urltest_exclude_countries]

[rule.out1.urltest_include_countries]

[rule.out1.urltest_exclude_outbounds]

[rule.out1.urltest_exclude_regex]

[rule.out1.urltest_include_outbounds]

[rule.out1.urltest_include_regex]

[rule.out1.subscription_update_interval]

[rule.out1.outbound_detour_enabled]
0
[rule.out1.mixed_proxy_enabled]
0
[rule.out1.resolve_real_ip_for_routing]
0
[rule.out1.domain]

[rule.out1.domain_suffix]

[rule.out1.domain_keyword]

[rule.out1.domain_regex]

[rule.out1.ip_cidr]

[rule.out1.source_ip_cidr]

[rule.out1.ports]

[rule.out1.fully_routed_ips]

[rule.out1.community_lists]

[rule.out1.rule_set]

[rule.out1.rule_set_with_subnets]

[rule.out1.domain_ip_lists]

[rule.bye1.action]
byedpi
[rule.bye1.byedpi_index]
1
[rule.bye1.mixed_proxy_enabled]
0
[rule.bye1.resolve_real_ip_for_routing]
1
[rule.bye1.domain]

[rule.bye1.domain_suffix]

[rule.bye1.domain_keyword]

[rule.bye1.domain_regex]

[rule.bye1.ip_cidr]

[rule.bye1.source_ip_cidr]

[rule.bye1.ports]

[rule.bye1.fully_routed_ips]

[rule.bye1.community_lists]

[rule.bye1.rule_set]

[rule.bye1.rule_set_with_subnets]

[rule.bye1.domain_ip_lists]

[rule.vpn1.action]
vpn
[rule.vpn1.connection_urls]
[ ]
[rule.vpn1.subscription_urls]
[ ]
[rule.vpn1.interfaces]
[ { "name": "wg0", "domain_resolver_enabled": "1", "domain_resolver_dns_type": "doh", "domain_resolver_dns_server": "https://dns.example/dns-query" } ]
[rule.vpn1.outbound_jsons]

[rule.vpn1.legacy_interface]
wg0
[rule.vpn1.legacy_outbound_json]

[rule.vpn1.urltests]
[ ]
[rule.vpn1.priority_groups]
[ ]
[rule.vpn1.urltest_enabled]
0
[rule.vpn1.detect_server_country]
flag_emoji
[rule.vpn1.urltest_check_interval]

[rule.vpn1.urltest_tolerance]
50
[rule.vpn1.urltest_testing_url]
https://www.gstatic.com/generate_204
[rule.vpn1.urltest_filter_mode]
disabled
[rule.vpn1.urltest_exclude_countries]

[rule.vpn1.urltest_include_countries]

[rule.vpn1.urltest_exclude_outbounds]

[rule.vpn1.urltest_exclude_regex]

[rule.vpn1.urltest_include_outbounds]

[rule.vpn1.urltest_include_regex]

[rule.vpn1.subscription_update_interval]

[rule.vpn1.outbound_detour_enabled]
0
[rule.vpn1.mixed_proxy_enabled]
0
[rule.vpn1.resolve_real_ip_for_routing]
1
[rule.vpn1.domain]

[rule.vpn1.domain_suffix]

[rule.vpn1.domain_keyword]

[rule.vpn1.domain_regex]

[rule.vpn1.ip_cidr]

[rule.vpn1.source_ip_cidr]

[rule.vpn1.ports]

[rule.vpn1.fully_routed_ips]

[rule.vpn1.community_lists]

[rule.vpn1.rule_set]

[rule.vpn1.rule_set_with_subnets]

[rule.vpn1.domain_ip_lists]

[server.srv_disabled.enabled]
0
[server.srv1.enabled]
1
[server.srv1.label]
srv1
[server.srv1.protocol]
vless
[server.srv1.listen]
0.0.0.0
[server.srv1.listen_port]
8443
[server.srv1.public_host]

[server.srv1.inbound_json]

[server.srv1.routing_mode]
rules
[server.srv1.routing_section]

[server.srv1.security]
reality
[server.srv1.server_users]
alice bob
[server.srv1.tls_server_name]
example.com
[server.srv1.tls_alpn]

[server.srv1.tls_certificate_path]

[server.srv1.tls_key_path]

[server.srv1.reality_handshake_server]

[server.srv1.reality_handshake_server_port]

[server.srv1.reality_private_key]

[server.srv1.reality_public_key]

[server.srv1.reality_short_id]

[server.srv1.reality_max_time_difference]

[server.srv1.transport]
ws
[server.srv1.transport_path]
/ws
[server.srv1.transport_host]

[server.srv1.transport_service_name]

[server.srv1.transport_hosts]

[server.srv1.transport_xhttp_mode]

[server.srv1.client_fingerprint]

[server.srv1.server_uuid]

[server.srv1.server_username]

[server.srv1.server_password]

[server.srv1.vless_flow]

[server.srv1.vmess_alter_id]

[server.srv1.shadowsocks_method]

[server.srv1.hysteria2_up_mbps]

[server.srv1.hysteria2_down_mbps]

[server.srv1.hysteria2_obfs_type]

[server.srv1.hysteria2_obfs_password]

[server.srv1.mtproto_secret]

[server.srv1.mtproto_faketls]

[server.srv1.mtproto_padding]

[server.srv1.mtproto_concurrency]

[server.srv1.mtproto_domain_fronting_port]

[server.srv1.mtproto_domain_fronting_ip]

[server.srv1.mtproto_domain_fronting_proxy_protocol]

[server.srv1.mtproto_prefer_ip]

[server.srv1.mtproto_auto_update]

[server.srv1.mtproto_allow_fallback_on_unknown_dc]

[server.srv1.mtproto_tolerate_time_skewness]

[server.srv1.mtproto_idle_timeout]

[server.srv1.mtproto_handshake_timeout]

[server.srv1.tailscale_auth_key]

[server.srv1.tailscale_control_url]

[server.srv1.tailscale_hostname]

[server.srv1.tailscale_accept_routes]
1
[server.srv1.tailscale_advertise_routes]

[server.srv1.tailscale_advertise_exit_node]

EOF_SING_BOX_SIG

assert_eq "$(md5_file "$WORK_DIR/sing-box-signature.expected")" \
  "$(state_ucode sing-box-signature-fixture "$WORK_DIR/sing-box-signature.json")" \
  "sing-box signature hash"

cat >"$WORK_DIR/dpi-signatures.json" <<'JSON'
{
  "section": [
    {
      ".name": "disabled_zap",
      ".type": "section",
      "enabled": "0",
      "action": "zapret",
      "nfqws_opt": "--disabled"
    },
    {
      ".name": "zap1",
      ".type": "section",
      "enabled": "1",
      "action": "zapret",
      "domain": [ "legacy.example" ],
      "domain_suffix": [ "full:full.example", "suffix.example", "keyword:ads" ],
      "domain_suffix_text": "full:textfull.example text-suffix.example",
      "community_lists": [ "telegram", "youtube" ],
      "rule_set": [ "https://example.com/zap.srs" ],
      "rule_set_with_subnets": [ "https://example.com/zap-sub.srs" ],
      "domain_ip_lists": [ "local.lst", "https://example.com/ip.lst" ],
      "user_domain_list_type": "dynamic",
      "user_domains": [ "dyn.example" ],
      "user_domains_text": "ignored.example",
      "local_domain_lists": [ "local-a" ],
      "remote_domain_lists": [ "remote-a" ]
    },
    {
      ".name": "zap2",
      ".type": "section",
      "enabled": "1",
      "action": "zapret2",
      "nfqws2_opt": "--z2\n opt",
      "domain": [ "z2.example" ],
      "domain_suffix": [ "z2-suffix.example" ],
      "community_lists": [ "discord" ],
      "rule_set": [ "https://example.com/zap2.srs" ],
      "rule_set_with_subnets": [ "https://example.com/zap2-sub.srs" ],
      "domain_ip_lists": [ "https://example.com/zap2-ip.lst" ],
      "user_domain_list_type": "text",
      "user_domains": [ "ignored-dyn.example" ],
      "user_domains_text": "text.example text2.example",
      "local_domain_lists": [ "local-b" ],
      "remote_domain_lists": [ "remote-b" ]
    },
    {
      ".name": "bye_disabled",
      ".type": "section",
      "enabled": "0",
      "action": "byedpi",
      "byedpi_cmd_opts": "--disabled"
    },
    {
      ".name": "bye1",
      ".type": "section",
      "enabled": "1",
      "action": "byedpi"
    },
    {
      ".name": "bye2",
      ".type": "section",
      "enabled": "1",
      "action": "byedpi",
      "byedpi_cmd_opts": "--disorder   3\n--fake-sni example.org"
    }
  ]
}
JSON

cat >"$WORK_DIR/zapret-queue.expected" <<'EOF_ZAPRET_QUEUE'
[zapret_queue.section]
zap1
EOF_ZAPRET_QUEUE

cat >"$WORK_DIR/zapret2-queue.expected" <<'EOF_ZAPRET2_QUEUE'
[zapret2_queue.section]
zap2
EOF_ZAPRET2_QUEUE

cat >"$WORK_DIR/zapret-runtime.expected" <<'EOF_ZAPRET_RUNTIME'
[zapret.zap1.nfqws_opt]
--default-zapret
[zapret.zap1.domain]
textfull.example,full.example,legacy.example
[zapret.zap1.domain_suffix]
text-suffix.example,suffix.example
[zapret.zap1.community_lists]
telegram youtube
[zapret.zap1.rule_set]
https://example.com/zap.srs
[zapret.zap1.rule_set_with_subnets]
https://example.com/zap-sub.srs
[zapret.zap1.domain_ip_lists]
local.lst https://example.com/ip.lst
[zapret.zap1.user_domain_list_type]
dynamic
[zapret.zap1.local_domain_lists]
local-a
[zapret.zap1.remote_domain_lists]
remote-a
[zapret.zap1.user_domains]
dyn.example
EOF_ZAPRET_RUNTIME

cat >"$WORK_DIR/zapret2-runtime.expected" <<'EOF_ZAPRET2_RUNTIME'
[zapret2.zap2.nfqws2_opt]
--z2 opt
[zapret2.zap2.domain]
z2.example
[zapret2.zap2.domain_suffix]
z2-suffix.example
[zapret2.zap2.community_lists]
discord
[zapret2.zap2.rule_set]
https://example.com/zap2.srs
[zapret2.zap2.rule_set_with_subnets]
https://example.com/zap2-sub.srs
[zapret2.zap2.domain_ip_lists]
https://example.com/zap2-ip.lst
[zapret2.zap2.user_domain_list_type]
text
[zapret2.zap2.local_domain_lists]
local-b
[zapret2.zap2.remote_domain_lists]
remote-b
[zapret2.zap2.user_domains]
text.example text2.example
EOF_ZAPRET2_RUNTIME

cat >"$WORK_DIR/byedpi-runtime.expected" <<'EOF_BYEDPI_RUNTIME'
[byedpi.bye1.index]
1
[byedpi.bye1.byedpi_cmd_opts]
--default-bye
[byedpi.bye2.index]
2
[byedpi.bye2.byedpi_cmd_opts]
--disorder 3 --fake-sni example.org
EOF_BYEDPI_RUNTIME

assert_eq "$(md5_file "$WORK_DIR/zapret-queue.expected")" \
  "$(state_ucode zapret-queue-signature-fixture "$WORK_DIR/dpi-signatures.json")" \
  "zapret queue signature hash"
assert_eq "$(md5_file "$WORK_DIR/zapret2-queue.expected")" \
  "$(state_ucode zapret2-queue-signature-fixture "$WORK_DIR/dpi-signatures.json")" \
  "zapret2 queue signature hash"
assert_eq "$(md5_file "$WORK_DIR/zapret-runtime.expected")" \
  "$(state_ucode zapret-runtime-signature-fixture "$WORK_DIR/dpi-signatures.json")" \
  "zapret runtime signature hash"
assert_eq "$(md5_file "$WORK_DIR/zapret2-runtime.expected")" \
  "$(state_ucode zapret2-runtime-signature-fixture "$WORK_DIR/dpi-signatures.json")" \
  "zapret2 runtime signature hash"
assert_eq "$(md5_file "$WORK_DIR/byedpi-runtime.expected")" \
  "$(state_ucode byedpi-runtime-signature-fixture "$WORK_DIR/dpi-signatures.json")" \
  "byedpi runtime signature hash"

cat >"$WORK_DIR/reload-state-signatures.json" <<'JSON'
{
  "settings": {
    "list_update_enabled": "1",
    "update_interval": "6h",
    "component_update_check_enabled": "1",
    "component_update_check_interval": "2h"
  },
  "section": [
    {
      ".name": "disabled",
      ".type": "section",
      "enabled": "0",
      "action": "proxy",
      "ports": [ "1" ],
      "community_lists": [ "telegram" ],
      "remote_domain_lists": [ "https://example.com/disabled-domains.lst" ],
      "remote_subnet_lists": [ "https://example.com/disabled-subnets.lst" ],
      "rule_set_with_subnets": [ "https://example.com/disabled-subnets.srs" ],
      "domain_ip_lists": [ "https://example.com/disabled-mixed.lst" ],
      "subscription_urls": [ "https://example.com/disabled-sub.txt" ],
      "urltest_enabled": "1"
    },
    {
      ".name": "list_proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "ports": [ "443", "bad" ],
      "ports_text": "80,443-444 # comment\nbad-port",
      "community_lists": [ "geoblock", "meta", "telegram", "youtube", "discord" ],
      "remote_domain_lists": [ "https://example.com/domains.lst", "local-domains" ],
      "remote_subnet_lists": [ "https://example.com/subnets.lst" ],
      "rule_set_with_subnets": [ "https://example.com/subnets.srs" ],
      "domain_ip_lists": [ "local.lst", "https://example.com/mixed.lst" ],
      "subscription_urls": [ "https://example.com/sub1.txt", "https://example.com/sub2.txt" ],
      "urltest_enabled": "1"
    },
    {
      ".name": "sub_paused",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "subscription_urls": [ "https://example.com/off.txt" ],
      "subscription_update_enabled": "0"
    },
    {
      ".name": "implicit_action",
      ".type": "section",
      "enabled": "1",
      "subscription_urls": [ "https://example.com/implicit.txt" ],
      "urltest_enabled": "1"
    },
    {
      ".name": "urltest_custom",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "urltest_enabled": "1",
      "urltest_check_interval": "7m"
    }
  ]
}
JSON

cat >"$WORK_DIR/list-signature.expected" <<'EOF_LIST_SIG'
[lists.list_proxy.ports]
443,80,443-444
[lists.list_proxy.community_subnet_lists]
meta telegram discord
[lists.list_proxy.remote_domain_lists]
https://example.com/domains.lst local-domains
[lists.list_proxy.remote_subnet_lists]
https://example.com/subnets.lst
[lists.list_proxy.rule_set_with_subnets]
https://example.com/subnets.srs
[lists.list_proxy.domain_ip_lists]
local.lst https://example.com/mixed.lst
[lists.sub_paused.ports]

[lists.sub_paused.community_subnet_lists]

[lists.sub_paused.remote_domain_lists]

[lists.sub_paused.remote_subnet_lists]

[lists.sub_paused.rule_set_with_subnets]

[lists.sub_paused.domain_ip_lists]

[lists.implicit_action.ports]

[lists.implicit_action.community_subnet_lists]

[lists.implicit_action.remote_domain_lists]

[lists.implicit_action.remote_subnet_lists]

[lists.implicit_action.rule_set_with_subnets]

[lists.implicit_action.domain_ip_lists]

[lists.urltest_custom.ports]

[lists.urltest_custom.community_subnet_lists]

[lists.urltest_custom.remote_domain_lists]

[lists.urltest_custom.remote_subnet_lists]

[lists.urltest_custom.rule_set_with_subnets]

[lists.urltest_custom.domain_ip_lists]

EOF_LIST_SIG

cat >"$WORK_DIR/cron-signature.expected" <<'EOF_CRON_SIG'
[settings.update_interval]
6h
[settings.component_update_check_interval]
2h
[lists.list_proxy.ports]
443,80,443-444
[lists.list_proxy.community_subnet_lists]
meta telegram discord
[lists.list_proxy.remote_domain_lists]
https://example.com/domains.lst local-domains
[lists.list_proxy.remote_subnet_lists]
https://example.com/subnets.lst
[lists.list_proxy.rule_set_with_subnets]
https://example.com/subnets.srs
[lists.list_proxy.domain_ip_lists]
local.lst https://example.com/mixed.lst
[lists.sub_paused.ports]

[lists.sub_paused.community_subnet_lists]

[lists.sub_paused.remote_domain_lists]

[lists.sub_paused.remote_subnet_lists]

[lists.sub_paused.rule_set_with_subnets]

[lists.sub_paused.domain_ip_lists]

[lists.implicit_action.ports]

[lists.implicit_action.community_subnet_lists]

[lists.implicit_action.remote_domain_lists]

[lists.implicit_action.remote_subnet_lists]

[lists.implicit_action.rule_set_with_subnets]

[lists.implicit_action.domain_ip_lists]

[lists.urltest_custom.ports]

[lists.urltest_custom.community_subnet_lists]

[lists.urltest_custom.remote_domain_lists]

[lists.urltest_custom.remote_subnet_lists]

[lists.urltest_custom.rule_set_with_subnets]

[lists.urltest_custom.domain_ip_lists]

[subscription.list_proxy.subscription_urls]
[ { "url": "https://example.com/sub1.txt", "subscription_update_enabled": "1", "subscription_update_interval": "1h", "download_via_proxy_section": "", "auto_user_agent": "1", "user_agent": "", "auto_hwid": "1", "hwid": "", "show_dashboard_metadata": "1", "prefix_nodes": "0", "node_prefix": "", "include_urltest_groups": "1", "hide_urltest_group_outbounds": "1", "hide_detour_outbounds": "1" }, { "url": "https://example.com/sub2.txt", "subscription_update_enabled": "1", "subscription_update_interval": "1h", "download_via_proxy_section": "", "auto_user_agent": "1", "user_agent": "", "auto_hwid": "1", "hwid": "", "show_dashboard_metadata": "1", "prefix_nodes": "0", "node_prefix": "", "include_urltest_groups": "1", "hide_urltest_group_outbounds": "1", "hide_detour_outbounds": "1" } ]
[subscription.list_proxy.subscription_update_interval]
1h
[subscription.sub_paused.subscription_urls]
[ { "url": "https://example.com/off.txt", "subscription_update_enabled": "0", "subscription_update_interval": "1h", "download_via_proxy_section": "", "auto_user_agent": "1", "user_agent": "", "auto_hwid": "1", "hwid": "", "show_dashboard_metadata": "1", "prefix_nodes": "0", "node_prefix": "", "include_urltest_groups": "1", "hide_urltest_group_outbounds": "1", "hide_detour_outbounds": "1" } ]
[subscription.sub_paused.subscription_update_interval]

EOF_CRON_SIG

assert_eq "$(md5_file "$WORK_DIR/list-signature.expected")" \
  "$(state_ucode list-update-signature-fixture "$WORK_DIR/reload-state-signatures.json")" \
  "list update signature hash"
assert_eq "$(md5_file "$WORK_DIR/cron-signature.expected")" \
  "$(state_ucode cron-signature-fixture "$WORK_DIR/reload-state-signatures.json")" \
  "cron signature hash"
nft_signature="$(nft_ucode nft-runtime-signature-fixture "$WORK_DIR/reload-state-signatures.json")"
assert_eq "$nft_signature" \
  "$(state_ucode nft-signature-fixture "$WORK_DIR/reload-state-signatures.json")" \
  "state reload nft signature parity"
assert_eq "list_proxy urltest_custom" \
  "$(state_ucode urltest-enabled-sections-fixture "$WORK_DIR/reload-state-signatures.json")" \
  "urltest enabled sections"
assert_eq "6h" \
  "$(state_ucode settings-update-interval-fixture "$WORK_DIR/reload-state-signatures.json")" \
  "settings update interval"
assert_eq "1h" \
  "$(state_ucode subscription-update-interval-fixture "$WORK_DIR/reload-state-signatures.json" list_proxy)" \
  "default subscription update interval"
assert_eq "" \
  "$(state_ucode subscription-update-interval-fixture "$WORK_DIR/reload-state-signatures.json" sub_paused)" \
  "disabled subscription update interval"
assert_eq "3m" \
  "$(state_ucode urltest-check-interval-fixture "$WORK_DIR/reload-state-signatures.json" list_proxy)" \
  "default urltest check interval"
assert_eq "7m" \
  "$(state_ucode urltest-check-interval-fixture "$WORK_DIR/reload-state-signatures.json" urltest_custom)" \
  "custom urltest check interval"
state_ucode has-subscription-update-sources-fixture "$WORK_DIR/reload-state-signatures.json" >/dev/null ||
  fail "fixture should have subscription update sources"

cat >"$WORK_DIR/reload-state.expected" <<EOF_RELOAD_STATE
format=1
service_trigger_signature=$(state_ucode service-trigger-signature-fixture "$WORK_DIR/reload-state-signatures.json")
dnsmasq_signature=$(state_ucode dnsmasq-signature-fixture "$WORK_DIR/reload-state-signatures.json")
sing_box_signature=$(state_ucode sing-box-signature-fixture "$WORK_DIR/reload-state-signatures.json")
nft_signature=$nft_signature
zapret_queue_signature=$(state_ucode zapret-queue-signature-fixture "$WORK_DIR/reload-state-signatures.json")
zapret_runtime_signature=$(state_ucode zapret-runtime-signature-fixture "$WORK_DIR/reload-state-signatures.json")
zapret2_queue_signature=$(state_ucode zapret2-queue-signature-fixture "$WORK_DIR/reload-state-signatures.json")
zapret2_runtime_signature=$(state_ucode zapret2-runtime-signature-fixture "$WORK_DIR/reload-state-signatures.json")
byedpi_runtime_signature=$(state_ucode byedpi-runtime-signature-fixture "$WORK_DIR/reload-state-signatures.json")
list_signature=$(state_ucode list-update-signature-fixture "$WORK_DIR/reload-state-signatures.json")
cron_signature=$(state_ucode cron-signature-fixture "$WORK_DIR/reload-state-signatures.json")
urltest_enabled_sections=list_proxy urltest_custom
dont_touch_dhcp=$(state_ucode dont-touch-dhcp-fixture "$WORK_DIR/reload-state-signatures.json")
EOF_RELOAD_STATE

assert_eq "$(cat "$WORK_DIR/reload-state.expected")" \
  "$(state_ucode reload-state-text-fixture "$WORK_DIR/reload-state-signatures.json" 1)" \
  "reload state aggregate text"

cat >"$WORK_DIR/disabled-update-interval.json" <<'JSON'
{
  "settings": {
    "list_update_enabled": "0",
    "update_interval": "6h"
  }
}
JSON

assert_eq "" \
  "$(state_ucode settings-update-interval-fixture "$WORK_DIR/disabled-update-interval.json")" \
  "disabled settings update interval"

cat >"$WORK_DIR/empty-update-interval.json" <<'JSON'
{
  "settings": {
    "list_update_enabled": "1",
    "update_interval": ""
  }
}
JSON

assert_eq "1d" \
  "$(state_ucode settings-update-interval-fixture "$WORK_DIR/empty-update-interval.json")" \
  "empty settings update interval default"

cat >"$WORK_DIR/no-subscription-source.json" <<'JSON'
{
  "section": [
    {
      ".name": "implicit_action",
      ".type": "section",
      "enabled": "1",
      "subscription_urls": [ "https://example.com/implicit.txt" ]
    },
    {
      ".name": "paused",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "subscription_urls": [ "https://example.com/off.txt" ],
      "subscription_update_enabled": "0"
    }
  ]
}
JSON

if state_ucode has-subscription-update-sources-fixture "$WORK_DIR/no-subscription-source.json" >/dev/null 2>&1; then
  fail "implicit or disabled subscription updates should not require subscription update"
fi

cat >"$WORK_DIR/source-detection.json" <<'JSON'
{
  "section": [
    {
      ".name": "disabled",
      ".type": "section",
      "enabled": "0",
      "community_lists": [ "telegram" ],
      "remote_domain_lists": [ "https://example.com/disabled-domains.lst" ],
      "remote_subnet_lists": [ "https://example.com/disabled-subnets.lst" ],
      "rule_set": [ "https://example.com/disabled.srs" ],
      "domain_ip_lists": [ "https://example.com/disabled-mixed.lst" ]
    },
    {
      ".name": "general",
      ".type": "section",
      "enabled": "1",
      "remote_domain_lists": [ "https://example.com/domains.lst" ]
    },
    {
      ".name": "nft",
      ".type": "section",
      "remote_subnet_lists": [ "https://example.com/subnets.lst" ]
    },
    {
      ".name": "remote_ruleset",
      ".type": "section",
      "enabled": "1",
      "rule_set": [ "/tmp/local.srs", "https://example.com/remote.srs" ]
    }
  ]
}
JSON

state_ucode has-list-update-sources-fixture "$WORK_DIR/source-detection.json" >/dev/null ||
  fail "fixture should have general list update sources"
state_ucode has-nft-list-update-sources-fixture "$WORK_DIR/source-detection.json" >/dev/null ||
  fail "fixture should have nft list update sources"
state_ucode has-remote-sing-box-ruleset-sources-fixture "$WORK_DIR/source-detection.json" >/dev/null ||
  fail "fixture should have remote sing-box ruleset sources"

cat >"$WORK_DIR/general-only-source.json" <<'JSON'
{
  "section": [
    {
      ".name": "general",
      ".type": "section",
      "remote_domain_lists": [ "https://example.com/domains.lst" ]
    }
  ]
}
JSON

state_ucode has-list-update-sources-fixture "$WORK_DIR/general-only-source.json" >/dev/null ||
  fail "remote domain list should require general list update"
if state_ucode has-nft-list-update-sources-fixture "$WORK_DIR/general-only-source.json" >/dev/null 2>&1; then
  fail "remote domain list alone should not require nft list update"
fi

cat >"$WORK_DIR/disabled-only-source.json" <<'JSON'
{
  "section": [
    {
      ".name": "disabled",
      ".type": "section",
      "enabled": "0",
      "community_lists": [ "telegram" ],
      "remote_domain_lists": [ "https://example.com/domains.lst" ],
      "remote_subnet_lists": [ "https://example.com/subnets.lst" ],
      "rule_set": [ "https://example.com/remote.srs" ],
      "rule_set_with_subnets": [ "https://example.com/subnets.srs" ],
      "domain_ip_lists": [ "https://example.com/mixed.lst" ]
    }
  ]
}
JSON

if state_ucode has-list-update-sources-fixture "$WORK_DIR/disabled-only-source.json" >/dev/null 2>&1; then
  fail "disabled rule should not require general list update"
fi
if state_ucode has-nft-list-update-sources-fixture "$WORK_DIR/disabled-only-source.json" >/dev/null 2>&1; then
  fail "disabled rule should not require nft list update"
fi
if state_ucode has-remote-sing-box-ruleset-sources-fixture "$WORK_DIR/disabled-only-source.json" >/dev/null 2>&1; then
  fail "disabled rule should not require remote sing-box ruleset refresh"
fi

printf 'runtime state predicate checks passed\n'
