#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
GENERATOR="$FORKOP_LIB/singbox/generator.uc"
FAILOVER="$FORKOP_LIB/singbox/dns_failover.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

generate() {
  local fixture="$1"
  local output="$2"
  local state="${3:-$WORK_DIR/missing-state.json}"
  FORKOP_LIB="$FORKOP_LIB" \
    FORKOP_DNS_FAILOVER_STATE_FILE="$state" \
    ucode -L "$FORKOP_LIB" "$GENERATOR" generate-config-fixture "$fixture" "$output" 192.168.1.1 0
}

cat >"$WORK_DIR/single.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "udp",
    "dns_server": "77.88.8.8",
    "bootstrap_dns_server": "77.88.8.8"
  },
  "section": [
    {
      ".name": "direct",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "domain_suffix": [ "example.org" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/multi.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "doh",
    "dns_server": [ "dns.google/dns-query", "cloudflare-dns.com/dns-query" ],
    "bootstrap_dns_server": [ "1.1.1.1", "8.8.8.8" ],
    "dns_check_interval": "10s",
    "dns_recovery_check_interval": "60s",
    "dns_check_timeout": "2s",
    "dns_failure_threshold": "3",
    "dns_recovery_threshold": "3",
    "dns_detour_enabled": "1",
    "dns_detour_section": "proxy"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "outbound",
      "outbound_json": "{\"type\":\"direct\",\"tag\":\"fixture\"}",
      "domain_suffix": [ "example.org" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/state.json" <<'JSON'
{
  "version": 1,
  "dns_type": "doh",
  "dns_detour": "proxy-out",
  "main_servers": [ "dns.google/dns-query", "cloudflare-dns.com/dns-query" ],
  "bootstrap_servers": [ "1.1.1.1", "8.8.8.8" ],
  "main_index": 1,
  "bootstrap_index": 1
}
JSON

generate "$WORK_DIR/single.json" "$WORK_DIR/single-config.json"
generate "$WORK_DIR/multi.json" "$WORK_DIR/multi-config.json" "$WORK_DIR/state.json"

ucode -e '
let fs = require("fs");

function cfg(path) { return json(fs.readfile(path)); }
function assert(value, message) { if (!value) { warn("FAIL: ", message, "\n"); exit(1); } }
function find_tag(values, tag) { for (let value in values || []) if (value.tag == tag) return value; return null; }
function count_prefix(values, prefix) { let count = 0; for (let value in values || []) if (index(value.tag || "", prefix) == 0) count++; return count; }

let single = cfg(ARGV[0]);
assert(length(single.dns.servers) == 3, "singleton keeps the legacy three-server shape");
assert(length(single.inbounds) == 3, "singleton adds no health inbounds");
assert(count_prefix(single.dns.servers, "dns-health-") == 0, "singleton adds no health servers");
assert(find_tag(single.dns.servers, "dns-server").server == "77.88.8.8", "singleton main DNS preserved");
assert(single.route.default_domain_resolver == "dns-server", "singleton keeps main default resolver");

let multi = cfg(ARGV[1]);
assert(length(multi.dns.servers) == 7, "two main and two bootstrap candidates are generated");
assert(length(multi.inbounds) == 8, "candidate and active health inbounds are generated");
assert(count_prefix(multi.dns.servers, "dns-health-main-") == 2, "main health servers generated");
assert(count_prefix(multi.dns.servers, "dns-health-bootstrap-") == 2, "bootstrap health servers generated");
let main = find_tag(multi.dns.servers, "dns-server");
let bootstrap = find_tag(multi.dns.servers, "bootstrap-dns-server");
assert(main.server == "cloudflare-dns.com", "runtime main index selects the second server");
assert(main.detour == "proxy-out", "main DNS uses selected section detour");
assert(main.domain_resolver == "bootstrap-dns-server", "main hostname uses direct bootstrap resolver");
assert(bootstrap.server == "8.8.8.8" && bootstrap.detour == null, "bootstrap index selects direct second server");
assert(multi.route.default_domain_resolver == "bootstrap-dns-server", "detour mode breaks endpoint DNS cycles with bootstrap");
let health_rules = 0;
for (let rule in multi.dns.rules || []) {
    if (index(rule.inbound || "", "dns-health-") == 0) {
        health_rules++;
        assert(rule.disable_cache === true, "health checks bypass DNS cache");
    }
}
assert(health_rules == 5, "each candidate and the canonical active DNS have an inbound-specific rule");
' "$WORK_DIR/single-config.json" "$WORK_DIR/multi-config.json"

cat >"$WORK_DIR/select-state.json" <<'JSON'
{
  "main_servers": [ "first", "second", "third" ],
  "bootstrap_servers": [ "a", "b" ],
  "main_index": 0,
  "bootstrap_index": 1
}
JSON
cat >"$WORK_DIR/alive-failover.json" <<'JSON'
{ "0": false, "1": true, "2": true }
JSON
cat >"$WORK_DIR/alive-recovery.json" <<'JSON'
{ "0": true, "1": true }
JSON

selected="$(ucode -L "$FORKOP_LIB" "$FAILOVER" select-fixture "$WORK_DIR/select-state.json" "$WORK_DIR/alive-failover.json" main 0)"
printf '%s' "$selected" | grep -Eq '"index"[[:space:]]*:[[:space:]]*1' || fail "dead active DNS must select the first live server below"
printf '%s' "$selected" | grep -Eq '"reason"[[:space:]]*:[[:space:]]*"active_dead"' || fail "failover reason"

selected="$(ucode -L "$FORKOP_LIB" "$FAILOVER" select-fixture "$WORK_DIR/select-state.json" "$WORK_DIR/alive-recovery.json" bootstrap 1)"
printf '%s' "$selected" | grep -Eq '"index"[[:space:]]*:[[:space:]]*0' || fail "recovery must return to the highest live priority"
printf '%s' "$selected" | grep -Eq '"reason"[[:space:]]*:[[:space:]]*"recovery"' || fail "recovery reason"

cat >"$WORK_DIR/verify-previous.json" <<'JSON'
{ "main_index": 0, "bootstrap_index": 0, "bootstrap_servers": [ "a", "b" ] }
JSON
cat >"$WORK_DIR/verify-bootstrap.json" <<'JSON'
{ "main_index": 0, "bootstrap_index": 1, "bootstrap_servers": [ "a", "b" ] }
JSON

verification="$(ucode -L "$FORKOP_LIB" "$FAILOVER" verification-plan-fixture "$WORK_DIR/verify-previous.json" "$WORK_DIR/verify-bootstrap.json")"
printf '%s' "$verification" | grep -Eq '"main"[[:space:]]*:[[:space:]]*false' || fail "bootstrap-only switch must not require a dead main DNS to recover"
printf '%s' "$verification" | grep -Eq '"bootstrap"[[:space:]]*:[[:space:]]*true' || fail "bootstrap-only switch must verify the selected bootstrap DNS"

cat >"$WORK_DIR/two-failures.json" <<'JSON'
[
  { "index": 1, "reason": "active_dead", "alive": true },
  { "index": 1, "reason": "active_dead", "alive": true }
]
JSON
cat >"$WORK_DIR/three-failures.json" <<'JSON'
[
  { "index": 1, "reason": "active_dead", "alive": true },
  { "index": 1, "reason": "active_dead", "alive": true },
  { "index": 1, "reason": "active_dead", "alive": true }
]
JSON
cat >"$WORK_DIR/reset-failures.json" <<'JSON'
[
  { "index": 1, "reason": "active_dead", "alive": true },
  { "index": 0, "reason": "alive", "alive": true },
  { "index": 1, "reason": "active_dead", "alive": true },
  { "index": 1, "reason": "active_dead", "alive": true }
]
JSON
cat >"$WORK_DIR/two-recoveries.json" <<'JSON'
[
  { "index": 0, "reason": "recovery", "alive": true },
  { "index": 0, "reason": "recovery", "alive": true }
]
JSON
cat >"$WORK_DIR/three-recoveries.json" <<'JSON'
[
  { "index": 0, "reason": "recovery", "alive": true },
  { "index": 0, "reason": "recovery", "alive": true },
  { "index": 0, "reason": "recovery", "alive": true }
]
JSON
cat >"$WORK_DIR/reset-recoveries.json" <<'JSON'
[
  { "index": 0, "reason": "recovery", "alive": true },
  { "index": 1, "reason": "unchanged", "alive": true },
  { "index": 0, "reason": "recovery", "alive": true },
  { "index": 0, "reason": "recovery", "alive": true }
]
JSON

threshold_result="$(ucode -L "$FORKOP_LIB" "$FAILOVER" threshold-fixture "$WORK_DIR/two-failures.json" 0 3 0)"
printf '%s' "$threshold_result" | grep -Eq '"index"[[:space:]]*:[[:space:]]*0' || fail "two failures must not switch"
threshold_result="$(ucode -L "$FORKOP_LIB" "$FAILOVER" threshold-fixture "$WORK_DIR/three-failures.json" 0 3 0)"
printf '%s' "$threshold_result" | grep -Eq '"index"[[:space:]]*:[[:space:]]*1' || fail "third failure must switch"
threshold_result="$(ucode -L "$FORKOP_LIB" "$FAILOVER" threshold-fixture "$WORK_DIR/reset-failures.json" 0 3 0)"
printf '%s' "$threshold_result" | grep -Eq '"index"[[:space:]]*:[[:space:]]*0' || fail "successful check must reset failures"

threshold_result="$(ucode -L "$FORKOP_LIB" "$FAILOVER" threshold-fixture "$WORK_DIR/two-recoveries.json" 1 3 1)"
printf '%s' "$threshold_result" | grep -Eq '"index"[[:space:]]*:[[:space:]]*1' || fail "two recoveries must not switch"
threshold_result="$(ucode -L "$FORKOP_LIB" "$FAILOVER" threshold-fixture "$WORK_DIR/three-recoveries.json" 1 3 1)"
printf '%s' "$threshold_result" | grep -Eq '"index"[[:space:]]*:[[:space:]]*0' || fail "third recovery must switch"
threshold_result="$(ucode -L "$FORKOP_LIB" "$FAILOVER" threshold-fixture "$WORK_DIR/reset-recoveries.json" 1 3 1)"
printf '%s' "$threshold_result" | grep -Eq '"index"[[:space:]]*:[[:space:]]*1' || fail "failed recovery must reset successes"

printf 'DNS failover checks passed\n'
