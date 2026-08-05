#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_UC="$ROOT_DIR/forkop/files/usr/lib/subscription/cache.uc"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"

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

cache_ucode() {
  ucode -L "$FORKOP_LIB" "$CACHE_UC" "$@"
}

assert_eq "first second" \
  "$(cache_ucode append-state-list-once "first" second)" \
  "append new state item"
assert_eq "first second" \
  "$(cache_ucode append-state-list-once "first second" second)" \
  "do not append duplicate state item"
assert_eq "first second" \
  "$(cache_ucode append-state-list-once " first second " "")" \
  "empty state item keeps normalized list"

cache_ucode state-list-contains "first second" second >/dev/null ||
  fail "state list should contain second"
if cache_ucode state-list-contains "first second" third >/dev/null 2>&1; then
  fail "state list should not contain third"
fi

SUBSCRIPTION_RUNTIME_SH="$ROOT_DIR/forkop/files/usr/lib/subscription_runtime.sh"
UPDATES_RUNTIME_SH="$ROOT_DIR/forkop/files/usr/lib/updates_runtime.sh"

[ ! -e "$SUBSCRIPTION_RUNTIME_SH" ] ||
  fail "subscription_runtime.sh shell owner must be removed"
[ ! -e "$UPDATES_RUNTIME_SH" ] ||
  fail "updates_runtime.sh shell owner must be removed"

if grep -R -n "subscription_runtime.sh" "$ROOT_DIR/forkop/files" >/dev/null 2>&1; then
  fail "runtime files must not reference subscription_runtime.sh"
fi

subscription_runtime_shell_symbols='subscription_runtime_|prepare_subscription_caches_for_startup|prepare_subscription_caches_for_runtime_generation|run_deferred_subscription_bootstrap|stop_deferred_subscription_bootstrap_retry_worker'
if grep -R -n -E "$subscription_runtime_shell_symbols" "$ROOT_DIR/forkop/files/usr/bin/forkop" "$ROOT_DIR/forkop/files/usr/lib" --include='*.sh' >/dev/null 2>&1; then
  fail "subscription_runtime shell symbols must not remain in runtime shell"
fi

if grep -R -n -E 'get_subscription_metadata_path|get_outbound_metadata_path' "$ROOT_DIR/forkop/files/usr/bin/forkop" "$ROOT_DIR/forkop/files/usr/lib" --include='*.sh' >/dev/null 2>&1; then
  fail "subscription metadata path helpers must be owned by subscription/cache.uc"
fi

if grep -n -E 'require\("uci"\)\.cursor|uci -q' "$CACHE_UC" >/dev/null 2>&1; then
  fail "subscription/cache.uc must use core.uci instead of owning direct UCI cursor or CLI calls"
fi

move_file_source="$(sed -n '/^function move_file(/,/^}/p' "$CACHE_UC")"
if grep -Fq 'unlink_path(target)' <<<"$move_file_source"; then
  fail "subscription cache replacement must keep the current file until atomic rename succeeds"
fi
if grep -Fq 'remove-legacy-server-country-cache' "$CACHE_UC"; then
  fail "subscription/cache.uc must not expose the migrated legacy cache cleanup"
fi

grep -q 'mode == "ensure-runtime-dirs"' "$CACHE_UC" ||
  fail "subscription/cache.uc must expose ensure-runtime-dirs owner mode"
grep -q 'mode == "ensure-runtime-cache-format"' "$CACHE_UC" ||
  fail "subscription/cache.uc must expose ensure-runtime-cache-format owner mode"
grep -q 'mode == "prepare-caches"' "$CACHE_UC" ||
  fail "subscription/cache.uc must expose prepare-caches owner mode"
grep -q 'mode == "update-source"' "$CACHE_UC" ||
  fail "subscription/cache.uc must expose update-source owner mode"
grep -q 'mode == "update-request"' "$CACHE_UC" ||
  fail "subscription/cache.uc must expose update-request owner mode"
grep -q 'mode == "update-section"' "$CACHE_UC" ||
  fail "subscription/cache.uc must expose update-section owner mode"
grep -q 'mode == "section-is-subscription-proxy"' "$CACHE_UC" ||
  fail "subscription/cache.uc must expose subscription proxy predicate mode"
grep -q 'mode == "subscription-metadata-path"' "$CACHE_UC" ||
  fail "subscription/cache.uc must expose subscription metadata path mode"
grep -q 'mode == "outbound-metadata-path"' "$CACHE_UC" ||
  fail "subscription/cache.uc must expose outbound metadata path mode"
