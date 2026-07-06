#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
PODKOP_BIN="$ROOT_DIR/podkop/files/usr/bin/podkop"
CLI_UC="$PODKOP_BIN"
SING_BOX_RUNTIME_SH="$PODKOP_LIB/sing_box_runtime.sh"
LIFECYCLE_UC="$PODKOP_LIB/service/lifecycle.uc"
SINGBOX_RUNTIME_UC="$PODKOP_LIB/singbox/runtime.uc"
SINGBOX_GENERATOR_UC="$PODKOP_LIB/singbox/generator.uc"
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
grep -Fq '#!/usr/bin/ucode' "$PODKOP_BIN" ||
  fail "podkop entrypoint must be a direct ucode executable"
grep -Fq 'service/lifecycle.uc' "$CLI_UC" ||
  fail "service/cli.uc must dispatch lifecycle orchestration through service/lifecycle.uc"
grep -Fq 'singbox/runtime.uc' "$LIFECYCLE_UC" ||
  fail "service/lifecycle.uc must call singbox/runtime.uc for sing-box runtime operations"
if grep -R -n -E 'sing_box_runtime_ucode|rulesets_ucode|sing_box_configure_service|sing_box_init_config|get_service_listen_address|get_device_ipv4_address|get_download_detour_tag' "$PODKOP_BIN" "$PODKOP_LIB" --include='*.sh' >/dev/null 2>&1; then
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
grep -Fq 'PODKOP_RULE_CONDITION_CACHE_DIR' "$LIFECYCLE_UC" ||
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

mkdir -p "$WORK_DIR/etc" "$WORK_DIR/tmp"
printf 'old config\n' >"$WORK_DIR/etc/config.json"
printf 'new config\n' >"$WORK_DIR/tmp/config.json"
ucode -L "$PODKOP_LIB" "$SINGBOX_RUNTIME_UC" save-config-file-fixture \
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
  ucode -L "$PODKOP_LIB" "$PODKOP_LIB/singbox/generator.uc" generate-config-fixture \
    "$fixture" "$output" "127.0.0.1" "$mwan3_active"
}

generate_config_with_subscription_cache() {
  local fixture="$1"
  local output="$2"

  mkdir -p "$output.section-cache" "$output.rulesets"
  TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions" \
    PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent-subscription-cache" \
    ucode -L "$PODKOP_LIB" "$PODKOP_LIB/singbox/generator.uc" generate-config-fixture \
      "$fixture" "$output" "127.0.0.1" "0"
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

if ucode -L "$PODKOP_LIB" "$SINGBOX_GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/no-enabled-fixture.json" "$WORK_DIR/no-enabled.json" "127.0.0.1" "0" \
  >"$WORK_DIR/no-enabled.stdout" 2>"$WORK_DIR/no-enabled.stderr"; then
  fail "generator should reject a config without enabled sections"
fi
if grep -Fq 'unsupported:' "$WORK_DIR/no-enabled.stderr"; then
  fail "generator failure reason must not include redundant unsupported prefix"
fi
grep -Fxq 'no enabled sections' "$WORK_DIR/no-enabled.stderr" ||
  fail "generator failure reason should be concise"

cat >"$WORK_DIR/generator-uci.state" <<'EOF_UCI'
podkop-plus.settings=settings
podkop-plus.settings.dns_server=1.1.1.1
podkop-plus.settings.bootstrap_dns_server=1.1.1.1
podkop-plus.settings.config_path=/tmp/sing-box/config.json
podkop-plus.settings.cache_path=/tmp/sing-box/cache.db
podkop-plus.settings.log_level=warn
podkop-plus.uci_proxy=section
podkop-plus.uci_proxy.enabled=1
podkop-plus.uci_proxy.action=connection
podkop-plus.uci_proxy.outbound_jsons={"type":"direct"}
podkop-plus.uci_proxy.domain_suffix=example.org
EOF_UCI
PODKOP_UCI_STATE_FILE="$WORK_DIR/generator-uci.state" \
  PODKOP_SECTION_CACHE_DIR="$WORK_DIR/generated-from-uci.section-cache" \
  ucode -L "$PODKOP_LIB" "$SINGBOX_GENERATOR_UC" generate-config "$WORK_DIR/generated-from-uci.json" "127.0.0.1" "0"
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
      "domain_suffix": [ "proxy.example.org", "сайт.рф", "full:пример.испытание", "keyword:пример", "regex:^сайт[.]рф$" ],
      "source_ip_cidr": [ "10.0.0.2/32", "2001:db8::2/128" ],
      "connection_url_settings": "{\"socks5://127.0.0.1:1080\":{\"outbound_detour_enabled\":\"1\",\"outbound_detour_section\":\"detour\"}}",
      "mixed_proxy_enabled": "1",
      "mixed_proxy_port": "19090",
      "mixed_proxy_auth_enabled": "1",
      "mixed_proxy_username": "user",
      "mixed_proxy_password": "pass"
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
      "selector_proxy_links": [
        "http://127.0.0.1:18081#Keep",
        "http://127.0.0.1:18082#Drop"
      ],
      "urltest_enabled": "1",
      "urltest_filter_mode": "include",
      "urltest_include_outbounds": [ "Keep" ],
      "domain_suffix": [ "example.org" ]
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

cat >"$WORK_DIR/vpn-domain-resolver-fixture.json" <<'JSON'
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
      "interfaces": [ "tun0" ],
      "interface_settings": "{\"tun0\":{\"domain_resolver_enabled\":\"1\",\"domain_resolver_dns_type\":\"doh\",\"domain_resolver_dns_server\":\"https://dns.example/dns-query\"}}",
      "domain_suffix": [ "vpn.example" ]
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
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "outbound",
      "outbound_json": "{\"type\":\"direct\"}",
      "fully_routed_ips": [ "192.168.1.20/32", "192.168.1.30/32", "2001:db8::20/128" ],
      "domain_suffix": [ "example.org" ]
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
      "__podkop_allow_group": true
    },
    {
      "type": "vless",
      "tag": "grouped-out",
      "server": "127.0.0.1",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000001",
      "tls": { "enabled": true, "server_name": "example.com" },
      "__podkop_hidden": true
    },
    {
      "type": "vless",
      "tag": "leaf",
      "server": "127.0.0.2",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000002",
      "tls": { "enabled": true, "server_name": "example.org" },
      "__podkop_hidden": true
    },
    {
      "type": "direct",
      "tag": "provider-direct"
    }
  ]
}
JSON
printf '%s' 'https://example.com/group.json' >"$WORK_DIR/subscriptions/grouped-subscription-1.url"
printf '%s' 'Happ' >"$WORK_DIR/subscriptions/grouped-subscription-1.user_agent"

