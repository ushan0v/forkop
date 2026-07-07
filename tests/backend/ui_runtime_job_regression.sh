#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UI_UC="$ROOT_DIR/podkop/files/usr/lib/service/ui.uc"
PODKOP_FILES="$ROOT_DIR/podkop/files"
PODKOP_BIN="$PODKOP_FILES/usr/bin/podkop"
PODKOP_INIT="$PODKOP_FILES/etc/init.d/podkop"
UI_RUNTIME_SH="$PODKOP_FILES/usr/lib/ui_runtime.sh"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

ui_ucode() {
  ucode -L "$PODKOP_FILES/usr/lib" "$UI_UC" "$@"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

write_state() {
  local name="$1"
  local content="$2"

  printf '%s\n' "$content" >"$WORK_DIR/$name.json"
  printf '%s\n' "$WORK_DIR/$name.json"
}

[ ! -e "$UI_RUNTIME_SH" ] ||
  fail "ui_runtime.sh shell owner must be removed"

if grep -R -n "ui_runtime.sh" "$PODKOP_FILES" >/dev/null 2>&1; then
  fail "runtime files must not reference ui_runtime.sh"
fi

ui_runtime_shell_symbols='ui_runtime_|podkop_fast_get_ui_state|PODKOP_UI_RUNTIME|load_ui_runtime'
if grep -R -n -E "$ui_runtime_shell_symbols" "$PODKOP_BIN" "$PODKOP_INIT" "$PODKOP_FILES/usr/lib" --include='*.sh' >/dev/null 2>&1; then
  fail "ui_runtime shell symbols must not remain in runtime shell"
fi

if grep -R -n '^get_ui_capabilities()' "$PODKOP_FILES/usr/lib" --include='*.sh' >/dev/null 2>&1; then
  fail "UI capabilities must be owned by service/ui.uc, not shell"
fi
grep -Fq 'require("core.uci")' "$UI_UC" ||
  fail "service/ui.uc must use core.uci for UI UCI-derived state"
if grep -n -E 'require\("uci"\)\.cursor|uci -q|uci", "-q"' "$UI_UC" >/dev/null 2>&1; then
  fail "service/ui.uc must not own direct UCI cursor or CLI reads"
fi
grep -Fq '"podkop-stably-running"' "$UI_UC" ||
  fail "UI Podkop status must use stable runtime state to avoid crash-loop flicker"
grep -Fq '"sing-box-service-stable"' "$UI_UC" ||
  fail "UI sing-box status must use stable runtime state to avoid crash-loop flicker"
grep -Fq 'run_pending_reload_after_service_action(action, success)' "$UI_UC" ||
  fail "UI service actions must run pending reload after the current action finishes"
grep -Fq 'service_action_wait_for_expected_state(action, SERVICE_ACTION_TIMEOUT_SECONDS, SERVICE_ACTION_SETTLE_SECONDS)' "$UI_UC" ||
  fail "UI service action worker must keep action state until the expected service state is stable"
grep -Fq 'let args = [ SERVICE_INIT, action ];' "$UI_UC" ||
  fail "UI service action worker must use init.d so procd triggers stay registered"
grep -Fq 'start_service_action("reload", "initd", "pending")' "$UI_UC" ||
  fail "pending reload must enter the normal reload service action immediately"
if grep -n -E 'pgrep.*sing-box|service-list-instance-running' "$UI_UC" >/dev/null 2>&1; then
  fail "service/ui.uc must not use transient sing-box process probes for visible status"
fi

for mode in \
  get-ui-capabilities \
  get-ui-state \
  component-action-running-for \
  service-action-begin-if-idle \
  service-action-update-pid \
  service-action-finish-after-command \
  latency-progress-state \
  service-action-async \
  service-action-status \
  latency-test-async \
  latency-test-status \
  action-ack; do
  grep -Fq "\"$mode\"" "$UI_UC" ||
    fail "service/ui.uc must expose $mode"
done

assert_eq "/tmp/ui/job-1.json" \
  "$(ui_ucode job-state-path /tmp/ui job-1)" \
  "valid UI job path"

if ui_ucode job-state-path /tmp/ui '../bad' >/dev/null 2>&1; then
  fail "invalid UI job id should be rejected"
fi

ui_ucode service-action-valid restart >/dev/null ||
  fail "restart service action should be valid"
if ui_ucode service-action-valid invalid >/dev/null 2>&1; then
  fail "invalid service action should be rejected"
fi
assert_eq "1" \
  "$(ui_ucode service-action-expected-running start)" \
  "start expects running service"
assert_eq "1" \
  "$(ui_ucode service-action-expected-running reload)" \
  "reload expects running service"
assert_eq "0" \
  "$(ui_ucode service-action-expected-running stop)" \
  "stop expects stopped service"
if ui_ucode service-action-expected-running invalid >/dev/null 2>&1; then
  fail "invalid service action expected state should be rejected"
fi
ui_ucode latency-type-valid proxy_list >/dev/null ||
  fail "proxy_list latency type should be valid"
if ui_ucode latency-type-valid invalid >/dev/null 2>&1; then
  fail "invalid latency type should be rejected"
fi

latency_action_dir="$WORK_DIR/latency-actions"
mkdir -p "$latency_action_dir"
latency_state="$latency_action_dir/latency-1.json"
printf '%s\n' '{"success":true,"running":true,"kind":"latency","latency_type":"proxy_list","section":"main","tag":"[]","started_at":100}' >"$latency_state"
PODKOP_UI_LATENCY_ACTION_DIR="$latency_action_dir" \
  ui_ucode latency-progress-state "$latency_state" 2 5 1 >/dev/null ||
  fail "latency-progress-state should update running latency jobs"
JOB_STATE="$latency_state" node - <<'NODE'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.env.JOB_STATE, "utf8"));
if (!value.progress || value.progress.completed !== 2 || value.progress.total !== 5 || value.progress.failed !== 1) {
  console.error("latency progress state mismatch");
  process.exit(1);
}
NODE

