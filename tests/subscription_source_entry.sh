#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEXROUTE_LIB="$ROOT_DIR/nexroute/files/usr/lib"
PARSER="$ROOT_DIR/nexroute/files/usr/lib/subscription/parser.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_tsv() {
  local entry="$1"
  local expected_url="$2"
  local expected_user_agent="$3"
  local parsed tab url user_agent

  parsed="$(ucode "$PARSER" parse-source-entry-tsv "$entry")"
  tab="$(printf '\t')"
  url="${parsed%%"$tab"*}"
  if [ "$url" = "$parsed" ]; then
    user_agent=""
  else
    user_agent="${parsed#*"$tab"}"
  fi

  [ "$url" = "$expected_url" ] || fail "expected url $expected_url, got $url"
  [ "$user_agent" = "$expected_user_agent" ] || fail "expected user-agent $expected_user_agent, got $user_agent"
}

assert_rejects() {
  local entry="$1"
  local expected="$2"
  local output

  if output="$(ucode "$PARSER" parse-source-entry-tsv "$entry" 2>/dev/null)"; then
    fail "entry should be rejected: $entry"
  fi
  printf '%s\n' "$output" | grep -q "$expected" || fail "expected reject message containing $expected"
}

assert_tsv ' https://example.com/sub.txt ' 'https://example.com/sub.txt' ''

assert_rejects 'https://example.com/a | Custom Agent/1.0' 'Configure User-Agent in the subscription item settings'
assert_rejects 'https://example.com/a | Agent One | Agent Two' 'Configure User-Agent in the subscription item settings'
assert_rejects 'https://example.com/a| Agent' 'Configure User-Agent in the subscription item settings'
assert_rejects 'file:///tmp/sub.txt' 'Subscription URL must start with http:// or https://'

cat >"$WORK_DIR/require-subscription-parser.uc" <<'UCODE'
let parser = require("subscription.parser");

let parsed = parser.parse_subscription_source_entry("https://example.com/a");
if (!parsed.valid || parsed.url != "https://example.com/a" || parsed.user_agent != "")
    exit(1);

let legacy = parser.parse_subscription_source_entry("https://example.com/a | Agent");
if (legacy.valid || legacy.error != "Configure User-Agent in the subscription item settings")
    exit(1);

let invalid = parser.parse_subscription_source_entry("file:///tmp/sub.txt");
if (invalid.valid || invalid.error != "Subscription URL must start with http:// or https://")
    exit(1);
UCODE

ucode -L "$NEXROUTE_LIB" "$WORK_DIR/require-subscription-parser.uc"

printf 'subscription source entry checks passed\n'
