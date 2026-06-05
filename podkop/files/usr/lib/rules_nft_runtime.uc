#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function ascii_lower(value) {
    let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    let lower = "abcdefghijklmnopqrstuvwxyz";
    return replace(as_string(value), /[A-Z]/g, function(ch) {
        return substr(lower, index(upper, ch), 1);
    });
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function write_compact_string_array(values) {
    print("[");
    for (let i = 0; i < length(values); i++) {
        if (i > 0)
            print(",");
        print(sprintf("%J", as_string(values[i])));
    }
    print("]\n");
}

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : data;
}

function strip_list_comment(line) {
    line = replace(as_string(line), /[[:space:]]*\/\/.*$/, "");
    return replace(line, /[[:space:]]*#.*$/, "");
}

function print_csv(values) {
    for (let i = 0; i < length(values); i++) {
        if (i > 0)
            print(",");
        print(as_string(values[i]));
    }
    if (length(values) > 0)
        print("\n");
}

function text_list_values(value, separator_mode) {
    let result = [];
    separator_mode = as_string(separator_mode);

    for (let line in split(as_string(value), "\n")) {
        line = strip_list_comment(line);
        line = separator_mode == "comma-space"
            ? replace(line, /[ ,]/g, "\n")
            : replace(line, /,/g, "\n");

        for (let item in split(line, "\n")) {
            item = trim(replace(item, /\r/g, ""));
            if (item != "")
                push(result, item);
        }
    }

    return result;
}

function text_list_to_csv(value, separator_mode) {
    print_csv(text_list_values(value, separator_mode));
}

function csv_to_json_array(value) {
    value = as_string(value);
    if (value == "") {
        print("[]\n");
        return;
    }

    write_compact_string_array(split(value, ","));
}

function csv_list_contains(value, needle) {
    needle = as_string(needle);
    if (needle == "")
        return false;

    for (let item in split(as_string(value), ",")) {
        if (item == needle)
            return true;
    }

    return false;
}

function stdin_contains(needle) {
    return index(read_stdin(), as_string(needle)) >= 0;
}

function valid_ipv4(value) {
    value = as_string(value);
    if (match(value, /^([0-9]{1,3}\.){3}[0-9]{1,3}$/) == null)
        return false;

    let parts = split(value, ".");
    if (length(parts) != 4)
        return false;

    for (let part in parts) {
        if (part == "" || match(part, /^[0-9]+$/) == null)
            return false;
        let octet = int(part);
        if (octet < 0 || octet > 255)
            return false;
    }

    return true;
}

function valid_ipv4_cidr(value) {
    value = as_string(value);
    let slash = index(value, "/");
    if (slash < 0 || index(substr(value, slash + 1), "/") >= 0)
        return false;

    let address = substr(value, 0, slash);
    let prefix = substr(value, slash + 1);
    if (prefix == "" || match(prefix, /^[0-9]+$/) == null)
        return false;

    prefix = int(prefix);
    return valid_ipv4(address) && prefix >= 0 && prefix <= 32;
}

function valid_domain_suffix(value) {
    value = ascii_lower(value);
    if (substr(value, 0, 1) == ".")
        value = substr(value, 1);

    return match(value, /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/) != null;
}

function decimal_without_leading_zero(value) {
    value = as_string(value);
    return value != "" && match(value, /^[0-9]+$/) != null && (length(value) == 1 || substr(value, 0, 1) != "0");
}

function nft_ipv4(value, allow_trailing_dot) {
    value = as_string(value);
    if (allow_trailing_dot && length(value) > 0 && substr(value, length(value) - 1, 1) == ".")
        value = substr(value, 0, length(value) - 1);

    let parts = split(value, ".");
    if (length(parts) != 4)
        return false;

    for (let part in parts) {
        if (!decimal_without_leading_zero(part))
            return false;

        let octet = int(part);
        if (octet < 0 || octet > 255)
            return false;
    }

    return true;
}

function nft_ipv4_cidr(value) {
    value = as_string(value);
    let slash = index(value, "/");
    if (slash <= 0 || index(substr(value, slash + 1), "/") >= 0)
        return false;

    let prefix = substr(value, slash + 1);
    if (!decimal_without_leading_zero(prefix))
        return false;

    let prefix_number = int(prefix);
    return nft_ipv4(substr(value, 0, slash), false) && prefix_number >= 0 && prefix_number <= 32;
}

function nft_ip_or_cidr(value) {
    return nft_ipv4(value, true) || nft_ipv4_cidr(value);
}

function domain_subnet_line_values(data) {
    let result = [];

    for (let line in split(as_string(data), "\n")) {
        line = trim(replace(strip_list_comment(line), /\r/g, ""));
        if (line != "")
            push(result, line);
    }

    return result;
}

function domain_subnet_value_valid(value, kind) {
    kind = as_string(kind);
    if (kind == "domains")
        return valid_domain_suffix(value);
    if (kind == "subnets")
        return valid_ipv4(value) || valid_ipv4_cidr(value);

    exit(1);
}

function normalize_domain_subnet_value(value, kind) {
    kind = as_string(kind);
    if (kind == "domains") {
        let normalized = ascii_lower(value);
        return valid_domain_suffix(normalized) ? normalized : null;
    }
    if (kind == "subnets")
        return valid_ipv4(value) || valid_ipv4_cidr(value) ? value : null;

    exit(1);
}

function filter_domain_subnet_values(values, kind) {
    let result = [];
    kind = as_string(kind);

    if (kind != "domains" && kind != "subnets")
        exit(1);

    for (let value in values) {
        let normalized = normalize_domain_subnet_value(value, kind);
        if (normalized != null)
            push(result, normalized);
    }

    return result;
}

function domain_subnet_text_csv(value, kind) {
    print_csv(filter_domain_subnet_values(text_list_values(value, "comma-space"), kind));
}

function domain_subnet_file_csv(path, kind) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    print_csv(filter_domain_subnet_values(domain_subnet_line_values(data), kind));
}

