#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
RUNTIME_MIGRATION="$FORKOP_LIB/config/migration.uc"
INSTALLER="$ROOT_DIR/install.sh"
WORK_DIR="$(mktemp -d)"
MIGRATION="$WORK_DIR/config-migration.uc"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

awk '
  /cat > "\$helper_path" <<'\''FORKOP_CONFIG_MIGRATION_EOF'\''/ { capture = 1; next }
  capture && /^FORKOP_CONFIG_MIGRATION_EOF$/ { exit }
  capture { print }
' "$INSTALLER" > "$MIGRATION"
[ -s "$MIGRATION" ] || fail "failed to extract config migration from install.sh"

grep -Fq 'Reserved for future Forkop configuration migrations.' "$RUNTIME_MIGRATION" ||
  fail "runtime config/migration.uc must remain a placeholder"
if grep -n -E 'require\("core\.uci"\)|function migrate_|migrate_runtime|migrate-fixture' "$RUNTIME_MIGRATION" >/dev/null 2>&1; then
  fail "runtime config/migration.uc must not contain migration logic"
fi

if grep -n -E 'require\("uci"\)\.cursor|uci -q|uci", "-q"' "$MIGRATION" >/dev/null 2>&1; then
  fail "installer config migration must use core.uci instead of direct UCI cursor or CLI access"
fi
grep -Fq 'require("core.uci")' "$MIGRATION" ||
  fail "installer config migration must import core.uci"

eval "$(ucode -L "$FORKOP_LIB" "$FORKOP_LIB/core/constants.uc" shell-env)"
export ZAPRET_LEGACY_DEFAULT_NFQWS_OPT ZAPRET_DEFAULT_NFQWS_OPT

node >"$WORK_DIR/fixture.json" <<'NODE'
const fixture = {
  settings: {
    '.name': 'settings',
    '.type': 'settings',
    download_lists_via_proxy: '1',
    download_subscriptions_via_proxy: '1',
    download_lists_via_proxy_section: 'legacy-urltest',
    dns_server: '9.9.9.9',
    bootstrap_dns_server: '1.1.1.1',
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
      enable_udp_over_tcp: '1',
      outbound_detour_enabled: '1',
      outbound_detour_section: 'legacy-sub',
      urltest_check_interval_disabled: '1',
      domain: [ 'Example.COM', 'full:Already.EXAMPLE' ],
      domain_keyword_text_mode: '1',
      domain_keyword_text: 'Video, Stream # comment',
      domain_regex_text: '^api[.]example$, ^cdn[.]example$',
      rule_set: [ 'https://example.com/domains.srs' ],
      rule_set_with_subnets: [ 'https://example.com/mixed.srs' ]
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
      '.name': 'legacy-list-sub',
      '.type': 'section',
      action: 'proxy',
      subscription_urls: [
        'https://example.com/list.txt | ListAgent/2.0',
        'https://example.com/auto.txt'
      ],
      subscription_update_interval: '6h'
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
      proxy_config_type: 'interface',
      interface: 'awg0',
      domain_resolver_enabled: '1',
      domain_resolver_dns_type: 'doh',
      domain_resolver_dns_server: 'https://dns.example/dns-query'
    },
    {
      '.name': 'legacy-outbound',
      '.type': 'section',
      action: 'outbound',
      outbound_json: '{"type":"socks","server":"127.0.0.1","server_port":1080,"version":"5"}',
      outbound_detour_enabled: '1',
      outbound_detour_section: 'legacy-url'
    },
    {
      '.name': 'legacy-outbound-collision',
      '.type': 'section',
      action: 'outbound',
      outbound_jsons: [ '{"type":"direct","tag":"legacy-outbound-collision-json-2-out"}' ],
      outbound_json: '{"type":"socks","server":"127.0.0.2","server_port":1080}'
    }
  ]
};

process.stdout.write(`${JSON.stringify(fixture, null, 2)}\n`);
NODE

FORKOP_LIB="$FORKOP_LIB" ucode -L "$FORKOP_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/fixture.json" >"$WORK_DIR/output.json"

