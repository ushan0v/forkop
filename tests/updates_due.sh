#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
UPDATES_UC="$ROOT_DIR/forkop/files/usr/lib/components/updates.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_status() {
  local expected="$1"
  local label="$2"
  shift 2
  local status=0

  updates_ucode update-is-due "$@" >/dev/null 2>&1 || status="$?"
  [ "$status" = "$expected" ] ||
    fail "$label: expected exit $expected, got $status"
}

updates_ucode() {
  ucode -L "$FORKOP_LIB" "$UPDATES_UC" "$@"
}

if grep -n -E 'require\("uci"\)\.cursor|uci -q' "$UPDATES_UC" >/dev/null 2>&1; then
  fail "components/updates.uc must use core.uci instead of owning direct UCI cursor or CLI calls"
fi

assert_updates_status() {
  local expected="$1"
  local label="$2"
  shift 2
  local status=0

  updates_ucode "$@" >/dev/null 2>&1 || status="$?"
  [ "$status" = "$expected" ] ||
    fail "$label: expected exit $expected, got $status"
}

assert_status 0 "never-run update should be due" 100 0 60
assert_status 0 "expired update should be due" 100 30 60
assert_status 1 "fresh update should not be due" 100 50 60
assert_status 1 "future timestamp should not be due" 100 130 60
assert_status 0 "invalid last-run timestamp should be treated as never-run" 100 invalid 60
assert_status 2 "invalid current timestamp should fail" invalid 0 60
assert_status 2 "invalid interval should fail" 100 0 invalid
assert_status 2 "zero interval should fail" 100 0 0

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

assert_eq 180 \
  "$(updates_ucode duration-to-seconds 3m)" \
  "minutes duration"
assert_eq 5400 \
  "$(updates_ucode duration-to-seconds 1.5h)" \
  "decimal duration"
if updates_ucode duration-to-seconds invalid >/dev/null 2>&1; then
  fail "invalid duration should fail"
fi

assert_eq "* * * * *" \
  "$(updates_ucode due-check-cron-schedule 60)" \
  "minute cron schedule"
assert_eq "0 * * * *" \
  "$(updates_ucode due-check-cron-schedule 3600)" \
  "hour cron schedule"
assert_eq "0 */2 * * *" \
  "$(updates_ucode due-check-cron-schedule 7200)" \
  "two-hour cron schedule"
assert_eq "*/30 * * * *" \
  "$(updates_ucode due-check-cron-schedule 1800)" \
  "half-hour cron schedule"
assert_eq "0 0 * * *" \
  "$(updates_ucode due-check-cron-schedule 86400)" \
  "daily cron schedule"

assert_eq "*/30 * * * * /usr/bin/forkop list_update_if_due # list" \
  "$(updates_ucode list-update-cron-job 30m /usr/bin/forkop '# list')" \
  "list update cron job"
assert_eq $'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/telegram.lst\nhttps://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv6/telegram.lst' \
  "$(updates_ucode builtin-subnet-urls telegram)" \
  "Telegram built-in subnet families"
assert_eq 'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/roblox.lst' \
  "$(updates_ucode builtin-subnet-urls roblox)" \
  "Roblox available subnet family"
assert_eq 7 \
  "$(grep -c 'log_message("Failed to download .*"error");' "$UPDATES_UC")" \
  "terminal list download errors"
if grep 'log_message("Failed to download .*"warn");' "$UPDATES_UC" >/dev/null 2>&1; then
  fail "terminal list download failures must not remain warnings"
fi
assert_eq "0 */2 * * * /usr/bin/forkop subscription_update_if_due # subscription" \
  "$(updates_ucode subscription-update-cron-job 7200 /usr/bin/forkop '# subscription')" \
  "subscription update cron job"
assert_eq $'error\trule3\tinvalid\nmin\t1800' \
  "$(printf 'rule1\t2h\nrule2\t30m\nrule3\tinvalid\nrule4\t\n' | updates_ucode subscription-update-interval-plan)" \
  "subscription interval plan"
assert_eq $'min\t0' \
  "$(printf 'rule1\t\n' | updates_ucode subscription-update-interval-plan)" \
  "empty subscription interval plan"