function split_domain_subnet_file(path, domains_path, subnets_path) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    let domains = [];
    let subnets = [];

    for (let value in domain_subnet_line_values(data)) {
        let domain = normalize_domain_subnet_value(value, "domains");
        if (domain != null)
            push(domains, domain);
        else if (valid_ipv4(value) || valid_ipv4_cidr(value))
            push(subnets, value);
    }

    if (!fs.writefile(domains_path, length(domains) > 0 ? join("\n", domains) + "\n" : ""))
        exit(1);
    if (!fs.writefile(subnets_path, length(subnets) > 0 ? join("\n", subnets) + "\n" : ""))
        exit(1);
}

function normalize_port_number_value(value) {
    value = trim(as_string(value));
    if (value == "" || match(value, /^[0-9]+$/) == null)
        return null;

    let number = int(value);
    return number >= 1 && number <= 65535 ? number : null;
}

function normalize_port_condition_value(value) {
    value = trim(as_string(value));
    if (value == "")
        return null;

    let dash = index(value, "-");
    if (dash < 0) {
        let number = normalize_port_number_value(value);
        return number == null ? null : as_string(number);
    }

    let start = normalize_port_number_value(substr(value, 0, dash));
    let end = normalize_port_number_value(substr(value, dash + 1));
    if (start == null || end == null || start > end)
        return null;

    return start == end ? as_string(start) : sprintf("%d-%d", start, end);
}

function normalize_port_condition_for_nft(value) {
    let normalized = normalize_port_condition_value(value);
    if (normalized == null)
        exit(1);
    print(normalized, "\n");
}

function normalize_port_range_value(value) {
    value = trim(as_string(value));
    let dash = index(value, "-");
    if (dash < 0)
        return null;

    let start = normalize_port_number_value(substr(value, 0, dash));
    let end = normalize_port_number_value(substr(value, dash + 1));
    if (start == null || end == null || start > end)
        return null;

    return sprintf("%d:%d", start, end);
}

function append_unique_port(result, seen, item) {
    let normalized = normalize_port_condition_value(item);
    if (normalized == null || seen[normalized])
        return;

    seen[normalized] = true;
    push(result, normalized);
}

function rule_ports_csv(list_values, text_value) {
    let result = [];
    let seen = {};
    let normalized_list = replace(as_string(list_values), /[[:space:]]+/g, "\n");

    for (let item in split(normalized_list, "\n"))
        append_unique_port(result, seen, item);

    for (let item in text_list_values(text_value, "comma-space"))
        append_unique_port(result, seen, item);

    print_csv(result);
}

function rule_port_values_json(csv) {
    let result = [];

    for (let item in split(as_string(csv), ",")) {
        if (index(item, "-") >= 0)
            continue;

        let port = normalize_port_number_value(item);
        if (port != null)
            push(result, port);
    }

    write_json(result);
}

