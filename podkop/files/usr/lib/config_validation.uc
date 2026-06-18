#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
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

function string_starts_with(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
}

function uci_show_list_value(value) {
    return trim(replace(as_string(value), /['"]/g, ""));
}

function stdin_first_line_field(field_index) {
    let data = read_stdin();
    let newline = index(data, "\n");
    let line = newline >= 0 ? substr(data, 0, newline) : data;
    let fields = split(trim(as_string(line)), /[ \t\r\n]+/);

    field_index = int(field_index || 0);
    if (field_index > 0 && field_index <= length(fields))
        print(fields[field_index - 1], "\n");
}

function shell_single_quote(value) {
    value = as_string(value);
    if (value == "")
        return;
    print("'", replace(value, /'/g, "'\\''"), "'\n");
}

function country_code_valid(value) {
    value = uc(as_string(value));
    return match(value, /^[A-Z][A-Z]$/) != null;
}

function enum_valid(value, start_index) {
    value = as_string(value);
    for (let i = start_index; i < length(ARGV); i++)
        if (value == as_string(ARGV[i]))
            return true;
    return false;
}

function regex_valid(pattern) {
    pattern = as_string(pattern);
    if (pattern == "")
        return true;

    try {
        regexp(pattern);
        return true;
    }
    catch (e) {
        return false;
    }
}

function strip_list_comment(line) {
    line = replace(as_string(line), /[[:space:]]*\/\/.*$/, "");
    return replace(line, /[[:space:]]*#.*$/, "");
}

function text_list_values(value) {
    let result = [];

    for (let line in split(as_string(value), "\n")) {
        line = replace(strip_list_comment(line), /[ ,]/g, "\n");
        for (let item in split(line, "\n")) {
            item = trim(replace(item, /\r/g, ""));
            if (item != "")
                push(result, item);
        }
    }

    return result;
}

function valid_domain_suffix(value) {
    value = lc(as_string(value));
    if (substr(value, 0, 1) == ".")
        value = substr(value, 1);

    return match(value, /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/) != null;
}

function combined_domain_valid(value) {
    value = trim(as_string(value));
    if (value == "")
        return true;

    let colon = index(value, ":");
    if (colon < 0)
        return valid_domain_suffix(value);

    let prefix = lc(substr(value, 0, colon));
    let body = substr(value, colon + 1);

    if (body == "")
        return false;

    if (prefix == "full")
        return valid_domain_suffix(body);

    if (prefix == "keyword")
        return match(body, /[,[:space:]]/) == null;

    if (prefix == "regex")
        return match(body, /[,[:space:]]/) == null && regex_valid(body);

    return false;
}

function combined_domain_text_valid(value) {
    for (let item in text_list_values(value))
        if (!combined_domain_valid(item))
            return false;
    return true;
}

function valid_outbound() {
    let value = read_stdin_json();
    return type(value) == "object" && type(value.type) == "string";
}

function outbound_detour_supported() {
    let value = read_stdin_json();
    if (type(value) != "object" || type(value.type) != "string")
        return false;

    let outbound_type = lc(as_string(value.type));
    return outbound_type != "selector" &&
        outbound_type != "urltest" &&
        outbound_type != "block" &&
        outbound_type != "dns";
}

function dhcp_has_https_dns_proxy_options(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return null;

    return index(data, "doh_backup_noresolv") >= 0 ||
        index(data, "doh_backup_server") >= 0 ||
        index(data, "doh_server") >= 0;
}

function dhcp_has_https_dns_proxy_options_exit(path) {
    let result = dhcp_has_https_dns_proxy_options(path);
    exit(result == null ? 2 : (result ? 0 : 1));
}

function mwan3_has_enabled_interface() {
    let prefix = "mwan3.";
    let sections = {};
    let enabled = {};

    for (let line in split(read_stdin(), "\n")) {
        let equals = index(as_string(line), "=");
        if (equals < 0)
            continue;

        let key = substr(line, 0, equals);
        let value = uci_show_list_value(substr(line, equals + 1));
        if (!string_starts_with(key, prefix))
            continue;

        let rest = substr(key, length(prefix));
        if (index(rest, ".") < 0) {
            if (value == "interface")
                sections[key] = true;
            continue;
        }

        let option_dot = rindex(key, ".");
        let section = substr(key, 0, option_dot);
        let option = substr(key, option_dot + 1);
        if (option == "enabled")
            enabled[section] = value;
    }

    for (let section, _ in sections)
        if (enabled[section] == "1")
            return true;

    return false;
}

let mode = ARGV[0] || "";

if (mode == "stdin-first-line-field")
    stdin_first_line_field(ARGV[1]);
else if (mode == "shell-single-quote")
    shell_single_quote(ARGV[1]);
else if (mode == "country-code-valid")
    exit(country_code_valid(ARGV[1]) ? 0 : 1);
else if (mode == "enum-valid")
    exit(enum_valid(ARGV[1], 2) ? 0 : 1);
else if (mode == "regex-valid")
    exit(regex_valid(ARGV[1]) ? 0 : 1);
else if (mode == "combined-domain-valid")
    exit(combined_domain_valid(ARGV[1]) ? 0 : 1);
else if (mode == "combined-domain-text-valid")
    exit(combined_domain_text_valid(ARGV[1]) ? 0 : 1);
else if (mode == "valid-outbound")
    exit(valid_outbound() ? 0 : 1);
else if (mode == "outbound-detour-supported")
    exit(outbound_detour_supported() ? 0 : 1);
else if (mode == "dhcp-has-https-dns-proxy-options")
    dhcp_has_https_dns_proxy_options_exit(ARGV[1]);
else if (mode == "mwan3-has-enabled-interface")
    exit(mwan3_has_enabled_interface() ? 0 : 1);
else {
    warn("Usage: config_validation.uc <operation> ...\n");
    exit(1);
}