node - "$WORK_DIR/output.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const config = out.config;
const sections = Object.fromEntries(config.section.map(section => [section['.name'], section]));
const childByType = type => config[type] || [];
const subscriptionUrls = childByType('subscription_url');
const urltests = childByType('urltest');

assert(JSON.stringify(config.settings.dns_server) === JSON.stringify(['9.9.9.9']), 'legacy main DNS scalar migrated to ordered list');
assert(JSON.stringify(config.settings.bootstrap_dns_server) === JSON.stringify(['1.1.1.1']), 'legacy Bootstrap DNS scalar migrated to ordered list');

function assert(condition, message) {
  if (!condition) {
    console.error(message);
    process.exit(1);
  }
}

function absent(object, key, label) {
  assert(!Object.prototype.hasOwnProperty.call(object, key), `${label}: ${key} should be absent`);
}

function childObjects(parent, children) {
  return children.filter(child => child.section === parent['.name']);
}

function childValues(parent, children, valueKey) {
  return childObjects(parent, children).map(child => child[valueKey]).filter(Boolean);
}

function childByValue(parent, children, valueKey, value) {
  return childObjects(parent, children).find(child => child[valueKey] === value);
}

function urltestByOwner(parent) {
  return urltests.find(item => item.section === parent['.name']);
}

assert(out.changed === true, 'migration should report changes');
assert(!config.rule, 'legacy rule sections should be converted');

assert(config.settings.list_update_enabled === '0', 'missing list_update_enabled should become disabled');
assert(config.settings.update_interval === '1d', 'missing update_interval should get 1d default');
assert(config.settings.download_lists_via_proxy === '1', 'download_lists_via_proxy should be preserved');
assert(config.settings.download_components_via_proxy === '1', 'download_components_via_proxy should be copied');
assert(config.settings.download_lists_via_proxy_section === 'legacy-urltest', 'download section should be preserved for lists/components');
assert(config.settings.download_components_via_proxy_section === 'legacy-urltest', 'component download section should be migrated from the legacy common selector');
absent(config.settings, 'download_subscriptions_via_proxy', 'settings');
absent(config.settings, 'routing_excluded_ips', 'settings');

const legacyUrl = sections['legacy-url'];
assert(legacyUrl['.type'] === 'section', 'legacy rule should become section');
assert(legacyUrl.action === 'connection', 'legacy-url action');
assert(JSON.stringify(legacyUrl.selector_proxy_links) === JSON.stringify(['vless://one', 'ss://two']), 'proxy_string links');
assert(legacyUrl.outbound_detour_enabled === '1', 'section cascade enabled preserved');
assert(legacyUrl.outbound_detour_section === 'legacy-sub', 'section cascade target preserved');
absent(legacyUrl, 'enable_udp_over_tcp', 'legacy-url');
const legacyUrlDomains = (legacyUrl.domain || '').split(/\s+/).filter(Boolean);
assert(legacyUrlDomains.includes('full:Example.COM'), 'full domain list value migrated');
assert(legacyUrlDomains.includes('full:Already.EXAMPLE'), 'prefixed full domain list value migrated without duplicate prefix');
assert(!legacyUrlDomains.includes('full:full:Already.EXAMPLE'), 'prefixed full domain list value should not get duplicate prefix');
assert(legacyUrlDomains.includes('keyword:Video'), 'keyword migrated');
assert(legacyUrlDomains.includes('keyword:Stream'), 'keyword comment stripped');
assert(legacyUrlDomains.includes('regex:^api[.]example$'), 'regex migrated');
assert(legacyUrlDomains.includes('regex:^cdn[.]example$'), 'second regex migrated');
assert(JSON.stringify(legacyUrl.rule_set) === JSON.stringify(['https://example.com/domains.srs']), 'domain rule set preserved');
assert(JSON.stringify(legacyUrl.rule_set_with_subnets) === JSON.stringify(['https://example.com/mixed.srs']), 'rule set subnet list preserved');
absent(legacyUrl, 'proxy_string', 'legacy-url');
absent(legacyUrl, 'proxy_config_type', 'legacy-url');
absent(legacyUrl, 'connection_type', 'legacy-url');
absent(legacyUrl, 'urltest_enabled', 'legacy-url');
absent(legacyUrl, 'rule_set_settings', 'legacy-url');
absent(legacyUrl, 'domain_suffix', 'legacy-url');
absent(legacyUrl, 'rule_set_items', 'legacy-url');
absent(legacyUrl, 'domain_keyword_text', 'legacy-url');
absent(legacyUrl, 'domain_regex_text', 'legacy-url');