function rule_port_ranges_json(csv) {
    let result = [];

    for (let item in split(as_string(csv), ",")) {
        if (index(item, "-") < 0)
            continue;

        let range = normalize_port_range_value(item);
        if (range != null)
            push(result, range);
    }

    write_json(result);
}

function csv_to_lines_file(csv, path) {
    if (!fs.writefile(path, replace(as_string(csv) + "\n", /,/g, "\n")))
        exit(1);
}

function nft_write_chunk(chunks, chunk) {
    if (length(chunk) > 0)
        push(chunks, "" + length(chunk) + "\t" + join(",", chunk));
}

function nft_push_chunk_value(chunks, chunk, value, chunk_size) {
    push(chunk, value);
    if (length(chunk) < chunk_size)
        return chunk;

    nft_write_chunk(chunks, chunk);
    return [];
}

function nft_invalid(invalid, value, message) {
    push(invalid, as_string(value) + "\t" + message);
}

function str_last_index(value, needle) {
    value = as_string(value);
    needle = as_string(needle);
    let result = -1;
    let start = 0;

    while (true) {
        let offset = index(substr(value, start), needle);
        if (offset < 0)
            return result;

        result = start + offset;
        start = result + length(needle);
    }
}

function nft_trimmed_lines(path) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    let result = [];
    for (let line in split(as_string(data), "\n")) {
        line = trim(replace(as_string(line), /\r/g, ""));
        if (line != "")
            push(result, line);
    }

    return result;
}

function nft_chunk_size(value) {
    value = int(value || 5000);
    return value > 0 ? value : 5000;
}

function nft_prepare_chunks(path, kind, ports_csv, chunk_size_text, chunks_path, invalid_path) {
    let chunk_size = nft_chunk_size(chunk_size_text);
    let chunks = [];
    let invalid = [];
    let chunk = [];
    let ports = split(as_string(ports_csv), ",");

    for (let line in nft_trimmed_lines(path)) {
        if (kind == "ports") {
            let port = normalize_port_condition_value(line);
            if (port == null) {
                nft_invalid(invalid, line, "is not a valid port or port range");
                continue;
            }
            chunk = nft_push_chunk_value(chunks, chunk, port, chunk_size);
            continue;
        }

        if (kind == "ip-ports") {
            let separator = index(line, " . ");
            let last_separator = str_last_index(line, " . ");
            if (separator < 0 || last_separator < 0) {
                nft_invalid(invalid, line, "is not an IPv4/CIDR and port nft tuple");
                continue;
            }

            let ip = substr(line, 0, separator);
            let port = substr(line, last_separator + 3);
            let original_port = port;
            if (!nft_ip_or_cidr(ip)) {
                nft_invalid(invalid, ip, "is not IPv4 or IPv4 CIDR");
                continue;
            }

            port = normalize_port_condition_value(port);
            if (port == null) {
                nft_invalid(invalid, original_port, "is not a valid port or port range");
                continue;
            }

            chunk = nft_push_chunk_value(chunks, chunk, ip + " . " + port, chunk_size);
            continue;
        }

        if (!nft_ip_or_cidr(line)) {
            nft_invalid(invalid, line, "is not IPv4 or IPv4 CIDR");
            continue;
        }

        if (kind == "ip-port-from-ip") {
            for (let port in ports) {
                if (port == "")
                    continue;

                let normalized = normalize_port_condition_value(port);
                if (normalized == null) {
                    nft_invalid(invalid, port, "is not a valid port or port range");
                    continue;
                }

                chunk = nft_push_chunk_value(chunks, chunk, line + " . " + normalized, chunk_size);
            }
        }
        else if (kind == "ips") {
            chunk = nft_push_chunk_value(chunks, chunk, line, chunk_size);
        }
        else {
            exit(1);
        }
    }

    nft_write_chunk(chunks, chunk);

    if (!fs.writefile(chunks_path, length(chunks) > 0 ? join("\n", chunks) + "\n" : ""))
        exit(1);
    if (!fs.writefile(invalid_path, length(invalid) > 0 ? join("\n", invalid) + "\n" : ""))
        exit(1);
}

function hex_digit_value(value) {
    let pos = index("0123456789abcdef", lc(as_string(value)));
    return pos >= 0 ? pos : null;
}

