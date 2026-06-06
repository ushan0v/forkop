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

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function arg_bool(value) {
    return value === true || value == "true" || value == "1" || value == 1;
}

function arg_number(value) {
    value = as_string(value);
    if (value == "" || match(value, /[^0-9-]/))
        return 0;
    return int(value);
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function path_basename(path) {
    let parts = split(as_string(path), "/");
    return length(parts) > 0 ? as_string(parts[length(parts) - 1]) : "";
}

function str_remove_suffix(value, suffix) {
    value = as_string(value);
    suffix = as_string(suffix);
    if (length(value) >= length(suffix) && substr(value, length(value) - length(suffix)) == suffix)
        return substr(value, 0, length(value) - length(suffix));
    return value;
}

function job_id_from_path(path) {
    return str_remove_suffix(path_basename(path), ".json");
}

function read_state_paths() {
    let result = {
        service: [],
        latency: [],
        component: [],
        subscription: []
    };

    for (let line in split(read_stdin(), "\n")) {
        line = trim(as_string(line));
        if (line == "")
            continue;

        let tab = index(line, "\t");
        if (tab <= 0)
            continue;

        let kind = substr(line, 0, tab);
        let path = substr(line, tab + 1);
        let value = read_json_file(path);
        if (type(value) != "object")
            continue;

        value.job_id = job_id_from_path(path);

        if (type(result[kind]) == "array")
            push(result[kind], value);
    }

    return result;
}

function service_status_text(running, enabled) {
    if (arg_bool(running))
        return arg_bool(enabled) ? "running & enabled" : "running but disabled";

    return arg_bool(enabled) ? "stopped but enabled" : "stopped & disabled";
}

function ui_state_json() {
    let action_state = read_state_paths();
    let podkop_running = arg_number(ARGV[1]);
    let podkop_enabled = arg_number(ARGV[2]);
    let podkop_status = as_string(ARGV[3]);
    let podkop_dns_configured = arg_number(ARGV[4]);
    let sing_box_running = arg_number(ARGV[5]);
    let sing_box_enabled = arg_number(ARGV[6]);
    let sing_box_status = as_string(ARGV[7]);

    if (podkop_status == "")
        podkop_status = service_status_text(podkop_running, podkop_enabled);

    if (sing_box_status == "")
        sing_box_status = service_status_text(sing_box_running, sing_box_enabled);

    write_json({
        service: {
            podkop: {
                running: podkop_running,
                enabled: podkop_enabled,
                status: podkop_status,
                dns_configured: podkop_dns_configured
            },
            sing_box: {
                running: sing_box_running,
                enabled: sing_box_enabled,
                status: sing_box_status
            }
        },
        capabilities: {
            sing_box_extended: arg_number(ARGV[8]),
            sing_box_tiny: arg_number(ARGV[9]),
            sing_box_tailscale: arg_number(ARGV[10]),
            zapret_installed: arg_number(ARGV[11]),
            zapret2_installed: arg_number(ARGV[12]),
            byedpi_installed: arg_number(ARGV[13]),
            server_inbounds_enabled_count: arg_number(ARGV[14])
        },
        actions: action_state
    });
}

function action_start_response(success, job_id, message) {
    write_json({
        success: arg_bool(success),
        job_id: as_string(job_id),
        message: as_string(message)
    });
}

function running_service_action(action, source, started_at) {
    write_json({
        success: true,
        running: true,
        kind: "service",
        action: as_string(action),
        source: as_string(source),
        message: "Service action is running",
        pid: null,
        started_at: arg_number(started_at),
        updated_at: null,
        exit_code: null
    });
}

function running_latency_action(latency_type, section, tag, started_at) {
    write_json({
        success: true,
        running: true,
        kind: "latency",
        latency_type: as_string(latency_type),
        section: as_string(section),
        tag: as_string(tag),
        message: "Latency test is running",
        pid: null,
        started_at: arg_number(started_at),
        updated_at: null,
        exit_code: null
    });
}

function set_running_job_pid(path, pid) {
    let value = object_or_empty(read_json_file(path));
    if (value.running === true)
        value.pid = as_string(pid);
    write_json(value);
}

function finished_action_state(path, success, message, exit_code, updated_at) {
    let value = object_or_empty(read_json_file(path));
    value.success = arg_bool(success);
    value.running = false;
    value.message = as_string(message);
    value.exit_code = as_string(exit_code) == "" ? null : arg_number(exit_code);
    value.updated_at = arg_number(updated_at);
    write_json(value);
}

function stale_action_state(path, message, updated_at) {
    let value = object_or_empty(read_json_file(path));
    if (value.running === true) {
        value.success = false;
        value.running = false;
        value.message = as_string(message);
        value.exit_code = null;
        value.updated_at = arg_number(updated_at);
    }
    write_json(value);
}

function json_file_field(path, key, fallback) {
    let value = read_json_file(path);
    if (type(value) == "object" && value[key] != null)
        print(as_string(value[key]), "\n");
    else
        print(as_string(fallback), "\n");
}

let mode = ARGV[0] || "";

if (mode == "ui-state-json")
    ui_state_json();
else if (mode == "action-start-response")
    action_start_response(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "running-service-action")
    running_service_action(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "running-latency-action")
    running_latency_action(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "set-running-job-pid")
    set_running_job_pid(ARGV[1], ARGV[2]);
else if (mode == "finished-action-state")
    finished_action_state(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]);
else if (mode == "stale-action-state")
    stale_action_state(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "json-file-field")
    json_file_field(ARGV[1], ARGV[2], ARGV[3]);
else {
    warn("Usage: ui_runtime.uc <operation> ...\n");
    exit(1);
}
