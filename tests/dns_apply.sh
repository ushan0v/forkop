#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="$ROOT_DIR/nexroute/files/usr/lib/dns/apply.uc"
UCODE_LIB="$ROOT_DIR/nexroute/files/usr/lib"
WORK_DIR="$(mktemp -d)"
STATE="$WORK_DIR/uci.state"
LOG="$WORK_DIR/uci.log"
DNSMASQ_LOG="$WORK_DIR/dnsmasq.log"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'UCI state:\n' >&2
  cat "$STATE" >&2 2>/dev/null || true
  printf 'UCI log:\n' >&2
  cat "$LOG" >&2 2>/dev/null || true
  exit 1
}

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/uci" <<'UCI'
#!/usr/bin/env bash
set -eo pipefail

while [ "${1:-}" = "-q" ]; do
  shift
done

cmd="${1:-}"
shift || true

state="${UCI_STATE:?}"
log="${UCI_LOG:?}"

get_value() {
  awk -F= -v key="$1" '$1 == key { print substr($0, length($1) + 2); found = 1 } END { exit found ? 0 : 1 }' "$state"
}

key_exists() {
  awk -F= -v key="$1" -v prefix="$1." '$1 == key || index($1, prefix) == 1 { found = 1 } END { exit found ? 0 : 1 }' "$state"
}

delete_key() {
  local key="$1"
  local tmp
  tmp="$(mktemp)"
  awk -F= -v key="$key" -v prefix="$key." '$1 != key && index($1, prefix) != 1' "$state" > "$tmp"
  mv "$tmp" "$state"
}

set_key() {
  local key="$1"
  local value="$2"
  delete_key "$key"
  printf '%s=%s\n' "$key" "$value" >> "$state"
}

case "$cmd" in
  get)
    get_value "$1"
    ;;
  show)
    key_exists "$1"
    ;;
  delete)
    delete_key "$1"
    ;;
  set)
    item="$1"
    set_key "${item%%=*}" "${item#*=}"
    ;;
  add_list)
    item="$1"
    key="${item%%=*}"
    value="${item#*=}"
    current="$(get_value "$key" 2>/dev/null || true)"
    if [ -n "$current" ]; then
      set_key "$key" "$current $value"
    else
      set_key "$key" "$value"
    fi
    ;;
  del_list)
    item="$1"
    key="${item%%=*}"
    value="${item#*=}"
    current="$(get_value "$key" 2>/dev/null || true)"
    [ -n "$current" ] || exit 1
    new=""
    removed=0
    for entry in $current; do
      if [ "$entry" = "$value" ]; then
        removed=1
        continue
      fi
      new="${new:+$new }$entry"
    done
    [ "$removed" -eq 1 ] || exit 1
    if [ -n "$new" ]; then
      set_key "$key" "$new"
    else
      delete_key "$key"
    fi
    ;;
  commit)
    printf 'commit %s\n' "$1" >> "$log"
    ;;
  *)
    printf 'unsupported uci command: %s\n' "$cmd" >&2
    exit 2
    ;;
esac
UCI
chmod 0755 "$WORK_DIR/bin/uci"

cat >"$WORK_DIR/dnsmasq-init" <<'DNSMASQ'
#!/usr/bin/env bash
set -eo pipefail
printf '%s\n' "$*" >> "${DNSMASQ_LOG:?}"
DNSMASQ
chmod 0755 "$WORK_DIR/dnsmasq-init"

export PATH="$WORK_DIR/bin:$PATH"
export UCI_STATE="$STATE"
export UCI_LOG="$LOG"
export DNSMASQ_LOG
export DNSMASQ_INIT="$WORK_DIR/dnsmasq-init"
export NEXROUTE_CONFIG_NAME="nexroute"
export SB_DNS_INBOUND_ADDRESS="127.0.0.42"

if grep -E 'uci -q|command -v uci' "$APPLY" >/dev/null; then
  fail "dns/apply.uc must use ucode UCI access instead of shelling out to uci"
fi

run_restore() {
  : > "$LOG"
  ucode -L "$UCODE_LIB" "$APPLY" failsafe-restore
}

uci_get() {
  "$WORK_DIR/bin/uci" -q get "$1"
}

assert_value() {
  local path="$1"
  local expected="$2"
  local actual

  actual="$(uci_get "$path" 2>/dev/null || true)"
  [ "$actual" = "$expected" ] || fail "$path: expected '$expected', got '$actual'"
}

assert_absent() {
  local path="$1"

  if uci_get "$path" >/dev/null 2>&1; then
    fail "$path: expected option to be absent"
  fi
}

