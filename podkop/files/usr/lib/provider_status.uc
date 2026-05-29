#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function int_arg(value) {
    value = as_string(value);
    return value == "" ? 0 : int(value, 10);
}

function bool_arg(value) {
    value = as_string(value);
    return value == "1" || value == "true";
}

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : data;
}

function read_json_file(path) {
    let data = fs.readfile(path);
    if (data == null)
        return null;

    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function byedpi_validation_result(valid, message, needle) {
    let needles = [];
    if (!bool_arg(valid)) {
        for (let line in split(read_stdin(), "\n")) {
            if (line != "")
                push(needles, line);
        }
    }

    write_json({
        valid: bool_arg(valid),
        message: as_string(message),
        needle: as_string(needle),
        needles
    });
}

function has_socks_outbound(config_path, tag, address, port) {
    let config = read_json_file(config_path);
    port = int_arg(port);
    for (let outbound in array_or_empty(config && config.outbounds)) {
        if (type(outbound) == "object" &&
            outbound.type == "socks" &&
            outbound.tag == tag &&
            outbound.server == address &&
            int(outbound.server_port || 0) == port)
            return true;
    }
    return false;
}

function has_direct_mark_outbound(config_path, tag, routing_mark) {
    let config = read_json_file(config_path);
    routing_mark = int_arg(routing_mark);
    for (let outbound in array_or_empty(config && config.outbounds)) {
        if (type(outbound) == "object" &&
            outbound.type == "direct" &&
            outbound.tag == tag &&
            int(outbound.routing_mark || 0) == routing_mark)
            return true;
    }
    return false;
}

function has_route_rule(config_path, inbound, outbound_tag) {
    let config = read_json_file(config_path);
    for (let rule in array_or_empty(config && config.route && config.route.rules)) {
        if (type(rule) == "object" &&
            rule.action == "route" &&
            rule.inbound == inbound &&
            rule.outbound == outbound_tag)
            return true;
    }
    return false;
}

function value_contains(value, needle) {
    if (type(value) == "array") {
        for (let item in value) {
            if (as_string(item) == needle)
                return true;
        }
        return false;
    }

    return as_string(value) == needle;
}

function find_tagged_item(items, tag) {
    for (let item in array_or_empty(items)) {
        if (type(item) == "object" && item.tag == tag)
            return item;
    }

    return null;
}

function tagged_runtime_summary(config_path, section_name, tag) {
    let config = read_json_file(config_path);
    let item = find_tagged_item(config && config[section_name], tag);

    if (item == null) {
        write_json({ exists: 0 });
        return;
    }

    write_json({
        exists: 1,
        type: as_string(item.type),
        listen: as_string(item.listen),
        listen_port: int_arg(item.listen_port)
    });
}

function has_route_rule_for_inbound(config_path, inbound) {
    let config = read_json_file(config_path);
    for (let rule in array_or_empty(config && config.route && config.route.rules)) {
        if (type(rule) == "object" &&
            (rule.action == "route" || rule.action == "reject") &&
            value_contains(rule.inbound, inbound))
            return true;
    }

    return false;
}

function byedpi_status(args) {
    write_json({
        installed: bool_arg(args[0]),
        package_installed: bool_arg(args[1]),
        provider_available: bool_arg(args[2]),
        provider_path: as_string(args[3]),
        version: as_string(args[4]),
        configured: bool_arg(args[5]),
        enabled_rule_count: int_arg(args[6]),
        expected_process_count: int_arg(args[7]),
        running_process_count: int_arg(args[8]),
        supervisor_process_count: int_arg(args[9]),
        restart_count: int_arg(args[10]),
        runtime_unstable: bool_arg(args[11]),
        standalone_service_enabled: bool_arg(args[12]),
        standalone_service_running: bool_arg(args[13]),
        listen_address: as_string(args[14]),
        port_base: int_arg(args[15]),
        outbounds_configured: bool_arg(args[16]),
        routes_configured: bool_arg(args[17]),
        ready: bool_arg(args[18]),
        conflict: bool_arg(args[19]),
        status_message: as_string(args[20])
    });
}

function byedpi_check(installed, package_installed, provider_path) {
    write_json({
        byedpi_installed: bool_arg(installed),
        byedpi_package_installed: bool_arg(package_installed),
        byedpi_provider_path: as_string(provider_path)
    });
}

function zapret_status(args) {
    write_json({
        installed: bool_arg(args[0]),
        package_installed: bool_arg(args[1]),
        provider_available: bool_arg(args[2]),
        provider_path: as_string(args[3]),
        files_available: bool_arg(args[4]),
        ipset_available: bool_arg(args[5]),
        version: as_string(args[6]),
        configured: bool_arg(args[7]),
        enabled_rule_count: int_arg(args[8]),
        expected_process_count: int_arg(args[9]),
        running_process_count: int_arg(args[10]),
        supervisor_process_count: int_arg(args[11]),
        standalone_service_enabled: bool_arg(args[12]),
        standalone_service_running: bool_arg(args[13]),
        standalone_config_present: bool_arg(args[14]),
        standalone_conflict: bool_arg(args[15]),
        luci_app_installed: bool_arg(args[16]),
        queue_base: int_arg(args[17]),
        queue_range_end: int_arg(args[18]),
        queue_overlap: bool_arg(args[19]),
        legacy_runtime_present: bool_arg(args[20]),
        ready: bool_arg(args[21]),
        conflict: bool_arg(args[22]),
        outbounds_configured: bool_arg(args[23]),
        routes_configured: bool_arg(args[24]),
        status_message: as_string(args[25])
    });
}

function zapret_check(installed, package_installed, provider_path) {
    write_json({
        zapret_installed: bool_arg(installed),
        zapret_package_installed: bool_arg(package_installed),
        zapret_provider_path: as_string(provider_path)
    });
}

let mode = ARGV[0] || "";

if (mode == "byedpi-validation")
    byedpi_validation_result(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "has-socks-outbound")
    exit(has_socks_outbound(ARGV[1], ARGV[2], ARGV[3], ARGV[4]) ? 0 : 1);
else if (mode == "has-direct-mark-outbound")
    exit(has_direct_mark_outbound(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
else if (mode == "has-route-rule")
    exit(has_route_rule(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
else if (mode == "inbound-summary")
    tagged_runtime_summary(ARGV[1], "inbounds", ARGV[2]);
else if (mode == "endpoint-summary")
    tagged_runtime_summary(ARGV[1], "endpoints", ARGV[2]);
else if (mode == "has-route-rule-for-inbound")
    exit(has_route_rule_for_inbound(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "byedpi-status")
    byedpi_status(slice(ARGV, 1));
else if (mode == "byedpi-check")
    byedpi_check(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "zapret-status")
    zapret_status(slice(ARGV, 1));
else if (mode == "zapret-check")
    zapret_check(ARGV[1], ARGV[2], ARGV[3]);
else {
    warn("Usage: provider_status.uc <operation> ...\n");
    exit(1);
}