if updates_ucode list-update-cron-job invalid /usr/bin/forkop '# list' >/dev/null 2>&1; then
  fail "invalid list update interval should fail"
fi
if updates_ucode subscription-update-cron-job 0 /usr/bin/forkop '# subscription' >/dev/null 2>&1; then
  fail "invalid subscription update interval should fail"
fi

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

cat >"$WORK_DIR/cron-plan.json" <<'JSON'
{
  "settings": {
    "list_update_enabled": "1",
    "update_interval": "30m",
    "component_update_check_enabled": "1",
    "component_update_check_interval": "2h"
  },
  "section": [
    {
      ".name": "list_rule",
      "enabled": "1",
      "action": "proxy",
      "community_lists": [ "telegram" ],
      "subscription_urls": [ "https://example.com/sub.txt" ],
      "subscription_update_interval": "2h"
    },
    {
      ".name": "fast_sub",
      "enabled": "1",
      "action": "proxy",
      "subscription_urls": [ "https://example.com/fast.txt" ],
      "subscription_update_interval": "45m"
    },
    {
      ".name": "bad_sub",
      "enabled": "1",
      "action": "proxy",
      "subscription_urls": [ "https://example.com/bad.txt" ],
      "subscription_update_interval": "bad"
    },
    {
      ".name": "disabled",
      "enabled": "0",
      "action": "proxy",
      "remote_domain_lists": [ "https://example.com/disabled.lst" ],
      "subscription_urls": [ "https://example.com/disabled.txt" ]
    }
  ]
}
JSON

assert_eq $'list\t*/30 * * * * /usr/bin/forkop list_update_if_due # list\nsubscription-error\tbad_sub\tbad\nsubscription\t*/45 * * * * /usr/bin/forkop subscription_update_if_due # subscription\ncomponent\t0 */2 * * * /usr/bin/forkop component_updates_if_due # component' \
  "$(updates_ucode cron-refresh-plan-fixture "$WORK_DIR/cron-plan.json" /usr/bin/forkop '# list' '# subscription' '# component')" \
  "cron refresh plan"

grep -Fq 'fs.writefile(tmp, as_string(text)) == null' "$UPDATES_UC" ||
  fail "empty crontab writes must not be treated as fs.writefile failure"

cat >"$WORK_DIR/cron-plan-list-disabled.json" <<'JSON'
{
  "settings": {
    "list_update_enabled": "0",
    "update_interval": "30m"
  },
  "section": [
    {
      ".name": "list_rule",
      "enabled": "1",
      "action": "proxy",
      "remote_domain_lists": [ "https://example.com/list.txt" ]
    }
  ]
}
JSON

assert_eq "list-disabled" \
  "$(updates_ucode cron-refresh-plan-fixture "$WORK_DIR/cron-plan-list-disabled.json" /usr/bin/forkop '# list' '# subscription' '# component')" \
  "disabled list cron plan"

cat >"$WORK_DIR/cron-plan-invalid-list.json" <<'JSON'
{
  "settings": {
    "list_update_enabled": "1",
    "update_interval": "bad"
  },
  "section": [
    {
      ".name": "list_rule",
      "enabled": "1",
      "action": "proxy",
      "remote_domain_lists": [ "https://example.com/list.txt" ]
    }
  ]
}
JSON

status=0
invalid_plan="$(updates_ucode cron-refresh-plan-fixture "$WORK_DIR/cron-plan-invalid-list.json" /usr/bin/forkop '# list' '# subscription' '# component')" || status="$?"
assert_eq 1 "$status" "invalid list cron plan status"
assert_eq $'list-error\tbad' "$invalid_plan" "invalid list cron plan output"

cat >"$WORK_DIR/existing.cron" <<'CRON'
0 1 * * * /bin/true # keep
* * * * * /usr/bin/forkop list_update_if_due # list
* * * * * /usr/bin/forkop subscription_update_if_due # subscription
* * * * * /usr/bin/forkop component_updates_if_due # component
CRON

