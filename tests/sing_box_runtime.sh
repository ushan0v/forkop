#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
FORKOP_BIN="$ROOT_DIR/forkop/files/usr/bin/forkop"
CLI_UC="$FORKOP_BIN"
SING_BOX_RUNTIME_SH="$FORKOP_LIB/sing_box_runtime.sh"
LIFECYCLE_UC="$FORKOP_LIB/service/lifecycle.uc"
SINGBOX_RUNTIME_UC="$FORKOP_LIB/singbox/runtime.uc"
SINGBOX_GENERATOR_UC="$FORKOP_LIB/singbox/generator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ ! -e "$SING_BOX_RUNTIME_SH" ] ||
  fail "sing_box_runtime.sh shell owner must be removed"
grep -Fq '#!/usr/bin/ucode' "$FORKOP_BIN" ||
  fail "forkop entrypoint must be a direct ucode executable"
grep -Fq 'service/lifecycle.uc' "$CLI_UC" ||
  fail "service/cli.uc must dispatch lifecycle orchestration through service/lifecycle.uc"
grep -Fq 'singbox/runtime.uc' "$LIFECYCLE_UC" ||
  fail "service/lifecycle.uc must call singbox/runtime.uc for sing-box runtime operations"
if grep -R -n -E 'sing_box_runtime_ucode|rulesets_ucode|sing_box_configure_service|sing_box_init_config|get_service_listen_address|get_device_ipv4_address|get_download_detour_tag' "$FORKOP_BIN" "$FORKOP_LIB" --include='*.sh' >/dev/null 2>&1; then
  fail "sing-box runtime shell symbols must not remain"
fi
grep -Fq 'mode == "configure-service"' "$SINGBOX_RUNTIME_UC" ||
  fail "singbox/runtime.uc must own sing-box service configuration"
grep -Fq 'mode == "init-config"' "$SINGBOX_RUNTIME_UC" ||
  fail "singbox/runtime.uc must own sing-box config initialization"
grep -Fq 'mode == "service-listen-address"' "$SINGBOX_RUNTIME_UC" ||
  fail "singbox/runtime.uc must own service listen address detection"
grep -Fq 'mode == "service-proxy-address"' "$SINGBOX_RUNTIME_UC" ||
  fail "singbox/runtime.uc must own service proxy address detection"
if grep -Fq 'log_file_lines(runtime_log, "debug", "sing-box config generator: ");' "$SINGBOX_RUNTIME_UC"; then
  fail "singbox/runtime.uc must not duplicate generator failure output as debug log"
fi
if grep -Fq 'warn("unsupported: "' "$SINGBOX_GENERATOR_UC"; then
  fail "singbox/generator.uc must emit concise generator failure reasons"
fi
if grep -n -E 'require\("uci"\)\.cursor|uci -q|uci", "-q"' "$SINGBOX_RUNTIME_UC" >/dev/null 2>&1; then
  fail "singbox/runtime.uc must use core.uci instead of owning direct UCI cursor or CLI calls"
fi
if grep -n -E 'require\("uci"\)\.cursor|uci -q|uci", "-q"' "$SINGBOX_GENERATOR_UC" >/dev/null 2>&1; then
  fail "singbox/generator.uc must use core.uci instead of owning direct UCI cursor or CLI calls"
fi
grep -Fq 'require("core.uci")' "$SINGBOX_GENERATOR_UC" ||
  fail "singbox/generator.uc must import core.uci"
grep -Fq 'FORKOP_RULE_CONDITION_CACHE_DIR' "$LIFECYCLE_UC" ||
  fail "service/lifecycle.uc must pass rule-condition cache dir through module environment"
if awk '
/"write-current-reload-state-clean"|"write-captured-reload-state"/ {
  in_block = 1
  bad = 0
}
in_block && /SECTION_CACHE_DIR/ {
  bad = 1
}
in_block && /\]\);/ {
  if (bad)
    found_bad = 1
  in_block = 0
}
END {
  exit found_bad ? 0 : 1
}
' "$LIFECYCLE_UC"; then
  fail "reload-state cleanup must not delete subscription section-cache"
fi

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/sing-box" <<'EOF_SING_BOX'
#!/bin/sh
echo 'sing-box version 1.12.25'
EOF_SING_BOX
chmod +x "$WORK_DIR/bin/sing-box"
stable_variant="$({
  PATH="$WORK_DIR/bin:$PATH" \
    FORKOP_LIB="$FORKOP_LIB" \
    SB_VARIANT_STATE_FILE="$WORK_DIR/sing-box-variant" \
    ucode -L "$FORKOP_LIB" "$SINGBOX_RUNTIME_UC" variant
} 2>"$WORK_DIR/stable-variant.stderr")" ||
  fail "singbox/runtime.uc must detect a stable binary without a ucode call-order failure"
[ "$stable_variant" = "stable" ] ||
  fail "singbox/runtime.uc should classify a regular sing-box binary as stable"
[ ! -s "$WORK_DIR/stable-variant.stderr" ] ||
  fail "stable sing-box variant detection must not emit ucode runtime errors"

mkdir -p "$WORK_DIR/check-bin"
cat >"$WORK_DIR/check-bin/sing-box" <<'EOF_SING_BOX_CHECK'
#!/bin/sh
printf '\n' >&2
printf '%s\n' 'FATAL[0000] route: missing outbound tag' >&2
exit 42
EOF_SING_BOX_CHECK
chmod +x "$WORK_DIR/check-bin/sing-box"
: >"$WORK_DIR/invalid-config.json"
if PATH="$WORK_DIR/check-bin:$PATH" \
  ucode -L "$FORKOP_LIB" "$SINGBOX_RUNTIME_UC" check-config-fixture \
  "$WORK_DIR/invalid-config.json" "$WORK_DIR/sing-box-check.log" \
  >"$WORK_DIR/sing-box-check.reason"; then
  fail "singbox/runtime.uc check fixture should preserve a failed sing-box status"
fi
[ "$(cat "$WORK_DIR/sing-box-check.reason")" = 'FATAL[0000] route: missing outbound tag' ] ||
  fail "singbox/runtime.uc must return the first non-empty sing-box check diagnostic"
grep -Fq 'Generated sing-box configuration is invalid: " + check_result.reason' "$SINGBOX_RUNTIME_UC" ||
  fail "generated config failure must include the captured sing-box check diagnostic"

cat >"$WORK_DIR/generator-failure.log" <<'EOF_GENERATOR_FAILURE'
skipped incompatible subscription outbound for rule 'only_xhttp': Only XHTTP node (XHTTP requires sing-box-extended)
connection section has no usable outbounds
EOF_GENERATOR_FAILURE
generator_reason="$(ucode -L "$FORKOP_LIB" "$SINGBOX_RUNTIME_UC" generator-failure-reason-fixture \
  "$WORK_DIR/generator-failure.log" 2)"
[ "$generator_reason" = 'connection section has no usable outbounds' ] ||
  fail "singbox/runtime.uc must report the terminal generator error instead of an earlier warning"

mkdir -p "$WORK_DIR/etc" "$WORK_DIR/tmp"
printf 'old config\n' >"$WORK_DIR/etc/config.json"
printf 'new config\n' >"$WORK_DIR/tmp/config.json"
ucode -L "$FORKOP_LIB" "$SINGBOX_RUNTIME_UC" save-config-file-fixture \
  "$WORK_DIR/tmp/config.json" "$WORK_DIR/etc/config.json"
[ "$(cat "$WORK_DIR/etc/config.json")" = "new config" ] ||
  fail "singbox/runtime.uc must replace an existing config from a temp file"
[ ! -e "$WORK_DIR/tmp/config.json" ] ||
  fail "singbox/runtime.uc must consume the temp config after save"

generate_config() {
  local fixture="$1"
  local output="$2"
  local mwan3_active="${3:-0}"

  mkdir -p "$output.section-cache" "$output.rulesets"
  ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/generator.uc" generate-config-fixture \
    "$fixture" "$output" "127.0.0.1" "$mwan3_active"
}

generate_config_with_subscription_cache() {
  local fixture="$1"
  local output="$2"
  local supports_xhttp="${3:-1}"

  mkdir -p "$output.section-cache" "$output.rulesets"
  TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions" \
    FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent-subscription-cache" \
    ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/generator.uc" generate-config-fixture \
      "$fixture" "$output" "127.0.0.1" "0" "$supports_xhttp"
}

cat >"$WORK_DIR/no-enabled-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_path": "/tmp/sing-box/config.json",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": []
}
JSON

