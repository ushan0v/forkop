#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
MIGRATION="$PODKOP_LIB/config/migration.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

if grep -n -E 'require\("uci"\)\.cursor|uci -q|uci", "-q"' "$MIGRATION" >/dev/null 2>&1; then
  fail "config/migration.uc must use core.uci instead of direct UCI cursor or CLI access"
fi
grep -Fq 'require("core.uci")' "$MIGRATION" ||
  fail "config/migration.uc must import core.uci"

eval "$(ucode -L "$PODKOP_LIB" "$PODKOP_LIB/core/constants.uc" shell-env)"
export ZAPRET_LEGACY_DEFAULT_NFQWS_OPT ZAPRET_DEFAULT_NFQWS_OPT

node >"$WORK_DIR/fixture.json" <<'NODE'
const fixture = {
  settings: {
    '.name': 'settings',
    '.type': 'settings',
    download_lists_via_proxy: '1',
    routing_excluded_ips: [ '192.0.2.0/24' ]
  },
  rule: [
    {
      '.name': 'legacy-url',
      '.type': 'rule',
      enabled: '1',
      connection_type: 'proxy',
      proxy_config_type: 'url',
      proxy_string: 'vless://one\n//commented\n ss://two ',
      urltest_check_interval_disabled: '1',
      domain: [ 'Example.COM' ],
      domain_keyword_text_mode: '1',
      domain_keyword_text: 'Video, Stream # comment',
      domain_regex_text: '^api[.]example$, ^cdn[.]example$'
    }
  ],
  section: [
    {
      '.name': 'legacy-sub',
      '.type': 'section',
      action: 'proxy',
      proxy_config_type: 'subscription',
      subscription_url: 'https://example.com/sub.txt',
      subscription_user_agent: 'Agent/1.0',
      subscription_update_interval_disabled: '1',
      urltest_enabled: '1',
      urltest_filter_mode: 'include',
      detect_server_country: '1'
    },
    {
      '.name': 'legacy-urltest',
      '.type': 'section',
      connection_type: 'proxy',
      proxy_config_type: 'urltest',
      urltest_proxy_links: [ 'vmess://a', 'vmess://a', 'trojan://b' ],
      urltest_exclude_regex: [ 'bad.*' ],
      urltest_enabled: '1',
      detect_server_country: '0'
    },
    {
      '.name': 'legacy-direct',
      '.type': 'section',
      action: 'direct',
      ip_cidr: [ '198.51.100.0/24' ]
    },
    {
      '.name': 'legacy-exclusion',
      '.type': 'section',
      connection_type: 'exclusion',
      ip_cidr: [ '203.0.113.0/24' ]
    },
    {
      '.name': 'legacy-zap',
      '.type': 'section',
      action: 'zapret',
      nfqws_opt: process.env.ZAPRET_LEGACY_DEFAULT_NFQWS_OPT,
      cmd_opts: '--legacy-bye'
    },
    {
      '.name': 'legacy-vpn',
      '.type': 'section',
      connection_type: 'vpn',
      proxy_config_type: 'subscription',
      proxy_string: 'ss://drop',
      subscription_url: 'https://drop.example/sub.txt',
      subscription_user_agent: 'DropUA',
      urltest_check_interval_disabled: '1',
      subscription_update_interval_disabled: '1'
    }
  ]
};

process.stdout.write(`${JSON.stringify(fixture, null, 2)}\n`);
NODE

PODKOP_LIB="$PODKOP_LIB" ucode -L "$PODKOP_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/fixture.json" >"$WORK_DIR/output.json"

node - "$WORK_DIR/output.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const config = out.config;
const sections = Object.fromEntries(config.section.map(section => [section['.name'], section]));

function assert(condition, message) {
  if (!condition) {
    console.error(message);
    process.exit(1);
  }
}

function absent(object, key, label) {
  assert(!Object.prototype.hasOwnProperty.call(object, key), `${label}: ${key} should be absent`);
}