grep -q 'mode == "run-deferred-bootstrap"' "$CACHE_UC" ||
  fail "subscription/cache.uc must expose deferred bootstrap owner mode"
grep -q 'mode == "stop-deferred-bootstrap-worker"' "$CACHE_UC" ||
  fail "subscription/cache.uc must expose deferred worker stop owner mode"
assert_eq "proxy-subscription-2" \
  "$(cache_ucode source-id proxy 2)" \
  "source id mode"
assert_eq "/var/run/forkop/subscription-metadata/proxy.json" \
  "$(cache_ucode subscription-metadata-path proxy)" \
  "subscription metadata path mode"
assert_eq "/var/run/forkop/outbound-metadata/proxy.json" \
  "$(cache_ucode outbound-metadata-path proxy)" \
  "outbound metadata path mode"
if cache_ucode subscription-metadata-path '../bad' >/dev/null 2>&1; then
  fail "subscription metadata path mode should reject unsafe section names"
fi

cat >"$WORK_DIR/normalized-subscription.json" <<'JSON'
{
  "version": 1,
  "format": "uri-list",
  "skipped": 2,
  "outbounds": [
    { "type": "vless", "tag": "one" },
    { "type": "trojan", "tag": "two" }
  ]
}
JSON
assert_eq "2 proxy entries, 2 skipped entries" \
  "$(cache_ucode subscription-import-stats "$WORK_DIR/normalized-subscription.json")" \
  "subscription import stats"
assert_eq "Subscription source 1 for rule 'proxy' imported: 2 proxy entries, 2 skipped entries" \
  "$(cache_ucode subscription-source-summary proxy 1 "$WORK_DIR/normalized-subscription.json" imported)" \
  "subscription source imported summary"
assert_eq "Subscription source 1 for rule 'proxy' is unchanged: 2 proxy entries, 2 skipped entries" \
  "$(cache_ucode subscription-source-summary proxy 1 "$WORK_DIR/normalized-subscription.json" unchanged)" \
  "subscription source unchanged summary"

runtime_env() {
  TMP_SING_BOX_FOLDER="$WORK_DIR/runtime/tmp-sing-box" \
    TMP_RULESET_FOLDER="$WORK_DIR/runtime/tmp-sing-box/rulesets" \
    TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/runtime/tmp-sing-box/subscriptions" \
    FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/runtime/run" \
    FORKOP_SUBSCRIPTION_UPDATE_STATE_DIR="$WORK_DIR/runtime/run/subscription-update" \
    FORKOP_SUBSCRIPTION_LINKS_DIR="$WORK_DIR/runtime/run/subscription-links" \
    FORKOP_SUBSCRIPTION_METADATA_DIR="$WORK_DIR/runtime/run/subscription-metadata" \
    FORKOP_OUTBOUND_METADATA_DIR="$WORK_DIR/runtime/run/outbound-metadata" \
    FORKOP_SECTION_CACHE_DIR="$WORK_DIR/runtime/run/section-cache" \
    FORKOP_RUNTIME_CACHE_FORMAT_FILE="$WORK_DIR/runtime/run/cache-format" \
    FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/runtime/persistent" \
    FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE="$WORK_DIR/runtime/persistent/cache-format" \
    FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT="7" \
    FORKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE="$WORK_DIR/runtime/run/bootstrap.pid" \
    "$@"
}

runtime_env cache_ucode ensure-runtime-dirs
for dir in \
  "$WORK_DIR/runtime/tmp-sing-box" \
  "$WORK_DIR/runtime/tmp-sing-box/rulesets" \
  "$WORK_DIR/runtime/tmp-sing-box/subscriptions" \
  "$WORK_DIR/runtime/run" \
  "$WORK_DIR/runtime/run/subscription-update" \
  "$WORK_DIR/runtime/run/subscription-metadata" \
  "$WORK_DIR/runtime/run/outbound-metadata" \
  "$WORK_DIR/runtime/run/section-cache"; do
  [ -d "$dir" ] || fail "ensure-runtime-dirs should create $dir"
done

if [ -d "$WORK_DIR/runtime/run/subscription-links" ]; then
  fail "ensure-runtime-dirs should not recreate the retired subscription-links directory"
fi

