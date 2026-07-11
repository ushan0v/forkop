#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
VALIDATOR="$ROOT_DIR/forkop/files/usr/lib/providers/zapret/validator.uc"
ZAPRET2_VALIDATOR="$ROOT_DIR/forkop/files/usr/lib/providers/zapret2/validator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

json_field() {
  local json="$1"
  local field="$2"

  JSON_VALUE="$json" node - "$field" <<'NODE'
const field = process.argv[2];
const value = JSON.parse(process.env.JSON_VALUE);
const actual = value[field];
if (Array.isArray(actual)) {
  console.log(actual.join("\n"));
} else {
  console.log(String(actual));
}
NODE
}

assert_json_field() {
  local json="$1"
  local field="$2"
  local expected="$3"
  local actual

  actual="$(json_field "$json" "$field")"
  [ "$actual" = "$expected" ] || fail "expected $field=$expected, got $actual"
}

valid_nfqws="$(ucode -L "$FORKOP_LIB" -- "$VALIDATOR" validate-json nfqws '--dpi-desync=fake --dpi-desync-repeats 2')"
assert_json_field "$valid_nfqws" valid true

configured="$(ucode -L "$FORKOP_LIB" -- "$VALIDATOR" strategy-or-default "$(printf -- '--dpi-desync=fake\t--dpi-desync-repeats 2')" '--default')"
[ "$configured" = "--dpi-desync=fake --dpi-desync-repeats 2" ] ||
  fail "configured zapret strategy should be normalized, got '$configured'"

defaulted="$(ucode -L "$FORKOP_LIB" -- "$VALIDATOR" strategy-or-default "" "$(printf -- '--default\t1')")"
[ "$defaulted" = "--default 1" ] ||
  fail "empty zapret strategy should use normalized default, got '$defaulted'"

if invalid_nfqws="$(ucode -L "$FORKOP_LIB" -- "$VALIDATOR" validate-json nfqws '--hostlist domains.txt' 2>/dev/null)"; then
  fail "hostlist selection should be rejected for nfqws"
fi
assert_json_field "$invalid_nfqws" valid false
assert_json_field "$invalid_nfqws" needle --hostlist

if ucode -L "$FORKOP_LIB" -- "$VALIDATOR" validate nfqws '--qnum=200' >/tmp/zapret-validator.out 2>/dev/null; then
  fail "qnum override should be rejected for nfqws"
fi
grep -q 'NFQUEUE number is assigned by Forkop' /tmp/zapret-validator.out ||
  fail "qnum rejection should explain ownership"

valid_nfqws2="$(ucode -L "$FORKOP_LIB" -- "$ZAPRET2_VALIDATOR" validate-json nfqws2 '--name forkop --intercept=1')"
assert_json_field "$valid_nfqws2" valid true

if invalid_nfqws2="$(ucode -L "$FORKOP_LIB" -- "$ZAPRET2_VALIDATOR" validate-json nfqws2 '--intercept=0' 2>/dev/null)"; then
  fail "disabled nfqws2 intercept should be rejected"
fi
assert_json_field "$invalid_nfqws2" valid false
assert_json_field "$invalid_nfqws2" needle --intercept

if ucode -L "$FORKOP_LIB" -- "$VALIDATOR" validate-json nfqws2 '--name forkop --intercept=1' >/dev/null 2>&1; then
  fail "zapret validator must not own nfqws2 validation"
fi
if ucode -L "$FORKOP_LIB" -- "$ZAPRET2_VALIDATOR" validate-json nfqws '--dpi-desync=fake' >/dev/null 2>&1; then
  fail "zapret2 validator must not own nfqws validation"
fi

cat >"$WORK_DIR/require-zapret-validator.uc" <<'UCODE'
let validator = require("providers.zapret.validator");
let zapret2_validator = require("providers.zapret2.validator");

let valid_nfqws = validator.validate_strategy("nfqws", "--dpi-desync=fake --dpi-desync-repeats 2", "");
if (!valid_nfqws.valid)
    exit(1);

let invalid_nfqws = validator.validate_strategy("nfqws", "--hostlist domains.txt", "");
if (invalid_nfqws.valid || invalid_nfqws.needle != "--hostlist")
    exit(1);

let valid_nfqws2 = zapret2_validator.validate_strategy("nfqws2", "--name forkop --intercept=1", "");
if (!valid_nfqws2.valid)
    exit(1);

if (validator.validate_strategy("nfqws2", "--name forkop --intercept=1", "").valid)
    exit(1);
if (zapret2_validator.validate_strategy("nfqws", "--dpi-desync=fake", "").valid)
    exit(1);

if (validator.strategy_or_default("", "--default\t1") != "--default 1")
    exit(1);
UCODE

ucode -L "$FORKOP_LIB" "$WORK_DIR/require-zapret-validator.uc"

printf 'Zapret validator checks passed\n'
