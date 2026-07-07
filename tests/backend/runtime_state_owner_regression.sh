#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_BIN="$ROOT_DIR/podkop/files/usr/bin/podkop"
PODKOP_INIT="$ROOT_DIR/podkop/files/etc/init.d/podkop"
CLI_UC="$PODKOP_BIN"
RUNTIME_STATE="$ROOT_DIR/podkop/files/usr/lib/runtime_state.sh"
UPDATES_RUNTIME="$ROOT_DIR/podkop/files/usr/lib/updates_runtime.sh"
LIFECYCLE_UC="$ROOT_DIR/podkop/files/usr/lib/service/lifecycle.uc"
UPDATES_UC="$ROOT_DIR/podkop/files/usr/lib/components/updates.uc"
STATE_UC="$ROOT_DIR/podkop/files/usr/lib/service/state.uc"
NFT_UC="$ROOT_DIR/podkop/files/usr/lib/nft/apply.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ ! -e "$RUNTIME_STATE" ] ||
  fail "runtime_state.sh shell owner must be removed"
[ ! -e "$UPDATES_RUNTIME" ] ||
  fail "updates_runtime.sh shell owner must be removed"

grep -Fq 'runtime_state.sh' "$PODKOP_BIN" &&
  fail "podkop must not source runtime_state.sh"

service_predicates='process_age_seconds|sing_box_service_pid|pid_is_sing_box|sing_box_service_is_running|sing_box_service_is_stable|podkop_runtime_network_is_configured|podkop_is_running|podkop_is_stably_running|wait_for_podkop_stable_start'
if grep -R -n -E "$service_predicates" "$PODKOP_BIN" "$ROOT_DIR/podkop/files/usr/lib" --include='*.sh' >/dev/null 2>&1; then
  fail "service running/stability predicates must not remain in shell"
fi

pending_state='mark_pending_reload|consume_pending_reload|run_pending_reload_if_requested|sync_time_if_needed'
if grep -R -n -E "$pending_state" "$PODKOP_BIN" "$PODKOP_INIT" "$ROOT_DIR/podkop/files/usr/lib" --include='*.sh' >/dev/null 2>&1; then
  fail "pending reload/time-sync ownership must not remain in shell"
fi

runtime_state_shell_symbols='runtime_state_ucode|acquire_runtime_dir_lock|release_runtime_dir_lock|capture_reload_state|write_reload_state_file|write_reload_state|clear_reload_state|populate_nft_runtime_sets|rebuild_nft_runtime|reload_sing_box_runtime|apply_pending_urltest_selector_switches|close_inherited_service_lock_fd|PODKOP_URLTEST_SELECTOR_SWITCHES'
if grep -R -n -E "$runtime_state_shell_symbols" "$PODKOP_BIN" "$PODKOP_INIT" "$ROOT_DIR/podkop/files/usr/lib" --include='*.sh' >/dev/null 2>&1; then
  fail "runtime_state.sh symbols must not remain in shell"
fi

if grep -Fq 'acquire_reload_lock' "$PODKOP_INIT" || grep -Fq 'release_reload_lock' "$PODKOP_INIT"; then
  fail "init.d must not own reload lock decisions"
fi

grep -Fq '#!/usr/bin/ucode' "$PODKOP_BIN" ||
  fail "podkop entrypoint must be a direct ucode executable"
grep -Fq 'service/lifecycle.uc' "$CLI_UC" ||
  fail "service/cli.uc must dispatch lifecycle orchestration through service/lifecycle.uc"
grep -Fq 'refresh-cron-from-uci' "$LIFECYCLE_UC" ||
  fail "service/lifecycle.uc start/reload must call the ucode cron refresh operation"
grep -Fq 'remove-cron-jobs' "$LIFECYCLE_UC" ||
  fail "service/lifecycle.uc stop must call the ucode cron removal operation"
grep -Fq '"list-update"' "$LIFECYCLE_UC" ||
  fail "service/lifecycle.uc start/reload must run list updates through components/updates.uc"
grep -Fq 'subscription_update: [ "components/updates.uc", "subscription-update", 2 ]' "$CLI_UC" ||
  fail "service/cli.uc must run subscription updates through components/updates.uc"
if grep -R -n -F 'updates_runtime.sh' "$PODKOP_BIN" "$ROOT_DIR/podkop/files/usr/lib" --include='*.sh' >/dev/null 2>&1; then
  fail "runtime shell must not reference updates_runtime.sh"
fi
grep -Fq 'mode == "refresh-cron-from-uci"' "$UPDATES_UC" ||
  fail "components/updates.uc must own cron refresh"
grep -Fq 'mode == "remove-cron-jobs"' "$UPDATES_UC" ||
  fail "components/updates.uc must own cron removal"
grep -Fq 'mode == "list-update"' "$UPDATES_UC" ||
  fail "components/updates.uc must own list update"
grep -Fq 'mode == "subscription-update"' "$UPDATES_UC" ||
  fail "components/updates.uc must own subscription update"
grep -Fq 'mode == "podkop-running"' "$STATE_UC" ||
  fail "service/state.uc must own Podkop running predicate"