assert(out.changed === true, 'migration should report changes');
assert(!config.rule, 'legacy rule sections should be converted');

assert(config.settings.list_update_enabled === '0', 'missing list_update_enabled should become disabled');
assert(config.settings.update_interval === '1d', 'missing update_interval should get 1d default');
assert(config.settings.download_lists_via_proxy === '1', 'download_lists_via_proxy should be preserved');
assert(config.settings.download_subscriptions_via_proxy === '1', 'download_subscriptions_via_proxy should be copied');
assert(config.settings.download_components_via_proxy === '1', 'download_components_via_proxy should be copied');
absent(config.settings, 'routing_excluded_ips', 'settings');

const legacyUrl = sections['legacy-url'];
assert(legacyUrl['.type'] === 'section', 'legacy rule should become section');
assert(legacyUrl.action === 'proxy', 'legacy-url action');
assert(JSON.stringify(legacyUrl.selector_proxy_links) === JSON.stringify(['vless://one', 'ss://two']), 'proxy_string links');
assert(legacyUrl.urltest_enabled === '0', 'urltest disabled flag');
assert(legacyUrl.domain_suffix.includes('full:Example.COM'), 'full domain list value migrated');
assert(legacyUrl.domain_suffix.includes('keyword:Video'), 'keyword migrated');
assert(legacyUrl.domain_suffix.includes('keyword:Stream'), 'keyword comment stripped');
assert(legacyUrl.domain_suffix.includes('regex:^api[.]example$'), 'regex migrated');
assert(legacyUrl.domain_suffix.includes('regex:^cdn[.]example$'), 'second regex migrated');
absent(legacyUrl, 'proxy_string', 'legacy-url');
absent(legacyUrl, 'proxy_config_type', 'legacy-url');
absent(legacyUrl, 'connection_type', 'legacy-url');
absent(legacyUrl, 'domain', 'legacy-url');
absent(legacyUrl, 'domain_keyword_text', 'legacy-url');
absent(legacyUrl, 'domain_regex_text', 'legacy-url');

const legacySub = sections['legacy-sub'];
assert(JSON.stringify(legacySub.subscription_urls) === JSON.stringify(['https://example.com/sub.txt | Agent/1.0']), 'subscription entry');
assert(legacySub.subscription_update_enabled === '0', 'subscription update disabled flag');
assert(legacySub.detect_server_country === 'flag_emoji', 'detect server country normalized');
absent(legacySub, 'subscription_url', 'legacy-sub');
absent(legacySub, 'subscription_user_agent', 'legacy-sub');
absent(legacySub, 'proxy_config_type', 'legacy-sub');

const legacyUrltest = sections['legacy-urltest'];
assert(legacyUrltest.action === 'proxy', 'legacy-urltest action');
assert(legacyUrltest.urltest_filter_mode === 'exclude', 'urltest filter mode migration');
assert(legacyUrltest.detect_server_country === 'flag_emoji', 'detect server country kept when urltest filter enabled');
assert(JSON.stringify(legacyUrltest.selector_proxy_links) === JSON.stringify(['vmess://a', 'trojan://b']), 'urltest links deduped');
absent(legacyUrltest, 'urltest_proxy_links', 'legacy-urltest');

const legacyDirect = sections['legacy-direct'];
assert(legacyDirect.action === 'bypass', 'direct action migrated to bypass');

const legacyExclusion = sections['legacy-exclusion'];
assert(legacyExclusion.action === 'bypass', 'legacy exclusion connection type migrated to bypass');
absent(legacyExclusion, 'connection_type', 'legacy-exclusion');

const legacyZap = sections['legacy-zap'];
assert(legacyZap.nfqws_opt === process.env.ZAPRET_DEFAULT_NFQWS_OPT, 'zapret legacy default migrated');
assert(legacyZap.byedpi_cmd_opts === '--legacy-bye', 'cmd_opts copied to byedpi_cmd_opts');
absent(legacyZap, 'cmd_opts', 'legacy-zap');