assert_log_contains() {
  local expected="$1"

  grep -Fxq "$expected" "$LOG" || fail "expected log entry '$expected'"
}

assert_log_empty() {
  [ ! -s "$LOG" ] || fail "expected empty log"
}

assert_dnsmasq_restarted() {
  grep -Fxq 'restart' "$DNSMASQ_LOG" || fail "expected dnsmasq restart"
}

cat >"$STATE" <<'EOF_STATE'
dhcp.@dnsmasq[0].server=1.1.1.1 8.8.8.8
dhcp.@dnsmasq[0].noresolv=0
dhcp.@dnsmasq[0].cachesize=150
nexroute.settings.shutdown_correctly=1
EOF_STATE

: > "$DNSMASQ_LOG"
: > "$LOG"
ucode -L "$UCODE_LIB" "$APPLY" configure force
assert_value 'dhcp.@dnsmasq[0].server' '127.0.0.42'
assert_value 'dhcp.@dnsmasq[0].nexroute_server' '1.1.1.1 8.8.8.8'
assert_value 'dhcp.@dnsmasq[0].noresolv' '1'
assert_value 'dhcp.@dnsmasq[0].nexroute_noresolv' '0'
assert_value 'dhcp.@dnsmasq[0].cachesize' '0'
assert_value 'dhcp.@dnsmasq[0].nexroute_cachesize' '150'
assert_log_contains 'commit dhcp'
assert_dnsmasq_restarted

: > "$DNSMASQ_LOG"
: > "$LOG"
ucode -L "$UCODE_LIB" "$APPLY" restore force
assert_value 'dhcp.@dnsmasq[0].server' '1.1.1.1 8.8.8.8'
assert_value 'dhcp.@dnsmasq[0].noresolv' '0'
assert_value 'dhcp.@dnsmasq[0].cachesize' '150'
assert_absent 'dhcp.@dnsmasq[0].nexroute_server'
assert_absent 'dhcp.@dnsmasq[0].nexroute_noresolv'
assert_absent 'dhcp.@dnsmasq[0].nexroute_cachesize'
assert_log_contains 'commit dhcp'
assert_dnsmasq_restarted

cat >"$STATE" <<'EOF_STATE'
dhcp.@dnsmasq[0].server=127.0.0.42
dhcp.@dnsmasq[0].notinterface=br-lan guest
dhcp.@dnsmasq[0].nexroute_server=1.1.1.1 8.8.8.8
dhcp.@dnsmasq[0].nexroute_notinterface=wan docker
dhcp.@dnsmasq[0].nexroute_noresolv=1
dhcp.@dnsmasq[0].nexroute_cachesize=0
dhcp.nexroute.interface=br-lan guest
nexroute.settings.dont_touch_dhcp=1
EOF_STATE

run_restore
assert_value 'dhcp.@dnsmasq[0].server' '1.1.1.1 8.8.8.8'
assert_value 'dhcp.@dnsmasq[0].notinterface' 'wan docker'
assert_value 'dhcp.@dnsmasq[0].noresolv' '1'
assert_value 'dhcp.@dnsmasq[0].cachesize' '0'
assert_absent 'dhcp.@dnsmasq[0].nexroute_server'
assert_absent 'dhcp.@dnsmasq[0].nexroute_notinterface'
assert_absent 'dhcp.@dnsmasq[0].nexroute_noresolv'
assert_absent 'dhcp.@dnsmasq[0].nexroute_cachesize'
assert_absent 'dhcp.nexroute.interface'
assert_log_contains 'commit dhcp'

cat >"$STATE" <<'EOF_STATE'
dhcp.@dnsmasq[0].server=9.9.9.9
nexroute.settings.dont_touch_dhcp=1
EOF_STATE

run_restore
assert_value 'dhcp.@dnsmasq[0].server' '9.9.9.9'
assert_log_empty

cat >"$STATE" <<'EOF_STATE'
dhcp.@dnsmasq[0].server=127.0.0.42
dhcp.@dnsmasq[0].nexroute_noresolv=1
dhcp.@dnsmasq[0].nexroute_cachesize=0
nexroute.settings.dont_touch_dhcp=0
EOF_STATE

run_restore
assert_absent 'dhcp.@dnsmasq[0].server'
assert_value 'dhcp.@dnsmasq[0].noresolv' '1'
assert_value 'dhcp.@dnsmasq[0].cachesize' '0'
assert_absent 'dhcp.@dnsmasq[0].nexroute_noresolv'
assert_absent 'dhcp.@dnsmasq[0].nexroute_cachesize'
assert_log_contains 'commit dhcp'

printf 'DNS apply checks passed\n'
