#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
FORKOP_BIN="$ROOT_DIR/forkop/files/usr/bin/forkop"
CLI_UC="$FORKOP_BIN"
UPDATER="$ROOT_DIR/forkop/files/usr/lib/components/updater.uc"
UPDATES_UC="$ROOT_DIR/forkop/files/usr/lib/components/updates.uc"
ACTION_UC="$ROOT_DIR/forkop/files/usr/lib/components/action.uc"
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

assert_eq "/tmp/jobs/abc-1_2.json" \
  "$(ucode "$UPDATER" updates-job-state-path /tmp/jobs abc-1_2)" \
  "valid job state path"

if ucode "$UPDATER" updates-job-state-path /tmp/jobs '../bad' >/dev/null 2>&1; then
  fail "invalid job id should be rejected"
fi

assert_eq outdated \
  "$(ucode -- "$UPDATER" updates-status-from-compare -1)" \
  "outdated compare status"
assert_eq latest \
  "$(ucode -- "$UPDATER" updates-status-from-compare 0)" \
  "latest compare status"
assert_eq dev \
  "$(ucode -- "$UPDATER" updates-status-from-compare 1)" \
  "dev compare status"
if ucode -- "$UPDATER" updates-status-from-compare invalid >/dev/null 2>&1; then
  fail "invalid compare status should be rejected"
fi

assert_eq "$(printf 'Latest version is installed\tcomponent is up to date (1.0)')" \
  "$(ucode "$UPDATER" updates-check-result-row component 1.0 1.0 latest)" \
  "latest check result"
assert_eq "$(printf 'Update is available\tcomponent update is available: 1.0 -> 2.0')" \
  "$(ucode "$UPDATER" updates-check-result-row component 1.0 2.0 outdated)" \
  "outdated check result"
assert_eq "$(printf 'Installed version is newer than release\tcomponent installed version is newer than upstream release: 2.0 -> 1.0')" \
  "$(ucode "$UPDATER" updates-check-result-row component 2.0 1.0 dev)" \
  "dev check result"
if ucode "$UPDATER" updates-check-result-row component 1.0 2.0 invalid >/dev/null 2>&1; then
  fail "invalid check result status should be rejected"
fi

[ ! -e "$ROOT_DIR/forkop/files/usr/lib/updater.sh" ] ||
  fail "updater.sh shell owner must be removed"
grep -Fq 'component_action: [ "components/action.uc", "component-action", 2 ]' "$CLI_UC" ||
  fail "service/cli.uc must dispatch direct component_action through components/action.uc"
grep -Fq 'component-action-async' "$UPDATES_UC" ||
  fail "components/updates.uc must own component action async"
grep -Fq 'component-action-status' "$UPDATES_UC" ||
  fail "components/updates.uc must own component action status"
grep -Fq 'components/action.uc' "$UPDATES_UC" ||
  fail "component action worker must execute components/action.uc directly"
grep -Fq 'singbox/runtime.uc' "$UPDATES_UC" ||
  fail "components/updates.uc must delegate sing-box service/config work to singbox/runtime.uc"
if grep -n -E 'function (configure_sing_box_service|rebuild_sing_box_config|save_sing_box_config_file|service_listen_address|managed_sing_box_service_text)' "$UPDATES_UC" >/dev/null 2>&1; then
  fail "components/updates.uc must not duplicate singbox/runtime.uc service/config ownership"
fi
if grep -Fq 'save-sing-box-config-file-fixture' "$UPDATES_UC"; then
  fail "components/updates.uc must not expose sing-box config save fixtures owned by singbox/runtime.uc"
fi
grep -Fq 'component_action_async: [ "components/updates.uc", "component-action-async", 2 ]' "$CLI_UC" ||
  fail "service/cli.uc must dispatch component_action_async through components/updates.uc"