if ucode -L "$FORKOP_LIB" "$SINGBOX_GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/no-enabled-fixture.json" "$WORK_DIR/no-enabled.json" "127.0.0.1" "0" \
  >"$WORK_DIR/no-enabled.stdout" 2>"$WORK_DIR/no-enabled.stderr"; then
  fail "generator should reject a config without enabled sections"
fi
if grep -Fq 'unsupported:' "$WORK_DIR/no-enabled.stderr"; then
  fail "generator failure reason must not include redundant unsupported prefix"
fi
grep -Fxq 'no enabled sections' "$WORK_DIR/no-enabled.stderr" ||
  fail "generator failure reason should be concise"

cat >"$WORK_DIR/deferred-section-fixture.json" <<'JSON'
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
      ".name": "subscription_only",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "subscription_urls": [ "https://example.com/sub.json" ]
    }
  ]
}
JSON
if ! ucode -L "$FORKOP_LIB" "$SINGBOX_GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/deferred-section-fixture.json" "$WORK_DIR/deferred-section.json" "127.0.0.1" "0" "1" "subscription_only"; then
  fail "generator must skip subscription-only sections deferred until after sing-box starts"
fi
if grep -Fq 'subscription_only-out' "$WORK_DIR/deferred-section.json"; then
  fail "deferred subscription-only section must not be emitted into the initial config"
fi
grep -Fq 'deferred_sections' "$SINGBOX_RUNTIME_UC" ||
  fail "singbox/runtime.uc must preserve deferred sections for generator input"

cat >"$WORK_DIR/generator-uci.state" <<'EOF_UCI'
forkop.settings=settings
forkop.settings.dns_server=1.1.1.1
forkop.settings.bootstrap_dns_server=1.1.1.1
forkop.settings.config_path=/tmp/sing-box/config.json
forkop.settings.cache_path=/tmp/sing-box/cache.db
forkop.settings.log_level=warn
forkop.uci_proxy=section
forkop.uci_proxy.enabled=1
forkop.uci_proxy.action=connection
forkop.uci_proxy.outbound_jsons={"type":"direct"}
forkop.uci_proxy.domain_suffix=example.org
EOF_UCI
FORKOP_UCI_STATE_FILE="$WORK_DIR/generator-uci.state" \
  FORKOP_SECTION_CACHE_DIR="$WORK_DIR/generated-from-uci.section-cache" \
  ucode -L "$FORKOP_LIB" "$SINGBOX_GENERATOR_UC" generate-config "$WORK_DIR/generated-from-uci.json" "127.0.0.1" "0"
grep -Fq '"example.org"' "$WORK_DIR/generated-from-uci.json" ||
  fail "singbox/generator.uc must read section matchers from core.uci"
grep -Fq '"uci_proxy-out"' "$WORK_DIR/generated-from-uci.json" ||
  fail "singbox/generator.uc must read section names from core.uci"

cat >"$WORK_DIR/disabled-updates-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_path": "/tmp/sing-box/config.json",
    "list_update_enabled": "0",
    "update_interval": "5m",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ],
      "domain_suffix": [ "example.org" ],
      "rule_set": [ "https://example.com/rules.srs" ],
      "resolve_real_ip_for_routing": "1"
    }
  ]
}
JSON

cat >"$WORK_DIR/default-updates-fixture.json" <<'JSON'
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
      "action": "outbound",
      "outbound_json": "{\"type\":\"direct\"}",
      "rule_set": [ "https://example.com/rules.srs" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/server-inbound-fixture.json" <<'JSON'
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
      "action": "outbound",
      "outbound_json": "{\"type\":\"direct\"}",
      "domain_suffix": [ "example.org" ]
    }
  ],
  "server": [
    {
      ".name": "edge",
      ".type": "server",
      "enabled": "1",
      "protocol": "socks",
      "listen": "0.0.0.0",
      "listen_port": "18080",
      "server_username": "tester",
      "server_password": "secret",
      "routing_mode": "direct"
    },
    {
      ".name": "open",
      ".type": "server",
      "enabled": "1",
      "protocol": "socks",
      "listen": "0.0.0.0",
      "listen_port": "18081",
      "socks_auth_enabled": "0",
      "server_username": "ignored",
      "server_password": "ignored",
      "routing_mode": "direct"
    }
  ]
}
JSON

cat >"$WORK_DIR/runtime-matchers-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_path": "/tmp/sing-box/config.json",
    "dns_server": "1.1.1.1",
    "dns_strategy": "prefer_ipv6",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "detour",
      ".type": "section",
      "enabled": "1",
      "action": "outbound",
      "outbound_json": "{\"type\":\"direct\"}",
      "domain_suffix": [ "detour.example" ]
    },
    {
      ".name": "bypass",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "domain_suffix": [ "example.org" ],
      "ip_cidr": [ "198.51.100.0/24" ],
      "source_ip_cidr": [ "10.0.0.3/32" ]
    },
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [ "socks5://127.0.0.1:1080" ],
      "domain": "commented.example # ignored.example\nfull:exact-comment.example // ignored-full.example\nfull:source-priority.test\nkeyword:clip",
      "domain_suffix": [ "proxy.example.org", "сайт.рф", "full:пример.испытание", "keyword:пример", "regex:^сайт[.]рф$" ],
      "ip_cidr": "77.111.247.0/24 #77.111.247.19\n198.51.100.0/24 //203.0.113.0/24",
      "source_ip_cidr": "10.0.0.2/32 #10.0.0.99\n2001:db8::2/128 //2001:db8::99/128",
      "ports_text": "80 # 443\n8080 // 8443",
      "outbound_detour_enabled": "1",
      "outbound_detour_section": "detour",
      "mixed_proxy_enabled": "1",
      "mixed_proxy_port": "19090",
      "mixed_proxy_auth_enabled": "1",
      "mixed_proxy_username": "user",
      "mixed_proxy_password": "pass"
    },
    {
      ".name": "proxy_global",
      ".type": "section",
      "enabled": "1",
      "action": "outbound",
      "outbound_json": "{\"type\":\"direct\"}",
      "domain_suffix": [ "example.org" ]
    },
    {
      ".name": "bypass_global",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "domain": [ "source-priority.test" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/dns-action.lst" <<'EOF_DNS_ACTION_LIST'
list-dns.example
198.51.100.0/24
EOF_DNS_ACTION_LIST
cat >"$WORK_DIR/dns-action-fixture.json" <<JSON
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
      ".name": "dns_first",
      ".type": "section",
      "enabled": "1",
      "action": "dns",
      "dns_type": "dot",
      "dns_server": "9.9.9.9:5353",
      "dns_detour_enabled": "1",
      "dns_detour_section": "detour",
      "domain_suffix": [ "dns-first.example" ],
      "community_lists": [ "youtube" ],
      "rule_set": [ "https://example.com/domain-only.srs" ],
      "domain_ip_lists": [ "$WORK_DIR/dns-action.lst" ],
      "ip_cidr": [ "203.0.113.0/24" ],
      "source_ip_cidr": [ "192.0.2.1/32" ],
      "fully_routed_ips": [ "192.0.2.2/32" ],
      "ports": [ "443" ]
    },
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ],
      "domain_suffix": [ "dns-first.example", "proxy-first.example" ]
    },
    {
      ".name": "dns_second",
      ".type": "section",
      "enabled": "1",
      "action": "dns",
      "dns_server": "8.8.8.8",
      "domain_suffix": [ "proxy-first.example" ]
    },
    {
      ".name": "detour",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ],
      "domain_suffix": [ "detour.example" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/urltest-filter-fixture.json" <<'JSON'
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
      "outbound_jsons": [
        "{\"type\":\"http\",\"tag\":\"Keep\",\"server\":\"127.0.0.1\",\"server_port\":18081}",
        "{\"type\":\"http\",\"tag\":\"Drop\",\"server\":\"127.0.0.1\",\"server_port\":18082}"
      ],
      "urltest_enabled": "1",
      "urltest_filter_mode": "include",
      "urltest_include_outbounds": [ "Keep" ],
      "domain_suffix": [ "example.org" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/manual-http-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": "1.1.1.1"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [ "http://127.0.0.1:8080" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/provider-actions-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_path": "/tmp/sing-box/config.json",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    { ".name": "zap", ".type": "section", "enabled": "1", "action": "zapret", "domain_suffix": [ "zap.example" ] },
    { ".name": "zap2", ".type": "section", "enabled": "1", "action": "zapret2", "domain_suffix": [ "zap2.example" ] },
    { ".name": "bye", ".type": "section", "enabled": "1", "action": "byedpi", "domain_suffix": [ "bye.example" ] }
  ]
}
JSON

