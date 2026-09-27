#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELOAD_UC="$ROOT_DIR/nexroute/files/usr/lib/service/reload.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

base_args=(
  svc dns sb nft zq zr z2q z2r br list cron 1 "alpha beta"
  svc dns sb nft zq zr z2q z2r br list cron "alpha beta" 0
  0 0 0 0 0
)

write_plan() {
  local output="$1"
  shift
  ucode "$RELOAD_UC" plan "$@" >"$output"
}

plan_value() {
  local file="$1"
  local key="$2"

  awk -F '\t' -v key="$key" '
    $1 == key { print $2; found = 1; exit }
    END { if (!found) exit 1 }
  ' "$file"
}

assert_plan_value() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local actual

  actual="$(plan_value "$file" "$key")" ||
    fail "missing plan key $key"
  [ "$actual" = "$expected" ] ||
    fail "$key: expected '$expected', got '$actual'"
}

run_case() {
  local name="$1"
  local output="$WORK_DIR/$name.plan"
  shift
  write_plan "$output" "$@"
  printf '%s\n' "$output"
}

write_state() {
  local file="$1"
  local service_key="$2"
  local service_value="$3"
  local dnsmasq="$4"
  local sing_box="$5"
  local nft="$6"
  local zapret_queue="$7"
  local zapret_runtime="$8"
  local zapret2_queue="$9"
  local zapret2_runtime="${10}"
  local byedpi_runtime="${11}"
  local list="${12}"
  local cron="${13}"
  local urltest_sections="${14}"
  local dont_touch_dhcp="${15:-0}"
  local format="${16:-1}"

  {
    printf 'format=%s\n' "$format"
    printf '%s=%s\n' "$service_key" "$service_value"
    printf 'dnsmasq_signature=%s\n' "$dnsmasq"
    printf 'sing_box_signature=%s\n' "$sing_box"
    printf 'nft_signature=%s\n' "$nft"
    printf 'zapret_queue_signature=%s\n' "$zapret_queue"
    printf 'zapret_runtime_signature=%s\n' "$zapret_runtime"
    printf 'zapret2_queue_signature=%s\n' "$zapret2_queue"
    printf 'zapret2_runtime_signature=%s\n' "$zapret2_runtime"
    printf 'byedpi_runtime_signature=%s\n' "$byedpi_runtime"
    printf 'list_signature=%s\n' "$list"
    printf 'cron_signature=%s\n' "$cron"
    printf 'urltest_enabled_sections=%s\n' "$urltest_sections"
    printf 'dont_touch_dhcp=%s\n' "$dont_touch_dhcp"
  } >"$file"
}

run_state_case() {
  local name="$1"
  local output="$WORK_DIR/$name.plan"
  local previous="$2"
  local current="$3"
  shift 3

  ucode "$RELOAD_UC" plan-state-files "$previous" "$current" "$@" >"$output"
  printf '%s\n' "$output"
}

assert_state_plan_exit() {
  local expected="$1"
  local previous="$2"
  local current="$3"
  local actual
  shift 3

  set +e
  ucode "$RELOAD_UC" plan-state-files "$previous" "$current" "$@" >/dev/null 2>&1
  actual="$?"
  set -e
  [ "$actual" -eq "$expected" ] ||
    fail "plan-state-files: expected exit $expected, got $actual"
}

args=("${base_args[@]}")
plan="$(run_case unchanged "${args[@]}")"
assert_plan_value "$plan" has_work 0
assert_plan_value "$plan" changed_sing_box 0
assert_plan_value "$plan" urltest_new_enabled_sections ""

args=("${base_args[@]}")
args[24]="alpha beta gamma"
plan="$(run_case urltest_new_sections "${args[@]}")"
assert_plan_value "$plan" urltest_new_enabled_sections "gamma"

args=("${base_args[@]}")
args[11]=0
args[24]="alpha beta gamma"
plan="$(run_case urltest_unknown_previous "${args[@]}")"
assert_plan_value "$plan" urltest_new_enabled_sections ""

