#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
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

config_get() {
  local __var="$1"
  local section="$2"
  local option="$3"
  local default="${4:-}"
  local value_var="CONFIG_${section}_${option}"
  local config_value="${!value_var-}"

  if [ -n "$config_value" ]; then
    printf -v "$__var" '%s' "$config_value"
  else
    printf -v "$__var" '%s' "$default"
  fi
}

config_get_bool() {
  local __var="$1"
  local section="$2"
  local option="$3"
  local default="${4:-0}"
  local bool_value

  config_get bool_value "$section" "$option" "$default"
  case "$bool_value" in
  1 | true | yes | on)
    printf -v "$__var" '%s' 1
    ;;
  *)
    printf -v "$__var" '%s' 0
    ;;
  esac
}

config_list_foreach() {
  local section="$1"
  local option="$2"
  local callback="$3"
  shift 3
  local list_var="CONFIG_LIST_${section}_${option}"
  local values="${!list_var-}"
  local value

  [ -n "$values" ] || return 0
  while IFS= read -r value || [ -n "$value" ]; do
    "$callback" "$value" "$@"
  done <<< "$values"
}

config_foreach() {
  local callback="$1"
  local type="$2"
  shift 2

  [ "$type" = "section" ] || return 0
  "$callback" "proxy"
}

log() {
  :
}

rule_is_enabled() {
  [ "$1" = "proxy" ]
}

get_rule_action() {
  [ "$1" = "proxy" ] && printf 'proxy\n'
}

rule_has_subscription_urls() {
  return 1
}

urltest_filter_mode_filters_enabled() {
  case "$1" in
  exclude | include | mixed)
    return 0
    ;;
  esac

  return 1
}

get_urltest_check_interval_for_rule() {
  local section="$1"
  local enabled interval

  config_get_bool enabled "$section" "urltest_enabled" 0
  if [ "$enabled" -eq 0 ]; then
    printf '\n'
    return 0
  fi

  config_get interval "$section" "urltest_check_interval"
  if [ -n "$interval" ]; then
    printf '%s\n' "$interval"
  else
    printf '3m\n'
  fi
}

write_subscription_metadata_json() {
  :
}

write_subscription_outbound_link_cache() {
  :
}

write_outbound_metadata() {
  :
}

subscription_section_is_deferred() {
  return 1
}

duration_to_seconds() {
  ucode "$PODKOP_LIB/updates.uc" duration-to-seconds "$1"
}

normalize_detect_server_country_method() {
  case "$1" in
  country_is)
    printf 'country_is\n'
    ;;
  *)
    printf 'flag_emoji\n'
    ;;
  esac
}

is_zapret_installed() {
  return 1
}

is_zapret2_installed() {
  return 1
}

is_byedpi_installed() {
  return 1
}

get_outbound_detour_tag_for_rule() {
  return 0
}

export PODKOP_LIB
TMP_SING_BOX_FOLDER="$WORK_DIR/sing-box"
TMP_SUBSCRIPTION_FOLDER="$TMP_SING_BOX_FOLDER/subscriptions"
PODKOP_SECTION_CACHE_DIR="$WORK_DIR/section-cache"
PODKOP_RUNTIME_CACHE_FORMAT=6
SING_BOX_DISABLED_UPDATE_INTERVAL="876000h"
SING_BOX_URLTEST_DEFAULT_IDLE_TIMEOUT="30m"
SERVER_COUNTRY_METHOD_FLAG_EMOJI="flag_emoji"
SERVER_COUNTRY_METHOD_COUNTRY_IS="country_is"
PODKOP_URLTEST_NEW_ENABLED_SECTIONS=""
PODKOP_URLTEST_SELECTOR_SWITCHES=""
SB_DIRECT_OUTBOUND_TAG="direct-out"
SB_DNS_SERVER_TAG="dns-server"
SB_FAKEIP_DNS_SERVER_TAG="fakeip-server"
SB_BOOTSTRAP_SERVER_TAG="bootstrap-dns-server"
SB_FAKEIP_DNS_RULE_TAG="fakeip-dns-rule-tag"
SB_FAKEIP_RULESET_DNS_RULE_TAG="fakeip-ruleset-dns-rule-tag"
SB_SERVICE_FAKEIP_DNS_RULE_TAG="service-fakeip-dns-rule-tag"
SB_TPROXY_INBOUND_TAG="tproxy-in"
SB_DNS_INBOUND_TAG="dns-in"
SB_SERVICE_MIXED_INBOUND_TAG="service-mixed-in"

mkdir -p "$TMP_SUBSCRIPTION_FOLDER" "$PODKOP_SECTION_CACHE_DIR"

# shellcheck source=/dev/null
. "$PODKOP_LIB/helpers.sh"
# shellcheck source=/dev/null
. "$PODKOP_LIB/subscription_parser.sh"
# shellcheck source=/dev/null
. "$PODKOP_LIB/sing_box_config_manager.sh"
# shellcheck source=/dev/null
. "$PODKOP_LIB/sing_box_config_facade.sh"
# shellcheck source=/dev/null
. "$PODKOP_LIB/sing_box_runtime.sh"

CONFIG_proxy_action="proxy"
CONFIG_proxy_urltest_enabled="1"
CONFIG_proxy_urltest_check_interval="3m"
CONFIG_proxy_urltest_tolerance="50"
CONFIG_proxy_urltest_testing_url="https://www.gstatic.com/generate_204"
CONFIG_proxy_urltest_filter_mode="disabled"
CONFIG_proxy_detect_server_country="flag_emoji"
CONFIG_LIST_proxy_selector_proxy_links=$'vless://00000000-0000-4000-8000-000000000001@example.com:443?encryption=none&security=tls&sni=example.com#first\nvless://00000000-0000-4000-8000-000000000002@example.org:443?encryption=none&security=tls&sni=example.org#second'

config='{"outbounds":[]}'
config="$(sing_box_cm_add_direct_outbound "$config" "$SB_DIRECT_OUTBOUND_TAG")"
configure_outbound_handler "proxy"

output="$WORK_DIR/config.json"
printf '%s\n' "$config" > "$output"

urltest_count="$(ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let count = 0;
for (let outbound in cfg.outbounds || [])
    if (outbound && outbound.type == "urltest" && outbound.interrupt_exist_connections === true)
        count++;
print(count, "\n");
' "$output")"
if [ "$urltest_count" != "1" ]; then
  cat "$output" >&2
  fail "expected exactly one URLTest outbound with interrupt_exist_connections=true, got $urltest_count"
fi

selector_count="$(ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let count = 0;
for (let outbound in cfg.outbounds || [])
    if (outbound && outbound.type == "selector" && outbound.interrupt_exist_connections === true)
        count++;
print(count, "\n");
' "$output")"
[ "$selector_count" = "1" ] || fail "expected exactly one selector outbound with interrupt_exist_connections=true, got $selector_count"

assert_contains "$output" '"tag": "proxy-urltest-out"' "generated config"
assert_contains "$output" '"url": "https://www.gstatic.com/generate_204"' "generated config"
assert_contains "$output" '"interval": "3m"' "generated config"
assert_not_contains "$output" '"idle_timeout":' "generated config"

printf 'URLTest interrupt regression checks passed\n'