const legacySub = sections['legacy-sub'];
assert(JSON.stringify(childValues(legacySub, subscriptionUrls, 'url')) === JSON.stringify(['https://example.com/sub.txt']), 'subscription entry');
assert(legacySub.action === 'connection', 'legacy-sub action');
const legacySubSource = childObjects(legacySub, subscriptionUrls)[0];
assert(legacySubSource.user_agent === 'Agent/1.0', 'subscription user-agent setting');
assert(legacySubSource.auto_user_agent === '0', 'subscription user-agent manual mode');
assert(legacySubSource.auto_hwid === '1', 'subscription HWID auto-generation');
assert(legacySubSource.prefix_nodes === '0', 'subscription node prefix disabled by default');
assert(legacySubSource.include_urltest_groups === '1', 'subscription URLTest groups import default');
assert(legacySubSource.hide_urltest_group_outbounds === '1', 'subscription URLTest group member hiding default');
assert(legacySubSource.hide_detour_outbounds === '1', 'subscription detour hiding default');
assert(legacySubSource.subscription_update_enabled === '0', 'subscription update disabled flag');
assert(legacySubSource.download_via_proxy_enabled === '1', 'subscription download through section flag');
assert(legacySubSource.download_via_proxy_section === 'legacy-urltest', 'subscription download target');
absent(legacySub, 'urltests', 'legacy-sub');
const legacySubUrltest = urltestByOwner(legacySub);
assert(Boolean(legacySubUrltest), 'legacy-sub URLTest child migrated');
assert(legacySubUrltest.section === 'legacy-sub', 'legacy-sub URLTest owner migrated');
absent(legacySubUrltest, 'id', 'legacy-sub URLTest');
absent(legacySubUrltest, 'display_name', 'legacy-sub URLTest');
assert(legacySubUrltest.name === 'Fastest', 'legacy-sub URLTest name migrated');
assert(legacySubUrltest.check_interval === '3m', 'legacy-sub URLTest interval default migrated');
assert(legacySubUrltest.tolerance === '50', 'legacy-sub URLTest tolerance default migrated');
assert(legacySubUrltest.testing_url === 'https://www.gstatic.com/generate_204', 'legacy-sub URLTest URL default migrated');
assert(legacySubUrltest.filter_mode === 'include', 'legacy-sub URLTest filter mode migrated');
assert(legacySubUrltest.detect_server_country === 'flag_emoji', 'legacy-sub detect server country normalized');
assert(legacySubUrltest.interrupt_exist_connections === '1', 'legacy-sub URLTest interrupt default migrated');
assert(legacySubUrltest.pin_dashboard === '1', 'legacy-sub URLTest dashboard pin default migrated');
absent(legacySub, 'subscription_update_enabled', 'legacy-sub');
absent(legacySub, 'subscription_update_interval', 'legacy-sub');
absent(legacySub, 'subscription_urls', 'legacy-sub');
absent(legacySub, 'subscription_url_items', 'legacy-sub');
absent(legacySub, 'subscription_url_settings', 'legacy-sub');
absent(legacySub, 'subscription_url', 'legacy-sub');
absent(legacySub, 'subscription_user_agent', 'legacy-sub');
absent(legacySub, 'proxy_config_type', 'legacy-sub');
absent(legacySub, 'urltest_enabled', 'legacy-sub');
absent(legacySub, 'urltest_filter_mode', 'legacy-sub');
absent(legacySub, 'detect_server_country', 'legacy-sub');