mkdir -p "$WORK_DIR/runtime/run/subscription-links" "$WORK_DIR/runtime/persistent"
printf '7\n' >"$WORK_DIR/runtime/run/cache-format"
printf 'stale\n' >"$WORK_DIR/runtime/run/section-cache/stale.json"
printf 'stale\n' >"$WORK_DIR/runtime/run/subscription-links/stale.json"
printf '7\n' >"$WORK_DIR/runtime/persistent/cache-format"
cat >"$WORK_DIR/runtime/persistent/proxy-subscription-1.json" <<'JSON'
{
  "version": 1,
  "format": "sing-box-json",
  "outbounds": [
    {
      "type": "socks",
      "tag": "preserved-node",
      "server": "127.0.0.1",
      "server_port": 1080
    }
  ]
}
JSON
runtime_env cache_ucode ensure-runtime-cache-format
assert_eq "8" \
  "$(sed -n '1p' "$WORK_DIR/runtime/run/cache-format")" \
  "runtime cache format"
[ ! -e "$WORK_DIR/runtime/run/section-cache/stale.json" ] ||
  fail "ensure-runtime-cache-format should clear old runtime section cache"
[ ! -e "$WORK_DIR/runtime/run/subscription-links" ] ||
  fail "runtime format migration should remove the retired subscription-links directory"
assert_eq "7" \
  "$(sed -n '1p' "$WORK_DIR/runtime/persistent/cache-format")" \
  "persistent cache format"
[ -f "$WORK_DIR/runtime/persistent/proxy-subscription-1.json" ] ||
  fail "runtime format migration should preserve the compatible persistent subscription cache"
node - "$WORK_DIR/runtime/persistent/proxy-subscription-1.json" <<'NODE'
const fs = require('fs');
const subscription = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const outbound = subscription.outbounds[0];
if (outbound.server !== '127.0.0.1' || outbound.share_link !== 'socks5://127.0.0.1:1080#preserved-node') {
  console.error('runtime format migration should preserve the outbound and backfill its direct link');
  process.exit(1);
}
NODE
runtime_env cache_ucode run-deferred-bootstrap ""
runtime_env cache_ucode stop-deferred-bootstrap-worker

mkdir -p \
  "$WORK_DIR/tmp" \
  "$WORK_DIR/persistent" \
  "$WORK_DIR/sections" \
  "$WORK_DIR/links" \
  "$WORK_DIR/metadata" \
  "$WORK_DIR/outbound"

cat >"$WORK_DIR/cache-maintenance.json" <<'JSON'
{
  "section": [
    {
      ".name": "proxy",
      "enabled": "1",
      "action": "proxy",
      "subscription_urls": [
        "https://example.com/one.txt",
        "https://example.com/two.txt"
      ]
    },
    {
      ".name": "direct",
      "enabled": "1",
      "action": "bypass"
    },
    {
      ".name": "disabled",
      "enabled": "0",
      "action": "proxy",
      "subscription_urls": [
        "https://example.com/disabled.txt"
      ]
    },
    {
      ".name": "bad/name",
      "enabled": "1",
      "action": "proxy",
      "subscription_urls": [
        "https://example.com/bad.txt"
      ]
    }
  ]
}
JSON

assert_eq $'sections\tproxy direct disabled\nsources\tproxy-subscription-1 proxy-subscription-2 disabled-subscription-1\nall\tproxy proxy-subscription-1 proxy-subscription-2 direct disabled disabled-subscription-1\nmissing\t1' \
  "$(cache_ucode maintenance-plan-fixture "$WORK_DIR/cache-maintenance.json" "$WORK_DIR/sections")" \
  "cache maintenance plan with missing proxy section cache"

touch "$WORK_DIR/sections/proxy.json"
assert_eq $'sections\tproxy direct disabled\nsources\tproxy-subscription-1 proxy-subscription-2 disabled-subscription-1\nall\tproxy proxy-subscription-1 proxy-subscription-2 direct disabled disabled-subscription-1\nmissing\t0' \
  "$(cache_ucode maintenance-plan-fixture "$WORK_DIR/cache-maintenance.json" "$WORK_DIR/sections")" \
  "cache maintenance plan with available proxy section cache"

cache_ucode runtime-cache-needs-rebuild-fixture "$WORK_DIR/cache-maintenance.json" "$WORK_DIR/sections" >/dev/null &&
  fail "runtime cache should not need rebuild after proxy cache exists"
cache_ucode prepared-runtime-cache-should-skip-fixture "$WORK_DIR/cache-maintenance.json" "$WORK_DIR/sections" runtime 1 >/dev/null ||
  fail "prepared runtime cache should skip only when section cache exists"
