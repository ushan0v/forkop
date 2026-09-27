#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function read_stdin() {
    let data = fs.readfile("/dev/stdin");
    return data == null ? "" : data;
}

function strip_trailing_cr(line) {
    line = as_string(line);
    return length(line) > 0 && substr(line, length(line) - 1) == "\r" ? substr(line, 0, length(line) - 1) : line;
}

function trim_left_space(value) {
    value = as_string(value);
    let i = 0;
    while (i < length(value) && match(substr(value, i, 1), /[ \t\r\n]/) != null)
        i++;
    return substr(value, i);
}

function strip_binary_prefix(line, binary) {
    line = as_string(line);
    binary = as_string(binary || "nfqws");

    let path_marker = "/" + binary + ":";
    let path_index = rindex(line, path_marker);
    if (path_index >= 0)
        return trim_left_space(substr(line, path_index + length(path_marker)));

    let name_marker = binary + ":";
    if (index(line, name_marker) == 0)
        return trim_left_space(substr(line, length(name_marker)));

    return line;
}

function summary_line_matches(line) {
    return index(line, "unrecognized option:") >= 0 ||
        index(line, "option requires an argument:") >= 0 ||
        index(line, "option does not take an argument:") >= 0 ||
        match(line, /[Ii]nvalid /) != null ||
        match(line, /bad [^ ]/) != null ||
        index(line, "must be ") >= 0 ||
        index(line, "fooling allowed values") >= 0 ||
        index(line, "incompatible") >= 0 ||
        index(line, "only one ") >= 0 ||
        index(line, "No such file") >= 0 ||
        index(line, "not found") >= 0 ||
        index(line, "cannot ") >= 0 ||
        index(line, "failed to ") >= 0 ||
        index(line, "unable to ") >= 0 ||
        index(line, "should be ") >= 0 ||
        index(line, "Too much splits") >= 0 ||
        index(line, "out of memory") >= 0 ||
        index(line, "not supported") >= 0 ||
        index(line, "value error") >= 0;
}

function ignored_fallback_line(line) {
    return match(line, /^github version /) != null ||
        match(line, /^we have [0-9]+ user defined desync profile/) != null ||
        match(line, /^Running as UID=/) != null ||
        line == "command line parameters verified" ||
        trim(line) == "";
}

function validation_summary(binary) {
    let lines = split(read_stdin(), "\n");

    for (let line in lines) {
        line = strip_trailing_cr(line);
        if (summary_line_matches(line)) {
            print(strip_binary_prefix(line, binary), "\n");
            return;
        }
    }

    for (let line in lines) {
        line = strip_trailing_cr(line);
        if (ignored_fallback_line(line))
            continue;
        print(strip_binary_prefix(line, binary), "\n");
        return;
    }
}

function value_after_last_colon(summary) {
    let colon = rindex(summary, ":");
    if (colon < 0)
        return "";

    let fields = split(trim_left_space(substr(summary, colon + 1)), /[ \t\r\n]+/);
    return length(fields) > 0 ? fields[0] : "";
}

function validation_value_hint_value(summary) {
    summary = as_string(summary);

    if (index(summary, "Invalid port filter :") >= 0 ||
        index(summary, "Invalid l7 filter :") >= 0 ||
        index(summary, "invalid debug mode :") >= 0 ||
        index(summary, "invalid ip_id mode :") >= 0 ||
        index(summary, "Invalid fakedsplit mod :") >= 0 ||
        index(summary, "Invalid hostfakesplit mod :") >= 0 ||
        index(summary, "Invalid tcp mod :") >= 0 ||
        index(summary, "Invalid tls mod :") >= 0 ||
        index(summary, "invalid dup ip_id mode :") >= 0)
        return value_after_last_colon(summary);

    return "";
}

function validation_value_hint(summary) {
    let value = validation_value_hint_value(summary);
    if (value != "")
        print(value, "\n");
}

function first_option_token(summary) {
    let matched = match(summary, /(--[[:alnum:]][[:alnum:]-]*)/);
    return matched ? matched[1] : "";
}

function option_after(summary, pattern, prefix) {
    let matched = match(summary, pattern);
    if (!matched || length(matched) < 2)
        return "";
    return as_string(prefix) + matched[1];
}