cat >"$WORK_DIR/manual-transport-fixture.json" <<'JSON'
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
      "selector_proxy_links": [
        "vless://11111111-1111-4111-8111-111111111111@127.0.0.1:443?security=tls&type=ws&path=%2Fws&host=example.com&sni=example.com&alpn=h2%2Chttp%2F1.1&encryption=mlkem768x25519plus.native.test#WS",
        "vmess://eyJ2IjoiMiIsInBzIjoiVk1lc3MgV1MiLCJhZGQiOiIxMjcuMC4wLjEiLCJwb3J0IjoiNDQzIiwiaWQiOiIyMjIyMjIyMi0yMjIyLTQyMjItODIyMi0yMjIyMjIyMjIyMjIiLCJhaWQiOiI0Iiwic2N5IjoiYXV0byIsIm5ldCI6IndzIiwidHlwZSI6Im5vbmUiLCJob3N0Ijoidm1lc3MuZXhhbXBsZSIsInBhdGgiOiIvdm1lc3MiLCJ0bHMiOiJ0bHMiLCJzbmkiOiJ2bWVzcy5leGFtcGxlIiwiYWxwbiI6ImgyLGh0dHAvMS4xIiwiZnAiOiJjaHJvbWUifQ==#VMess",
        "ss://YWVzLTEyOC1nY206cGFzcw@127.0.0.1:8388#SS"
      ],
      "domain_suffix": [ "example.org" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/vpn-interface-fixture.json" <<'JSON'
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
      ".name": "renamed_awg",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "domain_suffix": [ "vpn.example" ]
    }
  ],
  "section_interface": [
    {
      ".name": "vpn-interface",
      ".type": "section_interface",
      "section": "renamed_awg",
      "name": "tun0",
      "domain_resolver_enabled": "1",
      "domain_resolver_dns_type": "doh",
      "domain_resolver_dns_server": "https://dns.example/dns-query"
    }
  ]
}
JSON

cat >"$WORK_DIR/download-via-proxy-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_path": "/tmp/sing-box/config.json",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1",
    "download_lists_via_proxy": "1",
    "download_subscriptions_via_proxy": "1",
    "download_components_via_proxy": "1",
    "download_lists_via_proxy_section": "proxy",
    "download_components_via_proxy_section": "components_proxy"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "outbound",
      "outbound_json": "{\"type\":\"socks\",\"server\":\"127.0.0.1\",\"server_port\":1080}",
      "domain_suffix": [ "example.org" ],
      "community_lists": [ "discord" ],
      "rule_set": [ "https://example.com/rules.srs" ]
    },
    {
      ".name": "components_proxy",
      ".type": "section",
      "enabled": "1",
      "action": "outbound",
      "outbound_json": "{\"type\":\"socks\",\"server\":\"127.0.0.2\",\"server_port\":1080}",
      "domain_suffix": [ "components.example" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/fully-routed-fixture.json" <<'JSON'
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
      ".name": "proxy_high",
      ".type": "section",
      "enabled": "1",
      "action": "outbound",
      "outbound_json": "{\"type\":\"direct\"}",
      "domain_suffix": [ "forced-higher.test" ]
    },
    {
      ".name": "bypass",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "fully_routed_ips": [ "192.168.1.20/32", "192.168.1.30/32", "2001:db8::20/128" ],
      "domain_suffix": [ "example.org" ]
    },
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "outbound",
      "outbound_json": "{\"type\":\"direct\"}",
      "fully_routed_ips": [ "192.168.1.40/32" ],
      "domain_suffix": [ "proxy.example.org", "forced-lower.test" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/mwan3-auto-fixture.json" <<'JSON'
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
      "action": "outbound",
      "outbound_json": "{\"type\":\"direct\"}",
      "domain_suffix": [ "example.org" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/mwan3-pinned-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_path": "/tmp/sing-box/config.json",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1",
    "output_network_interface": "wan2"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "outbound",
      "outbound_json": "{\"type\":\"direct\"}",
      "domain_suffix": [ "example.org" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/domain-ip.lst" <<'EOF_LIST'
example.net
203.0.113.0/24
EOF_LIST

cat >"$WORK_DIR/with-subnets.json" <<'JSON'
{
  "version": 3,
  "rules": [
    { "domain_suffix": [ "ruleset.example" ], "ip_cidr": [ "198.51.100.0/24" ] }
  ]
}
JSON

cat >"$WORK_DIR/domain-ip-rulesets-fixture.json" <<JSON
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
      "action": "outbound",
      "outbound_json": "{\\"type\\":\\"direct\\"}",
      "domain_suffix": [ "example.org" ],
      "rule_set_with_subnets": [ "$WORK_DIR/with-subnets.json" ],
      "domain_ip_lists": [ "$WORK_DIR/domain-ip.lst" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/subscription-metadata-fixture.json" <<'JSON'
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
      "subscription_urls": [
        "https://example.com/sub-v2rayn.txt",
        "https://example.com/sub.txt"
      ],
      "subscription_url_settings": "{\"https://example.com/sub-v2rayn.txt\":{\"user_agent\":\"v2rayN\"}}",
      "domain_suffix": [ "proxy.example" ]
    },
    {
      ".name": "test",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "subscription_urls": [
        "https://example.com/test-sub.txt"
      ],
      "subscription_url_settings": "{\"https://example.com/test-sub.txt\":{\"user_agent\":\"v2rayN\"}}",
      "domain_suffix": [ "test.example" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/subscription-group-fixture.json" <<'JSON'
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
      ".name": "detour",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"socks\",\"server\":\"127.0.0.1\",\"server_port\":1081}" ],
      "domain_suffix": [ "detour.example" ]
    },
    {
      ".name": "grouped",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "subscription_urls": [
        "https://example.com/group.json"
      ],
      "subscription_url_settings": "{\"https://example.com/group.json\":{\"user_agent\":\"Happ\"}}",
      "domain_suffix": [ "grouped.example" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/subscription-group-disabled-fixture.json" <<'JSON'
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
      ".name": "grouped",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "subscription_urls": [
        "https://example.com/group.json"
      ],
      "subscription_url_settings": "{\"https://example.com/group.json\":{\"user_agent\":\"Happ\",\"include_urltest_groups\":\"0\"}}",
      "domain_suffix": [ "grouped.example" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/subscription-xhttp-fixture.json" <<'JSON'
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
      ".name": "xhttp",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "subscription_urls": [ "https://example.com/xhttp.json" ],
      "subscription_url_settings": "{\"https://example.com/xhttp.json\":{\"user_agent\":\"Happ\"}}",
      "domain_suffix": [ "xhttp.example" ]
    }
  ],
  "urltest": [
    {
      ".name": "ut_xhttp",
      ".type": "urltest",
      "section": "xhttp",
      "name": "Compatible URLTest"
    }
  ],
  "priority_group": [
    {
      ".name": "pg_xhttp",
      ".type": "priority_group",
      "section": "xhttp",
      "name": "Compatible Priority"
    }
  ],
  "priority_level": [
    {
      ".name": "pl_xhttp",
      ".type": "priority_level",
      "group": "pg_xhttp",
      "name": "All compatible",
      "order": "0",
      "filter_mode": "disabled"
    }
  ]
}
JSON

cat >"$WORK_DIR/subscription-only-xhttp-fixture.json" <<'JSON'
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
      ".name": "only_xhttp",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "subscription_urls": [ "https://example.com/only-xhttp.json" ],
      "subscription_url_settings": "{\"https://example.com/only-xhttp.json\":{\"user_agent\":\"Happ\"}}",
      "domain_suffix": [ "only-xhttp.example" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/manual-xhttp-fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "1.1.1.1" },
  "section": [
    {
      ".name": "manual_xhttp",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [
        "vless://00000000-0000-4000-8000-000000000001@xhttp.example:443?encryption=none&security=tls&sni=xhttp.example&type=xhttp#Manual XHTTP"
      ]
    }
  ]
}
JSON

cat >"$WORK_DIR/json-xhttp-fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "1.1.1.1" },
  "section": [
    {
      ".name": "json_xhttp",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [
        "{\"type\":\"vless\",\"tag\":\"JSON XHTTP\",\"server\":\"xhttp.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000002\",\"transport\":{\"type\":\"xhttp\"}}"
      ]
    }
  ]
}
JSON

mkdir -p "$WORK_DIR/subscriptions" "$WORK_DIR/persistent-subscription-cache"
for source in proxy-subscription-1 proxy-subscription-2 test-subscription-1; do
  cat >"$WORK_DIR/subscriptions/$source.json" <<'JSON'
{"outbounds":[{"type":"socks","tag":"subscription-proxy","server":"127.0.0.1","server_port":1080}]}
JSON
  printf '%s' 'https://example.com/sub.txt' >"$WORK_DIR/subscriptions/$source.url"
  cat >"$WORK_DIR/persistent-subscription-cache/$source.metadata.json" <<'JSON'
{"version":1,"title":"WolfPN"}
JSON
  printf '%s' 'https://example.com/sub.txt' >"$WORK_DIR/persistent-subscription-cache/$source.url"
done
printf '%s' 'https://example.com/sub-v2rayn.txt' >"$WORK_DIR/subscriptions/proxy-subscription-1.url"
printf '%s' 'https://example.com/sub-v2rayn.txt' >"$WORK_DIR/persistent-subscription-cache/proxy-subscription-1.url"
printf '%s' 'https://example.com/test-sub.txt' >"$WORK_DIR/subscriptions/test-subscription-1.url"
printf '%s' 'https://example.com/test-sub.txt' >"$WORK_DIR/persistent-subscription-cache/test-subscription-1.url"
printf '%s' 'v2rayN' >"$WORK_DIR/subscriptions/proxy-subscription-1.user_agent"
printf '%s' 'sing-box/default' >"$WORK_DIR/subscriptions/proxy-subscription-2.user_agent"
printf '%s' 'v2rayN' >"$WORK_DIR/subscriptions/test-subscription-1.user_agent"
printf '%s' 'v2rayN' >"$WORK_DIR/persistent-subscription-cache/proxy-subscription-1.user_agent"
printf '%s' 'sing-box/default' >"$WORK_DIR/persistent-subscription-cache/proxy-subscription-2.user_agent"
printf '%s' 'v2rayN' >"$WORK_DIR/persistent-subscription-cache/test-subscription-1.user_agent"
cat >"$WORK_DIR/subscriptions/grouped-subscription-1.json" <<'JSON'
{
  "outbounds": [
    {
      "type": "urltest",
      "tag": "Provider Group",
      "outbounds": [ "grouped-out", "leaf" ],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "10m",
      "tolerance": 50,
      "remark": "Provider Group",
      "__forkop_allow_group": true
    },
    {
      "type": "vless",
      "tag": "grouped-out",
      "server": "127.0.0.1",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000001",
      "tls": { "enabled": true, "server_name": "example.com" },
      "__forkop_hidden": true
    },
    {
      "type": "vless",
      "tag": "leaf",
      "server": "127.0.0.2",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000002",
      "tls": { "enabled": true, "server_name": "example.org" },
      "__forkop_hidden": true
    },
    {
      "type": "direct",
      "tag": "provider-direct"
    },
    {
      "type": "http",
      "tag": "provider-http",
      "server": "127.0.0.3",
      "server_port": 8080
    }
  ]
}
JSON
printf '%s' 'https://example.com/group.json' >"$WORK_DIR/subscriptions/grouped-subscription-1.url"
printf '%s' 'Happ' >"$WORK_DIR/subscriptions/grouped-subscription-1.user_agent"
cat >"$WORK_DIR/subscriptions/xhttp-subscription-1.json" <<'JSON'
{
  "outbounds": [
    {
      "type": "urltest",
      "tag": "Provider XHTTP Group",
      "outbounds": [ "xhttp-node", "plain-node" ],
      "default": "xhttp-node",
      "url": "https://www.gstatic.com/generate_204",
      "remark": "Provider XHTTP Group",
      "__forkop_allow_group": true
    },
    {
      "type": "vless",
      "tag": "xhttp-node",
      "remark": "Moscow XHTTP",
      "server": "127.0.0.10",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000010",
      "transport": { "type": "xhttp" },
      "__forkop_hidden": true
    },
    {
      "type": "socks",
      "tag": "plain-node",
      "remark": "Plain node",
      "server": "127.0.0.11",
      "server_port": 1080,
      "__forkop_hidden": true
    },
    {
      "type": "socks",
      "tag": "depends-on-xhttp",
      "remark": "Depends on XHTTP",
      "server": "127.0.0.12",
      "server_port": 1080,
      "detour": "xhttp-node"
    },
    {
      "type": "socks",
      "tag": "recursive-dependent",
      "remark": "Recursive dependent",
      "server": "127.0.0.13",
      "server_port": 1080,
      "detour": "depends-on-xhttp"
    }
  ]
}
JSON
printf '%s' 'https://example.com/xhttp.json' >"$WORK_DIR/subscriptions/xhttp-subscription-1.url"
printf '%s' 'Happ' >"$WORK_DIR/subscriptions/xhttp-subscription-1.user_agent"
cat >"$WORK_DIR/subscriptions/only_xhttp-subscription-1.json" <<'JSON'
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "only-xhttp-node",
      "remark": "Only XHTTP node",
      "server": "127.0.0.20",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000020",
      "transport": { "type": "xhttp" }
    }
  ]
}
JSON
printf '%s' 'https://example.com/only-xhttp.json' >"$WORK_DIR/subscriptions/only_xhttp-subscription-1.url"
printf '%s' 'Happ' >"$WORK_DIR/subscriptions/only_xhttp-subscription-1.user_agent"