rm -f "$WORK_DIR/sections/proxy.json"
cache_ucode runtime-cache-needs-rebuild-fixture "$WORK_DIR/cache-maintenance.json" "$WORK_DIR/sections" >/dev/null ||
  fail "runtime cache should need rebuild when proxy cache is missing"
if cache_ucode prepared-runtime-cache-should-skip-fixture "$WORK_DIR/cache-maintenance.json" "$WORK_DIR/sections" runtime 1 >/dev/null 2>&1; then
  fail "prepared runtime cache must not skip when section cache is missing"
fi

touch \
  "$WORK_DIR/tmp/proxy-subscription-1.json" \
  "$WORK_DIR/tmp/stale-subscription-1.json" \
  "$WORK_DIR/persistent/proxy-subscription-2.url" \
  "$WORK_DIR/persistent/stale-subscription-2.user_agent" \
  "$WORK_DIR/sections/proxy.json" \
  "$WORK_DIR/sections/proxy-subscription-1.json" \
  "$WORK_DIR/sections/stale.json" \
  "$WORK_DIR/links/proxy.json" \
  "$WORK_DIR/links/proxy-subscription-1.json" \
  "$WORK_DIR/metadata/direct.metadata.json" \
  "$WORK_DIR/outbound/stale.json" \
  "$WORK_DIR/outbound/cache-format"

candidate_paths="$(
  printf '%s\n' \
    "$WORK_DIR/tmp/proxy-subscription-1.json" \
    "$WORK_DIR/tmp/stale-subscription-1.json" \
    "$WORK_DIR/persistent/proxy-subscription-2.url" \
    "$WORK_DIR/persistent/stale-subscription-2.user_agent" \
    "$WORK_DIR/sections/proxy.json" \
    "$WORK_DIR/sections/proxy-subscription-1.json" \
    "$WORK_DIR/sections/stale.json" \
    "$WORK_DIR/links/proxy.json" \
    "$WORK_DIR/links/proxy-subscription-1.json" \
    "$WORK_DIR/metadata/direct.metadata.json" \
    "$WORK_DIR/outbound/stale.json" \
    "$WORK_DIR/outbound/cache-format"
)"

assert_eq "$(
  printf '%s\n' \
    "$WORK_DIR/tmp/stale-subscription-1.json" \
    "$WORK_DIR/persistent/stale-subscription-2.user_agent" \
    "$WORK_DIR/sections/stale.json" \
    "$WORK_DIR/links/proxy-subscription-1.json" \
    "$WORK_DIR/outbound/stale.json"
)" \
  "$(printf '%s\n' "$candidate_paths" | cache_ucode stale-cache-delete-paths-fixture \
    "$WORK_DIR/cache-maintenance.json" \
    "$WORK_DIR/tmp" \
    "$WORK_DIR/persistent" \
    "$WORK_DIR/sections" \
    "$WORK_DIR/links" \
    "$WORK_DIR/metadata" \
    "$WORK_DIR/outbound")" \
  "stale cache delete path plan"

mkdir -p "$WORK_DIR/runtime-cache" "$WORK_DIR/persistent-cache"
cat >"$WORK_DIR/cache-current.json" <<'JSON'
{
  "section": [
    {
      ".name": "proxy",
      "subscription_urls": [
        "https://example.com/one.txt",
        "https://example.com/two.txt"
      ],
      "subscription_url_settings": "{\"https://example.com/one.txt\":{\"user_agent\":\"v2rayN\"}}"
    },
    {
      ".name": "manual",
      "selector_proxy_links": "vless://manual"
    }
  ]
}
JSON

cat >"$WORK_DIR/runtime-cache/proxy-subscription-1.json" <<'JSON'
{"outbounds":[{"type":"direct","tag":"one"}]}
JSON
printf '%s' 'https://example.com/one.txt' >"$WORK_DIR/runtime-cache/proxy-subscription-1.url"
printf '%s' 'v2rayN' >"$WORK_DIR/runtime-cache/proxy-subscription-1.user_agent"

cache_ucode section-current-usable-cache-fixture \
  "$WORK_DIR/cache-current.json" proxy "$WORK_DIR/runtime-cache" "$WORK_DIR/persistent-cache" "sing-box/default" >/dev/null ||
  fail "runtime cache should be current and usable"

printf '%s' 'stale-hwid' >"$WORK_DIR/runtime-cache/proxy-subscription-1.hwid"
if cache_ucode section-current-usable-cache-fixture \
  "$WORK_DIR/cache-current.json" proxy "$WORK_DIR/runtime-cache" "$WORK_DIR/persistent-cache" "sing-box/default" >"$WORK_DIR/hwid.out" 2>"$WORK_DIR/hwid.err"; then
  fail "mismatched generated HWID cache should not be current"
