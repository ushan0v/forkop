#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
UPDATES_UC="$PODKOP_LIB/components/updates.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

fake_lib="$WORK_DIR/lib"
cache_dir="$WORK_DIR/cache"
job_dir="$WORK_DIR/jobs"
state_file="$job_dir/manual.json"
output_file="$job_dir/manual.out"
timestamp_file="$WORK_DIR/component-update-check.timestamp"
mkdir -p \
  "$fake_lib/core" \
  "$fake_lib/config" \
  "$fake_lib/components" \
  "$fake_lib/service" \
  "$fake_lib/providers/zapret" \
  "$fake_lib/providers/zapret2" \
  "$fake_lib/providers/byedpi" \
  "$job_dir"

cat >"$fake_lib/core/uci.uc" <<'UCODE'
function get_all(_config, section) {
    if (section == "settings") {
        return {
            component_update_check_enabled: getenv("TEST_COMPONENT_UPDATE_CHECK_ENABLED") || "0",
            component_update_check_interval: getenv("TEST_COMPONENT_UPDATE_CHECK_INTERVAL") || "1d"
        };
    }
    return {};
}

function section_objects(_config, _type) {
    return [];
}

return {
    get_all,
    section_objects
};
UCODE

cat >"$fake_lib/config/connections.uc" <<'UCODE'
return {};
UCODE

cat >"$fake_lib/components/action.uc" <<'UCODE'
#!/usr/bin/env ucode
let component = ARGV[1] || "podkop";
let action = ARGV[2] || "check_update";
print(sprintf("%J\n", {
    success: true,
    component,
    action,
    message: "Update is available",
    current_version: "1.0.0",
    latest_version: "1.1.0",
    release_url: "https://example.com/release",
    changed: 0,
    status: "outdated"
}));
UCODE

cat >"$fake_lib/providers/zapret/runtime.uc" <<'UCODE'
#!/usr/bin/env ucode
exit(1);
UCODE
cp "$fake_lib/providers/zapret/runtime.uc" "$fake_lib/providers/zapret2/runtime.uc"
cp "$fake_lib/providers/zapret/runtime.uc" "$fake_lib/providers/byedpi/runtime.uc"

cat >"$fake_lib/service/state.uc" <<'UCODE'
#!/usr/bin/env ucode
exit(0);
UCODE

updates_ucode() {
  TEST_COMPONENT_UPDATE_CHECK_ENABLED="${TEST_COMPONENT_UPDATE_CHECK_ENABLED:-1}" \
    TEST_COMPONENT_UPDATE_CHECK_INTERVAL="${TEST_COMPONENT_UPDATE_CHECK_INTERVAL:-1d}" \
    PODKOP_LIB="$fake_lib" \
    PODKOP_COMPONENT_UPDATE_CHECK_CACHE_DIR="$cache_dir" \
    PODKOP_COMPONENT_UPDATE_CHECK_STATE_FILE="$timestamp_file" \
    UPDATES_JOB_DIR="$job_dir" \
    ucode -L "$fake_lib" -L "$PODKOP_LIB" "$UPDATES_UC" "$@"
}

updates_ucode component-action-worker "$state_file" "$output_file" zapret check_update
[ -s "$cache_dir/zapret.json" ] ||
  fail "manual checks must be cached while automatic checks are enabled"

manual_cache="$(updates_ucode component-update-check-cache)"
node -e '
const value = JSON.parse(process.argv[1]);
if (!value.enabled || value.results.length !== 1 ||
    value.results[0].component !== "zapret" ||
    value.results[0].status !== "outdated" ||
    value.results[0].latest_version !== "1.1.0") process.exit(1);
' "$manual_cache" || fail "cached manual check response is invalid"

rm -rf "$cache_dir"
TEST_COMPONENT_UPDATE_CHECK_ENABLED=0 updates_ucode \
  component-action-worker "$state_file" "$output_file" zapret check_update
[ ! -e "$cache_dir/zapret.json" ] ||
  fail "manual checks must not be cached while automatic checks are disabled"

rm -f "$state_file" "$timestamp_file"
updates_ucode component-updates-if-due
[ -s "$cache_dir/podkop.json" ] ||
  fail "automatic checks must cache the Podkop Plus result"
[ -s "$timestamp_file" ] ||
  fail "automatic checks must record their last run"

printf 'component update check cache regression checks passed\n'