const legacyListSub = sections['legacy-list-sub'];
assert(JSON.stringify(childValues(legacyListSub, subscriptionUrls, 'url')) === JSON.stringify(['https://example.com/list.txt', 'https://example.com/auto.txt']), 'legacy list subscription entries normalized');
const legacyListSubSource = childByValue(legacyListSub, subscriptionUrls, 'url', 'https://example.com/list.txt');
const legacyListSubAutoSource = childByValue(legacyListSub, subscriptionUrls, 'url', 'https://example.com/auto.txt');
assert(legacyListSubSource.user_agent === 'ListAgent/2.0', 'legacy list subscription user-agent migrated');
assert(legacyListSubSource.auto_user_agent === '0', 'legacy list subscription manual user-agent mode');
assert(legacyListSubSource.subscription_update_interval === '6h', 'legacy list subscription interval migrated');
assert(legacyListSubAutoSource.auto_user_agent === '1', 'legacy list subscription without User-Agent stays automatic');
assert(!Object.prototype.hasOwnProperty.call(legacyListSubAutoSource, 'user_agent'), 'automatic legacy list subscription should not get user-agent');
absent(legacyListSub, 'subscription_url_settings', 'legacy-list-sub');
absent(legacyListSub, 'subscription_url_items', 'legacy-list-sub');

const legacyUrltest = sections['legacy-urltest'];
assert(legacyUrltest.action === 'connection', 'legacy-urltest action');
assert(JSON.stringify(legacyUrltest.selector_proxy_links) === JSON.stringify(['vmess://a', 'trojan://b']), 'urltest links deduped');
absent(legacyUrltest, 'urltests', 'legacy-urltest');
const legacyUrltestConfig = urltestByOwner(legacyUrltest);
assert(Boolean(legacyUrltestConfig), 'legacy-urltest URLTest child migrated');
absent(legacyUrltestConfig, 'id', 'legacy-urltest URLTest');
absent(legacyUrltestConfig, 'display_name', 'legacy-urltest URLTest');
assert(legacyUrltestConfig.name === 'Fastest', 'legacy-urltest URLTest name migrated');
assert(legacyUrltestConfig.filter_mode === 'exclude', 'legacy-urltest URLTest filter mode migrated');
assert(legacyUrltestConfig.detect_server_country === 'flag_emoji', 'legacy-urltest detect server country normalized');
assert(JSON.stringify(legacyUrltestConfig.exclude_regex) === JSON.stringify(['bad.*']), 'legacy-urltest exclude regex migrated');
absent(legacyUrltest, 'urltest_proxy_links', 'legacy-urltest');
absent(legacyUrltest, 'urltest_enabled', 'legacy-urltest');
absent(legacyUrltest, 'urltest_filter_mode', 'legacy-urltest');
absent(legacyUrltest, 'detect_server_country', 'legacy-urltest');
absent(legacyUrltest, 'urltest_exclude_regex', 'legacy-urltest');

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
assert(legacyVpn.action === 'connection', 'vpn action inferred');
assert(JSON.stringify(legacyVpn.interfaces) === JSON.stringify(['awg0']), 'vpn interface migrated to section list');
absent(legacyVpn, 'proxy_config_type', 'legacy-vpn');
absent(legacyVpn, 'interface', 'legacy-vpn');
absent(legacyVpn, 'interface_items', 'legacy-vpn');
absent(legacyVpn, 'domain_resolver_enabled', 'legacy-vpn');
absent(legacyVpn, 'domain_resolver_dns_type', 'legacy-vpn');
absent(legacyVpn, 'domain_resolver_dns_server', 'legacy-vpn');

const legacyOutbound = sections['legacy-outbound'];
assert(legacyOutbound.action === 'connection', 'outbound action inferred');
assert(Array.isArray(legacyOutbound.outbound_jsons) && legacyOutbound.outbound_jsons.length === 1, 'legacy JSON outbound migrated to list');
const migratedLegacyOutbound = JSON.parse(legacyOutbound.outbound_jsons[0]);
assert(migratedLegacyOutbound.detour === 'legacy-url-out', 'legacy JSON cascade embedded in outbound');
assert(migratedLegacyOutbound.tag === 'legacy-outbound-json-1-out', 'legacy tagless JSON outbound gets a stable list tag');
absent(legacyOutbound, 'outbound_detour_enabled', 'legacy-outbound');
absent(legacyOutbound, 'outbound_detour_section', 'legacy-outbound');