grep -Fq 'component_action_status: [ "components/updates.uc", "component-action-status", 1 ]' "$CLI_UC" ||
  fail "service/cli.uc must dispatch component_action_status through components/updates.uc"
grep -Fq 'require("core.uci")' "$ACTION_UC" ||
  fail "components/action.uc must use core.uci for component UCI mutations"
if grep -n -E 'require\("uci"\)\.cursor|uci -q|uci", "-q"|command_exists\("uci"\)' "$ACTION_UC" >/dev/null 2>&1; then
  fail "components/action.uc must not own direct UCI cursor or CLI calls"
fi
grep -Fq 'forkop_status_running_with_timeout()' "$ACTION_UC" ||
  fail "components/action.uc must use bounded Forkop status checks for component actions"
if grep -Fq 'command_success_from_args([ SERVICE_INIT, "status" ])' "$ACTION_UC"; then
  fail "components/action.uc must not call init.d status without a timeout"
fi
status_timeout_line="$(grep -n '^function forkop_status_running_with_timeout()' "$ACTION_UC" | cut -d: -f1)"
capture_state_line="$(grep -n '^function capture_forkop_running_state()' "$ACTION_UC" | cut -d: -f1)"
[ -n "$status_timeout_line" ] && [ -n "$capture_state_line" ] && [ "$status_timeout_line" -lt "$capture_state_line" ] ||
  fail "components/action.uc must declare bounded status helper before capture_forkop_running_state for OpenWrt ucode"
init_line="$(grep -n '^function init_tmp_dir()' "$ACTION_UC" | cut -d: -f1)"
tmp_file_line="$(grep -n '^function make_tmp_file' "$ACTION_UC" | cut -d: -f1)"
[ -n "$init_line" ] && [ -n "$tmp_file_line" ] && [ "$init_line" -lt "$tmp_file_line" ] ||
  fail "components/action.uc must declare init_tmp_dir before make_tmp_file for OpenWrt ucode"

sed -n '26,64p' "$ACTION_UC" >"$WORK_DIR/action-command-success.uc"
cat >>"$WORK_DIR/action-command-success.uc" <<'UCODE'
let output_path = ARGV[0] || "";
if (output_path == "" ||
    !command_success(command_from_args([ "printf", "%s", "extracted payload" ]) + " >" + shell_quote(output_path)))
    exit(1);
UCODE
command_success_output="$WORK_DIR/command-success-output"
ucode "$WORK_DIR/action-command-success.uc" "$command_success_output" ||
  fail "components/action.uc command_success should allow commands with explicit output redirection"
assert_eq "extracted payload" "$(cat "$command_success_output")" \
  "component command success preserves explicit output redirection"

package_runtime_lib="$WORK_DIR/package-runtime-lib"
package_runtime_bin="$WORK_DIR/package-runtime-bin"
mkdir -p "$package_runtime_lib/components" "$package_runtime_lib/core" "$package_runtime_lib/singbox" "$package_runtime_bin"
cp "$UPDATER" "$package_runtime_lib/components/updater.uc"
cat >"$package_runtime_lib/core/constants.uc" <<'UCODE'
function module_exports() {
  return {};
}

if (sourcepath(1) != null && sourcepath(1) != "")
  return module_exports();
UCODE
cat >"$package_runtime_lib/core/uci.uc" <<'UCODE'
function module_exports() {
  return {
    available: function() { return false; }
  };
}

if (sourcepath(1) != null && sourcepath(1) != "")
  return module_exports();
UCODE
cat >"$package_runtime_lib/core/packages.uc" <<'UCODE'
let mode = ARGV[0] || "";
if (mode == "opkg-version")
  exit(0);
if (mode == "opkg-installed")
  exit(1);
exit(1);
UCODE
cat >"$package_runtime_lib/singbox/runtime.uc" <<'UCODE'
let mode = ARGV[0] || "";
if (mode == "version")
  exit(0);
if (mode == "variant") {
  print("stable\n");
  exit(0);
}
if (mode == "is-extended" || mode == "is-tiny")
  exit(1);