args=("${base_args[@]}")
args[15]=sb2
plan="$(run_case sing_box_changed "${args[@]}")"
assert_plan_value "$plan" changed_sing_box 1
assert_plan_value "$plan" needs_sing_box_reload 1
assert_plan_value "$plan" has_work 1

args=("${base_args[@]}")
args[17]=zq2
plan="$(run_case zapret_queue_changed "${args[@]}")"
assert_plan_value "$plan" changed_zapret_queue 1
assert_plan_value "$plan" needs_zapret_restart 1
assert_plan_value "$plan" needs_nft_rebuild 1
assert_plan_value "$plan" needs_sing_box_reload 1

args=("${base_args[@]}")
args[14]=dns2
plan="$(run_case dnsmasq_configure "${args[@]}")"
assert_plan_value "$plan" changed_dnsmasq 1
assert_plan_value "$plan" needs_dnsmasq_configure 1
assert_plan_value "$plan" needs_dnsmasq_restore 0

args=("${base_args[@]}")
args[14]=dns2
args[25]=1
args[27]=1
plan="$(run_case dnsmasq_restore "${args[@]}")"
assert_plan_value "$plan" needs_dnsmasq_configure 0
assert_plan_value "$plan" needs_dnsmasq_restore 1

args=("${base_args[@]}")
args[22]=list2
args[28]=1
plan="$(run_case list_update_sources "${args[@]}")"
assert_plan_value "$plan" changed_list 1
assert_plan_value "$plan" needs_list_update 1

args=("${base_args[@]}")
args[16]=nft2
args[29]=1
plan="$(run_case nft_list_sources "${args[@]}")"
assert_plan_value "$plan" needs_nft_rebuild 1
assert_plan_value "$plan" needs_list_update 1

args=("${base_args[@]}")
args[30]=1
plan="$(run_case cache_rebuild "${args[@]}")"
assert_plan_value "$plan" changed_sing_box 1
assert_plan_value "$plan" needs_sing_box_reload 1

args=("${base_args[@]}")
args[26]=1
plan="$(run_case forced_reload "${args[@]}")"
assert_plan_value "$plan" changed_sing_box 0
assert_plan_value "$plan" needs_sing_box_reload 1

previous_state="$WORK_DIR/previous.state"
current_state="$WORK_DIR/current.state"
write_state "$previous_state" service_trigger_signature svc dns sb nft zq zr z2q z2r br list cron "alpha beta" 0
write_state "$current_state" service_trigger_signature svc dns sb nft zq zr z2q z2r br list cron "alpha beta" 0
plan="$(run_state_case state_unchanged "$previous_state" "$current_state" 0 0 0 0 0)"
assert_plan_value "$plan" has_work 0
assert_plan_value "$plan" changed_sing_box 0

write_state "$current_state" service_trigger_signature svc dns sb nft zq zr z2q z2r br list cron "alpha beta gamma" 0
plan="$(run_state_case state_urltest_new "$previous_state" "$current_state" 0 0 0 0 0)"
assert_plan_value "$plan" urltest_new_enabled_sections "gamma"

write_state "$previous_state" restart_signature svc dns sb nft zq zr z2q z2r br list cron "alpha beta" 0
write_state "$current_state" service_trigger_signature svc dns sb2 nft zq zr z2q z2r br list cron "alpha beta" 0
plan="$(run_state_case state_legacy_restart_signature "$previous_state" "$current_state" 0 0 0 0 0)"
assert_plan_value "$plan" changed_service_triggers 0
assert_plan_value "$plan" changed_sing_box 1
assert_plan_value "$plan" needs_sing_box_reload 1

write_state "$previous_state" service_trigger_signature svc dns sb nft zq zr z2q z2r br list cron "alpha beta" 0 0
write_state "$current_state" service_trigger_signature svc dns sb nft zq zr z2q z2r br list cron "alpha beta" 0 1
assert_state_plan_exit 2 "$previous_state" "$current_state" 0 0 0 0 0

rm -f "$previous_state"
assert_state_plan_exit 2 "$previous_state" "$current_state" 0 0 0 0 0

printf 'service reload plan checks passed\n'
