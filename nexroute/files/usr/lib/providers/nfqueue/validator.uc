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

function starts_with(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
}

function split_option_token(token) {
    let equals = index(token, "=");
    return equals >= 0 ? substr(token, 0, equals) : token;
}

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

let nfqws_optional = [
    "--debug", "--comment", "--synack-split", "--ctrack-disable", "--ipcache-hostname",
    "--dup-autottl", "--dup-autottl6", "--dup-tcp-flags-set", "--dup-tcp-flags-unset",
    "--dup-replace", "--orig-autottl", "--orig-autottl6", "--orig-tcp-flags-set",
    "--orig-tcp-flags-unset", "--dpi-desync-autottl", "--dpi-desync-autottl6",
    "--dpi-desync-tcp-flags-set", "--dpi-desync-tcp-flags-unset",
    "--dpi-desync-skip-nosni", "--dpi-desync-any-protocol"
];

let nfqws_none = [
    "--dry-run", "--version", "--daemon", "--hostcase", "--hostnospace", "--domcase",
    "--methodeol", "--new", "--skip", "--bind-fix4", "--bind-fix6"
];

let nfqws_required = [
    "--qnum", "--pidfile", "--user", "--uid", "--wsize", "--wssize", "--wssize-cutoff",
    "--wssize-forced-cutoff", "--ctrack-timeouts", "--ipcache-lifetime",
    "--hostspell", "--ip-id", "--dpi-desync", "--dpi-desync-fwmark", "--dup",
    "--dup-ttl", "--dup-ttl6", "--dup-fooling", "--dup-ts-increment",
    "--dup-badseq-increment", "--dup-badack-increment", "--dup-ip-id",
    "--dup-start", "--dup-cutoff", "--orig-ttl", "--orig-ttl6",
    "--orig-mod-start", "--orig-mod-cutoff", "--dpi-desync-ttl",
    "--dpi-desync-ttl6", "--dpi-desync-fooling", "--dpi-desync-repeats",
    "--dpi-desync-split-pos", "--dpi-desync-split-http-req",
    "--dpi-desync-split-tls", "--dpi-desync-split-seqovl",
    "--dpi-desync-split-seqovl-pattern", "--dpi-desync-fakedsplit-pattern",
    "--dpi-desync-fakedsplit-mod", "--dpi-desync-hostfakesplit-midhost",
    "--dpi-desync-hostfakesplit-mod", "--dpi-desync-ipfrag-pos-tcp",
    "--dpi-desync-ipfrag-pos-udp", "--dpi-desync-ts-increment",
    "--dpi-desync-badseq-increment", "--dpi-desync-badack-increment",
    "--dpi-desync-fake-tcp-mod", "--dpi-desync-fake-http",
    "--dpi-desync-fake-tls", "--dpi-desync-fake-tls-mod",
    "--dpi-desync-fake-unknown", "--dpi-desync-fake-syndata",
    "--dpi-desync-fake-quic", "--dpi-desync-fake-wireguard",
    "--dpi-desync-fake-dht", "--dpi-desync-fake-discord",
    "--dpi-desync-fake-stun", "--dpi-desync-fake-unknown-udp",
    "--dpi-desync-udplen-increment", "--dpi-desync-udplen-pattern",
    "--dpi-desync-cutoff", "--dpi-desync-start", "--hostlist",
    "--hostlist-domains", "--hostlist-exclude", "--hostlist-exclude-domains",
    "--hostlist-auto", "--hostlist-auto-fail-threshold",
    "--hostlist-auto-fail-time", "--hostlist-auto-retrans-threshold",
    "--hostlist-auto-debug", "--filter-l3", "--filter-tcp", "--filter-udp",
    "--filter-l7", "--ipset", "--ipset-ip", "--ipset-exclude",
    "--ipset-exclude-ip"
];

let nfqws2_optional = [
    "--debug", "--comment", "--intercept", "--chdir", "--ctrack-disable", "--payload-disable",
    "--server", "--ipcache-hostname", "--reasm-disable", "--writeable", "--new", "--template",
    "--hostlist-auto-retrans-reset"
];

let nfqws2_none = [
    "--dry-run", "--version", "--daemon", "--skip", "--bind-fix4", "--bind-fix6"
];