if (mode == "write-variant-marker" || mode == "write-version-state")
  exit(0);
exit(0);
UCODE
cat >"$package_runtime_bin/opkg" <<'SH'
#!/usr/bin/env sh
set -eu
printf 'opkg %s\n' "$*" >>"${FAKE_OPKG_LOG:?}"
case "${1:-}" in
  list)
    if [ -e "${FAKE_OPKG_UPDATED:?}" ]; then
      printf 'sing-box - 1.2.3 - fake package\n'
    fi
    ;;
  update)
    : >"${FAKE_OPKG_UPDATED:?}"
    ;;
  install|remove)
    ;;
  *)
    exit 1
    ;;
esac
SH
cat >"$package_runtime_bin/logger" <<'SH'
#!/usr/bin/env sh
exit 0
SH
chmod +x "$package_runtime_bin/opkg" "$package_runtime_bin/logger"

set +e
PATH="$package_runtime_bin:$PATH" \
FORKOP_LIB="$package_runtime_lib" \
FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/package-runtime" \
FORKOP_BIN="$WORK_DIR/missing-forkop" \
FORKOP_SERVICE_INIT="$WORK_DIR/missing-init" \
FAKE_OPKG_LOG="$WORK_DIR/opkg.log" \
FAKE_OPKG_UPDATED="$WORK_DIR/opkg.updated" \
ucode -L "$package_runtime_lib" "$ACTION_UC" component-action sing_box install_stable >/dev/null
set -e
OPKG_LOG="$WORK_DIR/opkg.log" node - <<'NODE'
const fs = require('fs');
const lines = fs.readFileSync(process.env.OPKG_LOG, 'utf8').trim().split(/\n+/);
function fail(message) {
  console.error(`${message}: ${JSON.stringify(lines)}`);
  process.exit(1);
}
const firstList = lines.indexOf('opkg list sing-box');
const update = lines.indexOf('opkg update');
const secondList = lines.indexOf('opkg list sing-box', firstList + 1);
const install = lines.findIndex(line => line.startsWith('opkg install ') && line.endsWith(' sing-box'));
if (firstList < 0) fail('initial stable sing-box package list lookup missing');
if (update <= firstList) fail('package list update must happen after empty initial lookup');
if (secondList <= update) fail('stable sing-box version must be resolved again after package list update');
if (install <= secondList) fail('stable sing-box install must happen after post-update version resolve');
NODE

release_json="$(cat <<'JSON'
{
  "tag_name": "1.2.3",
  "html_url": "https://example.com/release",
  "assets": [
    {"name": "forkop_1.2.3.ipk", "browser_download_url": "https://example.com/backend.ipk"},
    {"name": "luci-app-forkop_1.2.3.ipk", "browser_download_url": "https://example.com/app.ipk"},
    {"name": "luci-i18n-forkop-ru_1.2.3.ipk", "browser_download_url": "https://example.com/i18n.ipk"}
  ]
}
JSON
)"

assert_eq "$(printf 'https://example.com/release\tforkop_1.2.3.ipk\thttps://example.com/backend.ipk\tluci-app-forkop_1.2.3.ipk\thttps://example.com/app.ipk\tluci-i18n-forkop-ru_1.2.3.ipk\thttps://example.com/i18n.ipk')" \
  "$(printf '%s' "$release_json" | ucode "$UPDATER" forkop-release-plan 1.2.3 ipk 1)" \
  "forkop release plan with i18n"
assert_eq "$(printf 'https://example.com/release\tforkop_1.2.3.ipk\thttps://example.com/backend.ipk\tluci-app-forkop_1.2.3.ipk\thttps://example.com/app.ipk\t\t')" \
  "$(printf '%s' "$release_json" | ucode "$UPDATER" forkop-release-plan 1.2.3 ipk 0)" \
  "forkop release plan without i18n"
