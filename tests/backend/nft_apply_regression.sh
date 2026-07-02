#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
NFT_RUNTIME="$ROOT_DIR/podkop/files/usr/lib/nft/apply.uc"
WORK_DIR="$(mktemp -d)"
NFT_LOG="$WORK_DIR/nft.log"
LOGGER_LOG="$WORK_DIR/logger.log"
IP_LOG="$WORK_DIR/ip.log"
SYSCTL_LOG="$WORK_DIR/sysctl.log"

nft_ucode() {
  ucode -L "$PODKOP_LIB" "$NFT_RUNTIME" "$@"
}

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'nft log:\n' >&2
  cat "$NFT_LOG" >&2 2>/dev/null || true
  printf 'logger log:\n' >&2
  cat "$LOGGER_LOG" >&2 2>/dev/null || true
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  local label="$3"

  grep -Fq "$expected" "$file" || fail "$label: expected '$expected'"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

assert_line_before() {
  local file="$1"
  local first="$2"
  local second="$3"
  local label="$4"
  local first_line
  local second_line

  first_line="$(grep -Fn "$first" "$file" | head -n 1 | cut -d: -f1 || true)"
  second_line="$(grep -Fn "$second" "$file" | head -n 1 | cut -d: -f1 || true)"
  [ -n "$first_line" ] || fail "$label: missing first line '$first'"
  [ -n "$second_line" ] || fail "$label: missing second line '$second'"
  [ "$first_line" -lt "$second_line" ] || fail "$label: expected first line before second"
}

if grep -n 'require("uci").cursor' "$NFT_RUNTIME" >/dev/null 2>&1 ||
  grep -n 'uci -q' "$NFT_RUNTIME" >/dev/null 2>&1 ||
  grep -n '"uci", "-q"' "$NFT_RUNTIME" >/dev/null 2>&1 ||
  grep -n 'command_from_args(\[ "uci"' "$NFT_RUNTIME" >/dev/null 2>&1; then
  fail "nft/apply.uc must use core.uci instead of direct UCI cursor or CLI access"
