#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function read_stdin() {
    let data = fs.readfile("/dev/stdin");
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

function file_first_line(path) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    let newline = index(data, "\n");
    print(newline >= 0 ? substr(data, 0, newline) : data, "\n");
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

function stdin_first_ipv4_line() {
    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (match(line, /^[0-9]+\./) != null) {
            print(line, "\n");
            return;
        }
    }
}

function line_contains_any_marker(line, markers) {
    line = as_string(line);
    for (let marker in markers) {
        marker = as_string(marker);
        if (marker != "" && index(line, marker) >= 0)
            return true;
    }

    return false;
}

function filter_cron_markers(markers) {
    let data = read_stdin();
    if (data == "")
        return;

    let lines = split(data, "\n");
    let has_trailing_newline = substr(data, length(data) - 1) == "\n";

    for (let i = 0; i < length(lines); i++) {
        let line = as_string(lines[i]);
        if (i == length(lines) - 1 && has_trailing_newline && line == "")
            continue;
        if (line_contains_any_marker(line, markers))
            continue;
        print(line, "\n");
    }
}

function json_length(path) {
    let value = read_json_file(path);
    if (type(value) == "array" || type(value) == "object")
        print(length(value), "\n");
    else
        print("0\n");
}

function job_pid(path) {
    let value = read_json_file(path);
    if (type(value) == "object" && value.pid != null)
        print(as_string(value.pid), "\n");
}

function subscription_job_json_response(success, job_id, message) {
    write_json({
        success: arg_bool(success),
        job_id: as_string(job_id),
        message: as_string(message)
    });
}

function subscription_running_job_state(section, source_index, started_at) {
    write_json({
        success: true,
        running: true,
        message: "Subscription update is running",
        section: as_string(section),
        source_index: as_string(source_index),
        pid: null,
        started_at: arg_number(started_at),
        exit_code: null
    });
}

function subscription_finished_job_state(success, message, exit_code, updated_at, section, source_index, started_at) {
    write_json({
        success: arg_bool(success),
        running: false,
        message: as_string(message),
        section: as_string(section),
        source_index: as_string(source_index),
        pid: null,
        started_at: arg_number(started_at),
        exit_code: arg_number(exit_code),
        updated_at: arg_number(updated_at)
    });
}

function subscription_stale_job_state(updated_at, section, source_index, started_at) {
    write_json({
        success: false,
        running: false,
        message: "Subscription update worker exited unexpectedly",
        section: as_string(section),
        source_index: as_string(source_index),
        pid: null,
        started_at: arg_number(started_at),
        exit_code: null,
        updated_at: arg_number(updated_at)
    });
}

function subscription_status_error(message) {
    write_json({
        success: false,
        running: false,
        message: as_string(message),
        exit_code: null
    });
}

let mode = ARGV[0] || "";

if (mode == "json-length")
    json_length(ARGV[1]);
else if (mode == "file-first-line")
    file_first_line(ARGV[1]);
else if (mode == "stdin-first-ipv4-line")
    stdin_first_ipv4_line();
else if (mode == "filter-cron-markers")
    filter_cron_markers([ARGV[1], ARGV[2]]);
else if (mode == "job-pid")
    job_pid(ARGV[1]);
else if (mode == "subscription-job-json-response")
    subscription_job_json_response(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "subscription-running-job-state")
    subscription_running_job_state(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "subscription-finished-job-state")
    subscription_finished_job_state(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]);
else if (mode == "subscription-stale-job-state")
    subscription_stale_job_state(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "subscription-status-error")
    subscription_status_error(ARGV[1]);
else {
    warn("Usage: updates_runtime.uc <operation> ...\n");
    exit(1);
}
