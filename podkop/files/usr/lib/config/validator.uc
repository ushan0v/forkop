#!/usr/bin/env ucode

let fs = require("fs");
let uci_core_module = null;
let fixture_uci_data = null;
let subscription_parser_module = null;
let zapret_validator_module = null;
let zapret2_validator_module = null;
let byedpi_validator_module = null;
let constants_module = null;
let core_url = require("core.url");
let rule_config = require("config.rule");
let connections = require("config.connections");

const CONFIG_NAME = getenv("PODKOP_CONFIG_NAME") || "podkop-plus";
const DEFAULT_LATENCY_TEST_URL = "https://www.gstatic.com/generate_204";

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

function read_json_file(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return null;

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

function string_ends_with(value, suffix) {
    value = as_string(value);
    suffix = as_string(suffix);
    return length(value) >= length(suffix) && substr(value, length(value) - length(suffix)) == suffix;
}

function whitespace_values(value) {
    let result = [];
    for (let item in split(trim(as_string(value)), /[ \t\r\n]+/))
        if (item != "")
            push(result, item);
    return result;
}

function list_has_value(values, needle) {
    needle = as_string(needle);
    if (needle == "")
        return false;

    for (let value in whitespace_values(values))
        if (value == needle)
            return true;

    return false;
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function contains(values, needle) {
    for (let value in array_or_empty(values))
        if (value == needle)
            return true;
    return false;
}

function option(section, key, fallback) {
    if (fallback == null)
        fallback = "";

    let value = object_or_empty(section)[key];
    if (value == null)
        return fallback;
    if (type(value) == "array")
        return join(" ", value);
    return as_string(value);
}

function list_option(section, key) {
    let value = object_or_empty(section)[key];
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;

    value = trim(as_string(value));
    return value == "" ? [] : split(value, " ");
}

function bool_option(section, key, fallback) {
    if (fallback == null)
        fallback = false;

    let value = option(section, key, fallback ? "1" : "0");
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function file_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function file_executable(path) {
    let stat = fs.stat(as_string(path));
    if (stat == null || stat.mode == null)
        return false;

    return (int(stat.mode) & 73) != 0;
}

function file_nonempty(path) {
    let stat = fs.stat(as_string(path));
    return stat != null && stat.size != null && stat.size > 0;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];

    for (let arg in args)
        push(parts, shell_quote(arg));

    return join(" ", parts);
}

function run_args(args) {
    return system(command_from_args(args)) == 0;
}

function command_success_from_args(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function command_output(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";

    return as_string(data);
}

function command_output_from_args(args) {
    return command_output(command_from_args(args));
}

function command_trimmed_output_from_args(args) {
    return replace(command_output_from_args(args), /[\r\n]+$/g, "");
}

function command_exists(name) {
    return system("command -v " + shell_quote(name) + " >/dev/null 2>&1") == 0;
}

function log_message(message, level) {
    level = as_string(level || "info");
    run_args([ "logger", "-t", "podkop-plus", "[" + level + "] " + as_string(message) ]);
}

function fail_requirement(message, level) {
    log_message(message, level || "error");
    exit(1);
}

function mkdir_p(paths) {
    let args = [ "mkdir", "-p" ];

    for (let path in array_or_empty(paths))
        if (as_string(path) != "")
            push(args, path);

    return length(args) <= 2 || run_args(args);
}

function safe_rm_rf(path) {
    path = as_string(path);
    if (path == "" || substr(path, 0, length("/var/run/podkop-plus/")) != "/var/run/podkop-plus/")
        return true;

    return run_args([ "rm", "-rf", path ]);
}

function first_line_field_from_text(data, field_index) {
    let newline = index(as_string(data), "\n");
    let line = newline >= 0 ? substr(data, 0, newline) : data;
    let fields = split(trim(as_string(line)), /[ \t\r\n]+/);

    field_index = int(field_index || 0);
    return field_index > 0 && field_index <= length(fields) ? as_string(fields[field_index - 1]) : "";
}

function first_line_last_field(data) {
    let newline = index(as_string(data), "\n");
    let line = newline >= 0 ? substr(data, 0, newline) : data;
    let fields = split(trim(as_string(line)), /[ \t\r\n]+/);
    return length(fields) > 0 ? as_string(fields[length(fields) - 1]) : "";
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

function constant_value(constants, name) {
    return as_string(object_or_empty(constants)[name]);
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

function combined_domain_valid(value) {
    value = trim(as_string(value));
    if (value == "")
        return true;

    let normalized = rule_config.prefixed_domain_kind_value(value);
    if (normalized == null)
        return false;

    return normalized.kind != "domain_regex" || regex_valid(normalized.value);
}

function combined_domain_text_valid(value) {
    for (let item in text_list_values(value))
        if (!combined_domain_valid(item))
            return false;
    return true;
}

function community_service_valid(value, services) {
    return list_has_value(services, value);
}

function remote_reference(value) {
    return string_starts_with(value, "http://") || string_starts_with(value, "https://");
}

function absolute_reference_with_extension(value, first_extension, second_extension) {
    value = as_string(value);
    if (!string_starts_with(value, "/"))
        return false;

    return string_ends_with(value, first_extension) ||
        (second_extension != null && string_ends_with(value, second_extension));
}

function ruleset_reference_valid(reference, community_services) {
    reference = as_string(reference);

    return reference == "" ||
        community_service_valid(reference, community_services) ||
        remote_reference(reference) ||
        absolute_reference_with_extension(reference, ".srs", ".json");
}

function plain_domain_ip_list_reference_valid(reference) {
    reference = as_string(reference);

    return reference == "" ||
        remote_reference(reference) ||
        absolute_reference_with_extension(reference, ".lst", null);
}

function valid_outbound() {
    let value = read_stdin_json();
    return type(value) == "object" && type(value.type) == "string";
}

function valid_inbound() {
    let value = read_stdin_json();
    return type(value) == "object" && type(value.type) == "string";
}

function bool_flag(value) {
    value = as_string(value);
    return value == "1" || value == "true";
}

function outbound_detour_source_action(action) {
    action = as_string(action);
    return connections.is_connections_action(action);
}

function outbound_detour_target_action(action) {
    action = as_string(action);
    return connections.is_connections_action(action);
}

function outbound_detour_rows() {
    let rows = [];

    for (let line in split(read_stdin(), "\n")) {
        line = replace(as_string(line), /\r/g, "");
        if (trim(line) == "")
            continue;

        let fields = split(line, "\t");
        let row = {
            section: as_string(fields[0]),
            enabled: bool_flag(fields[1]),
            action: as_string(fields[2]),
            detour_enabled: bool_flag(fields[3]),
            detour_section: as_string(fields[4])
        };

        push(rows, row);
    }

    return rows;
}

function outbound_detour_rows_by_section(rows) {
    let by_section = {};

    for (let row in array_or_empty(rows))
        if (row.section != "")
            by_section[row.section] = row;

    return {
        rows: rows,
        by_section: by_section
    };
}

function outbound_detour_chain_reaches_source(by_section, source_section, current_section) {
    let seen = {};

    while (current_section != "") {
        if (current_section == source_section)
            return true;

        if (seen[current_section])
            return false;
        seen[current_section] = true;

        let row = by_section[current_section];
        if (type(row) != "object" || !row.enabled || !outbound_detour_source_action(row.action))
            return false;

        if (!row.detour_enabled)
            return false;

        current_section = row.detour_section;
    }

    return false;
}

function fail_outbound_detour(message) {
    print(message, "\n");
    exit(1);
}

function fail_validation(message) {
    print(message, "\n");
    exit(1);
}

function validate_outbound_detours_rows(rows) {
    let parsed = outbound_detour_rows_by_section(rows);

    for (let row in parsed.rows) {
        if (!row.enabled || !row.detour_enabled)
            continue;

        if (!outbound_detour_source_action(row.action))
            fail_outbound_detour("Outbound cascade is supported only for Connection rules, but rule '" +
                row.section + "' uses action '" + row.action + "'. Aborted.");

        if (row.detour_section == "")
            fail_outbound_detour("Outbound cascade is enabled for rule '" + row.section +
                "', but no intermediate rule is selected. Aborted.");

        if (row.detour_section == row.section)
            fail_outbound_detour("Outbound cascade for rule '" + row.section + "' cannot point to itself. Aborted.");

        let target = parsed.by_section[row.detour_section];
        if (type(target) != "object")
            fail_outbound_detour("Outbound cascade for rule '" + row.section + "' references missing rule '" +
                row.detour_section + "'. Select an enabled Connection rule or disable cascade connection. Aborted.");

        if (!target.enabled)
            fail_outbound_detour("Outbound cascade for rule '" + row.section + "' references disabled rule '" +
                row.detour_section + "'. Select an enabled Connection rule or disable cascade connection. Aborted.");

        if (!outbound_detour_target_action(target.action))
            fail_outbound_detour("Outbound cascade for rule '" + row.section + "' references rule '" +
                row.detour_section + "', but it is not a Connection rule. Select an enabled Connection rule or disable cascade connection. Aborted.");

        if (outbound_detour_chain_reaches_source(parsed.by_section, row.section, row.detour_section))
            fail_outbound_detour("Outbound cascade for rule '" + row.section + "' creates a cycle through '" +
                row.detour_section + "'. Aborted.");

    }
}

function validate_outbound_detours() {
    validate_outbound_detours_rows(outbound_detour_rows());
}

function basic_rule_rows() {
    let rows = [];

    for (let line in split(read_stdin(), "\n")) {
        line = replace(as_string(line), /\r/g, "");
        if (trim(line) == "")
            continue;

        let fields = split(line, "\t");
        push(rows, {
            section: as_string(fields[0]),
            enabled: bool_flag(fields[1]),
            action: as_string(fields[2])
        });
    }

    return rows;
}

function download_section_action_available(action, byedpi_installed, zapret_installed, zapret2_installed) {
    action = as_string(action);
    if (connections.is_connections_action(action))
        return true;
    if (action == "byedpi")
        return bool_flag(byedpi_installed);
    if (action == "zapret")
        return bool_flag(zapret_installed);
    if (action == "zapret2")
        return bool_flag(zapret2_installed);

    return false;
}

function validate_download_section_rows(target_section, byedpi_installed, zapret_installed, zapret2_installed, rows) {
    target_section = as_string(target_section);

    if (target_section == "")
        fail_validation("Downloading external resources through a section is enabled, but no download section is selected. Aborted.");

    let found = false;
    let enabled = false;
    let outbound = false;

    for (let row in array_or_empty(rows)) {
        if (row.section != target_section)
            continue;

        found = true;
        if (!row.enabled)
            continue;

        enabled = true;
        if (download_section_action_available(row.action, byedpi_installed, zapret_installed, zapret2_installed))
            outbound = true;
    }

    if (!found)
        fail_validation("Downloading external resources through a section references missing rule '" + target_section +
            "'. Select an enabled rule that can provide an outbound or disable the option. Aborted.");

    if (!enabled)
        fail_validation("Downloading external resources through a section references disabled rule '" + target_section +
            "'. Select an enabled rule that can provide an outbound or disable the option. Aborted.");

    if (!outbound)
        fail_validation("Downloading external resources through a section references rule '" + target_section +
            "', but it cannot provide an outbound. Select an enabled Connection, Zapret, Zapret2, or ByeDPI rule with its provider installed, or disable the option. Aborted.");
}

function validate_download_section(target_section, byedpi_installed, zapret_installed, zapret2_installed) {
    validate_download_section_rows(target_section, byedpi_installed, zapret_installed, zapret2_installed, basic_rule_rows());
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

function mwan3_has_enabled_interface_text(data) {
    let prefix = "mwan3.";
    let sections = {};
    let enabled = {};

    for (let line in split(as_string(data), "\n")) {
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

function mwan3_has_enabled_interface() {
    return mwan3_has_enabled_interface_text(read_stdin());
}

function mwan3_has_enabled_interface_from_sections() {
    for (let section in uci_core().section_objects("mwan3", "interface"))
        if (option(section, "enabled", "0") == "1")
            return true;
    return false;
}

function mwan3_is_active() {
    if (!file_executable("/etc/init.d/mwan3") || !file_nonempty("/etc/config/mwan3"))
        return false;

    if (!mwan3_has_enabled_interface_from_sections())
        return false;

    return command_success_from_args([ "/etc/init.d/mwan3", "status" ]) ||
        command_success_from_args([ "/etc/init.d/mwan3", "enabled" ]);
}

function hex_digit_value(value) {
    let pos = index("0123456789abcdef", lc(as_string(value)));
    return pos >= 0 ? pos : null;
}

function parse_number(value) {
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

function subscription_parser() {
    if (subscription_parser_module == null)
        subscription_parser_module = require("subscription.parser");
    return subscription_parser_module;
}

function zapret_validator() {
    if (zapret_validator_module == null)
        zapret_validator_module = require("providers.zapret.validator");
    return zapret_validator_module;
}

function zapret2_validator() {
    if (zapret2_validator_module == null)
        zapret2_validator_module = require("providers.zapret2.validator");
    return zapret2_validator_module;
}

function byedpi_validator() {
    if (byedpi_validator_module == null)
        byedpi_validator_module = require("providers.byedpi.validator");
    return byedpi_validator_module;
}

function runtime_constants() {
    if (constants_module == null)
        constants_module = require("core.constants");
    return constants_module;
}

function uci_core() {
    if (uci_core_module == null)
        uci_core_module = require("core.uci");
    return uci_core_module;
}

function fixture_section_list(type_name) {
    let value = object_or_empty(fixture_uci_data)[type_name];
    if (type(value) == "array")
        return value;
    if (type(value) == "object")
        return [ value ];

    let plural = object_or_empty(fixture_uci_data)[type_name + "s"];
    return type(plural) == "array" ? plural : [];
}

function fixture_get_section(section_name) {
    let fixture = object_or_empty(fixture_uci_data);
    if (section_name == "settings" && type(fixture.settings) == "object")
        return fixture.settings;

    for (let type_name in [ "settings", "server", "section", "subscription_url", "urltest", "priority_group", "priority_level" ]) {
        for (let section in fixture_section_list(type_name)) {
            if (as_string(section[".name"]) == section_name)
                return section;
        }
    }

    return {};
}

function use_fixture_cursor(path) {
    fixture_uci_data = object_or_empty(read_json_file(path));
    connections.set_item_sections_from_data(fixture_uci_data);
}

function settings_section() {
    if (fixture_uci_data != null)
        return object_or_empty(fixture_get_section("settings"));
    return object_or_empty(uci_core().get_all(CONFIG_NAME, "settings"));
}

function sections_by_type(type_name) {
    if (fixture_uci_data != null)
        return fixture_section_list(type_name);

    let result = [];
    for (let section in uci_core().section_objects(CONFIG_NAME, type_name))
        push(result, object_or_empty(section));
    return result;
}

function section_name(section) {
    return option(section, ".name", "");
}

function section_enabled(section) {
    return bool_option(section, "enabled", true);
}

function server_enabled(section) {
    return bool_option(section, "enabled", false);
}

function rule_action(section) {
    return option(section, "action", "");
}

function rule_action_supported(action) {
    return contains([ "connection", "proxy", "outbound", "vpn", "bypass", "block", "zapret", "zapret2", "byedpi" ], as_string(action));
}

function server_routing_section_action_supported(action) {
    return contains([ "connection", "proxy", "outbound", "vpn", "zapret", "zapret2", "byedpi" ], as_string(action));
}

function duration_to_seconds_value(value) {
    let rest = as_string(value);
    if (rest == "")
        return null;

    let total = 0.0;
    let multipliers = {
        ns: 0.000000001,
        us: 0.000001,
        ms: 0.001,
        s: 1,
        m: 60,
        h: 3600,
        d: 86400
    };

    while (rest != "") {
        let matched = match(rest, /^([0-9]+(\.[0-9]+)?)(ns|us|ms|s|m|h|d)/);
        if (!matched)
            return null;

        let token = as_string(matched[0]);
        let amount = matched[1] * 1;
        let unit = matched[3];
        total += amount * multipliers[unit];
        rest = substr(rest, length(token));
    }

    return total <= 0 ? null : int(total + 0.5);
}

function validate_duration_option(value, label) {
    if (as_string(value) == "")
        return;

    if (duration_to_seconds_value(value) != null)
        return;

    fail_validation("Invalid duration value for " + label + ": " + value + ". Use sing-box duration format like 1d, 12h or 30m. Aborted.");
}

function validate_required_duration_option(value, label) {
    if (as_string(value) == "")
        fail_validation("Missing duration value for " + label + ". Use sing-box duration format like 1d, 12h or 30m. Aborted.");

    validate_duration_option(value, label);
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
    if (dash < 0)
        return normalize_port_number_value(value);

    let start = normalize_port_number_value(substr(value, 0, dash));
    let end = normalize_port_number_value(substr(value, dash + 1));
    if (start == null || end == null || start > end)
        return null;

    return start == end ? start : sprintf("%d-%d", start, end);
}

function validate_port_condition_value(value, section) {
    if (normalize_port_condition_value(value) != null)
        return;

    fail_validation("Invalid port condition '" + value + "' in rule '" + section + "'. Use a single port or range like 80 or 1000-2000. Aborted.");
}

function validate_subscription_source_entry_value(entry, section) {
    if (index(as_string(entry), "|") >= 0)
        fail_validation("Invalid subscription URL in rule '" + section + "': Configure User-Agent in the subscription item settings. Aborted.");

    let parsed = subscription_parser().parse_subscription_source_entry(entry);
    if (parsed.valid)
        return;

    fail_validation("Invalid subscription URL in rule '" + section + "': " + parsed.error + ". Aborted.");
}

function valid_http_url(value) {
    value = trim(as_string(value));
    if (value == "" || match(value, /[ \t\r\n]/) != null)
        return false;

    let scheme = lc(core_url.scheme(value));
    if (scheme != "http" && scheme != "https")
        return false;

    return core_url.host(value) != "";
}

function validate_http_url_option(value, label) {
    if (valid_http_url(value))
        return;

    fail_validation("Invalid URL value for " + label + ": " + value + ". Use http:// or https:// URL. Aborted.");
}

function validate_country_code_value(value, section) {
    if (as_string(value) == "" || country_code_valid(value))
        return;

    fail_validation("Invalid country code '" + value + "' in rule '" + section + "'. Aborted.");
}

function validate_urltest_filter_mode_value(value, section) {
    if (as_string(value) == "" || contains([ "disabled", "exclude", "include", "mixed" ], value))
        return;

    fail_validation("Invalid URLTest filter mode '" + value + "' in rule '" + section + "'. Aborted.");
}

function validate_priority_filter_mode_value(value, section, group_id, level_id) {
    if (contains([ "disabled", "exclude", "include", "mixed" ], value))
        return;

    fail_validation("Invalid Priority filter mode '" + value + "' in rule '" + section + "', priority '" + group_id + "', level '" + level_id + "'. Aborted.");
}

function validate_detect_server_country_value(value, section) {
    if (as_string(value) == "" || contains([ "flag_emoji", "country_is" ], value))
        return;

    fail_validation("Invalid server country detection mode '" + value + "' in rule '" + section + "'. Aborted.");
}

function validate_urltest_regex_value(value, section) {
    if (as_string(value) == "" || regex_valid(value))
        return;

    fail_validation("Invalid URLTest regular expression '" + value + "' in rule '" + section + "'. Aborted.");
}

function validate_urltest_identifier_value(value, section) {
    value = as_string(value);
    if (value != "" && match(value, /^[A-Za-z0-9_]+$/) != null)
        return;

    fail_validation("Invalid URLTest identifier '" + value + "' in rule '" + section + "'. Use latin letters, digits and underscores. Aborted.");
}

function validate_priority_identifier_value(value, section) {
    value = as_string(value);
    if (value != "" && match(value, /^[A-Za-z0-9_]+$/) != null)
        return;

    fail_validation("Invalid priority identifier '" + value + "' in rule '" + section + "'. Use latin letters, digits and underscores. Aborted.");
}

function validate_urltest_tolerance_value(value, section, urltest_id) {
    value = trim(as_string(value));
    if (match(value, /^[0-9]+$/) != null) {
        let parsed = int(value, 10);
        if (parsed >= 0 && parsed <= 10000)
            return;
    }

    fail_validation("Invalid URLTest tolerance '" + value + "' in rule '" + section + "', URLTest '" + urltest_id + "'. Use a number from 0 to 10000. Aborted.");
}

function validate_priority_level_order(value, section, group_id, level_id) {
    value = trim(as_string(value));
    if (match(value, /^[0-9]+$/) != null)
        return;

    fail_validation("Invalid priority level order '" + value + "' in rule '" + section + "', priority '" + group_id + "', level '" + level_id + "'. Use a non-negative integer. Aborted.");
}

function validate_priority_group(section, group_id) {
    let name = section_name(section);
    validate_priority_identifier_value(group_id, name);

    if (trim(connections.priority_group_display_name(section, group_id)) == "")
        fail_validation("Priority group '" + group_id + "' in rule '" + name + "' has no display name. Aborted.");

    validate_http_url_option(connections.priority_group_health_url(section, group_id), "rule." + name + ".priority." + group_id + ".health_url");
    validate_required_duration_option(connections.priority_group_active_check_interval(section, group_id), "rule." + name + ".priority." + group_id + ".active_check_interval");
    validate_required_duration_option(connections.priority_group_check_timeout(section, group_id), "rule." + name + ".priority." + group_id + ".check_timeout");
    validate_required_duration_option(connections.priority_group_recovery_check_interval(section, group_id), "rule." + name + ".priority." + group_id + ".recovery_check_interval");
    if (connections.priority_group_switch_to_faster_same_priority(section, group_id))
        validate_required_duration_option(connections.priority_group_fastest_check_interval(section, group_id), "rule." + name + ".priority." + group_id + ".fastest_check_interval");

    for (let level_id in connections.priority_levels(group_id)) {
        validate_priority_identifier_value(level_id, name);
        if (trim(connections.priority_level_display_name(group_id, level_id)) == "")
            fail_validation("Priority level '" + level_id + "' in rule '" + name + "', priority '" + group_id + "' has no display name. Aborted.");

        validate_priority_level_order(connections.priority_level_order(group_id, level_id), name, group_id, level_id);
        if (connections.priority_level_direct(group_id, level_id))
            continue;

        let filter_mode = connections.priority_level_filter_mode(group_id, level_id);
        validate_priority_filter_mode_value(filter_mode, name, group_id, level_id);
        if (filter_mode != "disabled")
            validate_detect_server_country_value(connections.priority_level_detect_server_country(group_id, level_id), name);
        if (filter_mode == "include" || filter_mode == "mixed") {
            for (let value in connections.priority_level_include_countries(group_id, level_id))
                validate_country_code_value(value, name);
            for (let value in connections.priority_level_include_regex(group_id, level_id))
                validate_urltest_regex_value(value, name);
        }
        if (filter_mode == "exclude" || filter_mode == "mixed") {
            for (let value in connections.priority_level_exclude_countries(group_id, level_id))
                validate_country_code_value(value, name);
            for (let value in connections.priority_level_exclude_regex(group_id, level_id))
                validate_urltest_regex_value(value, name);
        }
    }
}

function validate_combined_domain_value(value, section) {
    if (as_string(value) == "" || combined_domain_valid(value))
        return;

    fail_validation("Invalid domain condition '" + value + "' in rule '" + section + "'. Use plain domains or full:, keyword:, regex: prefixes. Aborted.");
}

function validate_combined_domain_text_value(value, section) {
    if (as_string(value) == "" || combined_domain_text_valid(value))
        return;

    fail_validation("Invalid domain conditions in rule '" + section + "'. Use plain domains or full:, keyword:, regex: prefixes. Aborted.");
}

function validate_service_value(service, context) {
    if (community_service_valid(service, context.community_services))
        return;

    fail_validation("Invalid service in community lists: " + service + ". Check config and LuCI cache. Aborted.");
}

function validate_ruleset_reference_value(reference, context) {
    if (ruleset_reference_valid(reference, context.community_services))
        return;

    fail_validation("Unknown rule set reference '" + reference + "'. Aborted.");
}

function validate_plain_domain_ip_list_reference_value(reference) {
    if (plain_domain_ip_list_reference_valid(reference))
        return;

    fail_validation("Unknown plain list reference '" + reference + "'. Aborted.");
}

function validate_common_rule_references(section, context) {
    for (let value in connections.community_lists(section))
        validate_service_value(value, context);
    for (let value in connections.rule_sets(section))
        validate_ruleset_reference_value(value, context);
    for (let value in connections.rule_sets_with_subnets(section))
        validate_ruleset_reference_value(value, context);
    for (let value in list_option(section, "domain_ip_lists"))
        validate_plain_domain_ip_list_reference_value(value);
}

function outbound_json_object(value) {
    try {
        value = json(as_string(value));
    }
    catch (e) {
        return null;
    }

    return type(value) == "object" ? value : null;
}

function valid_outbound_json(value) {
    value = outbound_json_object(value);
    return value != null && type(value.type) == "string" && trim(as_string(value.type)) != "";
}

function validate_outbound_json_rule(section) {
    let name = section_name(section);
    let outbound_json = option(section, "outbound_json", "");

    if (outbound_json == "")
        fail_validation("JSON outbound rule '" + name + "' has empty outbound_json. Aborted.");

    if (!valid_outbound_json(outbound_json))
        fail_validation("JSON outbound rule '" + name + "' must contain a valid sing-box outbound JSON object with a type field. Aborted.");
}

function validate_outbound_json_values(section) {
    let name = section_name(section);
    let values = connections.outbound_jsons(section);
    let require_user_tag = length(list_option(section, "outbound_jsons")) > 0;
    let tags = {};

    for (let value in values) {
        if (as_string(value) == "")
            fail_validation("Connection rule '" + name + "' has empty JSON outbound. Aborted.");

        if (!valid_outbound_json(value))
            fail_validation("Connection rule '" + name + "' must contain valid sing-box outbound JSON objects with a type field. Aborted.");

        let outbound = outbound_json_object(value);
        let tag_name = trim(as_string(outbound.tag || ""));
        if (tag_name == "" && require_user_tag)
            fail_validation("Connection rule '" + name + "' has JSON outbound without a non-empty tag. Aborted.");
        if (tag_name != "" && tags[tag_name])
            fail_validation("Connection rule '" + name + "' has duplicate JSON outbound tag '" + tag_name + "'. Aborted.");
        if (tag_name != "")
            tags[tag_name] = true;
    }
}

function rule_has_subscription_urls(section) {
    return length(connections.subscription_urls(section)) > 0;
}

function subscription_update_interval_for_source(section, entry) {
    if (!connections.subscription_update_enabled(section, entry))
        return "";
    let value = connections.subscription_update_interval(section, entry);
    return value != "" ? value : "1h";
}

function validate_subscription_request_profile(section, entry) {
    if (connections.subscription_auto_hwid(section, entry))
        return;

    if (connections.subscription_hwid(section, entry) != "")
        return;

    fail_validation("Subscription source in rule '" + section_name(section) + "' has manual HWID enabled but HWID is empty. Fill HWID or enable auto-generation. Aborted.");
}

function validate_provider_strategy(kind, section, context) {
    let name = section_name(section);

    if (kind == "zapret") {
        let raw = zapret_validator().strategy_or_default(option(section, "nfqws_opt", ""), context.zapret_default_nfqws_opt);
        let result = zapret_validator().validate_strategy("nfqws", raw, context.zapret_legacy_default_nfqws_opt);
        if (!result.valid)
            fail_validation("Zapret rule '" + name + "' uses invalid NFQWS strategy: " + result.message + " Aborted.");
        return;
    }

    if (kind == "zapret2") {
        let raw = zapret2_validator().strategy_or_default(option(section, "nfqws2_opt", ""), context.zapret2_default_nfqws2_opt);
        let result = zapret2_validator().validate_strategy("nfqws2", raw, "");
        if (!result.valid)
            fail_validation("Zapret2 rule '" + name + "' uses invalid NFQWS2 strategy: " + result.message + " Aborted.");
        return;
    }

    let raw = byedpi_validator().strategy_or_default(option(section, "byedpi_cmd_opts", ""), context.byedpi_default_cmd_opts);
    let result = byedpi_validator().validate_byedpi_strategy(raw);
    if (!result.valid)
        fail_validation("Invalid ByeDPI strategy for rule '" + name + "': " + result.message);
}

function validate_rule(section, context) {
    if (!section_enabled(section))
        return;

    let name = section_name(section);
    let action = rule_action(section);
    if (action == "")
        fail_validation("Enabled rule '" + name + "' has no action. Aborted.");
    if (!rule_action_supported(action))
        fail_validation("Enabled rule '" + name + "' uses unsupported action '" + action + "'. Aborted.");

    for (let value in list_option(section, "ports"))
        validate_port_condition_value(value, name);

    if (action == "zapret") {
        if (!context.zapret_installed) {
            validate_common_rule_references(section, context);
            return;
        }
        validate_provider_strategy("zapret", section, context);
    }

    if (action == "zapret2") {
        if (!context.zapret2_installed) {
            validate_common_rule_references(section, context);
            return;
        }
        validate_provider_strategy("zapret2", section, context);
    }

    if (action == "byedpi") {
        if (!context.byedpi_installed) {
            validate_common_rule_references(section, context);
            return;
        }
        validate_provider_strategy("byedpi", section, context);
    }

    if (connections.is_connections_action(action)) {
        for (let urltest_id in connections.urltests(section)) {
            validate_urltest_identifier_value(urltest_id, name);

            let urltest_filter_mode = connections.urltest_filter_mode(section, urltest_id);
            validate_urltest_filter_mode_value(urltest_filter_mode, name);
            if (contains([ "exclude", "include", "mixed" ], urltest_filter_mode))
                validate_detect_server_country_value(connections.urltest_detect_server_country(section, urltest_id), name);

            validate_required_duration_option(connections.urltest_check_interval(section, urltest_id), "rule." + name + ".urltest." + urltest_id + ".urltest_check_interval");
            validate_urltest_tolerance_value(connections.urltest_tolerance(section, urltest_id), name, urltest_id);
            validate_http_url_option(connections.urltest_testing_url(section, urltest_id), "rule." + name + ".urltest." + urltest_id + ".testing_url");
            let idle_timeout = connections.urltest_idle_timeout(section, urltest_id);
            if (idle_timeout != "")
                validate_required_duration_option(idle_timeout, "rule." + name + ".urltest." + urltest_id + ".idle_timeout");

            if (contains([ "include", "mixed" ], urltest_filter_mode)) {
                for (let value in connections.urltest_include_regex(section, urltest_id))
                    validate_urltest_regex_value(value, name);
                for (let value in connections.urltest_include_countries(section, urltest_id))
                    validate_country_code_value(value, name);
            }
            if (contains([ "exclude", "mixed" ], urltest_filter_mode)) {
                for (let value in connections.urltest_exclude_countries(section, urltest_id))
                    validate_country_code_value(value, name);
                for (let value in connections.urltest_exclude_regex(section, urltest_id))
                    validate_urltest_regex_value(value, name);
            }
        }

        for (let group_id in connections.priority_groups(section))
            validate_priority_group(section, group_id);

        if (rule_has_subscription_urls(section)) {
            for (let value in connections.subscription_urls(section)) {
                validate_subscription_source_entry_value(value, name);
                validate_subscription_request_profile(section, value);
                let subscription_update_interval = subscription_update_interval_for_source(section, value);
                if (subscription_update_interval != "")
                    validate_required_duration_option(subscription_update_interval, "rule." + name + ".subscription_update_interval");
            }
        }

        validate_outbound_json_values(section);
    }

    if (action == "outbound")
        validate_outbound_json_rule(section);

    validate_combined_domain_text_value(option(section, "domain", ""), name);
    for (let value in list_option(section, "domain_suffix"))
        validate_combined_domain_value(value, name);
    validate_combined_domain_text_value(option(section, "domain_suffix_text", ""), name);
    validate_common_rule_references(section, context);
}

function download_via_proxy_option_for_purpose(purpose) {
    purpose = as_string(purpose || "lists");
    if (purpose == "lists")
        return "download_lists_via_proxy";
    if (purpose == "components")
        return "download_components_via_proxy";
    return "";
}

function download_via_proxy_section_option_for_purpose(purpose) {
    purpose = as_string(purpose || "lists");
    if (purpose == "lists")
        return "download_lists_via_proxy_section";
    if (purpose == "components")
        return "download_components_via_proxy_section";
    return "";
}

function download_via_proxy_section(settings, purpose) {
    let enabled_option = download_via_proxy_option_for_purpose(purpose);
    if (enabled_option == "" || !bool_option(settings, enabled_option, false))
        return "";

    let section_option = download_via_proxy_section_option_for_purpose(purpose);
    let configured = section_option != "" ? option(settings, section_option, "") : "";
    if (configured != "")
        return configured;

    return option(settings, "download_lists_via_proxy_section", "");
}

function download_via_proxy_enabled(settings, purpose) {
    let enabled_option = download_via_proxy_option_for_purpose(purpose);
    return enabled_option != "" && bool_option(settings, enabled_option, false);
}

function download_via_proxy_any_enabled(settings) {
    return download_via_proxy_enabled(settings, "lists") ||
        download_via_proxy_enabled(settings, "components");
}

function basic_rows_from_sections(sections) {
    let rows = [];
    for (let section in sections) {
        push(rows, {
            section: section_name(section),
            enabled: section_enabled(section),
            action: rule_action(section)
        });
    }
    return rows;
}

function detour_rows_from_sections(sections) {
    let rows = [];
    for (let section in sections) {
        push(rows, {
            section: section_name(section),
            enabled: section_enabled(section),
            action: rule_action(section),
            detour_enabled: bool_option(section, "outbound_detour_enabled", false),
            detour_section: option(section, "outbound_detour_section", "")
        });
    }
    return rows;
}

function validate_subscription_download_sections(sections, context) {
    let rows = basic_rows_from_sections(sections);

    for (let section in sections) {
        section = object_or_empty(section);
        if (!section_enabled(section))
            continue;

        let name = section_name(section);
        for (let entry in connections.subscription_urls(section)) {
            let target = connections.subscription_download_section(section, entry);
            if (target == "")
                continue;

            if (target == name)
                fail_validation("Subscription source in rule '" + name + "' cannot be downloaded through the same rule. Select another rule or disable download-through-section. Aborted.");

            validate_download_section_rows(
                target,
                context.byedpi_installed,
                context.zapret_installed,
                context.zapret2_installed,
                rows
            );
        }
    }
}

function basic_rows_by_section(rows) {
    let result = {};
    for (let row in array_or_empty(rows))
        if (type(row) == "object" && row.section != "")
            result[row.section] = row;
    return result;
}

function validate_server_routing_sections(sections) {
    let by_section = basic_rows_by_section(basic_rows_from_sections(sections));

    for (let server in sections_by_type("server")) {
        server = object_or_empty(server);
        if (!server_enabled(server))
            continue;

        let name = section_name(server);
        let mode = option(server, "routing_mode", "rules");
        if (!contains([ "rules", "direct", "section" ], mode))
            fail_validation("Server '" + name + "' uses unsupported routing mode '" + mode + "'. Aborted.");

        if (mode != "section")
            continue;

        let target_name = option(server, "routing_section", "");
        if (target_name == "")
            fail_validation("Server '" + name + "' uses selected-section routing, but no routing section is selected. Aborted.");

        let target = by_section[target_name];
        if (type(target) != "object")
            fail_validation("Server '" + name + "' references missing routing section '" + target_name + "'. Aborted.");
        if (!target.enabled)
            fail_validation("Server '" + name + "' references disabled routing section '" + target_name + "'. Aborted.");
        if (!server_routing_section_action_supported(target.action))
            fail_validation("Server '" + name + "' references routing section '" + target_name + "' with unsupported action '" + target.action + "'. Select a Connection, proxy, JSON outbound, VPN, Zapret, Zapret2, or ByeDPI section. Aborted.");
    }
}

function validate_list_update_settings(settings) {
    if (!bool_option(settings, "list_update_enabled", true))
        return;

    let update_interval = option(settings, "update_interval", "1d");
    if (update_interval == "")
        update_interval = "1d";
    validate_required_duration_option(update_interval, "settings.update_interval");
}

function validate_runtime_mark_ranges_context(context) {
    let fakeip_mark = parse_number(context.nft_fakeip_mark);
    let outbound_mark = parse_number(context.nft_outbound_mark);
    let ranges = [
        [ "Zapret", context.zapret_route_mark_base, context.zapret_queue_range_size, fakeip_mark, "FakeIP mark " + context.nft_fakeip_mark ],
        [ "Zapret", context.zapret_route_mark_base, context.zapret_queue_range_size, outbound_mark, "outbound mark " + context.nft_outbound_mark ],
        [ "Zapret2", context.zapret2_route_mark_base, context.zapret2_queue_range_size, fakeip_mark, "FakeIP mark " + context.nft_fakeip_mark ],
        [ "Zapret2", context.zapret2_route_mark_base, context.zapret2_queue_range_size, outbound_mark, "outbound mark " + context.nft_outbound_mark ]
    ];

    for (let range in ranges) {
        let label = as_string(range[0]);
        let base = parse_number(range[1]);
        let range_size = parse_number(range[2]);
        let mark_mask = range[3];
        let mark_mask_label = as_string(range[4]);

        if (base == null || range_size == null || mark_mask == null)
            fail_validation(label + " route mark range contains invalid numeric constants. Aborted.");

        for (let index_value = 1; index_value <= range_size; index_value++) {
            let mark_value = base + index_value;
            if ((mark_value & mark_mask) != 0)
                fail_validation(label + " route mark range overlaps " + mark_mask_label + ". Aborted.");
        }
    }
}

function validate_runtime_config(context) {
    let settings = settings_section();
    let sections = sections_by_type("section");

    validate_runtime_mark_ranges_context(context);
    validate_list_update_settings(settings);
    validate_http_url_option(option(settings, "latency_test_url", DEFAULT_LATENCY_TEST_URL) || DEFAULT_LATENCY_TEST_URL, "settings.latency_test_url");

    if (download_via_proxy_enabled(settings, "lists")) {
        validate_download_section_rows(
            download_via_proxy_section(settings, "lists"),
            context.byedpi_installed,
            context.zapret_installed,
            context.zapret2_installed,
            basic_rows_from_sections(sections)
        );
    }
    if (download_via_proxy_enabled(settings, "components")) {
        validate_download_section_rows(
            download_via_proxy_section(settings, "components"),
            context.byedpi_installed,
            context.zapret_installed,
            context.zapret2_installed,
            basic_rows_from_sections(sections)
        );
    }

    validate_outbound_detours_rows(detour_rows_from_sections(sections));
    validate_subscription_download_sections(sections, context);
    validate_server_routing_sections(sections);

    for (let section in sections)
        validate_rule(section, context);
}

function context_from_runtime() {
    let constants = object_or_empty(runtime_constants());

    return {
        constants,
        community_services: constant_value(constants, "COMMUNITY_SERVICES"),
        byedpi_default_cmd_opts: constant_value(constants, "BYEDPI_DEFAULT_CMD_OPTS"),
        zapret_default_nfqws_opt: constant_value(constants, "ZAPRET_DEFAULT_NFQWS_OPT"),
        zapret_legacy_default_nfqws_opt: constant_value(constants, "ZAPRET_LEGACY_DEFAULT_NFQWS_OPT"),
        zapret2_default_nfqws2_opt: constant_value(constants, "ZAPRET2_DEFAULT_NFQWS2_OPT"),
        byedpi_installed: file_executable(constant_value(constants, "BYEDPI_BIN")),
        zapret_installed: file_executable(constant_value(constants, "ZAPRET_PROVIDER_NFQWS_BIN")),
        zapret2_installed: file_executable(constant_value(constants, "ZAPRET2_PROVIDER_NFQWS2_BIN")),
        zapret_provider_nfqws_bin: constant_value(constants, "ZAPRET_PROVIDER_NFQWS_BIN"),
        zapret2_provider_nfqws2_bin: constant_value(constants, "ZAPRET2_PROVIDER_NFQWS2_BIN"),
        zapret_route_mark_base: constant_value(constants, "ZAPRET_ROUTE_MARK_BASE"),
        zapret_queue_range_size: constant_value(constants, "ZAPRET_QUEUE_RANGE_SIZE"),
        zapret2_route_mark_base: constant_value(constants, "ZAPRET2_ROUTE_MARK_BASE"),
        zapret2_queue_range_size: constant_value(constants, "ZAPRET2_QUEUE_RANGE_SIZE"),
        nft_fakeip_mark: constant_value(constants, "NFT_FAKEIP_MARK"),
        nft_outbound_mark: constant_value(constants, "NFT_OUTBOUND_MARK"),
        coreutils_base64_required_version: constant_value(constants, "COREUTILS_BASE64_REQUIRED_VERSION"),
        sing_box_required_version: constant_value(constants, "SB_REQUIRED_VERSION"),
        sing_box_variant_state_file: constant_value(constants, "SB_VARIANT_STATE_FILE"),
        sing_box_version_state_file: constant_value(constants, "SB_VERSION_STATE_FILE"),
        sing_box_managed_service_marker: constant_value(constants, "SB_MANAGED_SERVICE_MARKER"),
        zapret_legacy_runtime_base_dir: constant_value(constants, "ZAPRET_LEGACY_RUNTIME_BASE_DIR"),
        zapret_state_dir: constant_value(constants, "ZAPRET_STATE_DIR"),
        zapret_pid_dir: constant_value(constants, "ZAPRET_PID_DIR"),
        zapret_child_pid_dir: constant_value(constants, "ZAPRET_CHILD_PID_DIR"),
        zapret_log_dir: constant_value(constants, "ZAPRET_LOG_DIR"),
        zapret2_state_dir: constant_value(constants, "ZAPRET2_STATE_DIR"),
        zapret2_pid_dir: constant_value(constants, "ZAPRET2_PID_DIR"),
        zapret2_child_pid_dir: constant_value(constants, "ZAPRET2_CHILD_PID_DIR"),
        zapret2_log_dir: constant_value(constants, "ZAPRET2_LOG_DIR"),
        byedpi_bin: constant_value(constants, "BYEDPI_BIN"),
        byedpi_state_dir: constant_value(constants, "BYEDPI_STATE_DIR"),
        byedpi_pid_dir: constant_value(constants, "BYEDPI_PID_DIR"),
        byedpi_child_pid_dir: constant_value(constants, "BYEDPI_CHILD_PID_DIR"),
        byedpi_log_dir: constant_value(constants, "BYEDPI_LOG_DIR")
    };
}

function sing_box_variant_marker(ctx, value) {
    let path = as_string(ctx.sing_box_variant_state_file);
    if (path == "")
        path = "/etc/podkop-plus/sing-box-variant";

    let data = fs.readfile(path);
    return trim(as_string(data)) == as_string(value);
}

function sing_box_compressed_marker_set(ctx) {
    return sing_box_variant_marker(ctx, "extended-compressed");
}

function sing_box_extended_marker_set(ctx) {
    return sing_box_variant_marker(ctx, "extended");
}

function sing_box_version_state(ctx) {
    let path = as_string(ctx.sing_box_version_state_file);
    if (path == "")
        path = "/etc/podkop-plus/sing-box-version";

    let data = fs.readfile(path);
    if (data == null)
        return "";

    let newline = index(data, "\n");
    return newline >= 0 ? substr(data, 0, newline) : as_string(data);
}

function get_sing_box_version(ctx) {
    if (!command_exists("sing-box"))
        return "";

    if (sing_box_compressed_marker_set(ctx))
        return sing_box_version_state(ctx);

    return first_line_last_field(command_output_from_args([ "sing-box", "version" ]));
}

function sing_box_version_is_extended(version) {
    return index(as_string(version), "extended") >= 0;
}

function sing_box_is_extended(ctx, version) {
    if (as_string(version) == "" && command_exists("sing-box") &&
        (sing_box_compressed_marker_set(ctx) || sing_box_extended_marker_set(ctx)))
        return true;

    return sing_box_version_is_extended(version != null ? version : get_sing_box_version(ctx));
}

function sing_box_output_has_build_tag(output, tag) {
    tag = as_string(tag);
    if (tag == "")
        return false;

    for (let token in split(replace(as_string(output), /[,: \t\r\n]+/g, " "), " "))
        if (token == tag)
            return true;

    return false;
}

function sing_box_supports_tailscale(ctx, version, version_output) {
    if (command_exists("sing-box") && sing_box_compressed_marker_set(ctx))
        return true;

    if (sing_box_is_extended(ctx, version))
        return true;

    if (as_string(version_output) == "")
        version_output = command_output_from_args([ "sing-box", "version" ]);

    return sing_box_output_has_build_tag(version_output, "with_tailscale");
}

function managed_sing_box_service_script(marker) {
    marker = as_string(marker);
    if (marker == "")
        marker = "Podkop Plus managed sing-box service for binary variants";

    return "#!/bin/sh /etc/rc.common\n" +
        "# " + marker + "\n" +
        "\n" +
        "USE_PROCD=1\n" +
        "START=99\n" +
        "PROG=\"/usr/bin/sing-box\"\n" +
        "\n" +
        "start_service() {\n" +
        "    config_load \"sing-box\"\n" +
        "    local enabled config_file working_directory\n" +
        "    local log_stderr\n" +
        "\n" +
        "    config_get_bool enabled \"main\" \"enabled\" \"0\"\n" +
        "    [ \"$enabled\" -eq \"1\" ] || return 0\n" +
        "\n" +
        "    config_get config_file \"main\" \"conffile\" \"/etc/sing-box/config.json\"\n" +
        "    config_get working_directory \"main\" \"workdir\" \"/usr/share/sing-box\"\n" +
        "    config_get_bool log_stderr \"main\" \"log_stderr\" \"1\"\n" +
        "\n" +
        "    procd_open_instance\n" +
        "    procd_set_param command \"$PROG\" run -c \"$config_file\" -D \"$working_directory\"\n" +
        "    procd_set_param file \"$config_file\"\n" +
        "    procd_set_param stderr \"$log_stderr\"\n" +
        "    procd_set_param limits core=\"unlimited\"\n" +
        "    procd_set_param limits nofile=\"1000000 1000000\"\n" +
        "    procd_set_param respawn\n" +
        "    procd_close_instance\n" +
        "}\n" +
        "\n" +
        "service_triggers() {\n" +
        "    procd_add_reload_trigger \"sing-box\"\n" +
        "}\n";
}

function install_managed_sing_box_service_script(ctx) {
    let stamp = clock();
    let tmp_file = sprintf("/etc/init.d/sing-box.podkop-plus.%d.%d", stamp[0], stamp[1]);

    if (!fs.writefile(tmp_file, managed_sing_box_service_script(ctx.sing_box_managed_service_marker)))
        return false;

    if (!run_args([ "chmod", "0755", tmp_file ]) || !run_args([ "mv", "-f", tmp_file, "/etc/init.d/sing-box" ])) {
        fs.unlink(tmp_file);
        return false;
    }

    return true;
}

function service_exists(service) {
    return file_executable("/etc/init.d/" + as_string(service));
}

function validate_extended_server_features(ctx, sing_box_version, sing_box_version_output) {
    if (sing_box_is_extended(ctx, sing_box_version))
        return;

    for (let section in sections_by_type("server")) {
        if (!server_enabled(section))
            continue;

        let name = section_name(section);
        let protocol = option(section, "protocol", "vless");
        let transport = option(section, "transport", "tcp");

        if (protocol == "mtproto")
            fail_requirement("Server '" + name + "' uses MTProto proxy, but sing-box-extended is not installed. Install sing-box-extended or disable this server. Aborted.", "fatal");

        if (protocol == "tailscale" && !sing_box_supports_tailscale(ctx, sing_box_version, sing_box_version_output))
            fail_requirement("Server '" + name + "' uses Tailscale, but the installed sing-box binary was built without Tailscale support. Install full sing-box or sing-box-extended, or disable this server. Aborted.", "fatal");

        if (transport == "xhttp")
            fail_requirement("Server '" + name + "' uses XHTTP transport, but sing-box-extended is not installed. Install sing-box-extended or change the transport. Aborted.", "fatal");
    }
}

function has_outbound_section(ctx) {
    for (let section in sections_by_type("section")) {
        if (!section_enabled(section))
            continue;

        let action = rule_action(section);
        if (action == "byedpi" && ctx.byedpi_installed)
            return true;
        if (action == "zapret" && ctx.zapret_installed)
            return true;
        if (action == "zapret2" && ctx.zapret2_installed)
            return true;

        if (length(connections.connection_urls(section)) > 0 ||
            length(connections.subscription_urls(section)) > 0 ||
            length(connections.outbound_jsons(section)) > 0 ||
            length(connections.interfaces(section)) > 0)
            return true;
    }

    return false;
}

function has_enabled_rule_action(action) {
    action = as_string(action);

    for (let section in sections_by_type("section"))
        if (section_enabled(section) && rule_action(section) == action)
            return true;

    return false;
}

function cleanup_legacy_zapret_runtime(ctx) {
    let base = as_string(ctx.zapret_legacy_runtime_base_dir);
    if (base == "")
        return;

    let needle = base + "/nfq/nfqws";
    for (let line in split(command_output_from_args([ "ps", "w" ]), "\n")) {
        if (index(as_string(line), needle) < 0)
            continue;

        let fields = split(trim(as_string(line)), /[ \t]+/);
        let pid = length(fields) > 0 ? as_string(fields[0]) : "";
        if (match(pid, /^[0-9]+$/) != null)
            run_args([ "kill", pid ]);
    }

    safe_rm_rf(base);
}

function check_provider_requirement(action, display_name, bin_path, dirs, missing_message, prepare_failure_message) {
    if (!has_enabled_rule_action(action))
        return;

    if (!file_executable(bin_path)) {
        log_message(missing_message, "error");
        return;
    }

    if (!mkdir_p(dirs))
        fail_requirement(prepare_failure_message, "fatal");
}

function check_provider_requirements(ctx) {
    cleanup_legacy_zapret_runtime(ctx);

    check_provider_requirement(
        "zapret",
        "Zapret",
        ctx.zapret_provider_nfqws_bin,
        [ ctx.zapret_state_dir, ctx.zapret_pid_dir, ctx.zapret_child_pid_dir, ctx.zapret_log_dir ],
        "Zapret provider is not available at " + ctx.zapret_provider_nfqws_bin + ". Rules with action 'zapret' will be skipped until the zapret provider is installed.",
        "Failed to prepare the Podkop Plus zapret state directory in " + ctx.zapret_state_dir + ". Aborted."
    );

    check_provider_requirement(
        "zapret2",
        "Zapret2",
        ctx.zapret2_provider_nfqws2_bin,
        [ ctx.zapret2_state_dir, ctx.zapret2_pid_dir, ctx.zapret2_child_pid_dir, ctx.zapret2_log_dir ],
        "Zapret2 provider is not available at " + ctx.zapret2_provider_nfqws2_bin + ". Rules with action 'zapret2' will be skipped until the zapret2 provider is installed.",
        "Failed to prepare the Podkop Plus zapret2 state directory in " + ctx.zapret2_state_dir + ". Aborted."
    );

    check_provider_requirement(
        "byedpi",
        "ByeDPI",
        ctx.byedpi_bin,
        [ ctx.byedpi_state_dir, ctx.byedpi_pid_dir, ctx.byedpi_child_pid_dir, ctx.byedpi_log_dir ],
        "ByeDPI provider is not available at " + ctx.byedpi_bin + ". Rules with action 'byedpi' will be skipped until the byedpi package is installed.",
        "Failed to prepare the Podkop Plus ByeDPI state directory in " + ctx.byedpi_state_dir + ". Aborted."
    );
}

function check_runtime_requirements() {
    log_message("Checking required packages and runtime settings", "info");

    let ctx = context_from_runtime();
    let sing_box_version_output = command_exists("sing-box") ? command_output_from_args([ "sing-box", "version" ]) : "";
    let sing_box_version = sing_box_compressed_marker_set(ctx) ? sing_box_version_state(ctx) : first_line_last_field(sing_box_version_output);
    let coreutils_base64_version = first_line_field_from_text(command_output("base64 --version 2>/dev/null"), 4);

    if (sing_box_version == "") {
        if (!command_exists("sing-box") || !sing_box_compressed_marker_set(ctx))
            fail_requirement("Package 'sing-box' is not installed. Aborted.", "error");
    }
    else if (!version_at_least(sing_box_version, ctx.sing_box_required_version)) {
        fail_requirement("Package 'sing-box' version (" + sing_box_version + ") is lower than the required minimum (" + ctx.sing_box_required_version + "). Update sing-box: opkg update && opkg remove sing-box && opkg install sing-box. Aborted.", "error");
    }

    if (!service_exists("sing-box") && sing_box_compressed_marker_set(ctx))
        install_managed_sing_box_service_script(ctx);

    if (!service_exists("sing-box"))
        fail_requirement("Service 'sing-box' is missing. Install a sing-box package or reinstall the compressed sing-box-extended binary variant. Aborted.", "error");

    validate_extended_server_features(ctx, sing_box_version, sing_box_version_output);

    if (coreutils_base64_version == "")
        fail_requirement("Package 'coreutils-base64' is not installed. Aborted.", "error");
    else if (!version_at_least(coreutils_base64_version, ctx.coreutils_base64_required_version))
        log_message("Package 'coreutils-base64' version (" + coreutils_base64_version + ") is lower than the required minimum (" + ctx.coreutils_base64_required_version + "). This may cause issues when decoding base64 streams with missing padding, as automatic padding support is not available in older versions.", "warn");

    if (dhcp_has_https_dns_proxy_options("/etc/config/dhcp") === true)
        log_message("https-dns-proxy is enabled in DHCP config. Disable it or edit /etc/config/dhcp before starting Podkop Plus.", "error");

    if (has_outbound_section(ctx))
        log_message("Proxy outbound configuration found", "debug");
    else
        log_message("No proxy outbound sections found. Podkop Plus will use direct and/or provider-only routing.", "warn");

    check_provider_requirements(ctx);
}

function context_override_value(overrides, defaults, key) {
    let value = object_or_empty(overrides)[key];
    if (value != null)
        return as_string(value);
    return as_string(object_or_empty(defaults)[key]);
}

function context_override_bool(overrides, defaults, key) {
    let value = object_or_empty(overrides)[key];
    if (value != null)
        return bool_flag(value);
    return bool_flag(object_or_empty(defaults)[key]);
}

function context_from_json(value, defaults) {
    try {
        value = json(as_string(value));
    }
    catch (e) {
        value = {};
    }

    value = object_or_empty(value);
    defaults = object_or_empty(defaults);

    return {
        community_services: context_override_value(value, defaults, "community_services"),
        byedpi_default_cmd_opts: context_override_value(value, defaults, "byedpi_default_cmd_opts"),
        zapret_default_nfqws_opt: context_override_value(value, defaults, "zapret_default_nfqws_opt"),
        zapret_legacy_default_nfqws_opt: context_override_value(value, defaults, "zapret_legacy_default_nfqws_opt"),
        zapret2_default_nfqws2_opt: context_override_value(value, defaults, "zapret2_default_nfqws2_opt"),
        byedpi_installed: context_override_bool(value, defaults, "byedpi_installed"),
        zapret_installed: context_override_bool(value, defaults, "zapret_installed"),
        zapret2_installed: context_override_bool(value, defaults, "zapret2_installed"),
        zapret_route_mark_base: context_override_value(value, defaults, "zapret_route_mark_base"),
        zapret_queue_range_size: context_override_value(value, defaults, "zapret_queue_range_size"),
        zapret2_route_mark_base: context_override_value(value, defaults, "zapret2_route_mark_base"),
        zapret2_queue_range_size: context_override_value(value, defaults, "zapret2_queue_range_size"),
        nft_fakeip_mark: context_override_value(value, defaults, "nft_fakeip_mark"),
        nft_outbound_mark: context_override_value(value, defaults, "nft_outbound_mark")
    };
}

let mode = ARGV[0] || "";

if (mode == "stdin-first-line-field")
    stdin_first_line_field(ARGV[1]);
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
else if (mode == "community-service-valid")
    exit(community_service_valid(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "ruleset-reference-valid")
    exit(ruleset_reference_valid(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "plain-domain-ip-list-reference-valid")
    exit(plain_domain_ip_list_reference_valid(ARGV[1]) ? 0 : 1);
else if (mode == "valid-outbound")
    exit(valid_outbound() ? 0 : 1);
else if (mode == "valid-inbound")
    exit(valid_inbound() ? 0 : 1);
else if (mode == "validate-outbound-detours")
    validate_outbound_detours();
else if (mode == "validate-download-section")
    validate_download_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "dhcp-has-https-dns-proxy-options")
    dhcp_has_https_dns_proxy_options_exit(ARGV[1]);
else if (mode == "mwan3-has-enabled-interface")
    exit(mwan3_has_enabled_interface() ? 0 : 1);
else if (mode == "mwan3-is-active")
    exit(mwan3_is_active() ? 0 : 1);
else if (mode == "check-requirements")
    check_runtime_requirements();
else if (mode == "validate-runtime")
    validate_runtime_config(context_from_runtime());
else if (mode == "validate-runtime-fixture") {
    use_fixture_cursor(ARGV[1]);
    validate_runtime_config(context_from_json(ARGV[2], context_from_runtime()));
}
else {
    warn("Usage: config/validator.uc <operation> ...\n");
    exit(1);
}