function validation_option_hint_value(summary) {
    summary = as_string(summary);

    let option = first_option_token(summary);
    if (option != "")
        return option;

    if (index(summary, "unrecognized option:") >= 0) {
        option = option_after(summary, /unrecognized option:[ \t]*([^ \t\r\n]+)/, "");
        if (option == "")
            return "";
        if (index(option, "--") == 0)
            return option;
        else if (index(option, "-") == 0)
            return "-" + option;
        else
            return "--" + option;
    }

    if (index(summary, "option requires an argument:") >= 0) {
        option = option_after(summary, /option requires an argument:[ \t]*([^ \t\r\n]+)/, "--");
        return option;
    }

    if (index(summary, "option does not take an argument:") >= 0) {
        option = option_after(summary, /option does not take an argument:[ \t]*([^ \t\r\n]+)/, "--");
        return option;
    }

    let mappings = [
        ["invalid debug mode :", "--debug"],
        ["hostspell must be exactly 4 chars long", "--hostspell"],
        ["invalid ip_id mode :", "--ip-id"],
        ["invalid dup ip_id mode :", "--dup-ip-id"],
        ["dup-autottl value error", "--dup-autottl"],
        ["dup-autottl6 value error", "--dup-autottl6"],
        ["dpi-desync-autottl value error", "--dpi-desync-autottl"],
        ["dpi-desync-autottl6 value error", "--dpi-desync-autottl6"],
        ["orig-autottl value error", "--orig-autottl"],
        ["orig-autottl6 value error", "--orig-autottl6"],
        ["invalid dpi-desync mode", "--dpi-desync"],
        ["invalid desync combo :", "--dpi-desync"],
        ["invalid wssize-cutoff value", "--wssize-cutoff"],
        ["invalid synack-split value", "--synack-split"],
        ["invalid ctrack-timeouts value", "--ctrack-timeouts"],
        ["invalid ipcache-lifetime value", "--ipcache-lifetime"],
        ["dpi-desync-repeats must be within ", "--dpi-desync-repeats"],
        ["dup-repeats must be within ", "--dup"],
        ["invalid desync-cutoff value", "--dpi-desync-cutoff"],
        ["invalid desync-start value", "--dpi-desync-start"],
        ["Invalid fakedsplit mod :", "--dpi-desync-fakedsplit-mod"],
        ["Invalid hostfakesplit mod :", "--dpi-desync-hostfakesplit-mod"],
        ["Invalid tcp mod :", "--dpi-desync-fake-tcp-mod"],
        ["Invalid tls mod :", "--dpi-desync-fake-tls-mod"],
        ["Invalid argument for dpi-desync-split-http-req", "--dpi-desync-split-http-req"],
        ["Invalid argument for dpi-desync-split-tls", "--dpi-desync-split-tls"],
        ["Invalid argument for dpi-desync-split-seqovl", "--dpi-desync-split-seqovl"],
        ["Invalid argument for dpi-desync-hostfakesplit-midhost", "--dpi-desync-hostfakesplit-midhost"],
        ["dpi-desync-ipfrag-pos-tcp must be within ", "--dpi-desync-ipfrag-pos-tcp"],
        ["dpi-desync-ipfrag-pos-tcp must be multiple of 8", "--dpi-desync-ipfrag-pos-tcp"],
        ["dpi-desync-ipfrag-pos-udp must be within ", "--dpi-desync-ipfrag-pos-udp"],
        ["dpi-desync-ipfrag-pos-udp must be multiple of 8", "--dpi-desync-ipfrag-pos-udp"],
        ["dpi-desync-ts-increment should be ", "--dpi-desync-ts-increment"],
        ["dpi-desync-badseq-increment should be ", "--dpi-desync-badseq-increment"],
        ["dpi-desync-badack-increment should be ", "--dpi-desync-badack-increment"],
        ["dup-ts-increment should be ", "--dup-ts-increment"],
        ["dup-badseq-increment should be ", "--dup-badseq-increment"],
        ["dup-badack-increment should be ", "--dup-badack-increment"],
        ["bad value for --filter-l3", "--filter-l3"],
        ["auto hostlist fail time is not valid", "--hostlist-auto-fail-time"],
        ["auto hostlist fail threshold must be within 1..20", "--hostlist-auto-fail-threshold"],
        ["auto hostlist fail threshold must be within 2..10", "--hostlist-auto-retrans-threshold"],
        ["dpi-desync-udplen-increment must be integer within ", "--dpi-desync-udplen-increment"]
    ];

    for (let mapping in mappings) {
        if (index(summary, mapping[0]) >= 0)
            return mapping[1];
    }

    return "";
}

