#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
INITD_UC="$FORKOP_LIB/service/initd.uc"
STATE_UC="$FORKOP_LIB/service/state.uc"
INITD="$ROOT_DIR/forkop/files/etc/init.d/forkop"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

initd_ucode() {
  ucode -L "$FORKOP_LIB" "$INITD_UC" "$@"
}

config_file="$WORK_DIR/forkop"
guard_file="$WORK_DIR/internal-config-change"
sync_file="$WORK_DIR/service-triggers.sync"

printf '%s\n' "config-version=1" >"$config_file"
config_hash="$(md5sum "$config_file" | awk '{print $1}')"

printf '%s\n%s\n' 1000 "$config_hash" >"$guard_file"
initd_ucode initd-guard-matches-current-config "$guard_file" "$config_file" 1010 >/dev/null ||
  fail "valid internal config guard should match current config"
if initd_ucode initd-guard-matches-current-config "$guard_file" "$config_file" 1031 >/dev/null 2>&1; then
  fail "stale internal config guard should not match"
fi

printf '%s\n%s\n' 1000 "$config_hash" >"$guard_file"
initd_ucode initd-should-skip-internal-config-reload on_config_change "$guard_file" "$config_file" on_config_change 1010 >/dev/null ||
  fail "matching internal config guard should skip config-change reload"
[ ! -e "$guard_file" ] ||
  fail "matching internal config guard should be consumed"

printf '%s\n%s\n' 1000 "$config_hash" >"$guard_file"
if initd_ucode initd-should-skip-internal-config-reload manual "$guard_file" "$config_file" on_config_change 1010 >/dev/null 2>&1; then
  fail "manual reload should not be skipped by internal config guard"
fi
[ -e "$guard_file" ] ||
  fail "non-config-change reason should not consume internal config guard"

printf '%s\n%s\n' 1000 "bad-hash" >"$guard_file"
if initd_ucode initd-should-skip-internal-config-reload on_config_change "$guard_file" "$config_file" on_config_change 1010 >/dev/null 2>&1; then
  fail "mismatched internal config guard should not skip reload"
fi
[ ! -e "$guard_file" ] ||
  fail "mismatched internal config guard should be consumed"

printf '%s\n' 1 >"$sync_file"
initd_ucode initd-service-trigger-sync-requested "$sync_file" >/dev/null ||
  fail "service trigger sync marker should request sync"
[ ! -e "$sync_file" ] ||
  fail "service trigger sync marker should be consumed"

printf '%s\n' 0 >"$sync_file"
if initd_ucode initd-service-trigger-sync-requested "$sync_file" >/dev/null 2>&1; then
  fail "service trigger sync marker with value 0 should not request sync"
fi
[ ! -e "$sync_file" ] ||
  fail "service trigger sync marker value 0 should be consumed"

initd_ucode initd-should-ignore-config-change-reload on_config_change on_config_change 0 0 >/dev/null ||
  fail "disabled stopped service should ignore config-change reload"
if initd_ucode initd-should-ignore-config-change-reload manual on_config_change 0 0 >/dev/null 2>&1; then
  fail "manual reload should not be ignored"
fi
if initd_ucode initd-should-ignore-config-change-reload on_config_change on_config_change 1 0 >/dev/null 2>&1; then
  fail "running service should not ignore config-change reload"
fi
initd_ucode initd-should-ignore-config-change-reload on_config_change on_config_change 0 1 >/dev/null ||
  fail "stopped service should ignore config-change reload even when autostart is enabled"
initd_ucode initd-should-queue-config-change-reload on_config_change on_config_change 0 start >/dev/null ||
  fail "config-change reload during service start should be queued"
if initd_ucode initd-should-queue-config-change-reload on_config_change on_config_change 0 "" >/dev/null 2>&1; then
  fail "stopped service without active service action should not queue config-change reload"
fi
if initd_ucode initd-should-queue-config-change-reload on_config_change on_config_change 1 reload >/dev/null 2>&1; then
  fail "running service should not use stopped-service queue path"
fi

pending_file="$WORK_DIR/reload.pending"
if FORKOP_PENDING_RELOAD_FILE="$pending_file" \
  initd_ucode reload-begin-fixture on_config_change 123 0 1 start >/dev/null 2>&1; then
  fail "queued config-change reload should not run immediately while service is starting"
fi
[ -f "$pending_file" ] ||
  fail "config-change reload during service start should create pending reload"
grep -Fq 'reason=on_config_change' "$pending_file" ||
  fail "pending reload should preserve config-change reason"

rm -f "$pending_file"
if FORKOP_PENDING_RELOAD_FILE="$pending_file" \
  initd_ucode reload-begin-fixture pending 123 1 1 start >/dev/null 2>&1; then
  fail "pending reload should not run while another service action is active"
fi
[ -f "$pending_file" ] ||
  fail "pending reload should stay pending while another service action is active"
grep -Fq 'reason=pending' "$pending_file" ||
  fail "pending reload should preserve pending reason while delayed by active action"

