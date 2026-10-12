#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
LIFECYCLE_UC="$FORKOP_LIB/service/lifecycle.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

lifecycle_ucode() {
  FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run" \
    ucode -L "$FORKOP_LIB" "$LIFECYCLE_UC" "$@"
}

json_flatten() {
  tr -d ' \t\r\n'
}

cat >"$WORK_DIR/before.json" <<'JSON'
{
  "proxies": {
    "main-out": {
      "type": "Selector",
      "now": "main-2-out",
      "all": [ "main-1-out", "main-2-out" ]
    },
    "urltest-out": {
      "type": "URLTest",
      "now": "main-3-out",
      "all": [ "main-3-out", "main-4-out" ]
    },
    "broken-out": {
      "type": "Selector",
      "now": "missing-out",
      "all": [ "other-out" ]
    }
  }
}
JSON

snapshot="$(lifecycle_ucode selector-state-from-proxies-fixture "$WORK_DIR/before.json" | json_flatten)"
[ "$snapshot" = '{"main-out":"main-2-out"}' ] ||
  fail "selector snapshot should keep only valid selector selections, got: $snapshot"

cat >"$WORK_DIR/snapshot.json" <<JSON
$snapshot
JSON

cat >"$WORK_DIR/after.json" <<'JSON'
{
  "proxies": {
    "main-out": {
      "type": "Selector",
      "now": "main-1-out",
      "all": [ "main-1-out", "main-2-out" ]
    },
    "same-out": {
      "type": "Selector",
      "now": "same-1-out",
      "all": [ "same-1-out" ]
    }
  }
}
JSON

restore_pairs="$(lifecycle_ucode selector-restore-pairs-fixture "$WORK_DIR/snapshot.json" "$WORK_DIR/after.json" | json_flatten)"
[ "$restore_pairs" = '[{"group":"main-out","proxy":"main-2-out"}]' ] ||
  fail "restore pairs should contain only changed still-valid selector selections, got: $restore_pairs"

cat >"$WORK_DIR/already-selected.json" <<'JSON'
{
  "proxies": {
    "main-out": {
      "type": "Selector",
      "now": "main-2-out",
      "all": [ "main-1-out", "main-2-out" ]
    }
  }
}
JSON

restore_pairs="$(lifecycle_ucode selector-restore-pairs-fixture "$WORK_DIR/snapshot.json" "$WORK_DIR/already-selected.json" | json_flatten)"
[ "$restore_pairs" = '[]' ] ||
  fail "restore pairs should be empty when the selection is already active, got: $restore_pairs"

capture_calls="$(grep -Fc 'let selector_state = capture_selector_state();' "$LIFECYCLE_UC")"
[ "$capture_calls" -ge 2 ] ||
  fail "full restart paths should capture selector state before stopping runtime"

restore_calls="$(grep -Fc 'restore_selector_state(selector_state);' "$LIFECYCLE_UC")"
[ "$restore_calls" -ge 2 ] ||
  fail "full restart paths should restore selector state after runtime start"

printf 'selector state checks passed\n'
