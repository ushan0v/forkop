#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEXROUTE_LIB="$ROOT_DIR/nexroute/files/usr/lib"
VALIDATOR="$ROOT_DIR/nexroute/files/usr/lib/providers/byedpi/validator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_json_field() {
  local json="$1"
  local field="$2"
  local expected="$3"

  JSON_VALUE="$json" node - "$field" "$expected" <<'NODE'
const field = process.argv[2];
const expected = process.argv[3];
const value = JSON.parse(process.env.JSON_VALUE);
const actual = String(value[field]);
if (actual !== expected) {
  console.error(`expected ${field}=${expected}, got ${actual}`);
  process.exit(1);
}
NODE
}

valid_json="$(ucode -- "$VALIDATOR" validate-json '--disorder 3 --fake-sni example.org -N')"
assert_json_field "$valid_json" valid true

configured="$(ucode -- "$VALIDATOR" strategy-or-default "$(printf -- '--disorder\t3\n--fake-sni example.org')" '--default 1')"
[ "$configured" = "--disorder 3 --fake-sni example.org" ] ||
  fail "configured strategy should be normalized, got '$configured'"

defaulted="$(ucode -- "$VALIDATOR" strategy-or-default "" "$(printf -- '--default\t1')")"
[ "$defaulted" = "--default 1" ] ||
  fail "empty strategy should use normalized default, got '$defaulted'"

invalid_json="$(ucode -- "$VALIDATOR" validate-json '--port 1080 --disorder 3')"
assert_json_field "$invalid_json" valid false
assert_json_field "$invalid_json" needle --port

validator_output="$WORK_DIR/byedpi-validator.out"
if ucode -- "$VALIDATOR" validate '--transparent' >"$validator_output" 2>/dev/null; then
  fail "controlled transparent mode should be rejected"
fi
grep -q 'Transparent proxy mode is incompatible' "$validator_output" ||
  fail "reject message should explain transparent mode"

if ucode -- "$VALIDATOR" validate '--disorder --fake example.org' >/dev/null 2>&1; then
  fail "missing value should be rejected"
fi

cat >"$WORK_DIR/require-byedpi-validator.uc" <<'UCODE'
let validator = require("providers.byedpi.validator");

let valid = validator.validate_byedpi_strategy("--disorder 3 --fake-sni example.org -N");
if (!valid.valid)
    exit(1);

let invalid = validator.validate_byedpi_strategy("--port 1080 --disorder 3");
if (invalid.valid || invalid.needle != "--port")
    exit(1);

if (validator.strategy_or_default("", "--default\t1") != "--default 1")
    exit(1);
UCODE

ucode -L "$NEXROUTE_LIB" "$WORK_DIR/require-byedpi-validator.uc"

printf 'ByeDPI validator checks passed\n'