if printf '%s' "$release_json" | ucode "$UPDATER" forkop-release-plan 9.9.9 ipk 0 >/dev/null 2>&1; then
  fail "forkop release plan should reject tag mismatch"
fi
missing_i18n_json="$(cat <<'JSON'
{
  "tag_name": "1.2.3",
  "html_url": "https://example.com/release",
  "assets": [
    {"name": "forkop_1.2.3.ipk", "browser_download_url": "https://example.com/backend.ipk"},
    {"name": "luci-app-forkop_1.2.3.ipk", "browser_download_url": "https://example.com/app.ipk"}
  ]
}
JSON
)"
if printf '%s' "$missing_i18n_json" | ucode "$UPDATER" forkop-release-plan 1.2.3 ipk 1 >/dev/null 2>&1; then
  fail "forkop release plan should require i18n asset when requested"
fi

ucode "$UPDATER" forkop-release-version-valid 1.2.3 ||
  fail "three-part Forkop release version should be valid"
for invalid_version in v1.2.3 1.2 1.2.3.4 1.2.3-1 1.2.3-r1; do
  if ucode "$UPDATER" forkop-release-version-valid "$invalid_version" >/dev/null 2>&1; then
    fail "invalid Forkop release version was accepted: $invalid_version"
  fi
done
assert_eq "-1" "$(ucode "$UPDATER" forkop-release-version-compare 1.2.3 1.2.4)" \
  "three-part Forkop release version comparison"

assert_eq "1.13.14-extended-2.5.0" \
  "$(printf 'sing-box version 1.13.14-extended-2.5.0\n\nEnvironment: go1.26.4 linux/amd64\n' | ucode "$UPDATER" stdin-first-line-last-field)" \
  "sing-box extended binary version parsing"

component_actions_dir="$WORK_DIR/component-actions"
fake_lib="$WORK_DIR/lib"
mkdir -p "$fake_lib/components" "$fake_lib/config" "$fake_lib/core"
cp "$UPDATES_UC" "$fake_lib/components/updates.uc"
cp "$FORKOP_LIB/config/connections.uc" "$fake_lib/config/connections.uc"
cp "$FORKOP_LIB/core/uci.uc" "$fake_lib/core/uci.uc"
cp "$FORKOP_LIB/core/common.uc" "$fake_lib/core/common.uc"
cat >"$fake_lib/components/action.uc" <<'UCODE'
#!/usr/bin/env ucode
if ((ARGV[0] || "") == "component-action") {
  printf('{"success":true,"kind":"component","component":"%s","action":"%s","message":"done","current_version":"1.0","latest_version":"1.0","changed":0,"status":"latest"}\n', ARGV[1], ARGV[2]);
  exit(0);
}
exit(1);
UCODE

start_json="$(FORKOP_LIB="$fake_lib" UPDATES_JOB_DIR="$component_actions_dir" \
  ucode -L "$FORKOP_LIB" "$UPDATES_UC" component-action-async sing_box check_update)"
job_id="$(JSON_VALUE="$start_json" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (!value.success || !value.job_id) {
  process.exit(1);
}
process.stdout.write(value.job_id);
NODE
)"
[ -n "$job_id" ] || fail "component action async should return a job id"

status_json=""
for _ in 1 2 3 4 5; do
  status_json="$(FORKOP_LIB="$fake_lib" UPDATES_JOB_DIR="$component_actions_dir" \
    ucode -L "$FORKOP_LIB" "$UPDATES_UC" component-action-status "$job_id")"
  JSON_VALUE="$status_json" node - <<'NODE' && break || true
const value = JSON.parse(process.env.JSON_VALUE);
process.exit(value.running === false ? 0 : 1);
NODE
  sleep 1
done

JSON_VALUE="$status_json" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.running !== false || value.success !== true || value.component !== "sing_box" ||
    value.action !== "check_update" || value.message !== "done" || value.exit_code !== 0) {
  console.error("component action async/status state mismatch");
  process.exit(1);
}
NODE