function parse_mark_number(value) {
    value = lc(trim(as_string(value)));
    if (value == "")
        return null;

    if (substr(value, 0, 2) == "0x") {
        value = substr(value, 2);
        if (value == "")
            return null;

        let result = 0;
        for (let i = 0; i < length(value); i++) {
            let digit = hex_digit_value(substr(value, i, 1));
            if (digit == null)
                return null;
            result = result * 16 + digit;
        }
        return result;
    }

    return match(value, /^[0-9]+$/) == null ? null : int(value);
}

function normalized_fields(line) {
    line = trim(replace(as_string(line), /\r/g, ""));
    line = replace(line, /[[:space:]]+/g, " ");
    return line == "" ? [] : split(line, " ");
}

function rule_line_has_lookup_table(fields, table) {
    table = as_string(table);

    for (let i = 0; i + 1 < length(fields); i++)
        if (fields[i] == "lookup" && fields[i + 1] == table)
            return true;

    return false;
}

function rule_line_has_fwmark(fields, expected_mark) {
    for (let i = 0; i + 1 < length(fields); i++) {
        if (fields[i] != "fwmark")
            continue;

        let parts = split(fields[i + 1], "/");
        if (length(parts) != 2)
            continue;

        if (parse_mark_number(parts[0]) == expected_mark && parse_mark_number(parts[1]) == expected_mark)
            return true;
    }

    return false;
}

function has_tproxy_marking_rule(table, mark) {
    let rule_list = read_stdin();
    let expected_mark = parse_mark_number(mark);
    let has_lookup = false;
    let has_fwmark = false;

    if (expected_mark == null)
        exit(1);

    for (let line in split(rule_list, "\n")) {
        let fields = normalized_fields(line);
        if (length(fields) == 0)
            continue;

        if (!has_lookup && rule_line_has_lookup_table(fields, table))
            has_lookup = true;
        if (!has_fwmark && rule_line_has_fwmark(fields, expected_mark))
            has_fwmark = true;

        if (has_lookup && has_fwmark)
            return true;
    }

    return false;
}

function has_local_default_route() {
    for (let line in split(read_stdin(), "\n")) {
        line = trim(replace(as_string(line), /\r/g, ""));
        line = replace(line, /[[:space:]]+/g, " ");
        if (index(line, "local default dev lo scope host") >= 0)
            return true;
    }

    return false;
}

function file_regex_matches(path, pattern) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return null;

    try {
        return match(data, regexp(as_string(pattern))) != null;
    }
    catch (e) {
        return false;
    }
}

function file_regex_matches_exit(path, pattern) {
    let result = file_regex_matches(path, pattern);
    exit(result == null ? 2 : (result ? 0 : 1));
}

let mode = ARGV[0] || "";

if (mode == "text-list-to-csv")
    text_list_to_csv(ARGV[1], ARGV[2]);
else if (mode == "csv-to-json-array")
    csv_to_json_array(ARGV[1]);
else if (mode == "csv-list-contains")
    exit(csv_list_contains(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "stdin-contains")
    exit(stdin_contains(ARGV[1]) ? 0 : 1);
else if (mode == "domain-subnet-text-csv")
    domain_subnet_text_csv(ARGV[1], ARGV[2]);
else if (mode == "domain-subnet-file-csv")
    domain_subnet_file_csv(ARGV[1], ARGV[2]);
else if (mode == "split-domain-subnet-file")
    split_domain_subnet_file(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "normalize-port-condition-for-nft")
    normalize_port_condition_for_nft(ARGV[1]);
else if (mode == "rule-ports-csv")
    rule_ports_csv(ARGV[1], ARGV[2]);
else if (mode == "rule-port-values-json")
    rule_port_values_json(ARGV[1]);
else if (mode == "rule-port-ranges-json")
    rule_port_ranges_json(ARGV[1]);
else if (mode == "csv-to-lines-file")
    csv_to_lines_file(ARGV[1], ARGV[2]);
else if (mode == "nft-prepare-chunks")
    nft_prepare_chunks(ARGV[1], ARGV[2], ARGV[3] || "", ARGV[4], ARGV[5], ARGV[6]);
else if (mode == "has-tproxy-marking-rule")
    exit(has_tproxy_marking_rule(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "has-local-default-route")
    exit(has_local_default_route() ? 0 : 1);
else if (mode == "file-regex-matches")
    file_regex_matches_exit(ARGV[1], ARGV[2]);
else {
    warn("Usage: rules_nft_runtime.uc <operation> ...\n");
    exit(1);
}