generate_config "$WORK_DIR/disabled-updates-fixture.json" "$WORK_DIR/disabled.json"
generate_config "$WORK_DIR/default-updates-fixture.json" "$WORK_DIR/default.json"
generate_config "$WORK_DIR/server-inbound-fixture.json" "$WORK_DIR/server.json"
generate_config "$WORK_DIR/runtime-matchers-fixture.json" "$WORK_DIR/matchers.json"
generate_config "$WORK_DIR/dns-action-fixture.json" "$WORK_DIR/dns-action.json"
generate_config "$WORK_DIR/urltest-filter-fixture.json" "$WORK_DIR/urltest.json"
if generate_config "$WORK_DIR/manual-http-fixture.json" "$WORK_DIR/manual-http.json" \
  >"$WORK_DIR/manual-http.stdout" 2>"$WORK_DIR/manual-http.stderr"; then
  fail "generator should reject native HTTP connection URLs"
fi
grep -Fxq 'manual proxy link scheme is not supported by sing-box config generation yet' "$WORK_DIR/manual-http.stderr" ||
  fail "native HTTP connection URL failure should identify the unsupported scheme"
generate_config "$WORK_DIR/provider-actions-fixture.json" "$WORK_DIR/providers.json"
generate_config "$WORK_DIR/manual-transport-fixture.json" "$WORK_DIR/manual.json"
generate_config "$WORK_DIR/vpn-interface-fixture.json" "$WORK_DIR/vpn.json"
generate_config "$WORK_DIR/download-via-proxy-fixture.json" "$WORK_DIR/download.json"
generate_config "$WORK_DIR/fully-routed-fixture.json" "$WORK_DIR/fully-routed.json"
generate_config "$WORK_DIR/mwan3-auto-fixture.json" "$WORK_DIR/mwan3-auto.json" 1
generate_config "$WORK_DIR/mwan3-pinned-fixture.json" "$WORK_DIR/mwan3-pinned.json" 1
generate_config "$WORK_DIR/domain-ip-rulesets-fixture.json" "$WORK_DIR/domain-ip-rulesets.json"
generate_config_with_subscription_cache "$WORK_DIR/subscription-metadata-fixture.json" "$WORK_DIR/subscription-metadata.json"
generate_config_with_subscription_cache "$WORK_DIR/subscription-group-fixture.json" "$WORK_DIR/subscription-group.json"
generate_config_with_subscription_cache "$WORK_DIR/subscription-group-disabled-fixture.json" "$WORK_DIR/subscription-group-disabled.json"
generate_config_with_subscription_cache "$WORK_DIR/subscription-xhttp-fixture.json" "$WORK_DIR/subscription-xhttp-extended.json" 1
generate_config_with_subscription_cache "$WORK_DIR/subscription-xhttp-fixture.json" "$WORK_DIR/subscription-xhttp-stable.json" 0 \
  2>"$WORK_DIR/subscription-xhttp-stable.stderr"
