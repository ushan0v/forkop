#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATES_UC="$ROOT_DIR/nexroute/files/usr/lib/components/updates.uc"
UPDATES_RUNTIME="$ROOT_DIR/nexroute/files/usr/lib/updates_runtime.sh"
NEXROUTE_LIB="$ROOT_DIR/nexroute/files/usr/lib"
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

write_state() {
  local name="$1"
  local content="$2"

  printf '%s\n' "$content" >"$WORK_DIR/$name.json"
  printf '%s\n' "$WORK_DIR/$name.json"
}

updates_ucode() {
  ucode -L "$NEXROUTE_LIB" "$UPDATES_UC" "$@"
}

[ ! -e "$UPDATES_RUNTIME" ] ||
  fail "updates_runtime.sh shell owner must be removed"

assert_eq "/tmp/sub-jobs/job_1.json" \
  "$(updates_ucode subscription-job-state-path /tmp/sub-jobs job_1)" \
  "valid subscription job path"

if updates_ucode subscription-job-state-path /tmp/sub-jobs '../bad' >/dev/null 2>&1; then
  fail "invalid subscription job id should be rejected"
fi

running="$(write_state running '{"running":true,"pid":"321","started_at":100}')"
assert_eq "$(printf 'pid\t321\t0')" \
  "$(updates_ucode subscription-job-refresh-plan "$running" 105 15)" \
  "running job within grace"
assert_eq "$(printf 'pid\t321\t1')" \
  "$(updates_ucode subscription-job-refresh-plan "$running" 120 15)" \
  "running job after grace"

invalid_pid="$(write_state invalid-pid '{"running":true,"pid":"","started_at":100}')"
assert_eq "skip" \
  "$(updates_ucode subscription-job-refresh-plan "$invalid_pid" 105 15)" \
  "invalid pid within grace"
assert_eq "stale" \
  "$(updates_ucode subscription-job-refresh-plan "$invalid_pid" 120 15)" \
  "invalid pid after grace"

finished="$(write_state finished '{"running":false,"pid":"321","started_at":100}')"
assert_eq "skip" \
  "$(updates_ucode subscription-job-refresh-plan "$finished" 120 15)" \
  "finished job refresh"

stale_json="$(updates_ucode subscription-stale-job-state 200 proxy 2 100)"
JSON_VALUE="$stale_json" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.running !== false || value.success !== false || value.section !== "proxy" || value.source_index !== "2") {
  console.error("subscription stale state shape mismatch");
  process.exit(1);
}
NODE

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/nexroute" <<'SH'
#!/usr/bin/env sh
if [ "$1" != "subscription_update" ]; then
  exit 64
fi
printf 'fake update for %s/%s\n' "$2" "$3"
printf 'Subscription update completed by fake worker\n'
SH
chmod +x "$WORK_DIR/bin/nexroute"

ASYNC_ENV=(
  "NEXROUTE_LIB=$ROOT_DIR/nexroute/files/usr/lib"
  "NEXROUTE_BIN=$WORK_DIR/bin/nexroute"
  "TMP_SING_BOX_FOLDER=$WORK_DIR/tmp/sing-box"
  "TMP_RULESET_FOLDER=$WORK_DIR/tmp/sing-box/rulesets"
  "TMP_SUBSCRIPTION_FOLDER=$WORK_DIR/tmp/sing-box/subscriptions"
  "NEXROUTE_RUNTIME_STATE_DIR=$WORK_DIR/run"
  "NEXROUTE_SUBSCRIPTION_UPDATE_STATE_DIR=$WORK_DIR/run/subscription-update"
  "NEXROUTE_SUBSCRIPTION_UPDATE_JOB_DIR=$WORK_DIR/run/subscription-update-jobs"
  "NEXROUTE_SUBSCRIPTION_LINKS_DIR=$WORK_DIR/run/subscription-links"
  "NEXROUTE_SUBSCRIPTION_METADATA_DIR=$WORK_DIR/run/subscription-metadata"
  "NEXROUTE_OUTBOUND_METADATA_DIR=$WORK_DIR/run/outbound-metadata"
  "NEXROUTE_SECTION_CACHE_DIR=$WORK_DIR/run/section-cache"
  "NEXROUTE_RUNTIME_CACHE_FORMAT_FILE=$WORK_DIR/run/cache-format"
  "NEXROUTE_PERSISTENT_SUBSCRIPTION_CACHE_DIR=$WORK_DIR/persistent/subscription-cache"
  "NEXROUTE_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE=$WORK_DIR/persistent/subscription-cache/cache-format"
)

async_response="$(env "${ASYNC_ENV[@]}" ucode -L "$ROOT_DIR/nexroute/files/usr/lib" "$UPDATES_UC" subscription-update-async proxy 1)"
job_id="$(JSON_VALUE="$async_response" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.success !== true || !value.job_id) {
  console.error("subscription async response shape mismatch");
  process.exit(1);
}
process.stdout.write(value.job_id);
NODE
)"

final_status=""
for _ in $(seq 1 30); do
  final_status="$(env "${ASYNC_ENV[@]}" ucode -L "$ROOT_DIR/nexroute/files/usr/lib" "$UPDATES_UC" subscription-update-status "$job_id")"
  if JSON_VALUE="$final_status" node -e 'process.exit(JSON.parse(process.env.JSON_VALUE).running ? 1 : 0)' >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

JSON_VALUE="$final_status" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.success !== true || value.running !== false || value.section !== "proxy" || value.source_index !== "1" || value.exit_code !== 0) {
  console.error("subscription async final state mismatch");
  process.exit(1);
}
if (value.message !== "Subscription update completed by fake worker") {
  console.error(`unexpected final message: ${value.message}`);
  process.exit(1);
}
NODE

printf 'subscription update job checks passed\n'