fi
if grep -Fq "left-hand side is not a function" "$WORK_DIR/hwid.err"; then
  fail "mismatched generated HWID cache must not crash"
fi
rm -f "$WORK_DIR/runtime-cache/proxy-subscription-1.hwid"

mkdir -p "$WORK_DIR/custom-header-cache"
cat >"$WORK_DIR/cache-custom-headers.json" <<'JSON'
{
  "section": [
    {
      ".name": "custom",
      "subscription_urls": [
        "https://example.com/custom.txt"
      ],
      "subscription_url_settings": "{\"https://example.com/custom.txt\":{\"user_agent\":\"v2rayN\",\"custom_device_headers\":\"1\",\"device_os\":\"iOS\",\"ver_os\":\"26.4\",\"device_model\":\"iPhone 17 Pro Max\",\"device_locale\":\"ru\",\"app_version\":\"4.6.0\",\"accept_language\":\"ru-RU,ru;q=0.9\"}}"
    }
  ]
}
JSON
cat >"$WORK_DIR/custom-header-cache/custom-subscription-1.json" <<'JSON'
{"outbounds":[{"type":"direct","tag":"custom"}]}
JSON
printf '%s' 'https://example.com/custom.txt' >"$WORK_DIR/custom-header-cache/custom-subscription-1.url"
printf '%s' 'v2rayN' >"$WORK_DIR/custom-header-cache/custom-subscription-1.user_agent"

if cache_ucode section-current-usable-cache-fixture \
  "$WORK_DIR/cache-custom-headers.json" custom "$WORK_DIR/custom-header-cache" "$WORK_DIR/persistent-cache" "sing-box/default" >/dev/null 2>&1; then
  fail "custom device headers should invalidate a cache without their signature"
fi

cat >"$WORK_DIR/custom-header-cache/custom-subscription-1.json" <<'JSON'
{"outbounds":[{"type":"direct","tag":"custom"}]}
JSON
printf '%s' 'https://example.com/custom.txt' >"$WORK_DIR/custom-header-cache/custom-subscription-1.url"
printf '%s' 'v2rayN' >"$WORK_DIR/custom-header-cache/custom-subscription-1.user_agent"
printf '%s' '{ "enabled": "1", "device_os": "iOS", "ver_os": "26.4", "device_model": "iPhone 17 Pro Max", "device_locale": "ru", "app_version": "4.6.0", "accept_language": "ru-RU,ru;q=0.9" }' >"$WORK_DIR/custom-header-cache/custom-subscription-1.device_headers"

cache_ucode section-current-usable-cache-fixture \
  "$WORK_DIR/cache-custom-headers.json" custom "$WORK_DIR/custom-header-cache" "$WORK_DIR/persistent-cache" "sing-box/default" >/dev/null ||
  fail "matching custom device headers signature should keep the cache current"

sed 's/\\"device_os\\":\\"iOS\\"/\\"device_os\\":\\"Android\\"/' \
  "$WORK_DIR/cache-custom-headers.json" >"$WORK_DIR/cache-custom-headers-changed.json"
if cache_ucode section-current-usable-cache-fixture \
  "$WORK_DIR/cache-custom-headers-changed.json" custom "$WORK_DIR/custom-header-cache" "$WORK_DIR/persistent-cache" "sing-box/default" >/dev/null 2>&1; then
  fail "changing a custom device header should invalidate the cache"
fi

printf '%s' 'https://example.com/stale.txt' >"$WORK_DIR/runtime-cache/proxy-subscription-1.url"
if cache_ucode section-current-usable-cache-fixture \
  "$WORK_DIR/cache-current.json" proxy "$WORK_DIR/runtime-cache" "$WORK_DIR/persistent-cache" "sing-box/default" >/dev/null 2>&1; then
  fail "stale runtime cache URL should not be current"
fi

rm -f "$WORK_DIR/runtime-cache/proxy-subscription-1.json" "$WORK_DIR/runtime-cache/proxy-subscription-1.url" "$WORK_DIR/runtime-cache/proxy-subscription-1.user_agent"
cat >"$WORK_DIR/persistent-cache/proxy-subscription-2.json" <<'JSON'
{"outbounds":[{"type":"direct","tag":"two"}]}
JSON
printf '%s' 'https://example.com/two.txt' >"$WORK_DIR/persistent-cache/proxy-subscription-2.url"
printf '%s' 'sing-box/default' >"$WORK_DIR/persistent-cache/proxy-subscription-2.user_agent"