grep -Fq "Moscow XHTTP (XHTTP requires sing-box-extended)" "$WORK_DIR/subscription-xhttp-stable.stderr" ||
  fail "stable sing-box XHTTP warning should identify the incompatible subscription outbound"
grep -Fq "Recursive dependent (detour depends on unavailable outbound 'depends-on-xhttp')" "$WORK_DIR/subscription-xhttp-stable.stderr" ||
  fail "stable sing-box XHTTP filtering should report recursively pruned detours"

if generate_config_with_subscription_cache "$WORK_DIR/subscription-only-xhttp-fixture.json" "$WORK_DIR/subscription-only-xhttp.json" 0 \
  >"$WORK_DIR/subscription-only-xhttp.stdout" 2>"$WORK_DIR/subscription-only-xhttp.stderr"; then
  fail "stable sing-box should reject a subscription section with only XHTTP outbounds"
fi
grep -Fq "Only XHTTP node (XHTTP requires sing-box-extended)" "$WORK_DIR/subscription-only-xhttp.stderr" ||
  fail "all-XHTTP subscription failure should identify the incompatible outbound"
[ "$(tail -n 1 "$WORK_DIR/subscription-only-xhttp.stderr")" = 'connection section has no usable outbounds' ] ||
  fail "all-XHTTP subscription failure should end with the actionable generator error"

for fixture in manual-xhttp json-xhttp; do
  if ucode -L "$FORKOP_LIB" "$SINGBOX_GENERATOR_UC" generate-config-fixture \
    "$WORK_DIR/$fixture-fixture.json" "$WORK_DIR/$fixture-stable.json" "127.0.0.1" "0" "0" \
    >"$WORK_DIR/$fixture-stable.stdout" 2>"$WORK_DIR/$fixture-stable.stderr"; then
    fail "stable sing-box should reject explicit $fixture configuration"
  fi
  grep -Fq "uses XHTTP transport, but sing-box-extended is not installed" "$WORK_DIR/$fixture-stable.stderr" ||
    fail "explicit $fixture XHTTP failure should explain the extended requirement"
  generate_config "$WORK_DIR/$fixture-fixture.json" "$WORK_DIR/$fixture-extended.json"
done

ucode -e '
let fs = require("fs");
let dir = ARGV[0];

function cfg(name) {
    return json(fs.readfile(dir + "/" + name + ".json"));
}

function as_array(value) {
    if (value == null)
        return [];
    return type(value) == "array" ? value : [ value ];
}

function contains(values, needle) {
    for (let value in as_array(values))
        if (value == needle)
            return true;
    return false;
}

function assert(condition, message) {
    if (!condition) {
        warn("FAIL: ", message, "\n");
        exit(1);
    }
}

function no_internal_fields(value) {
    if (type(value) == "array") {
        for (let item in value)
            if (!no_internal_fields(item))
                return false;
    }
    else if (type(value) == "object") {
        for (let key, item in value) {
            if (substr(key, 0, 2) == "__")
                return false;
            if (!no_internal_fields(item))
                return false;
        }
    }
    return true;
}

function first_remote_ruleset(config) {
    for (let rule_set in config.route.rule_set || [])
        if (rule_set && rule_set.type == "remote")
            return rule_set;
    return null;
}

function ruleset(config, tag) {
    for (let rule_set in config.route.rule_set || [])
        if (rule_set && rule_set.tag == tag)
            return rule_set;
    return null;
}

function ruleset_url(config, url) {
    for (let rule_set in config.route.rule_set || [])
        if (rule_set && rule_set.url == url)
            return rule_set;
    return null;
}

function outbound(config, tag) {
    for (let item in config.outbounds || [])
        if (item && item.tag == tag)
            return item;
    return null;
}

function inbound(config, tag) {
    for (let item in config.inbounds || [])
        if (item && item.tag == tag)
            return item;
    return null;
}

function route_rule(config, predicate) {
    for (let rule in config.route.rules || [])
        if (rule && predicate(rule))
            return rule;
    return null;
}

function route_rule_index(config, predicate) {
    let rules = config.route.rules || [];
    for (let i = 0; i < length(rules); i++)
        if (rules[i] && predicate(rules[i]))
            return i;
    return -1;
}

function dns_rule(config, predicate) {
    for (let rule in config.dns.rules || [])
        if (rule && predicate(rule))
            return rule;
    return null;
}

function dns_rule_index(config, predicate) {
    let rules = config.dns.rules || [];
    for (let i = 0; i < length(rules); i++)
        if (rules[i] && predicate(rules[i]))
            return i;
    return -1;
}

function dns_server(config, predicate) {
    for (let server in config.dns.servers || [])
        if (server && predicate(server))
            return server;
    return null;
}

let disabled = cfg("disabled");
assert(first_remote_ruleset(disabled).update_interval == "876000h", "disabled list update interval");
assert(route_rule(disabled, r => r.action == "resolve" && r.server == "dns-server") != null, "resolve rule generated");

let defaults = cfg("default");
assert(first_remote_ruleset(defaults).update_interval == "1d", "default list update interval");
assert(defaults.dns.strategy == "prefer_ipv4", "missing DNS strategy keeps the prefer_ipv4 default");
assert(dns_server(defaults, r => r.tag == "dnsmasq-server") == null, "source-aware DNS server is omitted without device filters");

let server = cfg("server");
let socks = inbound(server, "server-edge-in");
assert(socks && socks.type == "socks" && socks.listen_port == 18080, "server socks inbound");
assert(socks.users && socks.users[0].username == "tester", "legacy server socks auth defaults to enabled");
let open_socks = inbound(server, "server-open-in");
assert(open_socks && open_socks.type == "socks" && open_socks.listen_port == 18081, "server open socks inbound");
assert(open_socks.users == null, "disabled server socks auth omits users");
assert(route_rule(server, r => r.inbound == "server-edge-in" && r.outbound == "direct-out") != null, "server direct route");

let matchers = cfg("matchers");
assert(matchers.dns.strategy == "prefer_ipv6", "configured DNS strategy is generated");
assert(dns_server(matchers, r => r.tag == "fakeip-server" && r.inet6_range == "fc00::/18") != null, "FakeIP IPv6 range");
assert(inbound(matchers, "tproxy6-in") != null, "IPv6 TProxy inbound");
assert(inbound(matchers, "tproxy6-in").listen == "::1", "IPv6 TProxy listen address");
assert(route_rule(matchers, r => r.action == "reject" && r.ip_version == 6) == null, "IPv6 traffic is not rejected globally");
assert(outbound(matchers, "bypass-out").type == "direct", "bypass fallback outbound");
assert(outbound(matchers, "proxy-1-out").detour == "detour-out", "connection URL outbound detour");
let mixed = inbound(matchers, "proxy-mixed-in");
assert(mixed && mixed.listen_port == 19090 && mixed.users[0].username == "user", "mixed inbound auth");
assert(route_rule(matchers, r => r.inbound == "proxy-mixed-in" && r.outbound == "proxy-out") != null, "mixed inbound route");
let source_dns_in = inbound(matchers, "source-dns-in");
assert(source_dns_in && source_dns_in.type == "direct" && source_dns_in.listen == "::" && source_dns_in.listen_port == 1603, "source-aware DNS uses one dual-stack inbound");
assert(route_rule(matchers, r => r.action == "sniff" && contains(r.inbound, "source-dns-in")) != null, "source-aware DNS inbound is sniffed before hijacking");
assert(dns_server(matchers, r => r.tag == "dnsmasq-server" && r.type == "udp" && r.server == "127.0.0.1" && r.server_port == 53) != null, "source-aware DNS uses the existing dnsmasq instance");
let bypass_dnsmasq = dns_rule(matchers, r =>
    r.type == "logical" && r.server == "dnsmasq-server" &&
    length(r.rules || []) == 2 && contains(r.rules[0].domain_suffix, "example.org"));
assert(bypass_dnsmasq != null, "filtered bypass probes dnsmasq before real DNS fallback");
assert(contains(bypass_dnsmasq.rules[0].inbound, "source-dns-in"), "filtered bypass DNS is limited to source-aware DNS clients");
assert(contains(bypass_dnsmasq.rules[0].source_ip_cidr, "10.0.0.3/32"), "filtered bypass DNS keeps the client source");
assert(bypass_dnsmasq.rules[1].invert === true && contains(bypass_dnsmasq.rules[1].ip_cidr, "198.18.0.0/15") && contains(bypass_dnsmasq.rules[1].ip_cidr, "fc00::/18"), "filtered bypass rejects nested FakeIP answers");
let bypass_real = dns_rule(matchers, r =>
    r.server == "dns-server" && contains(r.domain_suffix, "example.org") &&
    contains(r.source_ip_cidr, "10.0.0.3/32"));