const legacyOutboundCollision = sections['legacy-outbound-collision'];
assert(legacyOutboundCollision.outbound_jsons.length === 2, 'legacy JSON outbound is appended to an existing list');
assert(JSON.parse(legacyOutboundCollision.outbound_jsons[1]).tag === 'legacy-outbound-collision-json-2-out-1', 'legacy JSON outbound tag avoids existing list tags');

assert(out.removed_caches.includes('/tmp/sing-box/subscriptions/legacy-sub.json'), 'subscription runtime cache removal');
assert(out.removed_caches.includes('/var/run/forkop/section-cache/legacy-sub.json'), 'section cache removal');
NODE

cat >"$WORK_DIR/runtime-migrate.state" <<'EOF_UCI'
forkop.settings=settings
forkop.settings.routing_excluded_ips=192.0.2.0/24
forkop.legacy=rule
forkop.legacy.enabled=1
forkop.legacy.connection_type=proxy
forkop.legacy.proxy_config_type=url
forkop.legacy.proxy_string=vless://one
forkop.old_direct=section
forkop.old_direct.enabled=1
forkop.old_direct.action=direct
EOF_UCI
mkdir -p "$WORK_DIR/runtime" "$WORK_DIR/persistent-cache"
: >"$WORK_DIR/runtime-migrate.log"
FORKOP_UCI_STATE_FILE="$WORK_DIR/runtime-migrate.state" \
FORKOP_UCI_LOG_FILE="$WORK_DIR/runtime-migrate.log" \
FORKOP_CONFIG_NAME="forkop" \
TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/tmp-subscriptions" \
FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent-cache" \
FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
ucode -L "$FORKOP_LIB" "$MIGRATION" migrate

grep -Fxq 'forkop.legacy=section' "$WORK_DIR/runtime-migrate.state" ||
  fail "runtime migration must convert legacy rule type through core.uci"
grep -Fxq 'forkop.legacy.action=connection' "$WORK_DIR/runtime-migrate.state" ||
  fail "runtime migration must write migrated action through core.uci"
grep -Fxq 'forkop.old_direct.action=bypass' "$WORK_DIR/runtime-migrate.state" ||
  fail "runtime migration must convert direct action to bypass through core.uci"
grep -Eq '^forkop\\.cfg[0-9a-f]+=$' "$WORK_DIR/runtime-migrate.state" && fail "anonymous fixture section should include a type"
grep -Fxq 'forkop.legacy.selector_proxy_links=vless://one' "$WORK_DIR/runtime-migrate.state" ||
  fail "runtime migration must keep connection URLs in the parent section"
if grep -Fq '=connection_url' "$WORK_DIR/runtime-migrate.state"; then
  fail "runtime migration must not create connection_url child sections"
fi
if grep -Fq 'forkop.legacy.urltest_enabled=' "$WORK_DIR/runtime-migrate.state"; then
  fail "runtime migration must delete migrated urltest_enabled through core.uci"
fi
if grep -Fq 'forkop.settings.routing_excluded_ips=' "$WORK_DIR/runtime-migrate.state"; then
  fail "runtime migration must delete removed routing_excluded_ips through core.uci"
fi
if grep -Fq 'forkop.legacy.proxy_string=' "$WORK_DIR/runtime-migrate.state"; then
  fail "runtime migration must delete legacy proxy_string through core.uci"
fi
grep -Fxq 'commit forkop' "$WORK_DIR/runtime-migrate.log" ||
  fail "runtime migration must commit through core.uci"

: >"$WORK_DIR/uci-commit.log"
: >"$WORK_DIR/uci-commit.state"
FORKOP_UCI_STATE_FILE="$WORK_DIR/uci-commit.state" \
FORKOP_UCI_LOG_FILE="$WORK_DIR/uci-commit.log" \
FORKOP_CONFIG_NAME="forkop" \
FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
ucode -L "$FORKOP_LIB" "$MIGRATION" commit

grep -Fxq 'commit forkop' "$WORK_DIR/uci-commit.log" ||
  fail "commit mode must commit forkop through core.uci"

printf 'installer config migration checks passed\n'