start_json="$(FORKOP_LIB="$fake_lib" UPDATES_JOB_DIR="$component_actions_dir" \
  ucode -L "$FORKOP_LIB" "$UPDATES_UC" component-action-async sing-box check_update)"
job_id="$(JSON_VALUE="$start_json" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (!value.success || !value.job_id) {
  process.exit(1);
}
process.stdout.write(value.job_id);
NODE
)"
[ -n "$job_id" ] || fail "component action async should accept sing-box public name"

status_json=""
for _ in 1 2 3 4 5; do
  status_json="$(FORKOP_LIB="$fake_lib" UPDATES_JOB_DIR="$component_actions_dir" \
    ucode -L "$FORKOP_LIB" "$UPDATES_UC" component-action-status "$job_id")"
  JSON_VALUE="$status_json" node - <<'NODE' && break || true
const value = JSON.parse(process.env.JSON_VALUE);
process.exit(value.running === false ? 0 : 1);
NODE
  sleep 1
done

JSON_VALUE="$status_json" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.running !== false || value.success !== true || value.component !== "sing_box" ||
    value.action !== "check_update" || value.message !== "done" || value.exit_code !== 0) {
  console.error("component action public sing-box alias state mismatch");
  process.exit(1);
}
NODE

zapret_release_json="$(cat <<'JSON'
{
  "tag_name": "v70.1",
  "html_url": "https://example.com/zapret-release",
  "assets": [
    {"name": "zapret_v70.1_aarch64_generic.zip", "browser_download_url": "https://example.com/aarch64.zip"},
    {"name": "zapret_v70.1_mipsel_24kc.zip", "browser_download_url": "https://example.com/mipsel.zip"}
  ]
}
JSON
)"

assert_eq "$(printf 'mipsel_24kc\tzapret_v70.1_mipsel_24kc.zip\thttps://example.com/mipsel.zip\thttps://example.com/zapret-release\tv70.1')" \
  "$(printf '%s' "$zapret_release_json" | ucode "$UPDATER" release-select-arch-suffix-asset zip 'mipsel_24kc aarch64_generic')" \
  "release arch suffix selector"
[ -z "$(printf '%s' "$zapret_release_json" | ucode "$UPDATER" release-select-arch-suffix-asset zip 'arm_cortex-a7')" ] ||
  fail "release arch suffix selector should be empty for missing arch"

running="$(write_state running '{"running":true,"pid":"123","started_at":100}')"
assert_eq "$(printf 'pid\t123\t0')" \
  "$(ucode "$UPDATER" updates-job-refresh-plan "$running" 105 15)" \
  "alive candidate within grace"
assert_eq "$(printf 'pid\t123\t1')" \
  "$(ucode "$UPDATER" updates-job-refresh-plan "$running" 120 15)" \
  "alive candidate after grace"

invalid_pid="$(write_state invalid-pid '{"running":true,"pid":"","started_at":100}')"
assert_eq "skip" \
  "$(ucode "$UPDATER" updates-job-refresh-plan "$invalid_pid" 105 15)" \
  "invalid pid within grace"
assert_eq "stale" \
  "$(ucode "$UPDATER" updates-job-refresh-plan "$invalid_pid" 120 15)" \
  "invalid pid after grace"

finished="$(write_state finished '{"running":false,"pid":"123","started_at":100}')"
assert_eq "skip" \
  "$(ucode "$UPDATER" updates-job-refresh-plan "$finished" 120 15)" \
  "finished job refresh"

stale_json="$(ucode "$UPDATER" updates-mark-stale-job-state "$invalid_pid")"
JSON_VALUE="$stale_json" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.running !== false || value.success !== false || value.exit_code !== null) {
  console.error("stale state shape mismatch");
  process.exit(1);
}
NODE

printf 'component updater job checks passed\n'