start_retry_file="$WORK_DIR/start.retry"
if initd_ucode start-retry-pending "$start_retry_file" >/dev/null 2>&1; then
  fail "missing start retry marker should not be pending"
fi
initd_ucode mark-start-retry "$start_retry_file" start_failed >/dev/null ||
  fail "failed start should create WAN retry marker"
initd_ucode start-retry-pending "$start_retry_file" >/dev/null ||
  fail "created start retry marker should be pending"
grep -Fq 'reason=start_failed' "$start_retry_file" ||
  fail "start retry marker should preserve failure reason"
initd_ucode clear-start-retry "$start_retry_file"
if initd_ucode start-retry-pending "$start_retry_file" >/dev/null 2>&1; then
  fail "cleared start retry marker should not be pending"
fi

retry_pid_file="$WORK_DIR/start-retry.pid"
retry_call_file="$WORK_DIR/start-retry.called"
retry_service="$WORK_DIR/forkop-init"
cat >"$retry_service" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >>"$retry_call_file"
EOF
chmod +x "$retry_service"
FORKOP_SERVICE_INIT="$retry_service" \
  FORKOP_START_RETRY_PID_FILE="$retry_pid_file" \
  FORKOP_START_RETRY_DELAY_SECONDS=1 \
  initd_ucode schedule-start-retry >/dev/null ||
  fail "failed start should schedule an automatic retry"
[ -s "$retry_pid_file" ] ||
  fail "scheduled automatic retry should record its worker pid"
for _ in 1 2 3 4 5; do
  [ -s "$retry_call_file" ] && break
  sleep 1
done
grep -Fxq 'retry_start_on_wan_up' "$retry_call_file" ||
  fail "scheduled automatic retry should call the marker-gated retry action"
[ ! -e "$retry_pid_file" ] ||
  fail "automatic retry worker should clear its pid before retrying"

[ "$(initd_ucode retry-start-on-wan-up-action 1 1 1)" = "skip_running" ] ||
  fail "WAN retry should skip when runtime is already running"
[ "$(initd_ucode retry-start-on-wan-up-action 0 0 1)" = "skip_disabled" ] ||
  fail "WAN retry should skip when autostart is disabled"
[ "$(initd_ucode retry-start-on-wan-up-action 0 1 0)" = "skip_no_retry" ] ||
  fail "WAN retry should skip stopped service without failed-start marker"
[ "$(initd_ucode retry-start-on-wan-up-action 0 1 1)" = "restart" ] ||
  fail "WAN retry should restart only after a recorded failed start"

initd_ucode initd-should-restore-dnsmasq-on-start-fixture "" 0 >/dev/null ||
  fail "unclean shutdown should request dnsmasq restore on start"
if initd_ucode initd-should-restore-dnsmasq-on-start-fixture triggered 0 >/dev/null 2>&1; then
  fail "triggered start should not restore dnsmasq"
fi
if initd_ucode initd-should-restore-dnsmasq-on-start-fixture "" 1 >/dev/null 2>&1; then
  fail "clean shutdown should not restore dnsmasq"
fi

start_plan="$(initd_ucode start-plan-fixture "" 0 1 "wan vpn0" 123 1)"
case "$start_plan" in
  *"INITD_BIN_OK='1'"* ) ;;
  *) fail "start-plan must expose executable binary state" ;;
esac
if printf '%s\n' "$start_plan" | grep -Fq 'INITD_BADWAN_NETDEV'; then
  fail "start-plan must not emit the unused Bad WAN netdev plan"
fi

start_plan_triggered="$(initd_ucode start-plan-fixture triggered 0 1 "wan vpn0" 123 1)"
if printf '%s\n' "$start_plan_triggered" | grep -Fq 'INITD_BADWAN_NETDEV'; then
  fail "triggered start must not emit the unused Bad WAN netdev plan"
fi

cat >"$WORK_DIR/settings.json" <<'JSON'
{
  "settings": {
    "enable_badwan_interface_monitoring": "1",
    "badwan_monitored_interfaces": [ "wan", "vpn0", "wwan" ],
    "badwan_reload_delay": "3500"
  }
}
JSON
trigger_plan="$(initd_ucode trigger-plan-fixture "$WORK_DIR/settings.json")"
case "$trigger_plan" in
  *"delay	3500"* ) ;;
  *) fail "trigger-plan must emit Bad WAN reload delay" ;;
esac
case "$trigger_plan" in
  *"interface	interface.*.up	vpn0"* ) ;;
  *) fail "trigger-plan must include non-wan Bad WAN interface triggers" ;;
esac
case "$trigger_plan" in
  *"interface	interface.*.up	wan	"*"handle_wan_up"* ) ;;
  *) fail "trigger-plan must route WAN up through the Bad WAN-aware handler" ;;
esac

[ "$(initd_ucode wan-up-action 1 1 0 1)" = "reload" ] ||
  fail "monitored WAN up should reload a running service"
[ "$(initd_ucode wan-up-action 1 1 1 0)" = "skip_running" ] ||
  fail "unmonitored WAN up should not reload a running service"
