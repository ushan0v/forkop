#!/usr/bin/env ucode

let fs = require("fs");
let ip = require("core.ip");
let domain_config = require("config.domain");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function json_decode_text(text) {
    try {
        return json(as_string(text));
    }
    catch (e) {
        return null;
    }
}

function read_json_file(path) {
    let data = fs.readfile(path);
    return data == null ? null : json_decode_text(data);
}

function write_text_file(path, text) {
    let result = fs.writefile(path, text);
    if (result == null)
        return false;
    if (type(result) == "boolean" && !result)
        return false;
    return true;
}

function write_json_file(path, value) {
    return write_text_file(path, sprintf("%J", value) + "\n");
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function array_from_value(value) {
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;
    return [ value ];
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function trim_string(value) {
    let text = as_string(value);
    let start_match = match(text, /^[ \t\r\n]*/);
    let start = start_match ? length(start_match[0]) : 0;
    let end = length(text);

    while (end > start && match(substr(text, end - 1, 1), /[ \t\r\n]/))
        end--;

    return substr(text, start, end - start);
}

function sort_values(values) {
    sort(values, function(first, second) {
        first = sprintf("%J", first);
        second = sprintf("%J", second);
        return first == second ? 0 : (first < second ? -1 : 1);
    });
    return values;
}

function unique_values(values) {
    values = sort_values(values);
    let result = [];
    let previous = null;
    let has_previous = false;

    for (let value in values) {
        let encoded = sprintf("%J", value);
        if (!has_previous || encoded != previous) {
            push(result, value);
            previous = encoded;
            has_previous = true;
        }
    }

    return result;
}

function create_source(path) {
    if (!write_json_file(path, { version: 3, rules: [] }))
        exit(1);
}

function ruleset_tag(section, name, kind) {
    kind = as_string(kind);
    return kind == ""
        ? as_string(section) + "-" + as_string(name) + "-ruleset"
        : as_string(section) + "-" + as_string(name) + "-" + kind + "-ruleset";
}

function patch_source_values(path, key, values) {
    let ruleset = object_or_empty(read_json_file(path));
    values = array_or_empty(values);

    if (type(ruleset.rules) != "array")
        ruleset.rules = [];

    let found = false;
    for (let rule in ruleset.rules) {
        if (type(rule) == "object" && rule[key] != null) {
            let merged = [];
            for (let item in array_or_empty(rule[key]))
                push(merged, item);
            for (let item in values)
                push(merged, item);
            rule[key] = unique_values(merged);
            found = true;
            break;
        }
    }

    if (!found) {
        let rule = {};
        rule[key] = values;
        push(ruleset.rules, rule);
    }

    if (!write_json_file(path, ruleset))
        exit(1);
}

function patch_source(path, key, value_text) {
    patch_source_values(path, key, json_decode_text(value_text));
}

function normalize_plain_ruleset_value(value, kind) {
    if (kind == "domains")
        return domain_config.suffix_to_ascii(value);
    if (kind == "subnets")
        return ip.nft_ip_or_cidr(value) ? value : null;

    return null;
}

function write_optional_lines(path, lines) {
    if (path == null || path == "")
        return;

    if (!write_text_file(path, length(lines) > 0 ? join("\n", lines) + "\n" : ""))
        exit(1);
}

function import_plain_list(plain_path, ruleset_path, key, kind, chunk_size_text, invalid_path, counts_path) {
    let data = fs.readfile(plain_path);
    if (data == null)
        exit(1);

    let chunk_size = int(chunk_size_text || 5000);
    if (chunk_size < 1)
        chunk_size = 5000;

    let chunk = [];
    let invalid = [];
    let counts = [];

    for (let line in split(as_string(data), "\n")) {
        line = trim_string(line);

        if (line == "")
            continue;

        let normalized = normalize_plain_ruleset_value(line, kind);
        if (normalized == null) {
            push(invalid, line);
            continue;
        }

        push(chunk, normalized);

        if (length(chunk) == chunk_size) {
            push(counts, "" + length(chunk));
            patch_source_values(ruleset_path, key, chunk);
            chunk = [];
        }
    }

    if (length(chunk) > 0) {
        push(counts, "" + length(chunk));
        patch_source_values(ruleset_path, key, chunk);
    }

    write_optional_lines(invalid_path, invalid);
    write_optional_lines(counts_path, counts);
}

function extract_ip_cidr(json_path, output_path) {
    let ruleset = object_or_empty(read_json_file(json_path));
    let lines = [];

    for (let rule in array_or_empty(ruleset.rules)) {
        if (type(rule) != "object")
            continue;
        for (let ip in array_or_empty(rule.ip_cidr))
            push(lines, as_string(ip));
    }

    if (!write_text_file(output_path, length(lines) > 0 ? join("\n", lines) + "\n" : ""))
        exit(1);
}

function parse_port_number(value) {
    let text = trim_string(value);
    if (text == "" || match(text, /[^0-9]/))
        return null;

    let number = int(text);
    if (number < 1 || number > 65535)
        return null;

    return number;
}

function parse_port_interval(value, allow_open) {
    let text = trim_string(value);
    if (text == "")
        return null;

    let separator = index(text, ":") >= 0 ? ":" : (index(text, "-") >= 0 ? "-" : "");
    if (separator == "") {
        let port = parse_port_number(text);
        return port == null ? null : { start: port, end: port };
    }

    let parts = split(text, separator);
    if (length(parts) != 2)
        return null;

    let start = parts[0] == "" && allow_open ? 1 : parse_port_number(parts[0]);
    let end = parts[1] == "" && allow_open ? 65535 : parse_port_number(parts[1]);

    if (start == null || end == null || start > end)
        return null;

    return { start, end };
}

function normalize_port_intervals(intervals) {
    let sorted = [];
    for (let interval in array_or_empty(intervals)) {
        if (type(interval) == "object" && interval.start != null && interval.end != null)
            push(sorted, { start: int(interval.start), end: int(interval.end) });
    }

    sort(sorted, function(first, second) {
        if (first.start == second.start)
            return first.end - second.end;
        return first.start - second.start;
    });

    let result = [];
    for (let interval in sorted) {
        if (length(result) == 0) {
            push(result, interval);
            continue;
        }

        let last = result[length(result) - 1];
        if (interval.start <= last.end + 1) {
            if (interval.end > last.end)
                last.end = interval.end;
        }
        else {
            push(result, interval);
        }
    }

    return result;
}

function direct_port_filter(rule) {
    if (type(rule) != "object")
        return null;

    let intervals = [];
    for (let port in array_from_value(rule.port)) {
        let interval = parse_port_interval(port, false);
        if (interval != null)
            push(intervals, interval);
    }

    for (let port_range in array_from_value(rule.port_range)) {
        let interval = parse_port_interval(port_range, true);
        if (interval != null)
            push(intervals, interval);
    }

    return length(intervals) == 0 ? null : normalize_port_intervals(intervals);
}

function filter_is_empty(filter) {
    return type(filter) == "array" && length(filter) == 0;
}

function intersect_port_filters(first, second) {
    if (first == null)
        return second;
    if (second == null)
        return first;
    if (filter_is_empty(first) || filter_is_empty(second))
        return [];

    let result = [];
    for (let left in first) {
        for (let right in second) {
            let start = left.start > right.start ? left.start : right.start;
            let end = left.end < right.end ? left.end : right.end;
            if (start <= end)
                push(result, { start, end });
        }
    }

    return normalize_port_intervals(result);
}

function union_port_filters(first, second) {
    if (first == null || second == null)
        return null;

    let result = [];
    for (let item in first)
        push(result, item);
    for (let item in second)
        push(result, item);

    return normalize_port_intervals(result);
}

function extract_port_filter(rule) {
    if (type(rule) != "object")
        return null;

    let own_filter = direct_port_filter(rule);
    if (rule.type != "logical" || type(rule.rules) != "array")
        return own_filter;

    let mode = as_string(rule.mode);
    if (mode == "or") {
        let result = null;
        let initialized = false;

        for (let child in rule.rules) {
            let child_filter = extract_port_filter(child);
            if (!initialized) {
                result = child_filter;
                initialized = true;
            }
            else {
                result = union_port_filters(result, child_filter);
            }

            if (result == null)
                break;
        }

        return intersect_port_filters(own_filter, result);
    }

    let result = own_filter;
    for (let child in rule.rules) {
        result = intersect_port_filters(result, extract_port_filter(child));
        if (filter_is_empty(result))
            return result;
    }

    return result;
}

function nft_port_value(interval) {
    return interval.start == interval.end ? "" + interval.start : interval.start + "-" + interval.end;
}

function add_line(lines, value) {
    if (value != "")
        lines[value] = true;
}

function add_ip_cidr_values_to_nft_outputs(rule, port_filter, unscoped_lines, scoped_lines) {
    for (let ip in array_from_value(rule.ip_cidr)) {
        ip = trim_string(ip);
        if (ip == "")
            continue;

        if (port_filter == null) {
            add_line(unscoped_lines, ip);
            continue;
        }

        if (filter_is_empty(port_filter))
            continue;

        for (let interval in port_filter)
            add_line(scoped_lines, ip + " . " + nft_port_value(interval));
    }
}

function collect_ip_cidr_nft_outputs(rule, inherited_filter, unscoped_lines, scoped_lines) {
    if (type(rule) != "object")
        return;

    let own_filter = direct_port_filter(rule);
    let filter = intersect_port_filters(inherited_filter, own_filter);

    if (filter_is_empty(filter))
        return;

    if (rule.type == "logical" && type(rule.rules) == "array") {
        if (as_string(rule.mode) == "and") {
            for (let child in rule.rules) {
                filter = intersect_port_filters(filter, extract_port_filter(child));
                if (filter_is_empty(filter))
                    return;
            }
        }

        add_ip_cidr_values_to_nft_outputs(rule, filter, unscoped_lines, scoped_lines);

        for (let child in rule.rules)
            collect_ip_cidr_nft_outputs(child, filter, unscoped_lines, scoped_lines);

        return;
    }

    add_ip_cidr_values_to_nft_outputs(rule, filter, unscoped_lines, scoped_lines);
}

function write_lines(path, lines_object) {
    let lines = keys(lines_object);
    sort(lines, function(first, second) {
        return first == second ? 0 : (first < second ? -1 : 1);
    });

    if (!write_text_file(path, length(lines) > 0 ? join("\n", lines) + "\n" : ""))
        exit(1);
}

function extract_ip_cidr_nft_elements(json_path, unscoped_output_path, scoped_output_path, ports_text, port_ranges_text) {
    let ruleset = object_or_empty(read_json_file(json_path));
    let unscoped_lines = {};
    let scoped_lines = {};
    let outer_filter = direct_port_filter({
        port: array_or_empty(json_decode_text(ports_text)),
        port_range: array_or_empty(json_decode_text(port_ranges_text))
    });

    for (let rule in array_or_empty(ruleset.rules))
        collect_ip_cidr_nft_outputs(rule, outer_filter, unscoped_lines, scoped_lines);

    write_lines(unscoped_output_path, unscoped_lines);
    write_lines(scoped_output_path, scoped_lines);
}

function value_has_domain_matchers(value) {
    if (type(value) == "array") {
        for (let item in value) {
            if (value_has_domain_matchers(item))
                return true;
        }
        return false;
    }

    if (type(value) != "object")
        return false;

    for (let key, item in value) {
        if (key == "domain" || key == "domain_suffix" || key == "domain_keyword" || key == "domain_regex") {
            if (type(item) == "array" && length(item) > 0)
                return true;
            if (type(item) == "string" && item != "")
                return true;
        }

        if (value_has_domain_matchers(item))
            return true;
    }

    return false;
}

function has_domain_matchers(path) {
    return value_has_domain_matchers(read_json_file(path));
}

function has_rules(path) {
    let ruleset = object_or_empty(read_json_file(path));
    return length(array_or_empty(ruleset.rules)) > 0;
}

function module_exports() {
    return {
        create_source,
        patch_source,
        patch_source_values,
        import_plain_list,
        extract_ip_cidr,
        extract_ip_cidr_nft_elements,
        has_domain_matchers,
        has_rules,
        ruleset_tag,
        read_json_file,
        write_json_file
    };
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return module_exports();

let mode = ARGV[0] || "";

if (mode == "create-source")
    create_source(ARGV[1]);
else if (mode == "tag")
    print(ruleset_tag(ARGV[1], ARGV[2], ARGV[3]), "\n");
else if (mode == "patch-source")
    patch_source(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "import-plain-list")
    import_plain_list(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]);
else if (mode == "extract-ip-cidr")
    extract_ip_cidr(ARGV[1], ARGV[2]);
else if (mode == "extract-ip-cidr-nft")
    extract_ip_cidr_nft_elements(ARGV[1], ARGV[2], ARGV[3], ARGV[4] || "[]", ARGV[5] || "[]");
else if (mode == "has-domain-matchers")
    exit(has_domain_matchers(ARGV[1]) ? 0 : 1);
else if (mode == "has-rules")
    exit(has_rules(ARGV[1]) ? 0 : 1);
else {
    warn("Usage: routing/rulesets.uc <create-source|tag|patch-source|import-plain-list|extract-ip-cidr|extract-ip-cidr-nft|has-domain-matchers|has-rules> ...\n");
    exit(1);
}