assert(bypass_real != null && contains(bypass_real.query_type, "A") && contains(bypass_real.query_type, "AAAA"), "filtered bypass falls back to real address resolution");
assert(dns_rule(matchers, r => r.server == "dns-server" && contains(r.domain_suffix, "example.org") && r.source_ip_cidr == null) == null, "filtered bypass no longer changes DNS for every device");
assert(dns_rule(matchers, r => r.server == "fakeip-server" && contains(r.domain_suffix, "example.org") && r.source_ip_cidr == null) != null, "lower global proxy still gives FakeIP to other devices");
let scoped_proxy_dns = dns_rule(matchers, r => r.server == "fakeip-server" && contains(r.domain_suffix, "proxy.example.org"));
assert(scoped_proxy_dns != null && contains(scoped_proxy_dns.source_ip_cidr, "10.0.0.2/32") && contains(scoped_proxy_dns.inbound, "source-dns-in"), "filtered proxy gives FakeIP only to its devices");
let source_dns_fallback = dns_rule(matchers, r =>
    r.server == "dnsmasq-server" && r.type == null && r.domain == null &&
    r.domain_suffix == null && r.rule_set == null);
assert(source_dns_fallback != null && contains(source_dns_fallback.source_ip_cidr, "10.0.0.3/32") && contains(source_dns_fallback.source_ip_cidr, "10.0.0.2/32") && contains(source_dns_fallback.source_ip_cidr, "2001:db8::2/128"), "unmatched source-aware DNS returns through dnsmasq");
let bypass_probe_index = dns_rule_index(matchers, r => r.type == "logical" && r.server == "dnsmasq-server" && length(r.rules || []) > 0 && contains(r.rules[0].domain_suffix, "example.org"));
let bypass_real_index = dns_rule_index(matchers, r => r.server == "dns-server" && contains(r.domain_suffix, "example.org") && contains(r.source_ip_cidr, "10.0.0.3/32"));
let proxy_below_bypass_index = dns_rule_index(matchers, r => r.server == "fakeip-server" && contains(r.domain_suffix, "example.org") && r.source_ip_cidr == null);
assert(bypass_probe_index >= 0 && bypass_real_index > bypass_probe_index && proxy_below_bypass_index > bypass_real_index, "source-aware bypass keeps its section priority over lower proxy DNS");
let scoped_proxy_index = dns_rule_index(matchers, r => r.server == "fakeip-server" && contains(r.domain, "source-priority.test") && contains(r.source_ip_cidr, "10.0.0.2/32"));
let bypass_below_proxy_index = dns_rule_index(matchers, r => r.server == "dns-server" && contains(r.domain, "source-priority.test") && r.source_ip_cidr == null);
assert(scoped_proxy_index >= 0 && bypass_below_proxy_index > scoped_proxy_index, "source-aware proxy keeps its section priority over lower bypass DNS");
let scoped_proxy_route_index = route_rule_index(matchers, r => r.outbound == "proxy-out" && contains(r.domain, "source-priority.test") && contains(r.source_ip_cidr, "10.0.0.2/32"));
let bypass_below_proxy_route_index = route_rule_index(matchers, r => r.outbound == "bypass-out" && contains(r.domain, "source-priority.test") && r.source_ip_cidr == null);
assert(scoped_proxy_route_index >= 0 && bypass_below_proxy_route_index > scoped_proxy_route_index, "route and DNS priorities stay aligned for filtered proxy");
assert(dns_rule(matchers, r => contains(r.domain_suffix, "xn--80aswg.xn--p1ai")).server == "fakeip-server", "IDN suffix converted for DNS rule");
assert(dns_rule(matchers, r => contains(r.domain, "xn--e1afmkfd.xn--80akhbyknj4f")).server == "fakeip-server", "IDN full domain converted for DNS rule");
assert(dns_rule(matchers, r => contains(r.domain_keyword, "xn--e1afmkfd")).server == "fakeip-server", "IDN keyword converted for DNS rule");
assert(dns_rule(matchers, r => contains(r.domain_regex, "^xn--80aswg[.]xn--p1ai$")).server == "fakeip-server", "IDN regex converted for DNS rule");
assert(dns_rule(matchers, r => contains(r.domain_suffix, "commented.example")).server == "fakeip-server", "commented domain value generated");
assert(dns_rule(matchers, r => contains(r.domain, "exact-comment.example")).server == "fakeip-server", "commented full domain generated");
assert(dns_rule(matchers, r => contains(r.domain_keyword, "clip")).server == "fakeip-server", "commented keyword generated");
assert(index(sprintf("%J", matchers), "ignored.example") < 0 && index(sprintf("%J", matchers), "ignored-full.example") < 0, "domain comments excluded from generated config");
assert(route_rule(matchers, r => r.outbound == "bypass-out" && contains(r.domain_suffix, "example.org") && contains(r.source_ip_cidr, "10.0.0.3/32")) != null, "bypass fallback route");
assert(route_rule(matchers, r => r.outbound == "proxy-out" && contains(r.domain_suffix, "xn--80aswg.xn--p1ai")) != null, "IDN suffix converted for route rule");
assert(route_rule(matchers, r => r.outbound == "proxy-out" && contains(r.domain, "xn--e1afmkfd.xn--80akhbyknj4f")) != null, "IDN full domain converted for route rule");
assert(route_rule(matchers, r => r.outbound == "proxy-out" && contains(r.domain_keyword, "xn--e1afmkfd")) != null, "IDN keyword converted for route rule");
assert(route_rule(matchers, r => r.outbound == "proxy-out" && contains(r.domain_regex, "^xn--80aswg[.]xn--p1ai$")) != null, "IDN regex converted for route rule");
assert(route_rule(matchers, r => contains(r.inbound, "tproxy-in") && contains(r.inbound, "tproxy6-in") && r.outbound == "proxy-out") != null, "section route dual tproxy inbound");
assert(route_rule(matchers, r => r.outbound == "direct-out" && contains(r.source_ip_cidr, "192.168.1.5/32")) == null, "routing excluded source removed");
assert(route_rule(matchers, r => r.outbound == "proxy-out" && contains(r.source_ip_cidr, "10.0.0.2/32") && contains(r.source_ip_cidr, "2001:db8::2/128")) != null, "source_ip_cidr matcher");
let commented_ip_rule = route_rule(matchers, r => r.outbound == "proxy-out" && contains(r.ip_cidr, "77.111.247.0/24") && contains(r.ip_cidr, "198.51.100.0/24"));
assert(commented_ip_rule != null, "comment-aware ip_cidr matcher");
assert(contains(commented_ip_rule.port, 80) && contains(commented_ip_rule.port, 8080), "comment-aware port matcher");
let commented_rule_json = sprintf("%J", commented_ip_rule);
assert(index(commented_rule_json, "#77.111.247.19") < 0 && index(commented_rule_json, "203.0.113.0/24") < 0 && index(commented_rule_json, "10.0.0.99") < 0 && index(commented_rule_json, "2001:db8::99/128") < 0, "IP comments excluded from generated config");
assert(index(commented_rule_json, "443") < 0 && index(commented_rule_json, "8443") < 0, "port comments excluded from generated config");