[ "$(initd_ucode wan-up-action 0 1 1 1)" = "restart" ] ||
  fail "stopped monitored WAN up should keep failed-start retry"

for legacy in \
  service_trigger_sync_requested \
  current_config_hash \
  internal_config_guard_matches_current_config \
  should_skip_internal_config_reload \
  should_restore_dnsmasq_on_start; do
  if grep -Fq "$legacy" "$INITD"; then
    fail "init.d must not keep shell decision function $legacy"
  fi
done

grep -Fq 'service/initd.uc' "$INITD" ||
  fail "init.d must delegate init.d decisions to service/initd.uc"
grep -Fq 'start-service' "$INITD" ||
  fail "init.d must start through a complete ucode start entrypoint"
grep -Fq 'mode == "start-service"' "$INITD_UC" ||
  fail "service/initd.uc must expose the complete start entrypoint"
grep -Fq 'stop-service' "$INITD" ||
  fail "init.d must stop through a complete ucode stop entrypoint"
grep -Fq 'mode == "stop-service"' "$INITD_UC" ||
  fail "service/initd.uc must expose the complete stop entrypoint"
grep -Fq 'reload-service' "$INITD" ||
  fail "init.d must reload through a complete ucode reload entrypoint"
grep -Fq 'mode == "reload-service"' "$INITD_UC" ||
  fail "service/initd.uc must expose the complete reload entrypoint"
grep -Fq 'status-service' "$INITD" ||
  fail "init.d status must delegate to service/initd.uc"
grep -Fq 'mode == "status-service"' "$INITD_UC" ||
  fail "service/initd.uc must expose the complete status entrypoint"
grep -Fq 'retry-start-on-wan-up' "$INITD" ||
  fail "init.d WAN retry must delegate to service/initd.uc"
grep -Fq 'mode == "retry-start-on-wan-up"' "$INITD_UC" ||
  fail "service/initd.uc must expose the complete WAN retry entrypoint"
grep -Fq 'mode == "retry-start-on-wan-up-action"' "$INITD_UC" ||
  fail "service/initd.uc must expose the WAN retry decision fixture"
grep -Fq 'schedule_start_retry(START_RETRY_PID_FILE, START_RETRY_DELAY_SECONDS)' "$INITD_UC" ||
  fail "failed service start must schedule a retry even if WAN is already up"
grep -Fq 'start_retry_pending(START_RETRY_FILE)' "$INITD_UC" ||
  fail "WAN retry must be gated by a failed-start marker"
service_enabled_line="$(grep -nF 'function service_is_enabled()' "$INITD_UC" | head -n1 | cut -d: -f1)"
retry_start_line="$(grep -nF 'function retry_start_on_wan_up(' "$INITD_UC" | head -n1 | cut -d: -f1)"
[ -n "$service_enabled_line" ] && [ -n "$retry_start_line" ] && [ "$service_enabled_line" -lt "$retry_start_line" ] ||
  fail "service_is_enabled must be declared before retry_start_on_wan_up for ucode runtime calls"
grep -Fq 'trigger-plan' "$INITD" ||
  fail "init.d must get procd trigger plan from service/initd.uc"
grep -Fq 'handle_wan_up' "$INITD" ||
  fail "init.d must expose the Bad WAN-aware WAN-up handler"
if grep -Fq 'eval ' "$INITD"; then
  fail "init.d must not eval ucode-generated shell plans"
fi
if grep -Fq 'runtime_is_running' "$INITD"; then
  fail "init.d must not keep shell runtime status decisions"
fi
if grep -E -n 'FORKOP_(CONFIG_FILE|RELOAD_LOCK_DIR|RUNTIME_STATE_DIR|PENDING_RELOAD_FILE|SERVICE_TRIGGER_SYNC_FILE|INTERNAL_CONFIG_TRIGGER_GUARD|CONFIG_CHANGE_REASON|BIN|SERVICE_INIT)=' "$INITD" >/dev/null 2>&1; then
  fail "init.d must not pass internal orchestration paths through shell env"
fi
if grep -n -E 'require\("uci"\)\.cursor|uci -q|uci", "-q"' "$INITD_UC" >/dev/null 2>&1; then
  fail "service/initd.uc must use core.uci instead of direct UCI cursor/CLI access"
fi
if grep -E -n '(^|[[:space:]])config_(load|get|get_bool|set)[[:space:]]' "$INITD" >/dev/null 2>&1; then
  fail "init.d must not read UCI directly"
fi
if grep -Fq 'FORKOP_STATE_UC' "$INITD" || grep -Fq 'FORKOP_UI_UC' "$INITD" || grep -Fq 'FORKOP_STATUS_UC' "$INITD"; then
  fail "init.d must not orchestrate state/UI/status modules directly"
fi
if grep -Fq 'procd_set_param command "$FORKOP_BIN" start' "$INITD"; then
  fail "init.d must not hand the one-shot start operation to procd as a daemon"
fi
if grep -Fq 'initd-should-' "$STATE_UC"; then
  fail "service/state.uc must not keep init.d decision owner modes"
fi

printf 'init.d state checks passed\n'