assert_eq "running & enabled" \
  "$(ui_ucode service-status-text 1 1)" \
  "running enabled status"
assert_eq "running but disabled" \
  "$(ui_ucode service-status-text 1 0)" \
  "running disabled status"
assert_eq "stopped but enabled" \
  "$(ui_ucode service-status-text 0 1)" \
  "stopped enabled status"
assert_eq "stopped & disabled" \
  "$(ui_ucode service-status-text 0 0)" \
  "stopped disabled status"

running="$(write_state running '{"running":true,"pid":"456","started_at":100}')"
assert_eq "$(printf 'pid\t456\t0')" \
  "$(ui_ucode job-refresh-plan "$running" 105 15)" \
  "running UI job within grace"
assert_eq "$(printf 'pid\t456\t1')" \
  "$(ui_ucode job-refresh-plan "$running" 120 15)" \
  "running UI job after grace"

invalid_pid="$(write_state invalid-pid '{"running":true,"pid":"","started_at":100}')"
assert_eq "skip" \
  "$(ui_ucode job-refresh-plan "$invalid_pid" 105 15)" \
  "invalid UI pid within grace"
assert_eq "stale" \
  "$(ui_ucode job-refresh-plan "$invalid_pid" 120 15)" \
  "invalid UI pid after grace"

finished="$(write_state finished '{"running":false,"pid":"456","started_at":100}')"
assert_eq "skip" \
  "$(ui_ucode job-refresh-plan "$finished" 120 15)" \
  "finished UI job refresh"

stale_json="$(ui_ucode stale-action-state "$invalid_pid" "worker exited" 200)"
JSON_VALUE="$stale_json" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.running !== false || value.success !== false || value.message !== "worker exited") {
  console.error("UI stale state shape mismatch");
  process.exit(1);
}
NODE

acked="$(write_state acked '{"running":false,"acked_at":100}')"
ui_ucode action-ack-expired "$acked" 200 90 >/dev/null ||
  fail "acked state should be expired"
if ui_ucode action-ack-expired "$acked" 150 90 >/dev/null 2>&1; then
  fail "acked state should not expire before TTL"
fi

bad_ack="$(write_state bad-ack '{"running":false,"acked_at":"invalid"}')"
if ui_ucode action-ack-expired "$bad_ack" 200 90 >/dev/null 2>&1; then
  fail "invalid ack timestamp should not expire"
fi

cleanup_dir="$WORK_DIR/cleanup-actions"
mkdir -p "$cleanup_dir"
printf '%s\n' '{"running":false,"acked_at":1}' >"$cleanup_dir/done.json"
printf 'stdout\n' >"$cleanup_dir/done.out"
printf '{}\n' >"$cleanup_dir/done.out.json"
ui_ucode cleanup-action-dir-fixture "$cleanup_dir"
[ ! -e "$cleanup_dir/done.json" ] ||
  fail "expired acknowledged action state should be cleaned"