let dns_action = cfg("dns-action");
let dns_first_server = dns_server(dns_action, r => r.tag == "dns_first-dns-server");
assert(dns_first_server && dns_first_server.type == "tls" && dns_first_server.server == "9.9.9.9" && dns_first_server.server_port == 5353, "DNS action protocol and server");
assert(dns_first_server.detour == "detour-out", "DNS action detour");
assert(dns_server(dns_action, r => r.tag == "dns_second-dns-server" && r.server == "8.8.8.8") != null, "second DNS action server");
assert(outbound(dns_action, "dns_first-out") == null && outbound(dns_action, "dns_second-out") == null, "DNS actions do not create outbounds");
assert(route_rule(dns_action, r => contains(r.domain_suffix, "dns-first.example") && r.outbound != null) != null, "proxy still owns its route rule");
assert(route_rule(dns_action, r => contains(r.domain_suffix, "list-dns.example")) == null, "DNS action does not create route rules");
let dns_first_index = dns_rule_index(dns_action, r => contains(r.domain_suffix, "dns-first.example") && r.server == "dns_first-dns-server");
let proxy_after_dns_index = dns_rule_index(dns_action, r => contains(r.domain_suffix, "dns-first.example") && r.server == "fakeip-server");
assert(dns_first_index >= 0 && proxy_after_dns_index > dns_first_index, "higher DNS action wins over lower proxy DNS rule");
let proxy_first_index = dns_rule_index(dns_action, r => contains(r.domain_suffix, "proxy-first.example") && r.server == "fakeip-server");
let dns_after_proxy_index = dns_rule_index(dns_action, r => contains(r.domain_suffix, "proxy-first.example") && r.server == "dns_second-dns-server");
assert(proxy_first_index >= 0 && dns_after_proxy_index > proxy_first_index, "higher proxy DNS rule wins over lower DNS action");
assert(dns_rule(dns_action, r => contains(r.rule_set, "dns_first-youtube-community-ruleset") && r.server == "dns_first-dns-server") != null, "DNS action built-in domain rule set");
let dns_custom_ruleset = ruleset_url(dns_action, "https://example.com/domain-only.srs");
assert(dns_custom_ruleset && dns_rule(dns_action, r => contains(r.rule_set, dns_custom_ruleset.tag) && r.server == "dns_first-dns-server") != null, "DNS action custom domain rule set");
let dns_list = json(fs.readfile(dir + "/dns-action.json.rulesets/dns_first-lists-ruleset.json"));
assert(index(sprintf("%J", dns_list), "list-dns.example") >= 0, "DNS action imports domains from plain lists");
assert(index(sprintf("%J", dns_list), "198.51.100.0/24") < 0, "DNS action drops subnets from plain lists");

let urltest = cfg("urltest");
let urltest_out = outbound(urltest, "proxy-urltest-out");
assert(urltest_out && length(urltest_out.outbounds) == 1 && urltest_out.outbounds[0] == "Keep", "URLTest include filter");
assert(outbound(urltest, "Keep").type == "http", "HTTP JSON outbound remains supported");
assert(outbound(urltest, "proxy-out").default == "proxy-urltest-out", "selector defaults to URLTest");

let providers = cfg("providers");
assert(outbound(providers, "zap-out").routing_mark == 0x01000001, "Zapret mark");
assert(outbound(providers, "zap2-out").routing_mark == 0x02000001, "Zapret2 mark");
assert(outbound(providers, "bye-out").type == "socks" && outbound(providers, "bye-out").server_port == 1080, "ByeDPI outbound");

let manual = cfg("manual");
let vless = outbound(manual, "proxy-1-out");
assert(vless.transport.type == "ws" && vless.transport.path == "/ws", "manual VLESS WS transport");
assert(vless.tls.server_name == "example.com", "manual VLESS TLS");
assert(length(vless.tls.alpn) == 1 && vless.tls.alpn[0] == "http/1.1", "manual VLESS WS ALPN normalized");
assert(vless.encryption == "mlkem768x25519plus.native.test", "manual VLESS encryption preserved");
let vmess = outbound(manual, "proxy-2-out");
assert(vmess.type == "vmess" && vmess.uuid == "22222222-2222-4222-8222-222222222222", "manual VMess link");
assert(vmess.alter_id == 4 && vmess.security == "auto", "manual VMess alter_id and security");
assert(vmess.transport.type == "ws" && vmess.transport.path == "/vmess", "manual VMess WS transport");
assert(vmess.transport.headers.Host == "vmess.example", "manual VMess WS Host header");
assert(vmess.tls.server_name == "vmess.example", "manual VMess TLS SNI");
assert(length(vmess.tls.alpn) == 1 && vmess.tls.alpn[0] == "http/1.1", "manual VMess WS ALPN normalized");
assert(vmess.tls.utls.fingerprint == "chrome", "manual VMess fingerprint");
assert(outbound(manual, "proxy-3-out").type == "shadowsocks", "manual Shadowsocks link");

let vpn = cfg("vpn");
assert(outbound(vpn, "renamed_awg-interface-1-out").bind_interface == "tun0", "renamed VPN interface outbound");
assert(outbound(vpn, "renamed_awg-interface-1-out").domain_resolver == "renamed_awg-interface-1-domain-resolver", "renamed VPN domain resolver tag");
assert(dns_server(vpn, r => r.tag == "renamed_awg-interface-1-domain-resolver") != null, "renamed VPN domain resolver DNS server");
assert(outbound(vpn, "renamed_awg-interface-1-out").detour == null, "interface outbound must not receive a detour");
assert(route_rule(vpn, r => r.outbound == "renamed_awg-out" && contains(r.domain_suffix, "vpn.example")) != null, "renamed VPN custom domain route");
assert(dns_rule(vpn, r => contains(r.domain_suffix, "vpn.example")) != null, "renamed VPN custom domain DNS rule");

let download = cfg("download");
assert(inbound(download, "service-mixed-in") != null, "service mixed inbound");
assert(route_rule(download, r => r.inbound == "service-mixed-in" && r.outbound == "proxy-out") != null, "service mixed route");
assert(inbound(download, "service-components-in") != null, "components service mixed inbound");
assert(route_rule(download, r => r.inbound == "service-components-in" && r.outbound == "components_proxy-out") != null, "components service mixed route");
assert(ruleset(download, "proxy-discord-community-ruleset").download_detour == "proxy-out", "download_detour on community ruleset");
assert(ruleset_url(download, "https://example.com/rules.srs").download_detour == "proxy-out", "download_detour on custom remote ruleset");

let fully = cfg("fully-routed");
assert(route_rule(fully, r => r.outbound == "bypass-out" && contains(r.inbound, "tproxy-in") && contains(r.inbound, "tproxy6-in") && contains(r.source_ip_cidr, "192.168.1.20/32") && contains(r.source_ip_cidr, "192.168.1.30/32") && contains(r.source_ip_cidr, "2001:db8::20/128")) != null, "fully routed bypass IP route");
assert(route_rule(fully, r => r.outbound == "proxy-out" && contains(r.source_ip_cidr, "192.168.1.40/32")) != null, "fully routed proxy IP route");
let fully_bypass_dns = dns_rule(fully, r =>
    r.type == "logical" && r.server == "dnsmasq-server" &&
    length(r.rules || []) == 2 && contains(r.rules[0].source_ip_cidr, "192.168.1.20/32") &&
    r.rules[0].domain == null && r.rules[0].domain_suffix == null && r.rules[0].rule_set == null);
assert(fully_bypass_dns != null, "fully routed bypass rejects FakeIP for every domain");
assert(dns_rule(fully, r => r.server == "dns-server" && contains(r.source_ip_cidr, "192.168.1.20/32") && contains(r.query_type, "A")) != null, "fully routed bypass falls back to real DNS");
assert(dns_rule(fully, r => r.type == "logical" && r.server == "dnsmasq-server" && length(r.rules || []) > 0 && contains(r.rules[0].source_ip_cidr, "192.168.1.40/32")) == null, "fully routed proxy keeps normal FakeIP policy");
let higher_proxy_dns_index = dns_rule_index(fully, r => r.server == "fakeip-server" && contains(r.domain_suffix, "forced-higher.test"));
let forced_bypass_dns_index = dns_rule_index(fully, r => r.type == "logical" && r.server == "dnsmasq-server" && length(r.rules || []) > 0 && contains(r.rules[0].source_ip_cidr, "192.168.1.20/32"));
let lower_proxy_dns_index = dns_rule_index(fully, r => r.server == "fakeip-server" && contains(r.domain_suffix, "forced-lower.test"));
assert(higher_proxy_dns_index >= 0 && forced_bypass_dns_index > higher_proxy_dns_index && lower_proxy_dns_index > forced_bypass_dns_index, "forced bypass stays at its section priority in DNS rules");
let higher_proxy_route_index = route_rule_index(fully, r => r.outbound == "proxy_high-out" && contains(r.domain_suffix, "forced-higher.test"));
let forced_bypass_route_index = route_rule_index(fully, r => r.outbound == "bypass-out" && contains(r.source_ip_cidr, "192.168.1.20/32") && r.domain == null && r.domain_suffix == null);
let lower_proxy_route_index = route_rule_index(fully, r => r.outbound == "proxy-out" && contains(r.domain_suffix, "forced-lower.test"));
assert(higher_proxy_route_index >= 0 && forced_bypass_route_index > higher_proxy_route_index && lower_proxy_route_index > forced_bypass_route_index, "forced bypass stays at its section priority in route rules");