fi
grep -Fq 'require("core.uci")' "$NFT_RUNTIME" ||
  fail "nft/apply.uc must import core.uci"

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/nft" <<'NFT'
#!/usr/bin/env bash
set -eo pipefail
{
  printf 'nft'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "${NFT_LOG:?}"

if [ "$#" -eq 5 ] && [ "$1" = "list" ] && [ "$2" = "chain" ] &&
  [ "$3" = "inet" ] && [ "$5" = "mangle" ] && [ -n "${NFT_MANGLE_CHAIN_OUTPUT:-}" ]; then
  printf '%s\n' "$NFT_MANGLE_CHAIN_OUTPUT"
fi

if [ "$#" -eq 4 ] && [ "$1" = "list" ] && [ "$2" = "table" ] &&
  [ "$3" = "inet" ]; then
  if [ "${NFT_LIST_TABLE_FAIL:-0}" = "1" ]; then
    printf 'table %s is missing\n' "$4" >&2
    exit 1
  fi
fi
NFT
chmod 0755 "$WORK_DIR/bin/nft"

cat >"$WORK_DIR/bin/ip" <<'IP'
#!/usr/bin/env bash
set -eo pipefail
{
  printf 'ip'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "${IP_LOG:?}"

if [ "$#" -eq 4 ] && [ "$1" = "route" ] && [ "$2" = "list" ] && [ "$3" = "table" ]; then
  printf '%s\n' "${IP_ROUTE_OUTPUT:-}"
  exit 0
fi

if [ "$#" -eq 5 ] && [ "$1" = "-6" ] && [ "$2" = "route" ] && [ "$3" = "list" ] && [ "$4" = "table" ]; then
  printf '%s\n' "${IP_ROUTE6_OUTPUT:-}"
  exit 0
fi

if [ "$#" -eq 3 ] && [ "$1" = "-4" ] && [ "$2" = "rule" ] && [ "$3" = "list" ]; then
  printf '%s\n' "${IP_RULE_OUTPUT:-}"
  exit 0
fi

if [ "$#" -eq 3 ] && [ "$1" = "-6" ] && [ "$2" = "rule" ] && [ "$3" = "list" ]; then
  printf '%s\n' "${IP_RULE6_OUTPUT:-}"
  exit 0
fi

[ "${IP_FAIL_ADD:-0}" = "1" ] && exit 1
exit 0
IP
chmod 0755 "$WORK_DIR/bin/ip"

cat >"$WORK_DIR/bin/lsmod" <<'LSMOD'
#!/usr/bin/env bash
set -eo pipefail
printf '%s\n' "${LSMOD_OUTPUT:-}"
LSMOD
chmod 0755 "$WORK_DIR/bin/lsmod"

cat >"$WORK_DIR/bin/sysctl" <<'SYSCTL'
#!/usr/bin/env bash
set -eo pipefail
{
  printf 'sysctl'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "${SYSCTL_LOG:?}"

if [ "$#" -eq 2 ] && [ "$1" = "-n" ] && [ "$2" = "net.bridge.bridge-nf-call-iptables" ]; then
  printf '%s\n' "${SYSCTL_BRIDGE_NF_CALL_IPTABLES:-0}"
  exit 0
fi

exit 0
SYSCTL
chmod 0755 "$WORK_DIR/bin/sysctl"

cat >"$WORK_DIR/bin/logger" <<'LOGGER'
#!/usr/bin/env bash
set -eo pipefail
printf '%s\n' "$*" >> "${LOGGER_LOG:?}"
LOGGER
chmod 0755 "$WORK_DIR/bin/logger"

export PATH="$WORK_DIR/bin:$PATH"
export NFT_LOG
export LOGGER_LOG
export IP_LOG
export SYSCTL_LOG

assert_eq "/tmp/podkop-cache/condition_rule_1_domain_domains" \
  "$(nft_ucode cache-path 1 /tmp/podkop-cache condition rule_1 domain domains)" \
  "cache path"
if nft_ucode cache-path 1 /tmp/podkop-cache condition 'bad-name' domain domains >/dev/null 2>&1; then
  fail "unsafe cache key should fail"
fi

assert_eq "198.51.100.1,203.0.113.0/24" \
  "$(nft_ucode legacy-condition-csv subnets 1 0 $'198.51.100.1\nbad-value\n203.0.113.0/24' '10.0.0.0/8')" \
  "legacy text-mode subnets"
assert_eq "10.0.0.0/8,192.0.2.1" \
  "$(nft_ucode legacy-condition-csv subnets 0 0 '198.51.100.1' '10.0.0.0/8 192.0.2.1')" \
  "legacy list priority"
assert_eq "full:example.com,keyword:ads,regex:^foo" \
  "$(nft_ucode list-value-to-csv 'full:example.com keyword:ads regex:^foo')" \
  "list value csv"
assert_eq "one.example,list.example,legacy.example" \
  "$(nft_ucode rule-condition-csv domain domains 0 0 legacy.example '' 'full:one.example keyword:skip regex:^skip suffix.example' 'full:list.example keyword:list-skip')" \
  "combined domain plus legacy"
assert_eq "suffix.example,list.example" \
  "$(nft_ucode rule-condition-csv domain_suffix domains 0 0 legacy.example legacy-list.example 'full:one.example suffix.example keyword:skip' 'full:list-full.example list.example')" \
  "combined suffix ignores legacy"
assert_eq "xn--80aswg.xn--p1ai" \
  "$(nft_ucode rule-condition-csv domain_suffix domains 0 0 '' '' 'сайт.рф full:пример.испытание keyword:пример regex:^сайт[.]рф$' '')" \
  "combined IDN suffix is punycoded"
assert_eq "xn--e1afmkfd.xn--80akhbyknj4f" \
  "$(nft_ucode rule-condition-csv domain domains 0 0 '' '' 'сайт.рф full:пример.испытание keyword:пример regex:^сайт[.]рф$' '')" \
  "combined IDN full domain is punycoded"
assert_eq "xn--e1afmkfd" \
  "$(nft_ucode rule-condition-csv domain_keyword generic 0 0 '' '' 'сайт.рф full:пример.испытание keyword:пример regex:^сайт[.]рф$' '')" \
  "combined IDN keyword is punycoded"
assert_eq "^xn--80aswg[.]xn--p1ai$" \
  "$(nft_ucode rule-condition-csv domain_regex generic 0 0 '' '' 'сайт.рф full:пример.испытание keyword:пример regex:^сайт[.]рф$' '')" \
  "combined IDN regex is punycoded"

nft_ucode nft-create-runtime-base PodkopPlusTable localv4 podkop_plus_subnets podkop_plus_ports podkop_plus_ip_ports podkop_plus_interfaces "br-lan tun0" 0x00100000 0x00200000 198.18.0.0/15 1602 1
assert_contains "$NFT_LOG" $'nft\tadd\ttable\tinet\tPodkopPlusTable' "runtime table"
assert_contains "$NFT_LOG" $'nft\tadd\tset\tinet\tPodkopPlusTable\tlocalv4\t{ type ipv4_addr; flags interval; auto-merge; }' "runtime localv4 set"
assert_contains "$NFT_LOG" $'nft\tadd\tset\tinet\tPodkopPlusTable\tlocalv6\t{ type ipv6_addr; flags interval; auto-merge; }' "runtime localv6 set"
assert_contains "$NFT_LOG" '0.0.0.0/8,10.0.0.0/8,127.0.0.0/8' "runtime localv4 elements"
assert_contains "$NFT_LOG" '::/128,::1/128,64:ff9b::/96' "runtime localv6 elements"
assert_contains "$NFT_LOG" $'nft\tadd\tset\tinet\tPodkopPlusTable\tpodkop_plus_interfaces\t{ type ifname; flags interval; }' "runtime interface set"
assert_contains "$NFT_LOG" $'nft\tadd\telement\tinet\tPodkopPlusTable\tpodkop_plus_interfaces\t{ br-lan }' "runtime br-lan interface"
assert_contains "$NFT_LOG" $'nft\tadd\telement\tinet\tPodkopPlusTable\tpodkop_plus_interfaces\t{ tun0 }' "runtime tun0 interface"
assert_contains "$NFT_LOG" $'nft\tadd\tchain\tinet\tPodkopPlusTable\tmangle\t{ type filter hook prerouting priority -150; policy accept; }' "runtime mangle chain"
assert_contains "$NFT_LOG" $'nft\tadd\tchain\tinet\tPodkopPlusTable\tpriority_rules\t{ }' "runtime priority chain"
assert_contains "$NFT_LOG" $'nft\tadd\tchain\tinet\tPodkopPlusTable\tpriority_output_rules\t{ }' "runtime priority output chain"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tPodkopPlusTable\tmangle\tjump\tpriority_rules' "runtime priority jump"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tPodkopPlusTable\tmangle\tiifname\t@podkop_plus_interfaces\tip\tdaddr\t@podkop_plus_subnets\tmeta\tl4proto\ttcp\tmeta\tmark\tset\t0x00100000\tcounter' "runtime common tcp rule"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tPodkopPlusTable\tmangle\tiifname\t@podkop_plus_interfaces\tip6\tdaddr\t@podkop_plus_subnets6\tmeta\tl4proto\ttcp\tmeta\tmark\tset\t0x00100000\tcounter' "runtime common6 tcp rule"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tPodkopPlusTable\tproxy\tmeta\tmark\t&\t0x00100000\t==\t0x00100000\tmeta\tl4proto\ttcp\ttproxy\tip\tto\t:1602\tcounter' "runtime proxy tcp rule"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tPodkopPlusTable\tproxy\tmeta\tmark\t&\t0x00100000\t==\t0x00100000\tmeta\tl4proto\ttcp\ttproxy\tip6\tto\t[::1]:1602\tcounter' "runtime proxy6 tcp rule"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tPodkopPlusTable\tmangle_output\tmeta\tmark\t0x00200000\tcounter\treturn' "runtime outbound return"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tPodkopPlusTable\tmangle_output\tjump\tpriority_output_rules' "runtime priority output jump"
assert_contains "$NFT_LOG" $'nft\tinsert\trule\tinet\tPodkopPlusTable\tmangle\tudp\tdport\t123\treturn' "runtime ntp exclusion"

cat >"$WORK_DIR/runtime-base-uci.state" <<'EOF_UCI'
podkop-plus.settings=settings
podkop-plus.settings.source_network_interfaces=br-lan tun0
podkop-plus.settings.exclude_ntp=1
EOF_UCI
: > "$NFT_LOG"
PODKOP_UCI_STATE_FILE="$WORK_DIR/runtime-base-uci.state" \
  nft_ucode nft-create-runtime-base-from-uci PodkopPlusTable localv4 podkop_plus_subnets podkop_plus_ports podkop_plus_ip_ports podkop_plus_interfaces 0x00100000 0x00200000 198.18.0.0/15 1602
assert_contains "$NFT_LOG" $'nft\tadd\telement\tinet\tPodkopPlusTable\tpodkop_plus_interfaces\t{ br-lan }' "runtime base from UCI br-lan interface"
assert_contains "$NFT_LOG" $'nft\tadd\telement\tinet\tPodkopPlusTable\tpodkop_plus_interfaces\t{ tun0 }' "runtime base from UCI tun0 interface"
assert_contains "$NFT_LOG" $'nft\tinsert\trule\tinet\tPodkopPlusTable\tmangle\tudp\tdport\t123\treturn' "runtime base from UCI ntp exclusion"

: > "$NFT_LOG"
nft_ucode nft-create-runtime-output-rules PodkopPlusTable localv4 podkop_plus_subnets podkop_plus_ports podkop_plus_ip_ports 0x00100000 198.18.0.0/15
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tPodkopPlusTable\tmangle_output\tip\tdaddr\t@podkop_plus_subnets\tmeta\tl4proto\ttcp\tmeta\tmark\tset\t0x00100000\tcounter' "runtime output common tcp"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tPodkopPlusTable\tmangle_output\tip6\tdaddr\t@podkop_plus_subnets6\tmeta\tl4proto\ttcp\tmeta\tmark\tset\t0x00100000\tcounter' "runtime output common6 tcp"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tPodkopPlusTable\tmangle_output\tip\tdaddr\t.\ttcp\tdport\t@podkop_plus_ip_ports\tmeta\tmark\tset\t0x00100000\tcounter' "runtime output ip-port tcp"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tPodkopPlusTable\tmangle_output\tip6\tdaddr\t.\ttcp\tdport\t@podkop_plus_ip6_ports\tmeta\tmark\tset\t0x00100000\tcounter' "runtime output ip6-port tcp"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tPodkopPlusTable\tmangle_output\ttcp\tdport\t@podkop_plus_ports\tmeta\tmark\tset\t0x00100000\tcounter' "runtime output port tcp"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tPodkopPlusTable\tmangle_output\tip\tdaddr\t198.18.0.0/15\tmeta\tl4proto\tudp\tmeta\tmark\tset\t0x00100000\tcounter' "runtime output fakeip udp"

: > "$NFT_LOG"
if NFT_LIST_TABLE_FAIL=1 nft_ucode nft-table-present-fixture PodkopPlusTable 2>"$WORK_DIR/nft-table-present.err"; then
  fail "missing nft table should return false"
fi
[ ! -s "$WORK_DIR/nft-table-present.err" ] ||
  fail "missing nft table predicate must suppress nft stderr"
assert_contains "$NFT_LOG" $'nft\tlist\ttable\tinet\tPodkopPlusTable' "nft table presence check"

cat >"$WORK_DIR/provider-rules.json" <<'JSON'
{
  "section": [
    { ".name": "direct", "enabled": "1", "action": "bypass" },
    { ".name": "zapret_one", "enabled": "1", "action": "zapret" },
    { ".name": "zapret_disabled", "enabled": "0", "action": "zapret" },
    { ".name": "zapret_two", "enabled": "1", "action": "zapret" },
    { ".name": "zapret2_one", "enabled": "1", "action": "zapret2" }
  ]
}
JSON
provider_bin="$WORK_DIR/bin/provider"
printf '#!/usr/bin/env sh\nexit 0\n' >"$provider_bin"
chmod 0755 "$provider_bin"

: > "$NFT_LOG"
nft_ucode nft-create-provider-output-rules-fixture "$WORK_DIR/provider-rules.json" PodkopPlusTable zapret "$provider_bin" 0x01000000 4000 0x40000000 0x20000000
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tPodkopPlusTable\tmangle_output\tmeta\tmark\t&\t0x40000000\t==\t0x40000000\treturn' "zapret desync return"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tPodkopPlusTable\tmangle_output\tmeta\tmark\t0x01000001\tmeta\tl4proto\ttcp\tcounter\tqueue\tnum\t4000\tbypass' "zapret first tcp queue rule"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tPodkopPlusTable\tmangle_output\tmeta\tmark\t0x01000002\tmeta\tl4proto\tudp\tcounter\tqueue\tnum\t4001\tbypass' "zapret second udp queue rule"
if grep -Fq 'zapret_disabled' "$NFT_LOG"; then
  fail "disabled provider section should not create nft rule"
fi

: > "$NFT_LOG"
nft_ucode nft-create-provider-output-rules-fixture "$WORK_DIR/provider-rules.json" PodkopPlusTable zapret "$WORK_DIR/bin/missing-provider" 0x01000000 4000 0x40000000 0x20000000
if [ -s "$NFT_LOG" ]; then
  fail "missing provider binary should skip provider nft output rules"
fi

cat >"$WORK_DIR/priority-rules.json" <<'JSON'
{
  "section": [
    {
      ".name": "bypass_first",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "ip_cidr": [ "198.51.100.0/24" ]
    },
    {
      ".name": "wide_proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "ip_cidr": [ "0.0.0.0/0" ]
    },
    {
      ".name": "port_bypass",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "ports": [ "8443" ]
    }
  ]
}
JSON

: > "$NFT_LOG"
nft_ucode nft-add-section-priority-rules-fixture "$WORK_DIR/priority-rules.json" PodkopPlusTable podkop_plus_interfaces localv4 localv6 0x00100000
assert_contains "$NFT_LOG" $'nft\tadd\tset\tinet\tPodkopPlusTable\tpodkop_plus_rule_bypass_first_subnets\t{ type ipv4_addr; flags interval; auto-merge; }' "bypass priority subnet set"
assert_contains "$NFT_LOG" $'nft\tadd\tset\tinet\tPodkopPlusTable\tpodkop_plus_rule_wide_proxy_subnets\t{ type ipv4_addr; flags interval; auto-merge; }' "proxy priority subnet set"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tPodkopPlusTable\tpriority_rules\tiifname\t@podkop_plus_interfaces\tip\tdaddr\t!=\t@localv4\tip\tdaddr\t@podkop_plus_rule_bypass_first_subnets\tcounter\taccept' "bypass priority accept rule"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tPodkopPlusTable\tpriority_rules\tiifname\t@podkop_plus_interfaces\tip\tdaddr\t!=\t@localv4\tip\tdaddr\t@podkop_plus_rule_wide_proxy_subnets\tmeta\tmark\tset\t0x00100000\tcounter\taccept' "proxy priority capture rule"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tPodkopPlusTable\tpriority_rules\tiifname\t@podkop_plus_interfaces\tip\tdaddr\t!=\t@localv4\ttcp\tdport\t@podkop_plus_rule_port_bypass_ports\tcounter\taccept' "port-only bypass priority rule"
assert_line_before "$NFT_LOG" \
  $'nft\tadd\trule\tinet\tPodkopPlusTable\tpriority_rules\tiifname\t@podkop_plus_interfaces\tip\tdaddr\t!=\t@localv4\tip\tdaddr\t@podkop_plus_rule_bypass_first_subnets\tcounter\taccept' \
  $'nft\tadd\trule\tinet\tPodkopPlusTable\tpriority_rules\tiifname\t@podkop_plus_interfaces\tip\tdaddr\t!=\t@localv4\tip\tdaddr\t@podkop_plus_rule_wide_proxy_subnets\tmeta\tmark\tset\t0x00100000\tcounter\taccept' \
  "bypass priority order"

: > "$IP_LOG"
: > "$LOGGER_LOG"
rt_tables="$WORK_DIR/rt_tables"
IP_ROUTE_OUTPUT='' IP_ROUTE6_OUTPUT='' IP_RULE_OUTPUT='' IP_RULE6_OUTPUT='' nft_ucode ensure-tproxy-route-rule podkop 0x00100000 "$rt_tables"
assert_contains "$rt_tables" "105 podkop" "tproxy route table registry"
assert_contains "$IP_LOG" $'ip\troute\tadd\tlocal\t0.0.0.0/0\tdev\tlo\ttable\tpodkop' "tproxy route add"
assert_contains "$IP_LOG" $'ip\t-6\troute\tadd\tlocal\t::/0\tdev\tlo\ttable\tpodkop' "tproxy route6 add"
assert_contains "$IP_LOG" $'ip\t-4\trule\tadd\tfwmark\t0x00100000/0x00100000\ttable\tpodkop\tpriority\t105' "tproxy marking rule add"
assert_contains "$IP_LOG" $'ip\t-6\trule\tadd\tfwmark\t0x00100000/0x00100000\ttable\tpodkop\tpriority\t105' "tproxy marking rule6 add"
assert_contains "$LOGGER_LOG" "[debug] Added IPv4 TPROXY route" "tproxy route creation log"
assert_contains "$LOGGER_LOG" "[debug] Added IPv6 TPROXY route" "tproxy route6 creation log"
assert_contains "$LOGGER_LOG" "[debug] Creating IPv4 TPROXY marking rule" "tproxy marking rule creation log"
assert_contains "$LOGGER_LOG" "[debug] Creating IPv6 TPROXY marking rule" "tproxy marking rule6 creation log"

: > "$IP_LOG"
: > "$LOGGER_LOG"
printf '%s\n' '105 podkop' >"$rt_tables"
IP_ROUTE_OUTPUT='local default dev lo scope host' \
  IP_ROUTE6_OUTPUT='local default dev lo metric 1024 pref medium' \
  IP_RULE_OUTPUT='105: from all fwmark 0x100000/0x100000 lookup podkop' \
  IP_RULE6_OUTPUT='105: from all fwmark 0x100000/0x100000 lookup podkop' \
  nft_ucode ensure-tproxy-route-rule podkop 0x00100000 "$rt_tables"
if grep -Fq $'\tadd\t' "$IP_LOG"; then
  fail "existing tproxy route/rule should not be added again"
fi
assert_contains "$LOGGER_LOG" "[debug] IPv4 TPROXY route already exists" "existing tproxy route log"
assert_contains "$LOGGER_LOG" "[debug] IPv6 TPROXY route already exists" "existing tproxy route6 log"
assert_contains "$LOGGER_LOG" "[debug] IPv4 TPROXY marking rule already exists" "existing tproxy marking rule log"
assert_contains "$LOGGER_LOG" "[debug] IPv6 TPROXY marking rule already exists" "existing tproxy marking rule6 log"
IP_ROUTE_OUTPUT='local default dev lo scope host' \
  IP_ROUTE6_OUTPUT='local default dev lo metric 1024 pref medium' \
  IP_RULE_OUTPUT='105: from all fwmark 0x100000/0x100000 lookup podkop' \
  IP_RULE6_OUTPUT='105: from all fwmark 0x100000/0x100000 lookup podkop' \
  nft_ucode tproxy-route-rule-present podkop 0x00100000
if IP_ROUTE_OUTPUT='local default dev lo scope host' \
  IP_ROUTE6_OUTPUT='local default dev lo metric 1024 pref medium' \
  IP_RULE_OUTPUT='105: from all fwmark 0x100000/0x100000 lookup other' \
  IP_RULE6_OUTPUT='105: from all fwmark 0x100000/0x100000 lookup podkop' \
  nft_ucode tproxy-route-rule-present podkop 0x00100000 >/dev/null 2>&1; then
  fail "tproxy route/rule presence should require matching lookup table"
fi

: > "$SYSCTL_LOG"
: > "$LOGGER_LOG"
LSMOD_OUTPUT='br_netfilter 32768 0' SYSCTL_BRIDGE_NF_CALL_IPTABLES=1 nft_ucode ensure-bridge-netfilter-disabled
assert_contains "$SYSCTL_LOG" $'sysctl\t-n\tnet.bridge.bridge-nf-call-iptables' "bridge netfilter sysctl check"
assert_contains "$SYSCTL_LOG" $'sysctl\t-w\tnet.bridge.bridge-nf-call-iptables=0' "bridge netfilter ipv4 disable"
assert_contains "$SYSCTL_LOG" $'sysctl\t-w\tnet.bridge.bridge-nf-call-ip6tables=0' "bridge netfilter ipv6 disable"
assert_contains "$LOGGER_LOG" "[debug] br_netfilter is enabled; disabling it for transparent proxy routing" "bridge netfilter disable log"

: > "$SYSCTL_LOG"
LSMOD_OUTPUT='' SYSCTL_BRIDGE_NF_CALL_IPTABLES=1 nft_ucode ensure-bridge-netfilter-disabled
if [ -s "$SYSCTL_LOG" ]; then
  fail "bridge netfilter absent should not call sysctl"
fi

input="$WORK_DIR/ips.txt"
cat >"$input" <<'EOF_INPUT'
198.51.100.1
bad-value
203.0.113.0/24
EOF_INPUT

nft_ucode nft-add-file-chunks-to-set "$input" PodkopPlusTable podkop_plus_subnets ips "" 2
assert_contains "$NFT_LOG" $'nft\tadd\telement\tinet\tPodkopPlusTable\tpodkop_plus_subnets\t{ 198.51.100.1,203.0.113.0/24 }' "nft chunked ips"
assert_contains "$LOGGER_LOG" "[debug] 'bad-value' is not IP or CIDR" "invalid element log"
assert_contains "$LOGGER_LOG" "[debug] Adding 2 elements to nft set podkop_plus_subnets" "chunk count log"

: > "$NFT_LOG"
ports_input="$WORK_DIR/ip-ports.txt"
cat >"$ports_input" <<'EOF_INPUT'
198.51.100.1
203.0.113.0/24
EOF_INPUT

nft_ucode nft-add-file-chunks-to-set "$ports_input" PodkopPlusTable podkop_plus_ip_ports ip-port-from-ip "80,443-444" 3
assert_contains "$NFT_LOG" $'198.51.100.1 . 80,198.51.100.1 . 443-444,203.0.113.0/24 . 80' "ip-port chunk"
assert_contains "$NFT_LOG" $'203.0.113.0/24 . 443-444' "ip-port second chunk"

cat >"$WORK_DIR/populate-fixture.json" <<'JSON'
{
  "section": [
    {
      ".name": "disabled",
      ".type": "section",
      "enabled": "0",
      "action": "proxy",
      "ip_cidr": [ "192.0.2.1" ],
      "ports": [ "53" ],
      "fully_routed_ips": [ "192.168.1.50/32" ]
    },
    {
      ".name": "deferred",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "ip_cidr": [ "192.0.2.2" ],
      "ports": [ "54" ],
      "fully_routed_ips": [ "192.168.1.51/32" ]
    },
    {
      ".name": "inline",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "ip_cidr": [ "198.51.100.1", "203.0.113.0/24", "2001:db8::1" ],
      "ports": [ "80", "443-444" ],
      "fully_routed_ips": [ "192.168.1.20/32", "192.168.1.20/32", "2001:db8::20/128" ]
    },
    {
      ".name": "inline_no_ports",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "ip_cidr": [ "198.51.100.200", "2001:db8::200" ]
    },
    {
      ".name": "ports_only",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "ports": [ "53", "853" ],
      "ports_text": "5353, 853"
    },
    {
      ".name": "ports_with_domain",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "domain_suffix": [ "example.org" ],
      "ports": [ "8443" ]
    }
  ]
}
JSON

plain_subnets="$WORK_DIR/plain-subnets.txt"
cat >"$plain_subnets" <<'EOF_INPUT'
198.51.100.210
203.0.113.0/24
2001:db8::210
EOF_INPUT

: > "$NFT_LOG"
nft_ucode nft-add-subnet-file-for-section-fixture "$WORK_DIR/populate-fixture.json" inline_no_ports "$plain_subnets" PodkopPlusTable podkop_plus_subnets podkop_plus_ip_ports 5000
assert_contains "$NFT_LOG" $'nft\tadd\telement\tinet\tPodkopPlusTable\tpodkop_plus_rule_inline_no_ports_subnets\t{ 198.51.100.210,203.0.113.0/24 }' "plain subnet import without ports"
assert_contains "$NFT_LOG" $'nft\tadd\telement\tinet\tPodkopPlusTable\tpodkop_plus_rule_inline_no_ports_subnets6\t{ 2001:db8::210 }' "plain subnet6 import without ports"

: > "$NFT_LOG"
nft_ucode nft-add-subnet-file-for-section-fixture "$WORK_DIR/populate-fixture.json" ports_only "$plain_subnets" PodkopPlusTable podkop_plus_subnets podkop_plus_ip_ports 3
assert_contains "$NFT_LOG" $'198.51.100.210 . 53,198.51.100.210 . 853,198.51.100.210 . 5353' "plain subnet import scoped first chunk"
assert_contains "$NFT_LOG" $'203.0.113.0/24 . 53,203.0.113.0/24 . 853,203.0.113.0/24 . 5353' "plain subnet import scoped second chunk"
assert_contains "$NFT_LOG" $'2001:db8::210 . 53,2001:db8::210 . 853,2001:db8::210 . 5353' "plain subnet6 import scoped chunk"

json_ruleset="$WORK_DIR/subnets-ruleset.json"
cat >"$json_ruleset" <<'JSON'
{
  "version": 3,
  "rules": [
    { "ip_cidr": [ "198.51.100.220", "2001:db8::220" ] },
    { "ip_cidr": [ "198.51.100.221" ], "port": [ 443 ] },
    {
      "type": "logical",
      "mode": "and",
      "rules": [
        { "ip_cidr": [ "198.51.100.222" ] },
        { "port_range": [ "1000:1002" ] }
      ]
    }
  ]
}
JSON

: > "$NFT_LOG"
unscoped_json="$WORK_DIR/unscoped-json.txt"
scoped_json="$WORK_DIR/scoped-json.txt"
nft_ucode nft-add-json-ruleset-subnets-for-section-fixture "$WORK_DIR/populate-fixture.json" inline_no_ports "$json_ruleset" "fixture json" PodkopPlusTable podkop_plus_subnets podkop_plus_ip_ports "$unscoped_json" "$scoped_json" 5000
assert_contains "$NFT_LOG" $'nft\tadd\telement\tinet\tPodkopPlusTable\tpodkop_plus_rule_inline_no_ports_subnets\t{ 198.51.100.220 }' "json ruleset unscoped import"
assert_contains "$NFT_LOG" $'nft\tadd\telement\tinet\tPodkopPlusTable\tpodkop_plus_rule_inline_no_ports_subnets6\t{ 2001:db8::220 }' "json ruleset unscoped6 import"
assert_contains "$NFT_LOG" $'nft\tadd\telement\tinet\tPodkopPlusTable\tpodkop_plus_rule_inline_no_ports_ip_ports\t{ 198.51.100.221 . 443,198.51.100.222 . 1000-1002 }' "json ruleset own port filters"

: > "$NFT_LOG"
unscoped_json="$WORK_DIR/unscoped-json-ports.txt"
scoped_json="$WORK_DIR/scoped-json-ports.txt"
nft_ucode nft-add-json-ruleset-subnets-for-section-fixture "$WORK_DIR/populate-fixture.json" ports_only "$json_ruleset" "fixture json ports" PodkopPlusTable podkop_plus_subnets podkop_plus_ip_ports "$unscoped_json" "$scoped_json" 4
assert_contains "$NFT_LOG" $'198.51.100.220 . 53,198.51.100.220 . 5353,198.51.100.220 . 853' "json ruleset scoped import"
if grep -Fq '198.51.100.221' "$NFT_LOG" || grep -Fq '198.51.100.222' "$NFT_LOG"; then
  fail "json ruleset section ports should intersect rule-owned port filters"
fi

: > "$NFT_LOG"
nft_ucode nft-add-community-subnet-file-for-section-fixture "$WORK_DIR/populate-fixture.json" inline_no_ports discord "$plain_subnets" PodkopPlusTable podkop_plus_subnets podkop_plus_ip_ports podkop_plus_interfaces podkop_plus_discord_subnets 0x00100000 5000
assert_contains "$NFT_LOG" $'nft\tadd\telement\tinet\tPodkopPlusTable\tpodkop_plus_rule_inline_no_ports_subnets\t{ 198.51.100.210,203.0.113.0/24 }' "discord community subnet import"

: > "$NFT_LOG"
NFT_MANGLE_CHAIN_OUTPUT=$'iifname @podkop_plus_interfaces ip daddr @podkop_plus_discord_subnets udp dport { 19000-20000, 50000-65535 } meta mark set 0x00100000 counter\niifname @podkop_plus_interfaces ip6 daddr @podkop_plus_discord_subnets6 udp dport { 19000-20000, 50000-65535 } meta mark set 0x00100000 counter' \
  nft_ucode nft-add-community-subnet-file-for-section-fixture "$WORK_DIR/populate-fixture.json" inline_no_ports discord "$plain_subnets" PodkopPlusTable podkop_plus_subnets podkop_plus_ip_ports podkop_plus_interfaces podkop_plus_discord_subnets 0x00100000 5000
if grep -Fq $'nft\tadd\trule' "$NFT_LOG"; then
  fail "discord community existing rule should not insert"
fi

: > "$NFT_LOG"
nft_ucode nft-add-community-subnet-file-for-section-fixture "$WORK_DIR/populate-fixture.json" ports_only discord "$plain_subnets" PodkopPlusTable podkop_plus_subnets podkop_plus_ip_ports podkop_plus_interfaces podkop_plus_discord_subnets 0x00100000 3
if grep -Fq 'podkop_plus_discord_subnets' "$NFT_LOG"; then
  fail "discord community with section ports should not use the discord nft set"
fi
assert_contains "$NFT_LOG" $'198.51.100.210 . 53,198.51.100.210 . 853,198.51.100.210 . 5353' "discord community with ports uses scoped import"

: > "$NFT_LOG"
nft_ucode nft-populate-runtime-sets-fixture "$WORK_DIR/populate-fixture.json" 1 "deferred" PodkopPlusTable podkop_plus_subnets podkop_plus_ports podkop_plus_ip_ports podkop_plus_interfaces localv4 0x00100000
assert_contains "$NFT_LOG" $'198.51.100.1 . 80,198.51.100.1 . 443-444,203.0.113.0/24 . 80' "populate inline ip-port first chunk"
assert_contains "$NFT_LOG" $'203.0.113.0/24 . 443-444' "populate inline ip-port second chunk"
assert_contains "$NFT_LOG" $'nft\tadd\telement\tinet\tPodkopPlusTable\tpodkop_plus_rule_inline_ip_ports\t{ 198.51.100.1 . 80,198.51.100.1 . 443-444,203.0.113.0/24 . 80,203.0.113.0/24 . 443-444 }' "populate inline priority ip-port set"
assert_contains "$NFT_LOG" $'nft\tadd\telement\tinet\tPodkopPlusTable\tpodkop_plus_rule_inline_ip6_ports\t{ 2001:db8::1 . 80,2001:db8::1 . 443-444 }' "populate inline priority ip6-port set"
assert_contains "$NFT_LOG" $'nft\tadd\telement\tinet\tPodkopPlusTable\tpodkop_plus_rule_inline_no_ports_subnets\t{ 198.51.100.200 }' "populate inline ip without ports"
assert_contains "$NFT_LOG" $'nft\tadd\telement\tinet\tPodkopPlusTable\tpodkop_plus_rule_inline_no_ports_subnets6\t{ 2001:db8::200 }' "populate inline ip6 without ports"
assert_contains "$NFT_LOG" $'nft\tadd\telement\tinet\tPodkopPlusTable\tpodkop_plus_rule_ports_only_ports\t{ 53,853,5353 }' "populate ports-only set"
assert_contains "$NFT_LOG" $'nft\tinsert\trule\tinet\tPodkopPlusTable\tmangle\tiifname\t@podkop_plus_interfaces\tip\tsaddr\t192.168.1.20/32\tmeta\tl4proto\ttcp\tmeta\tmark\tset\t0x00100000\tcounter' "populate fully routed tcp"
assert_contains "$NFT_LOG" $'nft\tinsert\trule\tinet\tPodkopPlusTable\tmangle\tiifname\t@podkop_plus_interfaces\tip6\tsaddr\t2001:db8::20/128\tmeta\tl4proto\ttcp\tmeta\tmark\tset\t0x00100000\tcounter' "populate fully routed6 tcp"
if grep -Fq '192.0.2.1' "$NFT_LOG"; then
  fail "disabled section should not populate nft"
fi
if grep -Fq '192.0.2.2' "$NFT_LOG"; then
  fail "deferred section should not populate nft"
fi
if grep -Fq $'nft\tadd\telement\tinet\tPodkopPlusTable\tpodkop_plus_rule_ports_with_domain_ports\t{ 8443 }' "$NFT_LOG"; then
  fail "ports with destination matchers should not populate global port set"
fi
if [ "$(grep -F $'ip\tsaddr\t192.168.1.20/32' "$NFT_LOG" | wc -l | tr -d ' ')" != "3" ]; then
  fail "duplicate fully routed source should insert exactly one tcp/udp/local rule set"
fi

cat >"$WORK_DIR/signature-fixture.json" <<'JSON'
{
  "settings": {
    "source_network_interfaces": [ "br-lan", "tun0" ],
    "exclude_ntp": "1"
  },
  "section": [
    {
      ".name": "disabled",
      ".type": "section",
      "enabled": "0",
      "action": "proxy",
      "ip_cidr": [ "192.0.2.10" ],
      "ports": [ "1234" ],
      "community_lists": [ "discord" ]
    },
    {
      ".name": "text_rule",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "ip_cidr_text_mode": "1",
      "ip_cidr_text": "198.51.100.1\nbad-value\n203.0.113.0/24",
      "ip_cidr": [ "10.0.0.0/8" ],
      "ports": [ "443", "bad-value", "443" ],
      "ports_text": "80, 443-444\n0\n65536",
      "fully_routed_ips": [ "192.168.1.10/32" ],
      "community_lists": [ "geoblock", "meta", "telegram", "youtube", "discord" ],
      "remote_subnet_lists": [ "https://example.com/subnets.lst" ],
      "rule_set_with_subnets": [ "/tmp/local.json" ],
      "domain_ip_lists": [ "https://example.com/mixed.lst" ]
    },
    {
      ".name": "default_enabled",
      ".type": "section",
      "action": "proxy",
      "ip_cidr": [ "10.0.0.0/8", "192.0.2.1" ],
      "ports_text": "53 853",
      "community_lists": [ "youtube", "cloudflare", "roblox" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/signature-expected.txt" <<'EOF_EXPECTED'
[settings.source_network_interfaces]
br-lan tun0
[settings.exclude_ntp]
1
[rule.text_rule.action]
bypass
[rule.text_rule.ip_cidr]
198.51.100.1,203.0.113.0/24
[rule.text_rule.source_ip_cidr]

[rule.text_rule.ports]
443,80,443-444
[rule.text_rule.fully_routed_ips]
192.168.1.10/32
[rule.text_rule.community_subnet_lists]
meta telegram discord
[rule.text_rule.remote_subnet_lists]
https://example.com/subnets.lst
[rule.text_rule.rule_set_with_subnets]
/tmp/local.json
[rule.text_rule.domain_ip_lists]
https://example.com/mixed.lst
[rule.default_enabled.action]
proxy
[rule.default_enabled.ip_cidr]
10.0.0.0/8,192.0.2.1
[rule.default_enabled.source_ip_cidr]

[rule.default_enabled.ports]
53,853
[rule.default_enabled.fully_routed_ips]

[rule.default_enabled.community_subnet_lists]
cloudflare roblox
[rule.default_enabled.remote_subnet_lists]

[rule.default_enabled.rule_set_with_subnets]

[rule.default_enabled.domain_ip_lists]

EOF_EXPECTED
expected_signature="$(md5sum "$WORK_DIR/signature-expected.txt" | awk '{print $1}')"
assert_eq "$expected_signature" \
  "$(nft_ucode nft-runtime-signature-fixture "$WORK_DIR/signature-fixture.json")" \
  "nft runtime signature fixture"

cat >"$WORK_DIR/signature-uci.state" <<'EOF_UCI'
podkop-plus.settings=settings
podkop-plus.settings.source_network_interfaces=br-lan tun0
podkop-plus.settings.exclude_ntp=1
podkop-plus.disabled=section
podkop-plus.disabled.enabled=0
podkop-plus.disabled.ip_cidr=192.0.2.10
podkop-plus.enabled=section
podkop-plus.enabled.enabled=1
podkop-plus.enabled.action=bypass
podkop-plus.enabled.ip_cidr=10.0.0.0/8 192.0.2.1
podkop-plus.enabled.ports=443 bad-value
podkop-plus.enabled.ports_text=80 443-444 65536
podkop-plus.enabled.fully_routed_ips=192.168.1.10/32
podkop-plus.enabled.community_lists=geoblock meta telegram youtube discord
podkop-plus.enabled.remote_subnet_lists=https://example.com/subnets.lst
podkop-plus.enabled.rule_set_with_subnets=/tmp/local.json
podkop-plus.enabled.domain_ip_lists=https://example.com/mixed.lst
EOF_UCI
cat >"$WORK_DIR/signature-uci-expected.txt" <<'EOF_EXPECTED'
[settings.source_network_interfaces]
br-lan tun0
[settings.exclude_ntp]
1
[rule.enabled.action]
bypass
[rule.enabled.ip_cidr]
10.0.0.0/8,192.0.2.1
[rule.enabled.source_ip_cidr]

[rule.enabled.ports]
443,80,443-444
[rule.enabled.fully_routed_ips]
192.168.1.10/32
[rule.enabled.community_subnet_lists]
meta telegram discord
[rule.enabled.remote_subnet_lists]
https://example.com/subnets.lst
[rule.enabled.rule_set_with_subnets]
/tmp/local.json
[rule.enabled.domain_ip_lists]
https://example.com/mixed.lst
EOF_EXPECTED
expected_signature="$(md5sum "$WORK_DIR/signature-uci-expected.txt" | awk '{print $1}')"
assert_eq "$expected_signature" \
  "$(PODKOP_UCI_STATE_FILE="$WORK_DIR/signature-uci.state" nft_ucode nft-runtime-signature)" \
  "nft runtime signature from UCI state"

cat >"$WORK_DIR/signature-defaults-fixture.json" <<'JSON'
{}
JSON
cat >"$WORK_DIR/signature-defaults-expected.txt" <<'EOF_EXPECTED'
[settings.source_network_interfaces]
br-lan
[settings.exclude_ntp]
0
EOF_EXPECTED
expected_signature="$(md5sum "$WORK_DIR/signature-defaults-expected.txt" | awk '{print $1}')"
assert_eq "$expected_signature" \
  "$(nft_ucode nft-runtime-signature-fixture "$WORK_DIR/signature-defaults-fixture.json")" \
  "nft runtime signature defaults"

: > "$NFT_LOG"
nft_ucode nft-populate-runtime-sets-fixture "$WORK_DIR/populate-fixture.json" 0 "" PodkopPlusTable podkop_plus_subnets podkop_plus_ports podkop_plus_ip_ports podkop_plus_interfaces localv4 0x00100000
[ ! -s "$NFT_LOG" ] || fail "disabled nft population should not call nft"

: > "$NFT_LOG"
NFT_MANGLE_CHAIN_OUTPUT='ip saddr 192.168.1.20 meta l4proto tcp meta mark set 0x00100000 counter' \
  nft_ucode nft-populate-runtime-sets-fixture "$WORK_DIR/populate-fixture.json" 1 "disabled deferred inline inline_no_ports ports_only ports_with_domain" PodkopPlusTable podkop_plus_subnets podkop_plus_ports podkop_plus_ip_ports podkop_plus_interfaces localv4 0x00100000
if grep -Fq $'nft\tinsert\trule' "$NFT_LOG"; then
  fail "existing nft-normalized /32 fully routed source should not insert"
fi

printf 'NFT apply regression checks passed\n'