grep -Fq 'mode == "sing-box-service-stable"' "$STATE_UC" ||
  fail "service/state.uc must expose stable sing-box predicate"
grep -Fq 'mode == "wait-podkop-stable-start"' "$STATE_UC" ||
  fail "service/state.uc must own stable-start waiting"
grep -Fq 'mode == "mark-pending-reload"' "$STATE_UC" ||
  fail "service/state.uc must own pending reload writes"
grep -Fq 'mode == "sync-time-if-needed"' "$STATE_UC" ||
  fail "service/state.uc must own time-sync decisions"
grep -Fq 'mode == "acquire-runtime-dir-lock"' "$STATE_UC" ||
  fail "service/state.uc must own runtime lock acquisition"
grep -Fq 'mode == "write-captured-reload-state"' "$STATE_UC" ||
  fail "service/state.uc must own captured reload state writes"
grep -Fq 'mode == "reload-sing-box-runtime"' "$STATE_UC" ||
  fail "service/state.uc must own sing-box runtime reload"
grep -Fq '"wait-podkop-stable-start"' "$LIFECYCLE_UC" ||
  fail "service/lifecycle.uc must verify stable runtime after sing-box start/reload"
grep -Fq 'SING_BOX_START_STABLE_MIN_AGE' "$LIFECYCLE_UC" ||
  fail "service/lifecycle.uc must use a dedicated sing-box start stability window"
sing_box_start_line="$(grep -nF 'command_success_from_args([ "/etc/init.d/sing-box", "start" ])' "$LIFECYCLE_UC" | head -n1 | cut -d: -f1)"
early_stable_line="$(awk -v start="$sing_box_start_line" 'NR > start && /"wait-podkop-stable-start"/ { print NR; exit }' "$LIFECYCLE_UC")"
start_stable_min_age_line="$(awk -v start="$sing_box_start_line" 'NR > start && /SING_BOX_START_STABLE_MIN_AGE/ { print NR; exit }' "$LIFECYCLE_UC")"
deferred_bootstrap_line="$(grep -nF '"run-deferred-bootstrap"' "$LIFECYCLE_UC" | head -n1 | cut -d: -f1)"
[ -n "$sing_box_start_line" ] ||
  fail "service/lifecycle.uc must start sing-box through init.d"
[ -n "$early_stable_line" ] ||
  fail "service/lifecycle.uc must verify stable runtime immediately after sing-box start"
[ "$early_stable_line" -lt "$deferred_bootstrap_line" ] ||
  fail "service/lifecycle.uc must verify sing-box stability before deferred bootstrap work"
[ -n "$start_stable_min_age_line" ] && [ "$start_stable_min_age_line" -lt "$deferred_bootstrap_line" ] ||
  fail "service/lifecycle.uc must use the dedicated sing-box start stability window before deferred bootstrap work"
sing_box_reload_line="$(grep -nF '"reload-sing-box-runtime"' "$LIFECYCLE_UC" | head -n1 | cut -d: -f1)"
reload_stable_min_age_line="$(awk -v start="$sing_box_reload_line" 'NR > start && /SING_BOX_START_STABLE_MIN_AGE/ { print NR; exit }' "$LIFECYCLE_UC")"
[ -n "$sing_box_reload_line" ] ||
  fail "service/lifecycle.uc must reload sing-box through service/state.uc"
[ -n "$reload_stable_min_age_line" ] ||
  fail "service/lifecycle.uc must use the dedicated sing-box start stability window after sing-box reload"
grep -Fq 'Reload verification failed after sing-box was reloaded; stopping Podkop Plus runtime' "$LIFECYCLE_UC" ||
  fail "service/lifecycle.uc must fail reload when sing-box does not stay stable"
grep -Fq 'Reload runtime restart verification failed after Podkop Plus was started; rolling back DNS changes' "$LIFECYCLE_UC" ||
  fail "service/lifecycle.uc must fail full runtime restart when sing-box does not stay stable"
if grep -n -E 'require\("uci"\)\.cursor|uci -q|uci", "-q"|uci_get_cli|uci_exists_cli|mwan3_has_enabled_interface_from_uci_show' "$STATE_UC" >/dev/null 2>&1; then
  fail "service/state.uc must not own direct UCI CLI/cursor access"
fi
grep -Fq 'nft-rebuild-runtime-from-uci' "$LIFECYCLE_UC" ||
  fail "service/lifecycle.uc reload must call nft rebuild through ucode"
if grep -Fq 'nft-create-full-runtime-from-uci' "$LIFECYCLE_UC"; then
  fail "podkop start/reload must rebuild nft runtime instead of appending to stale state"
fi
grep -Fq 'nft-populate-runtime-sets-from-uci' "$LIFECYCLE_UC" ||
  fail "service/lifecycle.uc reload must call nft populate through ucode"
grep -Fq 'mode == "nft-rebuild-runtime-from-uci"' "$NFT_UC" ||
  fail "nft/apply.uc must own nft runtime rebuild"

printf 'runtime state ownership regression checks passed\n'
