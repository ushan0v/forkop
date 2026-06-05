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

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : data;
}

function read_stdin_json() {
    let data = read_stdin();
    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function file_has_cr(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return null;

    return index(data, "\r") >= 0;
}

function file_has_cr_exit(path) {
    let result = file_has_cr(path);
    exit(result == null ? 2 : (result ? 0 : 1));
}

function file_remove_cr(path) {
    path = as_string(path);
    let data = fs.readfile(path);
    if (data == null)
        return true;

    if (index(data, "\r") < 0)
        return true;

    let stamp = clock();
    let tmp_path = sprintf("%s.%d.%d.tmp", path, stamp[0], stamp[1]);
    if (!fs.writefile(tmp_path, replace(data, /\r/g, "")))
        return false;

    if (!fs.rename(tmp_path, path)) {
        fs.unlink(tmp_path);
        return false;
    }

    return true;
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

function valid_ipv4_octet(value) {
    value = as_string(value);
    return match(value, /^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)$/) != null;
}

function valid_ipv4(value) {
    value = as_string(value);

    let trailing_dot = length(value) > 0 && substr(value, length(value) - 1) == ".";
    if (trailing_dot)
        value = substr(value, 0, length(value) - 1);

    let parts = split(value, ".");
    if (length(parts) != 4)
        return false;

    for (let part in parts)
        if (!valid_ipv4_octet(part))
            return false;

    return true;
}

function valid_ipv4_cidr(value) {
    value = as_string(value);
    let slash = index(value, "/");
    if (slash < 0)
        return false;

    let ip = substr(value, 0, slash);
    let mask = substr(value, slash + 1);
    if (length(ip) > 0 && substr(ip, length(ip) - 1) == ".")
        return false;

    if (index(mask, "/") >= 0 || !valid_ipv4(ip))
        return false;

    if (mask == "" || match(mask, /[^0-9]/) != null)
        return false;

    let bits = int(mask);
    return bits >= 0 && bits <= 32;
}

function valid_domain(value) {
    return match(ascii_lower(value), /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/) != null;
}

function valid_domain_suffix(value) {
    value = as_string(value);
    if (substr(value, 0, 1) == ".")
        value = substr(value, 1);

    return valid_domain(value);
}

function digit_char(value) {
    return match(as_string(value), /^[0-9]$/) != null;
}

function strip_leading_zeroes(value) {
    value = as_string(value);
    let i = 0;
    while (i < length(value) - 1 && substr(value, i, 1) == "0")
        i++;
    return substr(value, i);
}

function version_compare(lhs, rhs) {
    lhs = as_string(lhs);
    rhs = as_string(rhs);

    let li = 0, ri = 0;
    while (li < length(lhs) || ri < length(rhs)) {
        if (li >= length(lhs))
            return substr(rhs, ri, 1) == "~" ? 1 : -1;
        if (ri >= length(rhs))
            return substr(lhs, li, 1) == "~" ? -1 : 1;

        let lc = substr(lhs, li, 1);
        let rc = substr(rhs, ri, 1);
        if (lc == rc) {
            li++;
            ri++;
            continue;
        }

        if (lc == "~" || rc == "~")
            return lc == "~" ? -1 : 1;

        if (digit_char(lc) && digit_char(rc)) {
            let ls = li, rs = ri;
            while (li < length(lhs) && digit_char(substr(lhs, li, 1)))
                li++;
            while (ri < length(rhs) && digit_char(substr(rhs, ri, 1)))
                ri++;

            let lnum = strip_leading_zeroes(substr(lhs, ls, li - ls));
            let rnum = strip_leading_zeroes(substr(rhs, rs, ri - rs));
            if (length(lnum) != length(rnum))
                return length(lnum) < length(rnum) ? -1 : 1;
            if (lnum != rnum)
                return lnum < rnum ? -1 : 1;
            continue;
        }

        return lc < rc ? -1 : 1;
    }

    return 0;
}

function version_at_least(current, required) {
    return version_compare(current, required) >= 0;
}

function first_index_any(value, needles, start) {
    value = as_string(value);
    start = int(start || 0);

    for (let i = start; i < length(value); i++) {
        let c = substr(value, i, 1);
        for (let needle in needles)
            if (c == needle)
                return i;
    }

    return -1;
}

function strip_anchored_scheme(value) {
    value = as_string(value);
    let marker = index(value, "://");
    if (marker < 0)
        return value;

    let prefix = substr(value, 0, marker);
    if (index(prefix, "/") >= 0 || index(prefix, "?") >= 0)
        return value;

    return substr(value, marker + 3);
}

function strip_first_scheme_marker(value) {
    value = as_string(value);
    let marker = index(value, "://");
    return marker >= 0 ? substr(value, marker + 3) : value;
}

function str_last_index(value, needle) {
    value = as_string(value);
    needle = as_string(needle);
    if (needle == "")
        return length(value);

    for (let i = length(value) - length(needle); i >= 0; i--)
        if (substr(value, i, length(needle)) == needle)
            return i;

    return -1;
}

function url_get_scheme(value) {
    value = as_string(value);
    let marker = index(value, "://");
    print(marker >= 0 ? substr(value, 0, marker) : value, "\n");
}

function url_get_userinfo(value) {
    value = strip_anchored_scheme(value);
    let at = index(value, "@");
    if (at >= 0)
        print(substr(value, 0, at), "\n");
}

function url_authority(value) {
    value = strip_first_scheme_marker(value);
    let at = index(value, "@");
    if (at >= 0)
        value = substr(value, at + 1);

    let end = first_index_any(value, ["/", "?", "#"], 0);
    return end >= 0 ? substr(value, 0, end) : value;
}

function url_get_host(value) {
    let authority = url_authority(value);
    let colon = index(authority, ":");
    print(colon >= 0 ? substr(authority, 0, colon) : authority, "\n");
}

function url_get_port(value) {
    let authority = url_authority(value);
    let colon = index(authority, ":");
    print(colon >= 0 ? substr(authority, colon + 1) : "", "\n");
}

function url_get_path(value) {
    value = strip_anchored_scheme(value);
    let slash = index(value, "/");
    value = slash >= 0 ? substr(value, slash) : "";

    let query = index(value, "?");
    if (query >= 0)
        value = substr(value, 0, query);

    print(value, "\n");
}

function url_get_query_param(value, param) {
    value = as_string(value);
    param = as_string(param);
    let result = null;

    for (let i = 0; i < length(value); i++) {
        let separator = substr(value, i, 1);
        if (separator != "?" && separator != "&")
            continue;

        let prefix_start = i + 1;
        if (substr(value, prefix_start, length(param) + 1) != param + "=")
            continue;

        let value_start = prefix_start + length(param) + 1;
        let value_end = first_index_any(value, ["&", "?", "#"], value_start);
        result = value_end >= 0 ? substr(value, value_start, value_end - value_start) : substr(value, value_start);
    }

    print(result != null ? result : "", "\n");
}

function url_file_extension(value) {
    let basename = as_string(value);
    let slash = str_last_index(basename, "/");
    if (slash >= 0)
        basename = substr(basename, slash + 1);

    let query = index(basename, "?");
    if (query >= 0)
        basename = substr(basename, 0, query);

    let fragment = index(basename, "#");
    if (fragment >= 0)
        basename = substr(basename, 0, fragment);

    let dot = str_last_index(basename, ".");
    if (dot >= 0)
        print(substr(basename, dot + 1), "\n");
    else
        print("\n");
}

function url_strip_fragment(value) {
    value = as_string(value);
    let fragment = index(value, "#");
    print(fragment >= 0 ? substr(value, 0, fragment) : value, "\n");
}

function normalize_strategy_whitespace(value) {
    value = replace(as_string(value), /[\t\r\n]/g, " ");
    value = replace(value, / +/g, " ");
    value = replace(value, /^ /, "");
    value = replace(value, / $/, "");
    print(value);
}

function strip_list_comment(line) {
    line = replace(as_string(line), /[[:space:]]*\/\/.*$/, "");
    return replace(line, /[[:space:]]*#.*$/, "");
}

function print_lines(values) {
    for (let value in values)
        print(as_string(value), "\n");
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

function text_list_to_lines(value, separator_mode) {
    print_lines(text_list_values(value, separator_mode));
}

function stdin_lines_to_json_array() {
    let input = read_stdin();
    if (input == "") {
        print("[]\n");
        return;
    }

    if (substr(input, length(input) - 1) == "\n")
        input = substr(input, 0, length(input) - 1);

    write_compact_string_array(split(input, "\n"));
}

function network_status_ipv4_address() {
    let value = read_stdin_json();
    if (type(value) != "object")
        return;

    let addresses = value["ipv4-address"];
    if (type(addresses) != "array" || length(addresses) == 0 || type(addresses[0]) != "object")
        return;

    let address = as_string(addresses[0].address || "");
    if (address != "")
        print(address, "\n");
}

function stdin_first_line_last_field() {
    let input = read_stdin();
    if (input == "")
        return;

    let newline = index(input, "\n");
    let line = newline >= 0 ? substr(input, 0, newline) : input;
    let trimmed = trim(line);
    if (trimmed == "") {
        print(line, "\n");
        return;
    }

    let fields = split(trimmed, /[ \t\r\n]+/);
    if (length(fields) > 0 && fields[0] != "")
        print(fields[length(fields) - 1], "\n");
    else
        print("\n");
}

function stdin_trim_string() {
    print(trim(read_stdin()), "\n");
}

function whitespace_list_contains(list, needle) {
    needle = as_string(needle);
    for (let item in split(trim(as_string(list)), /[ \t\r\n]+/))
        if (as_string(item) == needle)
            return true;
    return false;
}

function md5sum_hex_prefix(prefix_length) {
    let input = read_stdin();
    let newline = index(input, "\n");
    let line = newline >= 0 ? substr(input, 0, newline) : input;
    let fields = split(trim(as_string(line)), /[ \t\r\n]+/);
    let hash = length(fields) > 0 ? as_string(fields[0]) : "";

    prefix_length = int(prefix_length || 0);
    if (prefix_length > 0)
        print(substr(hash, 0, prefix_length), "\n");
}

function md5sum_hwid() {
    let input = read_stdin();
    let newline = index(input, "\n");
    let line = newline >= 0 ? substr(input, 0, newline) : input;
    let fields = split(trim(as_string(line)), /[ \t\r\n]+/);
    let hash = length(fields) > 0 ? substr(as_string(fields[0]), 0, 16) : "";

    print(
        substr(hash, 0, 4), "-",
        substr(hash, 4, 4), "-",
        substr(hash, 8, 4), "-",
        substr(hash, 12, 4), "\n"
    );
}

function tag_is_reserved(tag, reserved) {
    tag = as_string(tag);
    for (let value in reserved)
        if (tag == as_string(value))
            return true;
    return false;
}

function allocate_runtime_tag(base, postfix) {
    base = as_string(base);
    postfix = as_string(postfix);
    let reserved = slice(ARGV, 3);
    let candidate = base + "-" + postfix;
    let suffix = 1;

    if (match(base, /-[0-9]/) != null) {
        let dash = str_last_index(base, "-");
        let parent = dash >= 0 ? substr(base, 0, dash) : base;
        if (tag_is_reserved(parent + "-" + postfix, reserved)) {
            candidate = base + "-" + suffix + "-" + postfix;
            suffix++;
        }
    }

    while (tag_is_reserved(candidate, reserved)) {
        candidate = base + "-" + suffix + "-" + postfix;
        suffix++;
    }

    print(candidate, "\n");
}

function sing_box_version_is_extended(value) {
    return index(as_string(value), "extended") >= 0;
}

let mode = ARGV[0] || "";

if (mode == "stdin-lines-to-json-array")
    stdin_lines_to_json_array();
else if (mode == "file-has-cr")
    file_has_cr_exit(ARGV[1]);
else if (mode == "file-remove-cr")
    exit(file_remove_cr(ARGV[1]) ? 0 : 1);
else if (mode == "valid-ipv4")
    exit(valid_ipv4(ARGV[1]) ? 0 : 1);
else if (mode == "valid-ipv4-cidr")
    exit(valid_ipv4_cidr(ARGV[1]) ? 0 : 1);
else if (mode == "valid-domain")
    exit(valid_domain(ARGV[1]) ? 0 : 1);
else if (mode == "valid-domain-suffix")
    exit(valid_domain_suffix(ARGV[1]) ? 0 : 1);
else if (mode == "version-at-least")
    exit(version_at_least(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "network-status-ipv4-address")
    network_status_ipv4_address();
else if (mode == "stdin-first-line-last-field")
    stdin_first_line_last_field();
else if (mode == "stdin-trim-string")
    stdin_trim_string();
else if (mode == "whitespace-list-contains")
    exit(whitespace_list_contains(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "md5sum-hex-prefix")
    md5sum_hex_prefix(ARGV[1]);
else if (mode == "md5sum-hwid")
    md5sum_hwid();
else if (mode == "allocate-runtime-tag")
    allocate_runtime_tag(ARGV[1], ARGV[2]);
else if (mode == "sing-box-version-is-extended")
    exit(sing_box_version_is_extended(ARGV[1]) ? 0 : 1);
else if (mode == "url-get-scheme")
    url_get_scheme(ARGV[1]);
else if (mode == "url-get-userinfo")
    url_get_userinfo(ARGV[1]);
else if (mode == "url-get-host")
    url_get_host(ARGV[1]);
else if (mode == "url-get-port")
    url_get_port(ARGV[1]);
else if (mode == "url-get-path")
    url_get_path(ARGV[1]);
else if (mode == "url-get-query-param")
    url_get_query_param(ARGV[1], ARGV[2]);
else if (mode == "url-file-extension")
    url_file_extension(ARGV[1]);
else if (mode == "url-strip-fragment")
    url_strip_fragment(ARGV[1]);
else if (mode == "normalize-strategy-whitespace")
    normalize_strategy_whitespace(ARGV[1]);
else if (mode == "text-list-to-lines")
    text_list_to_lines(ARGV[1], ARGV[2]);
else {
    warn("Usage: helpers.uc <operation> ...\n");
    exit(1);
}
