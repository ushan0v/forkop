#!/usr/bin/env ucode

function as_string(value) {
    return value == null ? "" : "" + value;
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function normalize_strategy_whitespace(value) {
    value = replace(as_string(value), /[\t\r\n]/g, " ");
    value = replace(value, / +/g, " ");
    value = replace(value, /^ /, "");
    return replace(value, / $/, "");
}

function strategy_or_default(value, default_value) {
    value = as_string(value);
    if (value == "")
        value = as_string(default_value);
    return normalize_strategy_whitespace(value);
}

function print_strategy_or_default(value, default_value) {
    print(strategy_or_default(value, default_value), "\n");
}

function words(value) {
    value = normalize_strategy_whitespace(value);
    return value == "" ? [] : split(value, " ");
}

function contains(values, needle) {
    for (let value in values)
        if (value == needle)
            return true;
    return false;
}

let long_value_options = [
    "--max-conn", "--conn-ip", "--buf-size", "--debug", "--def-ttl", "--auto", "--auto-mode",
    "--cache-ttl", "--cache-dump", "--timeout", "--proto", "--hosts", "--ipset", "--pf",
    "--round", "--split", "--disorder", "--oob", "--disoob", "--fake", "--fake-sni",
    "--ttl", "--fake-offset", "--fake-data", "--fake-tls-mod", "--oob-data", "--mod-http",
    "--tlsrec", "--tlsminor", "--udp-fake"
];

let long_flag_options = [
    "--md5sig", "--tfo", "--drop-sack", "--no-domain", "--no-udp"
];

let short_value_options = [
    "-c", "-I", "-b", "-x", "-g", "-A", "-L", "-u", "-y", "-T", "-K", "-H", "-j",
    "-V", "-R", "-s", "-d", "-o", "-q", "-f", "-n", "-t", "-O", "-l", "-Q", "-e",
    "-M", "-r", "-m", "-a"
];

let short_flag_options = [
    "-N", "-U", "-F", "-S", "-Y"
];

function validation_failure(message, needles) {
    needles = type(needles) == "array" ? needles : [];
    return {
        valid: false,
        message: as_string(message),
        needle: length(needles) > 0 ? as_string(needles[0]) : "",
        needles
    };
}

function validation_success() {
    return {
        valid: true,
        message: "",
        needle: "",
        needles: []
    };
}

function token_looks_like_option(token) {
    token = as_string(token);
    return match(token, /^--.+/) != null || match(token, /^-[A-Za-z].*/) != null;
}

function short_option_name(token) {
    token = as_string(token);
    return length(token) >= 2 ? substr(token, 0, 2) : token;
}

function controlled_option_failure(token, next_token) {
    let base = split(as_string(token), "=")[0];
    let display = as_string(token);

    if (token == "--ip" || index(token, "--ip=") == 0 || token == "-i" || match(token, /^-i.+/) != null ||
        token == "--port" || index(token, "--port=") == 0 || token == "-p" || match(token, /^-p.+/) != null) {
        if ((token == "--ip" || token == "-i" || token == "--port" || token == "-p") &&
            as_string(next_token) != "" && substr(as_string(next_token), 0, 1) != "-")
            display += " " + as_string(next_token);
        return validation_failure(
            "ByeDPI listen address and port are assigned by Forkop and must not be set in the strategy: " + display,
            [ base ]
        );
    }

    if (token == "--transparent" || token == "-E" || match(token, /^-E.+/) != null)
        return validation_failure(
            "Transparent proxy mode is incompatible with action=byedpi because Forkop connects to ciadpi through SOCKS.",
            [ base ]
        );

    if (token == "--daemon" || token == "-D" || match(token, /^-D.+/) != null)
        return validation_failure(
            "Forkop manages the ciadpi process lifecycle itself, so daemon mode is not allowed here.",
            [ base ]
        );

    if (token == "--pidfile" || index(token, "--pidfile=") == 0 || token == "-w" || match(token, /^-w.+/) != null)
        return validation_failure(
            "Forkop manages ciadpi pid files itself, so pidfile options are not allowed here.",
            [ base ]
        );

    if (token == "--help" || token == "-h" || match(token, /^-h.+/) != null ||
        token == "--version" || token == "-v" || match(token, /^-v.+/) != null)
        return validation_failure(
            "This field must start a working ciadpi strategy; help/version options exit immediately and are not allowed here.",
            [ base ]
        );

    return null;
}

function validate_token(tokens, index_value) {
    let token = as_string(tokens[index_value]);
    let next_token = as_string(tokens[index_value + 1]);
    let controlled = controlled_option_failure(token, next_token);
    if (controlled != null)
        return controlled;

    let equals = index(token, "=");
    if (index(token, "--") == 0 && equals > 0) {
        let base = substr(token, 0, equals);
        let value = substr(token, equals + 1);

        if (contains(long_value_options, base))
            return value == "" ? validation_failure("ByeDPI option requires a value: " + base, [ base ]) : null;
        if (contains(long_flag_options, base))
            return validation_failure("ByeDPI option does not accept a value: " + base, [ base ]);
        return validation_failure("Unknown ByeDPI option: " + base, [ base ]);
    }

    if (index(token, "--") == 0) {
        if (contains(long_value_options, token)) {
            if (next_token == "" || token_looks_like_option(next_token))
                return validation_failure("ByeDPI option requires a value: " + token, [ token ]);
            return { consume_next: true };
        }
        if (contains(long_flag_options, token))
            return null;
        return validation_failure("Unknown ByeDPI option: " + token, [ token ]);
    }

    if (substr(token, 0, 1) == "-") {
        if (token == "-")
            return validation_failure("Unexpected ByeDPI strategy argument: " + token, [ token ]);

        let short = short_option_name(token);
        let value = substr(token, length(short));
        if (contains(short_value_options, short)) {
            if (token == short) {
                if (next_token == "" || token_looks_like_option(next_token))
                    return validation_failure("ByeDPI option requires a value: " + short, [ short ]);
                return { consume_next: true };
            }
            if (value == "")
                return validation_failure("ByeDPI option requires a value: " + short, [ short ]);
            return null;
        }

        if (contains(short_flag_options, short)) {
            if (token != short)
                return validation_failure("ByeDPI option does not accept a compact value: " + short, [ short ]);
            return null;
        }

        return validation_failure("Unknown ByeDPI option: " + short, [ short ]);
    }

    return validation_failure("Unexpected ByeDPI strategy argument: " + token, [ token ]);
}

function validate_byedpi_strategy(raw_opt) {
    let tokens = words(raw_opt);

    if (length(tokens) == 0)
        return validation_failure("ByeDPI strategy cannot be empty.", []);

    for (let i = 0; i < length(tokens); i++) {
        let result = validate_token(tokens, i);
        if (result == null)
            continue;
        if (result.consume_next === true) {
            i++;
            continue;
        }
        return result;
    }

    return validation_success();
}

function write_validation_json(result) {
    write_json(result);
}

function validate_exit(raw_opt) {
    let result = validate_byedpi_strategy(raw_opt);
    if (result.valid)
        exit(0);

    print(result.message, "\n");
    exit(1);
}

function module_exports() {
    return {
        normalize_strategy_whitespace,
        strategy_or_default,
        validate_byedpi_strategy
    };
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return module_exports();

let mode = ARGV[0] || "";

if (mode == "validate-json")
    write_validation_json(validate_byedpi_strategy(ARGV[1]));
else if (mode == "validate")
    validate_exit(ARGV[1]);
else if (mode == "strategy-or-default")
    print_strategy_or_default(ARGV[1], ARGV[2]);
else {
    warn("Usage: providers/byedpi/validator.uc <validate|validate-json|strategy-or-default> ...\n");
    exit(1);
}