updates_ucode refresh-cron-fixture "$WORK_DIR/cron-plan.json" "$WORK_DIR/existing.cron" /usr/bin/forkop '# list' '# subscription' '# component' >"$WORK_DIR/cron-apply.json"
node - "$WORK_DIR/cron-apply.json" <<'JS'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const expected = [
  "0 1 * * * /bin/true # keep",
  "*/30 * * * * /usr/bin/forkop list_update_if_due # list",
  "*/45 * * * * /usr/bin/forkop subscription_update_if_due # subscription",
  "0 */2 * * * /usr/bin/forkop component_updates_if_due # component",
  ""
].join("\n");
if (value.crontab !== expected) {
  console.error("unexpected applied crontab", JSON.stringify(value.crontab));
  process.exit(1);
}
const messages = value.logs.map(item => item.message);
if (!messages.includes("The cron job removed") ||
    !messages.includes("The cron job has been created: */30 * * * * /usr/bin/forkop list_update_if_due # list") ||
    !messages.includes("The subscription cron job has been created: */45 * * * * /usr/bin/forkop subscription_update_if_due # subscription") ||
    !messages.includes("The component update check cron job has been created: 0 */2 * * * /usr/bin/forkop component_updates_if_due # component")) {
  console.error("unexpected cron apply logs", JSON.stringify(value.logs));
  process.exit(1);
}
JS

status=0
updates_ucode refresh-cron-fixture "$WORK_DIR/cron-plan-invalid-list.json" "$WORK_DIR/existing.cron" /usr/bin/forkop '# list' '# subscription' '# component' >"$WORK_DIR/cron-apply-invalid.json" || status="$?"
assert_eq 1 "$status" "invalid cron apply status"
node - "$WORK_DIR/cron-apply-invalid.json" <<'JS'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (value.crontab !== "0 1 * * * /bin/true # keep\n") {
  console.error("invalid plan should remove old forkop cron jobs only", JSON.stringify(value.crontab));
  process.exit(1);
}
if (!value.logs.some(item => item.level === "error" && item.message === "Invalid update_interval value: bad")) {
  console.error("invalid plan error log missing", JSON.stringify(value.logs));
  process.exit(1);
}
JS

LIST_TIMESTAMP="$WORK_DIR/list.timestamp"
SUB_TIMESTAMP="$WORK_DIR/sub.timestamp"
rm -f "$LIST_TIMESTAMP" "$SUB_TIMESTAMP"

assert_updates_status 0 "list update should be due without timestamp" \
  list-update-due-status-fixture "$WORK_DIR/cron-plan.json" "$LIST_TIMESTAMP" 1000
printf '900\n' >"$LIST_TIMESTAMP"
assert_updates_status 1 "list update should not be due before interval" \
  list-update-due-status-fixture "$WORK_DIR/cron-plan.json" "$LIST_TIMESTAMP" 1000
assert_updates_status 1 "disabled list update should not be due" \
  list-update-due-status-fixture "$WORK_DIR/cron-plan-list-disabled.json" "$LIST_TIMESTAMP" 1000
status=0
invalid_due="$(updates_ucode list-update-due-status-fixture "$WORK_DIR/cron-plan-invalid-list.json" "$LIST_TIMESTAMP" 1000)" || status="$?"
assert_eq 2 "$status" "invalid list due status"
assert_eq $'error\tbad' "$invalid_due" "invalid list due output"

rm -f "$SUB_TIMESTAMP"
assert_updates_status 0 "subscription update should be due without timestamp" \
  subscription-update-section-due-status-fixture "$WORK_DIR/cron-plan.json" fast_sub "$SUB_TIMESTAMP" 1000
printf '900\n' >"$SUB_TIMESTAMP"
assert_updates_status 1 "subscription update should not be due before interval" \
  subscription-update-section-due-status-fixture "$WORK_DIR/cron-plan.json" fast_sub "$SUB_TIMESTAMP" 1000
assert_updates_status 1 "missing subscription section should not be due" \
  subscription-update-section-due-status-fixture "$WORK_DIR/cron-plan.json" missing "$SUB_TIMESTAMP" 1000
status=0
invalid_due="$(updates_ucode subscription-update-section-due-status-fixture "$WORK_DIR/cron-plan.json" bad_sub "$SUB_TIMESTAMP" 1000)" || status="$?"
assert_eq 2 "$status" "invalid subscription due status"
assert_eq $'error\tbad' "$invalid_due" "invalid subscription due output"

printf 'updates due checks passed\n'