generate_config "$WORK_DIR/disabled-updates-fixture.json" "$WORK_DIR/disabled.json"
generate_config "$WORK_DIR/default-updates-fixture.json" "$WORK_DIR/default.json"
generate_config "$WORK_DIR/server-inbound-fixture.json" "$WORK_DIR/server.json"
generate_config "$WORK_DIR/runtime-matchers-fixture.json" "$WORK_DIR/matchers.json"
generate_config "$WORK_DIR/urltest-filter-fixture.json" "$WORK_DIR/urltest.json"
generate_config "$WORK_DIR/provider-actions-fixture.json" "$WORK_DIR/providers.json"
generate_config "$WORK_DIR/manual-transport-fixture.json" "$WORK_DIR/manual.json"
generate_config "$WORK_DIR/vpn-domain-resolver-fixture.json" "$WORK_DIR/vpn.json"
generate_config "$WORK_DIR/download-via-proxy-fixture.json" "$WORK_DIR/download.json"
generate_config "$WORK_DIR/fully-routed-fixture.json" "$WORK_DIR/fully-routed.json"
generate_config "$WORK_DIR/mwan3-auto-fixture.json" "$WORK_DIR/mwan3-auto.json" 1
generate_config "$WORK_DIR/mwan3-pinned-fixture.json" "$WORK_DIR/mwan3-pinned.json" 1
generate_config "$WORK_DIR/domain-ip-rulesets-fixture.json" "$WORK_DIR/domain-ip-rulesets.json"
generate_config_with_subscription_cache "$WORK_DIR/subscription-metadata-fixture.json" "$WORK_DIR/subscription-metadata.json"
generate_config_with_subscription_cache "$WORK_DIR/subscription-group-fixture.json" "$WORK_DIR/subscription-group.json"
generate_config_with_subscription_cache "$WORK_DIR/subscription-group-disabled-fixture.json" "$WORK_DIR/subscription-group-disabled.json"

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