let mwan3_auto = cfg("mwan3-auto");
assert(mwan3_auto.route.auto_detect_interface === false, "mwan3 disables auto_detect_interface");
assert(mwan3_auto.route.default_interface == null, "mwan3 without pinned interface does not set default_interface");

let mwan3_pinned = cfg("mwan3-pinned");
assert(mwan3_pinned.route.auto_detect_interface === false, "mwan3 pinned interface disables auto_detect_interface");
assert(mwan3_pinned.route.default_interface == "wan2", "mwan3 pinned interface is preserved");

let lists = cfg("domain-ip-rulesets");
assert(no_internal_fields(lists), "internal runtime fields stripped from generated config");
let local_ruleset = null;
for (let rule_set in lists.route.rule_set || [])
    if (rule_set.tag == "proxy-lists-ruleset")
        local_ruleset = rule_set;
assert(local_ruleset && local_ruleset.type == "local" && local_ruleset.format == "source", "domain_ip_lists local ruleset");
assert(route_rule(lists, r => contains(r.rule_set, "proxy-lists-ruleset") && length(as_array(r.rule_set)) >= 2) != null, "domain_ip_lists and rule_set_with_subnets route");
assert(dns_rule(lists, r => contains(r.rule_set, "proxy-lists-ruleset")) != null, "domain_ip_lists fakeip DNS rule");

let generated_list = json(fs.readfile(dir + "/domain-ip-rulesets.json.rulesets/proxy-lists-ruleset.json"));
let has_domain = false;
let has_ip = false;
for (let rule in generated_list.rules || []) {
    if (contains(rule.domain_suffix, "example.net"))
        has_domain = true;
    if (contains(rule.ip_cidr, "203.0.113.0/24"))
        has_ip = true;
}
assert(has_domain && has_ip, "generated domain/IP source ruleset contents");

let subscription_group = cfg("subscription-group");
let provider_group = outbound(subscription_group, "Provider Group");
assert(provider_group && provider_group.type == "urltest", "provider URLTest group imported");
assert(length(provider_group.outbounds) == 2, "provider URLTest group keeps leaf references");
assert(provider_group.outbounds[0] == "grouped-out-1", "provider URLTest group leaf reference retagged");
assert(provider_group.outbounds[1] == "leaf", "provider URLTest group second leaf reference kept");
assert(provider_group.detour == null, "provider URLTest group does not receive outbound detour");
let grouped_leaf = outbound(subscription_group, "grouped-out-1");
let second_leaf = outbound(subscription_group, "leaf");
assert(grouped_leaf && grouped_leaf.detour == null, "hidden subscription leaf does not receive connection URL detour");
assert(second_leaf && second_leaf.detour == null, "second hidden subscription leaf does not receive connection URL detour");
assert(outbound(subscription_group, "provider-direct") == null, "provider direct outbound skipped");
assert(outbound(subscription_group, "provider-http") == null, "provider HTTP outbound skipped");
let grouped_selector = outbound(subscription_group, "grouped-out");
assert(grouped_selector && length(grouped_selector.outbounds) == 1 && grouped_selector.outbounds[0] == "Provider Group", "selector exposes provider group only");
let grouped_state = cfg("subscription-group.json.section-cache/grouped");
assert(grouped_state.outboundMetadata.names["Provider Group"] == "Provider Group", "provider group metadata visible");
assert(grouped_state.outboundMetadata.names["grouped-out-1"] == "grouped-out", "hidden leaf metadata visible");
assert(length(grouped_state.urltestGroups["Provider Group"].outbounds) == 2, "provider group membership cached");
assert(grouped_state.urltestGroups["Provider Group"].outbounds[0] == "grouped-out-1", "provider group membership retagged");
assert(grouped_state.linkRefs == null, "section cache omits source link refs");
assert(index(grouped_state.links["grouped-out-1"], "vless://") == 0, "hidden leaf caches its direct proxy link");
assert(index(grouped_state.links["leaf"], "vless://") == 0, "second hidden leaf caches its direct proxy link");
let subscription_group_disabled = cfg("subscription-group-disabled");
assert(outbound(subscription_group_disabled, "Provider Group") == null, "provider URLTest group skipped when import is disabled");
let disabled_grouped_leaf = outbound(subscription_group_disabled, "grouped-out-1");
let disabled_second_leaf = outbound(subscription_group_disabled, "leaf");
assert(disabled_grouped_leaf && disabled_second_leaf, "URLTest group leaf outbounds kept when import is disabled");
let disabled_grouped_selector = outbound(subscription_group_disabled, "grouped-out");
assert(disabled_grouped_selector && contains(disabled_grouped_selector.outbounds, "grouped-out-1") && contains(disabled_grouped_selector.outbounds, "leaf"), "selector exposes URLTest group leaves when import is disabled");
let disabled_grouped_state = cfg("subscription-group-disabled.json.section-cache/grouped");
assert(disabled_grouped_state.urltestGroups["Provider Group"] == null, "skipped provider group is not cached as URLTest");
assert(disabled_grouped_state.linkRefs == null, "disabled group cache omits source link refs");
assert(index(disabled_grouped_state.links["grouped-out-1"], "vless://") == 0, "visible leaf caches its direct proxy link when group import is disabled");

let xhttp_stable = cfg("subscription-xhttp-stable");
assert(outbound(xhttp_stable, "xhttp-node") == null, "stable sing-box excludes XHTTP subscription leaf");
assert(outbound(xhttp_stable, "depends-on-xhttp") == null, "stable sing-box excludes outbound detouring through XHTTP");
assert(outbound(xhttp_stable, "recursive-dependent") == null, "stable sing-box recursively excludes XHTTP-dependent detours");
let stable_provider_group = outbound(xhttp_stable, "Provider XHTTP Group");
assert(stable_provider_group && length(stable_provider_group.outbounds) == 1 && stable_provider_group.outbounds[0] == "plain-node", "provider group removes XHTTP member");
assert(stable_provider_group.default == null, "stable sing-box provider URLTest removes unsupported default field");
let stable_urltest = outbound(xhttp_stable, "xhttp-urltest-ut_xhttp-out");
assert(stable_urltest && length(stable_urltest.outbounds) == 1 && stable_urltest.outbounds[0] == "plain-node", "URLTest receives only compatible subscription leaves");
let stable_priority = outbound(xhttp_stable, "xhttp-priority-pg_xhttp-out");
assert(stable_priority && length(stable_priority.outbounds) == 1 && stable_priority.outbounds[0] == "plain-node", "Priority receives only compatible subscription leaves");

let xhttp_extended = cfg("subscription-xhttp-extended");
assert(outbound(xhttp_extended, "xhttp-node") != null, "extended sing-box keeps XHTTP subscription leaf");
assert(outbound(xhttp_extended, "Provider XHTTP Group").default == null, "extended sing-box provider URLTest also removes unsupported default field");
assert(outbound(xhttp_extended, "depends-on-xhttp").detour == "xhttp-node", "extended sing-box keeps XHTTP detour chain");
assert(outbound(xhttp_extended, "recursive-dependent").detour == "depends-on-xhttp", "extended sing-box keeps recursive detour chain");

let proxy_cache = json(fs.readfile(dir + "/subscription-metadata.json.section-cache/proxy.json"));
let test_cache = json(fs.readfile(dir + "/subscription-metadata.json.section-cache/test.json"));
let proxy_share_link_cached = false;
for (let tag, link in proxy_cache.links || {})
    if (link == "socks5://127.0.0.1:1080#subscription-proxy")
        proxy_share_link_cached = true;
assert(proxy_share_link_cached, "subscription share link cached for instant dashboard copy");
assert(proxy_cache.linkRefs == null && test_cache.linkRefs == null, "subscription caches contain direct links without source refs");
let proxy_metadata = as_array(proxy_cache.subscriptionMetadata);
let test_metadata = as_array(test_cache.subscriptionMetadata);
assert(length(proxy_metadata) == 2, "duplicate subscription URL metadata kept for both proxy sources");
assert(proxy_metadata[0].sourceSection == "proxy-subscription-1" && proxy_metadata[0].title == "WolfPN", "proxy source 1 metadata marker");
assert(proxy_metadata[1].sourceSection == "proxy-subscription-2" && proxy_metadata[1].title == "WolfPN", "proxy source 2 metadata marker");
assert(length(test_metadata) == 1, "same subscription URL metadata kept for second section");
assert(test_metadata[0].sourceSection == "test-subscription-1" && test_metadata[0].title == "WolfPN", "test source metadata marker");
' "$WORK_DIR"

printf 'sing-box runtime checks passed\n'