let nfqws2_required = [
    "--qnum", "--pidfile", "--user", "--uid", "--ctrack-timeouts", "--ipcache-lifetime",
    "--fwmark", "--fuzz", "--blob", "--lua-init", "--lua-gc", "--hostlist",
    "--hostlist-domains", "--hostlist-exclude", "--hostlist-exclude-domains",
    "--hostlist-auto", "--hostlist-auto-fail-threshold", "--hostlist-auto-fail-time",
    "--hostlist-auto-retrans-threshold", "--hostlist-auto-retrans-maxseq",
    "--hostlist-auto-incoming-maxseq", "--hostlist-auto-udp-in", "--hostlist-auto-udp-out",
    "--hostlist-auto-debug", "--name", "--import", "--cookie", "--filter-l3", "--filter-tcp",
    "--filter-udp", "--filter-icmp", "--filter-ipp", "--filter-l7", "--filter-ssid",
    "--ipset", "--ipset-ip", "--ipset-exclude", "--ipset-exclude-ip",
    "--payload", "--in-range", "--out-range", "--lua-desync"
];

function option_mode(kind, token) {
    if (kind == "nfqws") {
        if (contains(nfqws_optional, token))
            return "optional";
        if (contains(nfqws_none, token))
            return "none";
        if (contains(nfqws_required, token))
            return "required";
        return "unknown";
    }

    if (contains(nfqws2_optional, token))
        return "optional";
    if (contains(nfqws2_none, token))
        return "none";
    if (contains(nfqws2_required, token))
        return "required";
    return "unknown";
}

function unsupported_reason(kind, token) {
    let name = kind == "nfqws2" ? "nfqws2" : "nfqws";
    let action = kind == "nfqws2" ? "zapret2" : "zapret";

    if (token == "<HOSTLIST>" || token == "<HOSTLIST_NOAUTO>")
        return "Forkop does not expand " + action + " hostlist templates in per-rule strategies because sing-box already selects the resources before NFQUEUE.";

    let base = split_option_token(token);
    if (contains([
        "--hostlist", "--hostlist-domains", "--hostlist-exclude", "--hostlist-exclude-domains",
        "--hostlist-auto", "--hostlist-auto-fail-threshold", "--hostlist-auto-fail-time",
        "--hostlist-auto-retrans-threshold", "--hostlist-auto-debug"
    ], base) || (kind == "nfqws2" && contains([
        "--hostlist-auto-retrans-maxseq", "--hostlist-auto-retrans-reset",
        "--hostlist-auto-incoming-maxseq", "--hostlist-auto-udp-in", "--hostlist-auto-udp-out"
    ], base)))
        return "Hostname-based selection inside " + name + " is incompatible with the Forkop architecture because sing-box already chooses which resources enter action=" + action + ".";

    if (contains([ "--ipset", "--ipset-ip", "--ipset-exclude", "--ipset-exclude-ip" ], base))
        return "IP or CIDR selection inside " + name + " is incompatible with the Forkop architecture because sing-box already chooses which resources enter action=" + action + ".";

    if (base == "--qnum")
        return "The NFQUEUE number is assigned by Forkop per rule and must not be overridden in the strategy.";

    if (kind == "nfqws" && base == "--dpi-desync-fwmark")
        return "The desync fwmark is managed by Forkop for loop prevention and must not be overridden in the strategy.";

    if (kind == "nfqws2" && (base == "--fwmark" || base == "--dpi-desync-fwmark"))
        return "The nfqws2 fwmark is managed by Forkop for loop prevention and must not be overridden in the strategy.";

    if (kind == "nfqws2" && base == "--fuzz")
        return "nfqws2 fuzz mode disables normal interception and is incompatible with Forkop-managed action=zapret2 rules.";

    if (kind == "nfqws2" && token == "--intercept=0")
        return "nfqws2 interception must stay enabled for Forkop-managed action=zapret2 rules.";

    if (base == "--daemon")
        return "Forkop manages the " + name + " process lifecycle itself. The strategy must not daemonize " + name + ".";
    if (base == "--dry-run")
        return "The strategy must launch a working " + name + " process. --dry-run exits immediately and is not allowed.";
    if (base == "--version")
        return "The strategy must launch a working " + name + " process. --version exits immediately and is not allowed.";

    return null;
}

function token_has_external_config_prefix(token) {
    return starts_with(token, "@") || starts_with(token, "$");
}

function next_is_separate_value(next_token) {
    return as_string(next_token) != "" && !starts_with(next_token, "--");
}

function label(kind) {
    return kind == "nfqws2" ? "NFQWS2" : "NFQWS";
}