function dns_rule(config, predicate) {
    for (let rule in config.dns.rules || [])
        if (rule && predicate(rule))
            return rule;
    return null;
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

let server = cfg("server");
let socks = inbound(server, "server-edge-in");
assert(socks && socks.type == "socks" && socks.listen_port == 18080, "server socks inbound");
assert(socks.users && socks.users[0].username == "tester", "server socks auth");
assert(route_rule(server, r => r.inbound == "server-edge-in" && r.outbound == "direct-out") != null, "server direct route");

let matchers = cfg("matchers");
assert(matchers.dns.strategy == "prefer_ipv4", "DNS strategy allows IPv6 answers");
assert(dns_server(matchers, r => r.tag == "fakeip-server" && r.inet6_range == "fc00::/18") != null, "FakeIP IPv6 range");
assert(inbound(matchers, "tproxy6-in") != null, "IPv6 TProxy inbound");
assert(inbound(matchers, "tproxy6-in").listen == "::1", "IPv6 TProxy listen address");
assert(outbound(matchers, "bypass-out").type == "direct", "bypass fallback outbound");
assert(outbound(matchers, "proxy-1-out").detour == "detour-out", "connection URL outbound detour");
let mixed = inbound(matchers, "proxy-mixed-in");
assert(mixed && mixed.listen_port == 19090 && mixed.users[0].username == "user", "mixed inbound auth");
assert(route_rule(matchers, r => r.inbound == "proxy-mixed-in" && r.outbound == "proxy-out") != null, "mixed inbound route");
assert(dns_rule(matchers, r => contains(r.domain_suffix, "example.org")).server == "dns-server", "bypass domain real DNS rule");
assert(dns_rule(matchers, r => contains(r.domain_suffix, "proxy.example.org")).server == "fakeip-server", "proxy domain FakeIP DNS rule");
assert(dns_rule(matchers, r => contains(r.domain_suffix, "xn--80aswg.xn--p1ai")).server == "fakeip-server", "IDN suffix converted for DNS rule");
assert(dns_rule(matchers, r => contains(r.domain, "xn--e1afmkfd.xn--80akhbyknj4f")).server == "fakeip-server", "IDN full domain converted for DNS rule");
assert(dns_rule(matchers, r => contains(r.domain_keyword, "xn--e1afmkfd")).server == "fakeip-server", "IDN keyword converted for DNS rule");
assert(dns_rule(matchers, r => contains(r.domain_regex, "^xn--80aswg[.]xn--p1ai$")).server == "fakeip-server", "IDN regex converted for DNS rule");
assert(route_rule(matchers, r => r.outbound == "bypass-out" && contains(r.domain_suffix, "example.org") && contains(r.source_ip_cidr, "10.0.0.3/32")) != null, "bypass fallback route");
assert(route_rule(matchers, r => r.outbound == "proxy-out" && contains(r.domain_suffix, "xn--80aswg.xn--p1ai")) != null, "IDN suffix converted for route rule");
assert(route_rule(matchers, r => r.outbound == "proxy-out" && contains(r.domain, "xn--e1afmkfd.xn--80akhbyknj4f")) != null, "IDN full domain converted for route rule");
assert(route_rule(matchers, r => r.outbound == "proxy-out" && contains(r.domain_keyword, "xn--e1afmkfd")) != null, "IDN keyword converted for route rule");
assert(route_rule(matchers, r => r.outbound == "proxy-out" && contains(r.domain_regex, "^xn--80aswg[.]xn--p1ai$")) != null, "IDN regex converted for route rule");
assert(route_rule(matchers, r => contains(r.inbound, "tproxy-in") && contains(r.inbound, "tproxy6-in") && r.outbound == "proxy-out") != null, "section route dual tproxy inbound");
assert(route_rule(matchers, r => r.outbound == "direct-out" && contains(r.source_ip_cidr, "192.168.1.5/32")) == null, "routing excluded source removed");
assert(route_rule(matchers, r => r.outbound == "proxy-out" && contains(r.source_ip_cidr, "10.0.0.2/32") && contains(r.source_ip_cidr, "2001:db8::2/128")) != null, "source_ip_cidr matcher");

let urltest = cfg("urltest");
let urltest_out = outbound(urltest, "proxy-urltest-out");
assert(urltest_out && length(urltest_out.outbounds) == 1 && urltest_out.outbounds[0] == "proxy-1-out", "URLTest include filter");
assert(outbound(urltest, "proxy-out").default == "proxy-urltest-out", "selector defaults to URLTest");

let providers = cfg("providers");
assert(outbound(providers, "zap-out").routing_mark == 0x01000001, "Zapret mark");
assert(outbound(providers, "zap2-out").routing_mark == 0x01010001, "Zapret2 mark");
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
assert(route_rule(vpn, r => r.outbound == "renamed_awg-out" && contains(r.domain_suffix, "vpn.example")) != null, "renamed VPN custom domain route");
assert(dns_rule(vpn, r => contains(r.domain_suffix, "vpn.example")) != null, "renamed VPN custom domain DNS rule");

let download = cfg("download");
assert(inbound(download, "service-mixed-in") != null, "service mixed inbound");
assert(route_rule(download, r => r.inbound == "service-mixed-in" && r.outbound == "proxy-out") != null, "service mixed route");
assert(inbound(download, "service-components-in") != null, "components service mixed inbound");
assert(route_rule(download, r => r.inbound == "service-components-in" && r.outbound == "components_proxy-out") != null, "components service mixed route");
assert(first_remote_ruleset(download).download_detour == "proxy-out", "download_detour on remote ruleset");

let fully = cfg("fully-routed");
assert(route_rule(fully, r => contains(r.inbound, "tproxy-in") && contains(r.inbound, "tproxy6-in") && contains(r.source_ip_cidr, "192.168.1.20/32") && contains(r.source_ip_cidr, "192.168.1.30/32") && contains(r.source_ip_cidr, "2001:db8::20/128")) != null, "fully routed IP route");

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
let grouped_selector = outbound(subscription_group, "grouped-out");
assert(grouped_selector && length(grouped_selector.outbounds) == 1 && grouped_selector.outbounds[0] == "Provider Group", "selector exposes provider group only");
let grouped_state = cfg("subscription-group.json.section-cache/grouped");
assert(grouped_state.outboundMetadata.names["Provider Group"] == "Provider Group", "provider group metadata visible");
assert(grouped_state.outboundMetadata.names["grouped-out-1"] == "grouped-out", "hidden leaf metadata visible");
assert(length(grouped_state.urltestGroups["Provider Group"].outbounds) == 2, "provider group membership cached");
assert(grouped_state.urltestGroups["Provider Group"].outbounds[0] == "grouped-out-1", "provider group membership retagged");
assert(grouped_state.linkRefs["Provider Group"] == null, "provider group has no source link ref");
assert(grouped_state.linkRefs["grouped-out-1"].sourceIndex == 2, "hidden leaf keeps source link ref");
let subscription_group_disabled = cfg("subscription-group-disabled");
assert(outbound(subscription_group_disabled, "Provider Group") == null, "provider URLTest group skipped when import is disabled");
let disabled_grouped_leaf = outbound(subscription_group_disabled, "grouped-out-1");
let disabled_second_leaf = outbound(subscription_group_disabled, "leaf");
assert(disabled_grouped_leaf && disabled_second_leaf, "URLTest group leaf outbounds kept when import is disabled");
let disabled_grouped_selector = outbound(subscription_group_disabled, "grouped-out");
assert(disabled_grouped_selector && contains(disabled_grouped_selector.outbounds, "grouped-out-1") && contains(disabled_grouped_selector.outbounds, "leaf"), "selector exposes URLTest group leaves when import is disabled");
let disabled_grouped_state = cfg("subscription-group-disabled.json.section-cache/grouped");
assert(disabled_grouped_state.urltestGroups["Provider Group"] == null, "skipped provider group is not cached as URLTest");
assert(disabled_grouped_state.linkRefs["grouped-out-1"].sourceIndex == 2, "visible leaf keeps source link ref when group import is disabled");

let proxy_cache = json(fs.readfile(dir + "/subscription-metadata.json.section-cache/proxy.json"));
let test_cache = json(fs.readfile(dir + "/subscription-metadata.json.section-cache/test.json"));
let proxy_metadata = as_array(proxy_cache.subscriptionMetadata);
let test_metadata = as_array(test_cache.subscriptionMetadata);
assert(length(proxy_metadata) == 2, "duplicate subscription URL metadata kept for both proxy sources");
assert(proxy_metadata[0].sourceSection == "proxy-subscription-1" && proxy_metadata[0].title == "WolfPN", "proxy source 1 metadata marker");
assert(proxy_metadata[1].sourceSection == "proxy-subscription-2" && proxy_metadata[1].title == "WolfPN", "proxy source 2 metadata marker");
assert(length(test_metadata) == 1, "same subscription URL metadata kept for second section");
assert(test_metadata[0].sourceSection == "test-subscription-1" && test_metadata[0].title == "WolfPN", "test source metadata marker");
' "$WORK_DIR"

printf 'sing-box runtime regression checks passed\n'