[ ! -e "$cleanup_dir/done.out" ] ||
  fail "expired acknowledged action stdout sidecar should be cleaned"
[ ! -e "$cleanup_dir/done.out.json" ] ||
  fail "expired acknowledged action JSON sidecar should be cleaned"

export PODKOP_UI_STATE_DIR="$WORK_DIR/ui-state"
export PODKOP_UI_SERVICE_ACTION_DIR="$PODKOP_UI_STATE_DIR/service-actions"
export PODKOP_UI_SERVICE_ACTION_LOCK_DIR="$PODKOP_UI_STATE_DIR/service-actions.lock"
export PODKOP_UI_LATENCY_ACTION_DIR="$PODKOP_UI_STATE_DIR/latency-actions"
export PODKOP_UI_COMPONENT_ACTION_DIR="$PODKOP_UI_STATE_DIR/component-actions"
export PODKOP_UI_SUBSCRIPTION_ACTION_DIR="$PODKOP_UI_STATE_DIR/subscription-actions"

latency_start="$(
  PODKOP_BIN=/bin/true \
  PODKOP_LIB="$PODKOP_FILES/usr/lib" \
    ui_ucode latency-test-async proxy_list main '["proxy-a","proxy-b"]' 5000
)"
latency_job_id="$(printf '%s' "$latency_start" | sed -n 's/.*"job_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
[ -n "$latency_job_id" ] || fail "latency-test-async should return a job id"
latency_async_state="$PODKOP_UI_LATENCY_ACTION_DIR/$latency_job_id.json"
[ -f "$latency_async_state" ] || fail "latency-test-async should create a state file"
JOB_STATE="$latency_async_state" node - <<'NODE'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.env.JOB_STATE, "utf8"));
if (!value.progress || value.progress.completed !== 0 || value.progress.total !== 2 || value.progress.failed !== 0) {
  console.error("initial latency progress state mismatch");
  process.exit(1);
}
NODE

job_id="$(ui_ucode service-action-begin-if-idle reload test)"
[ -n "$job_id" ] || fail "service-action-begin-if-idle should create a job"
service_state="$PODKOP_UI_SERVICE_ACTION_DIR/$job_id.json"
[ -f "$service_state" ] || fail "service action state file should be created"
assert_eq "reload" \
  "$(ui_ucode active-service-action)" \
  "active-service-action should use the default service action dir"

if ui_ucode service-action-begin-if-idle restart test >/dev/null 2>&1; then
  fail "second service action should be rejected while first is running"
fi

ui_ucode service-action-update-pid "$job_id" "$$" >/dev/null ||
  fail "service-action-update-pid should update running job"

PODKOP_UI_SERVICE_ACTION_TIMEOUT_SECONDS=1 \
PODKOP_UI_SERVICE_ACTION_SETTLE_SECONDS=0 \
PODKOP_SERVICE_INIT=/bin/true \
PODKOP_BIN=/bin/true \
PODKOP_LIB="$PODKOP_FILES/usr/lib" \
  ui_ucode service-action-finish-after-command reload "$job_id" 0 >/dev/null ||
  fail "service-action-finish-after-command should spawn waiter without ucode declaration-order failure"

sleep 2
if grep -q '"running"[[:space:]]*:[[:space:]]*true' "$service_state"; then
  fail "service-action-finish-after-command waiter should finish the running service action"
fi

ui_ucode service-action-finish "$job_id" true done 0 >/dev/null ||
  fail "service-action-finish should finish running job"

JOB_STATE="$service_state" node - <<'NODE'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.env.JOB_STATE, "utf8"));
if (value.running !== false || value.success !== true || value.message !== "done" || value.exit_code !== 0) {
  console.error("finished service action state mismatch");
  process.exit(1);
}
NODE

component_job="$PODKOP_UI_COMPONENT_ACTION_DIR/component-1.json"
mkdir -p "$PODKOP_UI_COMPONENT_ACTION_DIR"
printf '%s\n' '{"running":true,"component":"sing_box","started_at":100}' >"$component_job"
ui_ucode component-action-running-for sing_box >/dev/null ||
  fail "component-action-running-for should detect running sing-box component action"
if ui_ucode component-action-running-for zapret >/dev/null 2>&1; then
  fail "component-action-running-for should ignore other components"
fi

ui_ucode action-ack service "$job_id" >/dev/null ||
  fail "action-ack should acknowledge finished service action"

printf 'UI runtime job regression checks passed\n'