cache_ucode section-current-usable-cache-fixture \
  "$WORK_DIR/cache-current.json" proxy "$WORK_DIR/runtime-cache" "$WORK_DIR/persistent-cache" "sing-box/default" >/dev/null ||
  fail "persistent cache should restore and satisfy current cache"
test -s "$WORK_DIR/runtime-cache/proxy-subscription-2.json" ||
  fail "persistent cache restore should write runtime json"
assert_eq 'https://example.com/two.txt' \
  "$(cat "$WORK_DIR/runtime-cache/proxy-subscription-2.url")" \
  "restored subscription URL"

if cache_ucode section-current-usable-cache-fixture \
  "$WORK_DIR/cache-current.json" manual "$WORK_DIR/runtime-cache" "$WORK_DIR/persistent-cache" "sing-box/default" >/dev/null 2>&1; then
  fail "section without subscription URLs should not have usable subscription cache"
fi

mkdir -p "$WORK_DIR/link-subscriptions"
cat >"$WORK_DIR/link-subscriptions/proxy-subscription-1.json" <<'JSON'
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-encrypted",
      "server": "example.com",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000001",
      "encryption": "mlkem768x25519plus.native.test"
    },
    {
      "type": "vless",
      "tag": "vless-none",
      "server": "example.com",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000001",
      "encryption": "none"
    }
  ]
}
JSON
serialize_outbound_link() {
  ucode -L "$FORKOP_LIB" -e '
    let fs = require("fs");
    let share_link = require("subscription.share_link");
    let source = json(fs.readfile(ARGV[0]));
    print(share_link.serialize_outbound_link(source.outbounds[int(ARGV[1])]), "\n");
  ' "$1" "$2"
}

encrypted_link="$(serialize_outbound_link "$WORK_DIR/link-subscriptions/proxy-subscription-1.json" 0)"
case "$encrypted_link" in
  *encryption=mlkem768x25519plus.native.test*) ;;
  *) fail "expected VLESS encryption in serialized link, got $encrypted_link" ;;
esac
none_link="$(serialize_outbound_link "$WORK_DIR/link-subscriptions/proxy-subscription-1.json" 1)"
case "$none_link" in
  *encryption=none*) fail "did not expect encryption=none in serialized link, got $none_link" ;;
esac

mkdir -p "$WORK_DIR/persist-runtime" "$WORK_DIR/persist-empty" "$WORK_DIR/persist-fresh"
cat >"$WORK_DIR/persist-runtime/proxy-subscription-1.json" <<'JSON'
{"outbounds":[{"type":"direct","tag":"one"}]}
JSON
cat >"$WORK_DIR/runtime/persistent/proxy-subscription-1.metadata.json" <<'JSON'
{"version":1,"title":"WolfPN"}
JSON
printf '%s' 'https://example.com/one.txt' >"$WORK_DIR/runtime/persistent/proxy-subscription-1.url"
printf '%s' 'v2rayN' >"$WORK_DIR/runtime/persistent/proxy-subscription-1.user_agent"
cat >"$WORK_DIR/persist-empty/empty.metadata.json" <<'JSON'
{}
JSON

runtime_env cache_ucode persist-source-cache \
  proxy-subscription-1 \
  "$WORK_DIR/persist-runtime/proxy-subscription-1.json" \
  'https://example.com/one.txt' \
  'v2rayN' \
  "$WORK_DIR/persist-empty/empty.metadata.json"
test -s "$WORK_DIR/runtime/persistent/proxy-subscription-1.metadata.json" ||
  fail "same subscription source with empty fresh metadata must keep previous metadata"
node - "$WORK_DIR/runtime/persistent/proxy-subscription-1.metadata.json" <<'JS'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (value.title !== "WolfPN") {
  console.error("previous metadata was not preserved");
  process.exit(1);
}
JS

runtime_env cache_ucode persist-source-cache \
  proxy-subscription-1 \
  "$WORK_DIR/persist-runtime/proxy-subscription-1.json" \
  'https://example.com/changed.txt' \
  'v2rayN' \
  "$WORK_DIR/persist-empty/empty.metadata.json"
[ ! -e "$WORK_DIR/runtime/persistent/proxy-subscription-1.metadata.json" ] ||
  fail "changed subscription URL with empty metadata must drop stale metadata"

printf 'subscription cache state checks passed\n'
