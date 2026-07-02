#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

reject_runtime_pattern() {
  local pattern="$1"
  local label="$2"

  if rg -n --fixed-strings "$pattern" "$ROOT_DIR/podkop/files" >/dev/null 2>&1; then
    rg -n --fixed-strings "$pattern" "$ROOT_DIR/podkop/files" >&2
    fail "$label"
  fi
}

reject_runtime_regex() {
  local pattern="$1"
  local label="$2"

  if rg -n "$pattern" "$ROOT_DIR/podkop/files" >/dev/null 2>&1; then
    rg -n "$pattern" "$ROOT_DIR/podkop/files" >&2
    fail "$label"
  fi
}

reject_runtime_pattern "ucode sing-box runtime generator" \
  "sing-box logs must not expose the implementation language"
reject_runtime_pattern "runtime generator" \
  "sing-box generator errors must describe config generation, not the internal generator"
reject_runtime_pattern "Reload signature changes:" \
  "reload logs must not dump internal signature vectors"
reject_runtime_pattern "Reload plan: sing-box=" \
  "reload logs must not dump boolean plan internals"
reject_runtime_pattern "Trying subscription User-Agent" \
  "subscription logs must not expose automatic User-Agent fallback attempts"
reject_runtime_pattern "Selected subscription User-Agent" \
  "subscription logs must not expose automatic User-Agent fallback selection"
reject_runtime_pattern "Current sing-box config hash:" \
  "sing-box config logs must not emit duplicate hash lines"
reject_runtime_pattern "Temporary sing-box config hash:" \
  "sing-box config logs must not emit duplicate hash lines"
reject_runtime_pattern "Podkop Plus did not reach a stable running state after start" \
  "startup rollback logs must not be fatal secondary errors"
reject_runtime_pattern "Flush nft" \
  "stop logs must not expose routine nft cleanup as user-facing info"
reject_runtime_pattern "Flush ip rule" \
  "stop logs must not expose routine ip-rule cleanup as user-facing info"
reject_runtime_pattern "Flush ip route" \
  "stop logs must not expose routine route cleanup as user-facing info"
reject_runtime_pattern "Create IPv4 marking rule" \
  "nft logs must use polished wording"
reject_runtime_pattern "Create IPv6 marking rule" \
  "nft logs must use polished wording"
reject_runtime_pattern "marking rule exist" \
  "nft logs must use correct grammar"
reject_runtime_pattern "br_netfilter enabled detected. Disabling" \
  "nft logs must use polished bridge-netfilter wording"

reject_runtime_regex 'log_message\("subscription/cache\.uc: ' \
  "runtime logs must not expose subscription/cache.uc as a user-facing prefix"
reject_runtime_regex 'log_message\("singbox/runtime\.uc: ' \
  "runtime logs must not expose singbox/runtime.uc as a user-facing prefix"

printf 'log hygiene regression checks passed\n'