const legacyVpn = sections['legacy-vpn'];
assert(legacyVpn.action === 'vpn', 'vpn action inferred');
absent(legacyVpn, 'proxy_config_type', 'legacy-vpn');
absent(legacyVpn, 'proxy_string', 'legacy-vpn');
absent(legacyVpn, 'subscription_url', 'legacy-vpn');
absent(legacyVpn, 'subscription_user_agent', 'legacy-vpn');

assert(out.removed_caches.includes('/tmp/sing-box/subscriptions/legacy-sub.json'), 'subscription runtime cache removal');
assert(out.removed_caches.includes('/var/run/podkop-plus/section-cache/legacy-sub.json'), 'section cache removal');
NODE

cat >"$WORK_DIR/runtime-migrate.state" <<'EOF_UCI'
podkop-plus.settings=settings
podkop-plus.settings.routing_excluded_ips=192.0.2.0/24
podkop-plus.legacy=rule
podkop-plus.legacy.enabled=1
podkop-plus.legacy.connection_type=proxy
podkop-plus.legacy.proxy_config_type=url
podkop-plus.legacy.proxy_string=vless://one
podkop-plus.old_direct=section
podkop-plus.old_direct.enabled=1
podkop-plus.old_direct.action=direct
EOF_UCI
mkdir -p "$WORK_DIR/runtime" "$WORK_DIR/persistent-cache"
: >"$WORK_DIR/runtime-migrate.log"
PODKOP_UCI_STATE_FILE="$WORK_DIR/runtime-migrate.state" \
PODKOP_UCI_LOG_FILE="$WORK_DIR/runtime-migrate.log" \
PODKOP_CONFIG_NAME="podkop-plus" \
TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/tmp-subscriptions" \
PODKOP_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent-cache" \
PODKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
ucode -L "$PODKOP_LIB" "$MIGRATION" migrate

grep -Fxq 'podkop-plus.legacy=section' "$WORK_DIR/runtime-migrate.state" ||
  fail "runtime migration must convert legacy rule type through core.uci"
grep -Fxq 'podkop-plus.legacy.action=proxy' "$WORK_DIR/runtime-migrate.state" ||
  fail "runtime migration must write migrated action through core.uci"
grep -Fxq 'podkop-plus.old_direct.action=bypass' "$WORK_DIR/runtime-migrate.state" ||
  fail "runtime migration must convert direct action to bypass through core.uci"
grep -Fxq 'podkop-plus.legacy.selector_proxy_links=vless://one' "$WORK_DIR/runtime-migrate.state" ||
  fail "runtime migration must write migrated list option through core.uci"
if grep -Fq 'podkop-plus.settings.routing_excluded_ips=' "$WORK_DIR/runtime-migrate.state"; then
  fail "runtime migration must delete removed routing_excluded_ips through core.uci"
fi
if grep -Fq 'podkop-plus.legacy.proxy_string=' "$WORK_DIR/runtime-migrate.state"; then
  fail "runtime migration must delete legacy proxy_string through core.uci"
fi
grep -Fxq 'commit podkop-plus' "$WORK_DIR/runtime-migrate.log" ||
  fail "runtime migration must commit through core.uci"

: >"$WORK_DIR/uci-commit.log"
: >"$WORK_DIR/uci-commit.state"
PODKOP_UCI_STATE_FILE="$WORK_DIR/uci-commit.state" \
PODKOP_UCI_LOG_FILE="$WORK_DIR/uci-commit.log" \
PODKOP_CONFIG_NAME="podkop-plus" \
PODKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
ucode -L "$PODKOP_LIB" "$MIGRATION" commit

grep -Fxq 'commit podkop-plus' "$WORK_DIR/uci-commit.log" ||
  fail "commit mode must commit podkop-plus through core.uci"

printf 'config migration regression checks passed\n'