function validate_strategy(kind, raw_opt, legacy_default) {
    kind = as_string(kind);
    if (kind != "nfqws" && kind != "nfqws2")
        return validation_failure("NFQUEUE validator accepts only nfqws or nfqws2 strategies.", [ kind ]);

    raw_opt = normalize_strategy_whitespace(raw_opt);

    if (kind == "nfqws" && raw_opt == as_string(legacy_default))
        return validation_success();

    let tokens = words(raw_opt);
    let token_count = 0;

    for (let i = 0; i < length(tokens); ) {
        let token = as_string(tokens[i]);
        let next_token = as_string(tokens[i + 1]);
        let base_token = split_option_token(token);

        if (token_count == 0 && token_has_external_config_prefix(token))
            return validation_failure(
                "Unsupported " + label(kind) + " token '" + token + "': External " + (kind == "nfqws2" ? "nfqws2" : "nfqws") + " config files bypass Forkop validation and queue management.",
                [ token ]
            );

        let reason = unsupported_reason(kind, token);
        if (reason != null) {
            let display = token;
            let mode = option_mode(kind, base_token);
            if (base_token == token && mode == "required" && next_is_separate_value(next_token)) {
                display += " " + next_token;
                return validation_failure("Unsupported " + label(kind) + " token '" + display + "': " + reason, [ base_token, next_token ]);
            }
            return validation_failure("Unsupported " + label(kind) + " token '" + display + "': " + reason, [ base_token ]);
        }

        if (starts_with(token, "--")) {
            let mode = option_mode(kind, base_token);
            if (mode == "unknown")
                return validation_failure("Unknown " + label(kind) + " flag '" + token + "'.", [ base_token ]);

            if (mode == "none") {
                if (base_token != token)
                    return validation_failure(label(kind) + " flag '" + base_token + "' does not accept a value.", [ base_token ]);
                i++;
                token_count++;
                continue;
            }

            if (mode == "optional") {
                if (base_token == token && next_is_separate_value(next_token))
                    return validation_failure(
                        "Optional value for '" + base_token + "' must be attached as '" + base_token + "=value'. Separate tokens are ignored by " + kind + " here.",
                        [ base_token, next_token ]
                    );
                i++;
                token_count++;
                continue;
            }

            if (base_token != token) {
                i++;
                token_count++;
                continue;
            }

            if (!next_is_separate_value(next_token))
                return validation_failure(label(kind) + " option '" + base_token + "' requires a value.", [ base_token ]);

            i += 2;
            token_count += 2;
            continue;
        }

        return validation_failure(
            "Unexpected standalone " + label(kind) + " token '" + token + "'. Use explicit flags such as --name or --name=value.",
            [ token ]
        );
    }

    return validation_success();
}

function validate_exit(kind, raw_opt, legacy_default) {
    let result = validate_strategy(kind, raw_opt, legacy_default);
    if (result.valid)
        exit(0);

    print(result.message, "\n");
    exit(1);
}

function validate_json(kind, raw_opt, legacy_default) {
    let result = validate_strategy(kind, raw_opt, legacy_default);
    write_json(result);
    exit(result.valid ? 0 : 1);
}

function expected_label(expected_kind) {
    return expected_kind == "nfqws2" ? "Zapret2" : "Zapret";
}

function validate_expected_strategy(expected_kind, kind, raw_opt, legacy_default) {
    expected_kind = as_string(expected_kind);
    if (as_string(kind) != expected_kind)
        return validation_failure(expected_label(expected_kind) + " validator accepts only " + expected_kind + " strategies.", [ as_string(kind) ]);
    return validate_strategy(expected_kind, raw_opt, legacy_default);
}

function validate_expected_exit(expected_kind, kind, raw_opt, legacy_default) {
    let result = validate_expected_strategy(expected_kind, kind, raw_opt, legacy_default);
    if (result.valid)
        exit(0);

    print(result.message, "\n");
    exit(1);
}

function validate_expected_json(expected_kind, kind, raw_opt, legacy_default) {
    let result = validate_expected_strategy(expected_kind, kind, raw_opt, legacy_default);
    write_json(result);
    exit(result.valid ? 0 : 1);
}

function run_expected(expected_kind, usage_path, argv) {
    argv = type(argv) == "array" ? argv : [];

    let mode = argv[0] || "";

    if (mode == "validate")
        validate_expected_exit(expected_kind, argv[1], argv[2], argv[3]);
    else if (mode == "validate-json")
        validate_expected_json(expected_kind, argv[1], argv[2], argv[3]);
    else if (mode == "strategy-or-default")
        print_strategy_or_default(argv[1], argv[2]);
    else {
        warn("Usage: " + usage_path + "\n");
        exit(1);
    }
}

function module_exports() {
    return {
        normalize_strategy_whitespace,
        strategy_or_default,
        validate_strategy,
        validate_expected_strategy,
        run_expected
    };
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return module_exports();

let mode = ARGV[0] || "";

if (mode == "validate")
    validate_exit(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "validate-json")
    validate_json(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "strategy-or-default")
    print_strategy_or_default(ARGV[1], ARGV[2]);
else {
    warn("Usage: providers/nfqueue/validator.uc <validate|validate-json|strategy-or-default> <nfqws|nfqws2> <strategy> [legacy-default]\n");
    exit(1);
}
