#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEXROUTE_LIB="$ROOT_DIR/nexroute/files/usr/lib"
UI_UC="$NEXROUTE_LIB/service/ui.uc"
WORK_DIR="$(mktemp -d)"
PROBE_BIN="$WORK_DIR/sing-box"
PROBE_COUNT="$WORK_DIR/probe-count"
PROBE_PIDS="$WORK_DIR/probe-pids"
CACHE_FILE="$WORK_DIR/sing-box-version-cache"

cleanup() {
  if [ -f "$PROBE_PIDS" ]; then
    while IFS= read -r pid; do
      kill -9 "$pid" 2>/dev/null || true
    done <"$PROBE_PIDS"
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cat >"$PROBE_BIN" <<'SH'
#!/bin/sh
printf '%s\n' "$$" >>"$NEXROUTE_TEST_SING_BOX_PROBE_PIDS"
printf 'probe\n' >>"$NEXROUTE_TEST_SING_BOX_PROBE_COUNT"
if [ "${NEXROUTE_TEST_SING_BOX_PROBE_MODE:-fast}" = "slow" ]; then
  exec sleep 30
fi
printf 'sing-box version 1.13.14\n\n'
printf 'Tags: with_quic,with_tailscale\n'
SH
chmod 755 "$PROBE_BIN"
cat >"$WORK_DIR/opkg" <<'SH'
#!/bin/sh
exit 0
SH
chmod 755 "$WORK_DIR/opkg"

ui_capabilities() {
  PATH="$WORK_DIR:$PATH" \
  NEXROUTE_CONFIG_NAME=nexroute-ui-probe-test \
  NEXROUTE_UI_STATE_DIR="$WORK_DIR/state" \
  NEXROUTE_UI_COMPONENT_ACTION_DIR="$WORK_DIR/components" \
  NEXROUTE_UI_SING_BOX_VERSION_CACHE_FILE="$CACHE_FILE" \
  NEXROUTE_UI_SING_BOX_VARIANT_STATE_FILE="$WORK_DIR/missing-variant" \
  NEXROUTE_UI_SING_BOX_BIN_PATH="$PROBE_BIN" \
  NEXROUTE_UI_SING_BOX_VERSION_PROBE_TIMEOUT_SECONDS=1 \
  NEXROUTE_UI_SING_BOX_VERSION_PROBE_FAILURE_TTL_SECONDS=30 \
  ZAPRET_PROVIDER_NFQWS_BIN="$WORK_DIR/missing-nfqws" \
  ZAPRET2_PROVIDER_NFQWS2_BIN="$WORK_DIR/missing-nfqws2" \
  BYEDPI_BIN="$WORK_DIR/missing-ciadpi" \
  NEXROUTE_TEST_SING_BOX_PROBE_COUNT="$PROBE_COUNT" \
  NEXROUTE_TEST_SING_BOX_PROBE_PIDS="$PROBE_PIDS" \
  ucode -L "$NEXROUTE_LIB" "$UI_UC" get-ui-capabilities
}

fast_first="$(NEXROUTE_TEST_SING_BOX_PROBE_MODE=fast ui_capabilities)"
fast_second="$(NEXROUTE_TEST_SING_BOX_PROBE_MODE=fast ui_capabilities)"
[ "$(wc -l <"$PROBE_COUNT")" -eq 1 ] ||
  fail "successful sing-box capability detection must be cached by binary signature"

JSON_VALUE="$fast_first" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.sing_box_extended !== 0 || value.sing_box_tiny !== 0 || value.sing_box_tailscale !== 1) {
  console.error('cached sing-box capability flags mismatch');
  process.exit(1);
}
NODE
[ "$fast_first" = "$fast_second" ] ||
  fail "cached sing-box capabilities must match the initial detection"

: >"$PROBE_COUNT"
: >"$PROBE_PIDS"
rm -rf "$CACHE_FILE" "$CACHE_FILE.lock"

start_seconds=$SECONDS
workers=""
for index in 1 2 3 4 5; do
  NEXROUTE_TEST_SING_BOX_PROBE_MODE=slow ui_capabilities >"$WORK_DIR/slow-$index.json" &
  workers="$workers $!"
done
for worker in $workers; do
  wait "$worker"
done
elapsed_seconds=$((SECONDS - start_seconds))

[ "$elapsed_seconds" -le 4 ] ||
  fail "bounded sing-box probes took ${elapsed_seconds}s"
[ "$(wc -l <"$PROBE_COUNT")" -eq 1 ] ||
  fail "parallel UI requests must share one sing-box probe"

for output in "$WORK_DIR"/slow-*.json; do
  JSON_FILE="$output" node - <<'NODE'
const fs = require('fs');
const value = JSON.parse(fs.readFileSync(process.env.JSON_FILE, 'utf8'));
if (value.sing_box_extended !== 0 || value.sing_box_tiny !== 0 || value.sing_box_tailscale !== 0) {
  console.error('failed sing-box probe must produce conservative capability flags');
  process.exit(1);
}
NODE
done

NEXROUTE_TEST_SING_BOX_PROBE_MODE=slow ui_capabilities >/dev/null
[ "$(wc -l <"$PROBE_COUNT")" -eq 1 ] ||
  fail "failed sing-box probe must be cached during the retry cooldown"

while IFS= read -r pid; do
  if kill -0 "$pid" 2>/dev/null; then
    fail "timed-out sing-box probe process $pid is still running"
  fi
done <"$PROBE_PIDS"
: >"$PROBE_PIDS"

printf 'UI sing-box probe checks passed\n'