function validation_option_hint(summary) {
    let option = validation_option_hint_value(summary);
    if (option != "")
        print(option, "\n");
}

function validation_needles(summary) {
    let option = validation_option_hint_value(summary);
    let value = validation_value_hint_value(summary);

    if (option != "")
        print(option, "\n");
    if (value != "")
        print(value, "\n");
}

function cleaned_queue_token(token) {
    return replace(as_string(token), /[{},;]/g, "");
}

function queue_token_overlaps(token, range_start, range_end) {
    token = cleaned_queue_token(token);
    if (match(token, /^[0-9]+(-[0-9]+)?$/) == null)
        return false;

    let parts = split(token, "-");
    let first = int(parts[0]);
    let last = length(parts) > 1 && parts[1] != "" ? int(parts[1]) : first;

    return first <= range_end && last >= range_start;
}

function nft_queue_overlap(own_table, range_start, range_end) {
    own_table = as_string(own_table);
    range_start = int(range_start || 0);
    range_end = int(range_end || 0);

    let in_own_table = false;
    for (let line in split(read_stdin(), "\n")) {
        let fields = split(trim(as_string(line)), /[ \t\r\n]+/);
        if (length(fields) == 0 || fields[0] == "")
            continue;

        if (fields[0] == "table")
            in_own_table = length(fields) >= 3 && fields[1] == "inet" && fields[2] == own_table;

        if (in_own_table)
            continue;

        for (let i = 0; i < length(fields); i++) {
            if (fields[i] != "queue")
                continue;

            for (let j = i + 1; j < length(fields); j++) {
                if ((fields[j] == "num" || fields[j] == "to") && j + 1 < length(fields)) {
                    if (queue_token_overlaps(fields[j + 1], range_start, range_end))
                        return true;
                }
                else if (queue_token_overlaps(fields[j], range_start, range_end)) {
                    return true;
                }
            }
        }
    }

    return false;
}

function rewrite_legacy_runtime_path(legacy_path, provider_path) {
    let data = read_stdin();
    legacy_path = as_string(legacy_path);

    if (legacy_path == "") {
        print(data);
        return;
    }

    print(replace(data, legacy_path, as_string(provider_path)));
}

function stdin_contains(needle) {
    return index(read_stdin(), as_string(needle)) >= 0;
}

function ps_matching_pids(needle) {
    needle = as_string(needle);
    if (needle == "")
        return;

    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (index(line, needle) < 0 ||
            index(line, "grep") >= 0 ||
            index(line, "ps-matching-pids") >= 0)
            continue;

        let fields = split(trim(line), /[ \t\r\n]+/);
        if (length(fields) > 0 && fields[0] != "")
            print(fields[0], "\n");
    }
}

function run(argv, usage_path) {
    argv = type(argv) == "array" ? argv : [];
    usage_path = as_string(usage_path || "providers/nfqueue/check.uc");

    let mode = argv[0] || "";

    if (mode == "summary")
        validation_summary(argv[1]);
    else if (mode == "value-hint")
        validation_value_hint(argv[1]);
    else if (mode == "option-hint")
        validation_option_hint(argv[1]);
    else if (mode == "needles")
        validation_needles(argv[1]);
    else if (mode == "nft-queue-overlap")
        exit(nft_queue_overlap(argv[1], argv[2], argv[3]) ? 0 : 1);
    else if (mode == "rewrite-legacy-runtime-path")
        rewrite_legacy_runtime_path(argv[1], argv[2]);
    else if (mode == "stdin-contains")
        exit(stdin_contains(argv[1]) ? 0 : 1);
    else if (mode == "ps-matching-pids")
        ps_matching_pids(argv[1]);
    else {
        warn("Usage: " + usage_path + " <summary|value-hint|option-hint|needles|nft-queue-overlap|rewrite-legacy-runtime-path|stdin-contains|ps-matching-pids> ...\n");
        exit(1);
    }
}

if (sourcepath(1) != null && sourcepath(1) != "") {
    return {
        run,
        nft_queue_overlap
    };
}

run(ARGV, "providers/nfqueue/check.uc");
