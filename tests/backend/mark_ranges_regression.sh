#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_no_overlap() {
  local label="$1"
  local mark="$2"
  local mask="$3"
  local mask_label="$4"

  if (( (mark & mask) != 0 )); then
    printf 'FAIL: %s mark 0x%08x overlaps %s 0x%08x\n' "$label" "$mark" "$mask_label" "$mask" >&2
    exit 1
  fi
}

assert_mark_range_no_overlap() {
  local label="$1"
  local base="$2"
  local range_size="$3"
  local mask="$4"
  local mask_label="$5"
  local index mark

  for ((index = 1; index <= range_size; index++)); do
    mark=$((base + index))
    assert_no_overlap "$label[$index]" "$mark" "$mask" "$mask_label"
  done
}

# shellcheck source=/dev/null
. "$PODKOP_LIB/constants.sh"
# shellcheck source=/dev/null
. "$PODKOP_LIB/config_validation.sh"

log() {
  :
}

assert_mark_range_no_overlap "Zapret" "$((ZAPRET_ROUTE_MARK_BASE))" "$ZAPRET_QUEUE_RANGE_SIZE" "$((NFT_FAKEIP_MARK))" "FakeIP"
assert_mark_range_no_overlap "Zapret" "$((ZAPRET_ROUTE_MARK_BASE))" "$ZAPRET_QUEUE_RANGE_SIZE" "$((NFT_OUTBOUND_MARK))" "outbound"
assert_mark_range_no_overlap "Zapret2" "$((ZAPRET2_ROUTE_MARK_BASE))" "$ZAPRET2_QUEUE_RANGE_SIZE" "$((NFT_FAKEIP_MARK))" "FakeIP"
assert_mark_range_no_overlap "Zapret2" "$((ZAPRET2_ROUTE_MARK_BASE))" "$ZAPRET2_QUEUE_RANGE_SIZE" "$((NFT_OUTBOUND_MARK))" "outbound"

validate_runtime_mark_ranges

if (ZAPRET2_ROUTE_MARK_BASE="0x01100000"; validate_runtime_mark_ranges); then
  fail "legacy Zapret2 route mark base should overlap FakeIP mark"
fi

printf 'mark range regression checks passed\n'
