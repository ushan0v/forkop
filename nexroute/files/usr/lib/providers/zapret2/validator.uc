#!/usr/bin/env ucode

let validator = require("providers.nfqueue.validator");

const KIND = "nfqws2";
const USAGE = "providers/zapret2/validator.uc <validate|validate-json|strategy-or-default> <nfqws2> <strategy>";

function validate_strategy(kind, raw_opt, legacy_default) {
    return validator.validate_expected_strategy(KIND, kind, raw_opt, legacy_default);
}

function module_exports() {
    return {
        normalize_strategy_whitespace: validator.normalize_strategy_whitespace,
        strategy_or_default: validator.strategy_or_default,
        validate_strategy
    };
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return module_exports();

validator.run_expected(KIND, USAGE, ARGV);
