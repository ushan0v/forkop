#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEXROUTE_LIB="$ROOT_DIR/nexroute/files/usr/lib"
VALIDATOR="$NEXROUTE_LIB/config/validator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

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
    assert_no_overlap "${label}[$index]" "$mark" "$mask" "$mask_label"
  done
}

eval "$(ucode -L "$NEXROUTE_LIB" "$NEXROUTE_LIB/core/constants.uc" shell-env)"

TAILSCALE_FWMARK_MASK=0x00ff0000

assert_no_overlap "FakeIP" "$((NFT_FAKEIP_MARK))" "$((TAILSCALE_FWMARK_MASK))" "Tailscale"
assert_no_overlap "outbound" "$((NFT_OUTBOUND_MARK))" "$((TAILSCALE_FWMARK_MASK))" "Tailscale"
assert_mark_range_no_overlap "Zapret" "$((ZAPRET_ROUTE_MARK_BASE))" "$ZAPRET_QUEUE_RANGE_SIZE" "$((NFT_FAKEIP_MARK))" "FakeIP"
assert_mark_range_no_overlap "Zapret" "$((ZAPRET_ROUTE_MARK_BASE))" "$ZAPRET_QUEUE_RANGE_SIZE" "$((NFT_OUTBOUND_MARK))" "outbound"
assert_mark_range_no_overlap "Zapret2" "$((ZAPRET2_ROUTE_MARK_BASE))" "$ZAPRET2_QUEUE_RANGE_SIZE" "$((NFT_FAKEIP_MARK))" "FakeIP"
assert_mark_range_no_overlap "Zapret2" "$((ZAPRET2_ROUTE_MARK_BASE))" "$ZAPRET2_QUEUE_RANGE_SIZE" "$((NFT_OUTBOUND_MARK))" "outbound"
assert_mark_range_no_overlap "Zapret" "$((ZAPRET_ROUTE_MARK_BASE))" "$ZAPRET_QUEUE_RANGE_SIZE" "$((TAILSCALE_FWMARK_MASK))" "Tailscale"
assert_mark_range_no_overlap "Zapret2" "$((ZAPRET2_ROUTE_MARK_BASE))" "$ZAPRET2_QUEUE_RANGE_SIZE" "$((TAILSCALE_FWMARK_MASK))" "Tailscale"

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": [ "77.88.8.8" ], "bootstrap_dns_server": [ "77.88.8.8" ] }
}
JSON

context_json() {
  local zapret2_base="${1:-$ZAPRET2_ROUTE_MARK_BASE}"
  local fakeip_mark="${2:-$NFT_FAKEIP_MARK}"
  local outbound_mark="${3:-$NFT_OUTBOUND_MARK}"

  cat <<JSON
{
  "community_services": "$COMMUNITY_SERVICES",
  "byedpi_default_cmd_opts": "",
  "zapret_default_nfqws_opt": "",
  "zapret_legacy_default_nfqws_opt": "",
  "zapret2_default_nfqws2_opt": "",
  "byedpi_installed": false,
  "zapret_installed": false,
  "zapret2_installed": false,
  "zapret_route_mark_base": "$ZAPRET_ROUTE_MARK_BASE",
  "zapret_queue_range_size": "$ZAPRET_QUEUE_RANGE_SIZE",
  "zapret2_route_mark_base": "$zapret2_base",
  "zapret2_queue_range_size": "$ZAPRET2_QUEUE_RANGE_SIZE",
  "nft_fakeip_mark": "$fakeip_mark",
  "nft_outbound_mark": "$outbound_mark"
}
JSON
}

NEXROUTE_LIB="$NEXROUTE_LIB" ucode -L "$NEXROUTE_LIB" "$VALIDATOR" validate-runtime-fixture "$WORK_DIR/fixture.json" "$(context_json)"

if NEXROUTE_LIB="$NEXROUTE_LIB" ucode -L "$NEXROUTE_LIB" "$VALIDATOR" validate-runtime-fixture "$WORK_DIR/fixture.json" "$(context_json "0x01010000")" >/dev/null 2>&1; then
  fail "legacy Zapret2 route mark base should overlap Tailscale fwmark mask"
fi
if NEXROUTE_LIB="$NEXROUTE_LIB" ucode -L "$NEXROUTE_LIB" "$VALIDATOR" validate-runtime-fixture "$WORK_DIR/fixture.json" "$(context_json "" "0x00100000")" >/dev/null 2>&1; then
  fail "legacy FakeIP mark should overlap Tailscale fwmark mask"
fi
if NEXROUTE_LIB="$NEXROUTE_LIB" ucode -L "$NEXROUTE_LIB" "$VALIDATOR" validate-runtime-fixture "$WORK_DIR/fixture.json" "$(context_json "" "" "0x00200000")" >/dev/null 2>&1; then
  fail "legacy outbound mark should overlap Tailscale fwmark mask"
fi

printf 'mark range checks passed\n'
