#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");

const CONFIG_NAME = getenv("PODKOP_CONFIG_NAME") || "podkop-plus";
const LIB_DIR = getenv("PODKOP_LIB") || "/usr/lib/podkop-plus";
const BIN_PATH = getenv("PODKOP_BIN") || "/usr/bin/podkop-plus";
const SERVICE_INIT = getenv("PODKOP_SERVICE_INIT") || "/etc/init.d/podkop-plus";
const SERVICE_NAME = getenv("PODKOP_SERVICE_NAME") || "podkop-plus";
const STATE_UC = LIB_DIR + "/service/state.uc";
const UI_UC = LIB_DIR + "/service/ui.uc";
const STATE_DIR = getenv("PODKOP_UI_STATE_DIR") || "/var/run/podkop-plus/ui-state";
const PENDING_RELOAD_FILE = getenv("PODKOP_PENDING_RELOAD_FILE") || "/var/run/podkop-plus/reload.pending";
const SERVICE_ACTION_DIR = getenv("PODKOP_UI_SERVICE_ACTION_DIR") || STATE_DIR + "/service-actions";
const SERVICE_ACTION_LOCK_DIR = getenv("PODKOP_UI_SERVICE_ACTION_LOCK_DIR") || STATE_DIR + "/service-actions.lock";
const LATENCY_ACTION_DIR = getenv("PODKOP_UI_LATENCY_ACTION_DIR") || STATE_DIR + "/latency-actions";
const COMPONENT_ACTION_DIR = getenv("PODKOP_UI_COMPONENT_ACTION_DIR") || getenv("UPDATES_JOB_DIR") || "/var/run/podkop-plus/component-actions";
const SUBSCRIPTION_ACTION_DIR = getenv("PODKOP_UI_SUBSCRIPTION_ACTION_DIR") || getenv("PODKOP_SUBSCRIPTION_UPDATE_JOB_DIR") || "/var/run/podkop-plus/subscription-update-jobs";
const SING_BOX_VERSION_CACHE_FILE = getenv("PODKOP_UI_SING_BOX_VERSION_CACHE_FILE") || STATE_DIR + "/sing-box-version";
const SING_BOX_VERSION_STATE_FILE = getenv("PODKOP_UI_SING_BOX_VERSION_STATE_FILE") || "/etc/podkop-plus/sing-box-version";
const SING_BOX_VARIANT_STATE_FILE = getenv("PODKOP_UI_SING_BOX_VARIANT_STATE_FILE") || "/etc/podkop-plus/sing-box-variant";
const ACTION_FINISHED_TTL_MINUTES = getenv("PODKOP_UI_ACTION_FINISHED_TTL_MINUTES") || "60";
const ACTION_ACKED_TTL_SECONDS = getenv("PODKOP_UI_ACTION_ACKED_TTL_SECONDS") || "15";
const ACTION_STALE_GRACE_SECONDS = getenv("PODKOP_UI_ACTION_STALE_GRACE_SECONDS") || "15";
const SERVICE_ACTION_TIMEOUT_SECONDS = getenv("PODKOP_UI_SERVICE_ACTION_TIMEOUT_SECONDS") || "120";
const SERVICE_ACTION_SETTLE_SECONDS = getenv("PODKOP_UI_SERVICE_ACTION_SETTLE_SECONDS") || "2";
const RUNTIME_STABLE_MIN_AGE = getenv("PODKOP_RUNTIME_STABLE_MIN_AGE") || "2";
const NFT_TABLE_NAME = getenv("NFT_TABLE_NAME") || "PodkopPlusTable";
const RT_TABLE_NAME = getenv("RT_TABLE_NAME") || "podkop";
const NFT_FAKEIP_MARK = getenv("NFT_FAKEIP_MARK") || "0x00100000";
const SB_DNS_INBOUND_ADDRESS = getenv("SB_DNS_INBOUND_ADDRESS") || "127.0.0.42";
const ZAPRET_PROVIDER_NFQWS_BIN = getenv("ZAPRET_PROVIDER_NFQWS_BIN") || "/opt/zapret/nfq/nfqws";
const ZAPRET2_PROVIDER_NFQWS2_BIN = getenv("ZAPRET2_PROVIDER_NFQWS2_BIN") || "/opt/zapret2/nfq2/nfqws2";
const BYEDPI_BIN = getenv("BYEDPI_BIN") || "/usr/bin/ciadpi";

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

function parse_json_or_null(value) {
    try {
        return json(as_string(value));
    }
    catch (e) {
        return null;
    }
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function json_text(value) {
    return sprintf("%J", value) + "\n";
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

function command_env(assignments) {
    let parts = [];

    for (let name, value in assignments)
        push(parts, name + "=" + shell_quote(value));

    return join(" ", parts);
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

function command_status(command) {
    let status = int(system(command));
    return status > 255 ? int(status / 256) : status;
}

function command_success(command) {
    return command_status(command + " >/dev/null 2>&1") == 0;
}

function command_success_from_args(args) {
    return command_success(command_from_args(args));
}

function module_success(module_path, args) {
    let command_args = [ "ucode", "-L", LIB_DIR, module_path ];
    for (let arg in args)
        push(command_args, arg);
    return command_success_from_args(command_args);
}

function now_seconds() {
    return int(clock()[0]);
}

function ensure_dir(path) {
    command_success_from_args([ "mkdir", "-p", path ]);
}

function ensure_dirs() {
    for (let dir in [
        STATE_DIR,
        SERVICE_ACTION_DIR,
        LATENCY_ACTION_DIR,
        COMPONENT_ACTION_DIR,
        SUBSCRIPTION_ACTION_DIR
    ])
        ensure_dir(dir);
}

function write_file(path, value) {
    return fs.writefile(as_string(path), as_string(value)) != null;
}

function write_state_file(path, value) {
    path = as_string(path);
    let stamp = clock();
    let tmp_path = sprintf("%s.%d.%d.tmp", path, stamp[0], stamp[1]);

    if (!write_file(tmp_path, json_text(value))) {
        fs.unlink(tmp_path);
        return false;
    }
    if (!fs.rename(tmp_path, path)) {
        fs.unlink(tmp_path);
        return false;
    }
    return true;
}

function remove_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function remove_state_file(path) {
    path = as_string(path);
    let base = path;
    let suffix = ".json";
    if (length(base) >= length(suffix) && substr(base, length(base) - length(suffix)) == suffix)
        base = substr(base, 0, length(base) - length(suffix));
    remove_file(path);
    remove_file(base + ".out");
    remove_file(base + ".out.json");
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

function non_negative_number(value) {
    let number = arg_number(value);
    return number < 0 ? 0 : number;
}

function unsigned_number(value) {
    value = as_string(value);
    if (value == "" || match(value, /[^0-9]/) != null)
        return null;
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

function valid_action_state(value) {
    return type(value) == "object" && (value.running === true || value.running === false);
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
        if (!valid_action_state(value))
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

function print_service_status_text(running, enabled) {
    print(service_status_text(running, enabled), "\n");
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
            sing_box_compressed: arg_number(ARGV[10]),
            sing_box_tailscale: arg_number(ARGV[11]),
            zapret_installed: arg_number(ARGV[12]),
            zapret2_installed: arg_number(ARGV[13]),
            byedpi_installed: arg_number(ARGV[14]),
            server_inbounds_enabled_count: arg_number(ARGV[15])
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

function service_action_valid(action) {
    action = as_string(action);
    return action == "start" || action == "stop" || action == "restart" || action == "reload";
}

function latency_type_valid(latency_type) {
    latency_type = as_string(latency_type);
    return latency_type == "group" || latency_type == "proxy" || latency_type == "proxy_list";
}

function service_action_expected_running(action) {
    action = as_string(action);

    if (action == "start" || action == "restart" || action == "reload")
        print("1\n");
    else if (action == "stop")
        print("0\n");
    else
        exit(1);
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

function ack_action_state(path, acked_at) {
    let value = object_or_empty(read_json_file(path));
    if (value.running === false)
        value.acked_at = arg_number(acked_at);
    write_json(value);
}

function action_ack_expired(path, now_value, ttl_value) {
    let value = read_json_file(path);
    if (type(value) != "object")
        exit(1);

    let acked_at = unsigned_number(value.acked_at);
    let now = unsigned_number(now_value);
    let ttl = unsigned_number(ttl_value);

    if (acked_at == null || now == null || now <= 0 || ttl == null)
        exit(1);

    exit(now - acked_at >= ttl ? 0 : 1);
}

function json_file_field(path, key, fallback) {
    let value = read_json_file(path);
    if (type(value) == "object" && value[key] != null)
        print(as_string(value[key]), "\n");
    else
        print(as_string(fallback), "\n");
}

function job_state_path(dir, job_id) {
    dir = as_string(dir);
    job_id = as_string(job_id);

    if (job_id == "" || job_id == "." || job_id == ".." || match(job_id, /[^A-Za-z0-9._-]/) != null)
        exit(1);

    print(dir, "/", job_id, ".json\n");
}

function job_started_at_within_grace(value, now, grace_seconds) {
    let started_at = arg_number(value);
    now = arg_number(now);
    grace_seconds = arg_number(grace_seconds);

    if (started_at <= 0 || now <= 0)
        return false;

    return now - started_at < grace_seconds;
}

function job_pid_valid(pid) {
    pid = as_string(pid);
    return pid != "" && match(pid, /^[0-9]+$/) != null;
}

function job_refresh_plan(path, now, grace_seconds) {
    let value = read_json_file(path);
    if (type(value) != "object" || value.running !== true) {
        print("skip\n");
        return;
    }

    let within_grace = job_started_at_within_grace(value.started_at, now, grace_seconds);
    let pid = as_string(value.pid || "");
    if (!job_pid_valid(pid)) {
        print(within_grace ? "skip\n" : "stale\n");
        return;
    }

    print("pid\t", pid, "\t", within_grace ? "0" : "1", "\n");
}

function active_service_action(dir) {
    dir = as_string(dir || SERVICE_ACTION_DIR);

    for (let path in fs.glob(as_string(dir) + "/*.json")) {
        let value = read_json_file(path);
        if (type(value) == "object" && value.running === true && as_string(value.action) != "") {
            print(as_string(value.action), "\n");
            return;
        }
    }

    exit(1);
}

function active_service_action_value() {
    for (let path in fs.glob(SERVICE_ACTION_DIR + "/*.json")) {
        let value = read_json_file(path);
        if (type(value) == "object" && value.running === true && as_string(value.action) != "")
            return as_string(value.action);
    }

    return "";
}

function file_executable(path) {
    let stat = fs.stat(as_string(path));
    return stat != null && stat.mode != null && (int(stat.mode) & 73) != 0;
}

function first_line(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return "";

    let newline = index(data, "\n");
    return trim(newline >= 0 ? substr(data, 0, newline) : data);
}

function valid_job_id(job_id) {
    job_id = as_string(job_id);
    return job_id != "" && job_id != "." && job_id != ".." && match(job_id, /[^A-Za-z0-9._-]/) == null;
}

function job_state_path_value(dir, job_id) {
    if (!valid_job_id(job_id))
        return "";
    return as_string(dir) + "/" + as_string(job_id) + ".json";
}

function job_id() {
    let stamp = clock();
    return sprintf("%d-%d", stamp[0], stamp[1]);
}

function running_service_action_value(action, source, started_at) {
    return {
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
    };
}

function latency_progress_value(completed, total, failed) {
    let progress_total = non_negative_number(total);
    let progress_completed = non_negative_number(completed);
    if (progress_total > 0 && progress_completed > progress_total)
        progress_completed = progress_total;

    return {
        completed: progress_completed,
        total: progress_total,
        failed: non_negative_number(failed)
    };
}

function proxy_list_total(tag) {
    let value = parse_json_or_null(tag);
    if (type(value) != "array")
        return 0;

    let total = 0;
    for (let proxy_tag in value) {
        if (type(proxy_tag) == "string" && proxy_tag != "")
            total++;
    }

    return total;
}

function initial_latency_progress(latency_type, tag) {
    if (as_string(latency_type) != "proxy_list")
        return null;

    return latency_progress_value(0, proxy_list_total(tag), 0);
}

function running_latency_action_value(latency_type, section, tag, started_at) {
    let value = {
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
    };

    let progress = initial_latency_progress(latency_type, tag);
    if (type(progress) == "object")
        value.progress = progress;

    return value;
}

function latency_action_path_allowed(path) {
    path = as_string(path);
    let prefix = LATENCY_ACTION_DIR + "/";
    let suffix = ".json";
    return path != "" &&
        substr(path, 0, length(prefix)) == prefix &&
        length(path) > length(prefix) + length(suffix) &&
        substr(path, length(path) - length(suffix)) == suffix;
}

function update_latency_progress_state(path, completed, total, failed) {
    if (!latency_action_path_allowed(path))
        return false;

    let value = read_json_file(path);
    if (type(value) != "object" || value.kind != "latency" || value.running !== true)
        return false;

    value.progress = latency_progress_value(completed, total, failed);
    value.updated_at = now_seconds();
    return write_state_file(path, value);
}

function update_latency_progress_state_mode(path, completed, total, failed) {
    exit(update_latency_progress_state(path, completed, total, failed) ? 0 : 1);
}

function finished_action_state_value(path, success, message, exit_code, updated_at) {
    let value = object_or_empty(read_json_file(path));
    value.success = arg_bool(success);
    value.running = false;
    value.message = as_string(message);
    value.exit_code = as_string(exit_code) == "" ? null : arg_number(exit_code);
    value.updated_at = arg_number(updated_at);
    return value;
}

function stale_action_state_value(path, message, updated_at) {
    let value = object_or_empty(read_json_file(path));
    if (value.running === true) {
        value.success = false;
        value.running = false;
        value.message = as_string(message);
        value.exit_code = null;
        value.updated_at = arg_number(updated_at);
    }
    return value;
}

function ack_action_state_value(path, acked_at) {
    let value = object_or_empty(read_json_file(path));
    if (value.running === false)
        value.acked_at = arg_number(acked_at);
    return value;
}

function set_running_job_pid_file(path, pid) {
    pid = as_string(pid);
    if (!job_pid_valid(pid))
        return false;

    let value = object_or_empty(read_json_file(path));
    if (value.running === true) {
        value.pid = pid;
        return write_state_file(path, value);
    }

    return false;
}

function write_finished_action_state(path, success, message, exit_code) {
    return write_state_file(path, finished_action_state_value(path, success, message, exit_code, now_seconds()));
}

function write_stale_action_state(path, message) {
    return write_state_file(path, stale_action_state_value(path, message, now_seconds()));
}

function pid_running(pid) {
    pid = as_string(pid);
    return job_pid_valid(pid) && command_success_from_args([ "kill", "-0", pid ]);
}

function refresh_pid_job_state(path, stale_message) {
    let value = read_json_file(path);
    if (type(value) != "object" || value.running !== true)
        return;

    let now = now_seconds();
    let within_grace = job_started_at_within_grace(value.started_at, now, ACTION_STALE_GRACE_SECONDS);
    let pid = as_string(value.pid || "");

    if (job_pid_valid(pid) && pid_running(pid))
        return;

    if (!within_grace)
        write_stale_action_state(path, stale_message);
}

function state_file_ack_expired(path) {
    let value = read_json_file(path);
    if (type(value) != "object")
        return false;

    let acked_at = unsigned_number(value.acked_at);
    let now = now_seconds();
    let ttl = unsigned_number(ACTION_ACKED_TTL_SECONDS);
    return acked_at != null && now > 0 && ttl != null && now - acked_at >= ttl;
}

function cleanup_dir(dir) {
    dir = as_string(dir);
    for (let path in fs.glob(dir + "/*.json")) {
        let value = read_json_file(path);
        if (!valid_action_state(value)) {
            remove_state_file(path);
            continue;
        }
        if (value.running === false && state_file_ack_expired(path))
            remove_state_file(path);
    }

    let old = command_output_from_args([ "find", dir, "-type", "f", "-name", "*.json", "-mmin", "+" + as_string(ACTION_FINISHED_TTL_MINUTES) ]);
    for (let path in split(old, "\n")) {
        path = trim(as_string(path));
        if (path == "")
            continue;
        let value = read_json_file(path);
        if (type(value) == "object" && value.running === false)
            remove_state_file(path);
    }
}

function refresh_action_dirs() {
    ensure_dirs();
    cleanup_dir(SERVICE_ACTION_DIR);
    cleanup_dir(LATENCY_ACTION_DIR);
    cleanup_dir(COMPONENT_ACTION_DIR);
    cleanup_dir(SUBSCRIPTION_ACTION_DIR);

    for (let path in fs.glob(SERVICE_ACTION_DIR + "/*.json"))
        refresh_pid_job_state(path, "Service action worker exited unexpectedly");
    for (let path in fs.glob(LATENCY_ACTION_DIR + "/*.json"))
        refresh_pid_job_state(path, "Latency test worker exited unexpectedly");
    for (let path in fs.glob(COMPONENT_ACTION_DIR + "/*.json"))
        refresh_pid_job_state(path, "Component action worker exited unexpectedly");
    for (let path in fs.glob(SUBSCRIPTION_ACTION_DIR + "/*.json"))
        refresh_pid_job_state(path, "Subscription update worker exited unexpectedly");
}

function active_service_action_default() {
    refresh_action_dirs();
    active_service_action(SERVICE_ACTION_DIR);
}

function action_state_from_dir(dir) {
    let result = [];

    for (let path in fs.glob(as_string(dir) + "/*.json")) {
        let value = read_json_file(path);
        if (!valid_action_state(value))
            continue;

        value.job_id = job_id_from_path(path);
        push(result, value);
    }

    return result;
}

function action_state_from_dirs() {
    return {
        service: action_state_from_dir(SERVICE_ACTION_DIR),
        latency: action_state_from_dir(LATENCY_ACTION_DIR),
        component: action_state_from_dir(COMPONENT_ACTION_DIR),
        subscription: action_state_from_dir(SUBSCRIPTION_ACTION_DIR)
    };
}

function acquire_dir_lock(lock_dir) {
    lock_dir = as_string(lock_dir);
    let owner_pid = trim(command_output("sh -c 'echo $$'"));
    if (command_success_from_args([ "mkdir", lock_dir ])) {
        write_file(lock_dir + "/pid", owner_pid + "\n");
        return true;
    }

    let current_owner_pid = first_line(lock_dir + "/pid");
    if (pid_running(current_owner_pid))
        return false;

    remove_file(lock_dir + "/pid");
    command_success_from_args([ "rmdir", lock_dir ]);
    if (!command_success_from_args([ "mkdir", lock_dir ]))
        return false;

    write_file(lock_dir + "/pid", owner_pid + "\n");
    return true;
}

function release_dir_lock(lock_dir) {
    remove_file(as_string(lock_dir) + "/pid");
    command_success_from_args([ "rmdir", lock_dir ]);
}

function service_enabled() {
    return file_executable("/etc/rc.d/S99" + SERVICE_NAME);
}

function sing_box_enabled() {
    return file_executable("/etc/rc.d/S99sing-box");
}

function sing_box_running() {
    return module_success(LIB_DIR + "/service/state.uc", [
        "sing-box-service-stable",
        RUNTIME_STABLE_MIN_AGE
    ]);
}

function podkop_running() {
    return module_success(LIB_DIR + "/service/state.uc", [
        "podkop-stably-running",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_FAKEIP_MARK,
        RUNTIME_STABLE_MIN_AGE
    ]);
}

function dns_configured() {
    return index(uci_core.get("dhcp.@dnsmasq[0].server"), SB_DNS_INBOUND_ADDRESS) >= 0;
}

function marker_is(expected) {
    return first_line(SING_BOX_VARIANT_STATE_FILE) == as_string(expected);
}

function tiny_package_installed() {
    if (command_success_from_args([ "sh", "-c", "command -v apk" ]))
        return command_success_from_args([ "apk", "info", "-e", "sing-box-tiny" ]);

    let installed = command_output_from_args([ "opkg", "list-installed" ]);
    for (let line in split(installed, "\n"))
        if (split(trim(as_string(line)), /[ \t]+/)[0] == "sing-box-tiny")
            return true;

    return false;
}

function component_action_running_for(component) {
    component = as_string(component);
    for (let path in fs.glob(COMPONENT_ACTION_DIR + "/*.json")) {
        let value = read_json_file(path);
        if (type(value) == "object" && value.running === true && as_string(value.component) == component)
            return true;
    }

    return false;
}

function sing_box_signature() {
    let fields = split(trim(command_output_from_args([ "ls", "-ln", "/usr/bin/sing-box" ])), /[ \t]+/);
    if (length(fields) < 8)
        return "";

    return join(":", [ fields[4], fields[5], fields[6], fields[7] ]);
}

function sing_box_version_state() {
    return first_line(SING_BOX_VERSION_STATE_FILE);
}

function sing_box_version() {
    if (!command_success_from_args([ "sh", "-c", "command -v sing-box" ]))
        return "";

    if (marker_is("extended-compressed"))
        return sing_box_version_state();

    let signature = sing_box_signature();
    if (signature != "" && fs.stat(SING_BOX_VERSION_CACHE_FILE) != null) {
        let data = split(as_string(fs.readfile(SING_BOX_VERSION_CACHE_FILE)), "\n");
        if ((data[0] || "") == signature && as_string(data[1] || "") != "")
            return as_string(data[1]);
    }

    let first = split(command_output_from_args([ "sing-box", "version" ]), "\n")[0] || "";
    let fields = split(trim(as_string(first)), /[ \t]+/);
    let version = length(fields) > 0 ? fields[length(fields) - 1] : "";
    if (version == "")
        return "";

    if (signature != "") {
        ensure_dir(STATE_DIR);
        write_file(SING_BOX_VERSION_CACHE_FILE, signature + "\n" + version + "\n");
    }

    return version;
}

function server_inbounds_enabled_count() {
    let count = 0;
    for (let section in uci_core.section_objects(CONFIG_NAME, "server")) {
        section = object_or_empty(section);
        let enabled = section.enabled == null ? "1" : as_string(section.enabled);
        if (enabled != "0")
            count++;
    }
    return count;
}

function capability_flags() {
    let result = {
        sing_box_extended: 0,
        sing_box_tiny: 0,
        sing_box_compressed: 0,
        sing_box_tailscale: 0,
        zapret_installed: file_executable(ZAPRET_PROVIDER_NFQWS_BIN) ? 1 : 0,
        zapret2_installed: file_executable(ZAPRET2_PROVIDER_NFQWS2_BIN) ? 1 : 0,
        byedpi_installed: file_executable(BYEDPI_BIN) ? 1 : 0,
        server_inbounds_enabled_count: 0
    };

    if (command_success_from_args([ "sh", "-c", "command -v sing-box" ])) {
        if (marker_is("extended-compressed")) {
            result.sing_box_extended = 1;
            result.sing_box_compressed = 1;
            result.sing_box_tailscale = 1;
        }
        else if (marker_is("extended")) {
            result.sing_box_extended = 1;
            result.sing_box_tailscale = 1;
        }
        else if (tiny_package_installed() || marker_is("tiny")) {
            result.sing_box_tiny = 1;
        }
        else if (component_action_running_for("sing_box")) {
            result.sing_box_tailscale = 1;
        }
        else {
            let output = command_output_from_args([ "sing-box", "version" ]);
            let first = split(output, "\n")[0] || "";
            let fields = split(trim(as_string(first)), /[ \t]+/);
            let version = length(fields) > 0 ? fields[length(fields) - 1] : "";
            if (index(version, "extended") >= 0) {
                result.sing_box_extended = 1;
                result.sing_box_tailscale = 1;
            }
            else {
                let tags = "";
                for (let line in split(output, "\n")) {
                    line = as_string(line);
                    if (substr(line, 0, 5) == "Tags:") {
                        tags = trim(substr(line, 5));
                        break;
                    }
                }
                if (match(tags, /(^|[,: \t])with_tailscale([, \t]|$)/) != null)
                    result.sing_box_tailscale = 1;
                if (result.sing_box_tailscale == 0)
                    result.sing_box_tiny = 1;
            }
        }
    }

    result.server_inbounds_enabled_count = server_inbounds_enabled_count();
    return result;
}

function ui_capabilities_json() {
    write_json(capability_flags());
}

function current_ui_state_json() {
    refresh_action_dirs();

    let capabilities = capability_flags();
    let podkop_is_running = podkop_running() ? 1 : 0;
    let podkop_is_enabled = service_enabled() ? 1 : 0;
    let sing_box_is_running = sing_box_running() ? 1 : 0;
    let sing_box_is_enabled = sing_box_enabled() ? 1 : 0;
    let podkop_status = service_status_text(podkop_is_running, podkop_is_enabled);
    let sing_box_status = service_status_text(sing_box_is_running, sing_box_is_enabled);
    let active_action = active_service_action_value();

    if (active_action == "start")
        podkop_status = "starting";
    else if (active_action == "stop")
        podkop_status = "stopping";
    else if (active_action == "restart")
        podkop_status = "restarting";
    else if (active_action == "reload")
        podkop_status = "reloading";

    write_json({
        service: {
            podkop: {
                running: podkop_is_running,
                enabled: podkop_is_enabled,
                status: podkop_status,
                dns_configured: dns_configured() ? 1 : 0
            },
            sing_box: {
                running: sing_box_is_running,
                enabled: sing_box_is_enabled,
                status: sing_box_status
            }
        },
        capabilities,
        actions: action_state_from_dirs()
    });
}

function service_action_expected_running_value(action) {
    action = as_string(action);
    if (action == "start" || action == "restart" || action == "reload")
        return 1;
    if (action == "stop")
        return 0;
    return -1;
}

function service_action_reached_expected_state(action) {
    let expected = service_action_expected_running_value(action);
    if (expected < 0)
        return false;
    return expected == 1 ? podkop_running() : !podkop_running();
}

function service_action_wait_for_expected_state(action, timeout, settle_seconds) {
    timeout = arg_number(timeout || SERVICE_ACTION_TIMEOUT_SECONDS);
    settle_seconds = arg_number(settle_seconds || SERVICE_ACTION_SETTLE_SECONDS);
    let deadline = now_seconds() + timeout;
    let stable_seconds = 0;

    while (true) {
        if (service_action_reached_expected_state(action)) {
            stable_seconds++;
            if (stable_seconds >= settle_seconds)
                return true;
        }
        else {
            stable_seconds = 0;
        }

        if (now_seconds() >= deadline)
            return false;
        system("sleep 1");
    }
}

function begin_service_action_if_idle(action, source) {
    action = as_string(action);
    source = as_string(source || "ui");
    if (!service_action_valid(action))
        return { status: 1, job_id: "" };

    ensure_dirs();
    if (!acquire_dir_lock(SERVICE_ACTION_LOCK_DIR))
        return { status: 2, job_id: "" };

    refresh_action_dirs();
    if (active_service_action_value() != "") {
        release_dir_lock(SERVICE_ACTION_LOCK_DIR);
        return { status: 2, job_id: "" };
    }

    let id = job_id();
    let path = job_state_path_value(SERVICE_ACTION_DIR, id);
    if (path == "" || !write_state_file(path, running_service_action_value(action, source, now_seconds()))) {
        release_dir_lock(SERVICE_ACTION_LOCK_DIR);
        return { status: 1, job_id: "" };
    }

    release_dir_lock(SERVICE_ACTION_LOCK_DIR);
    return { status: 0, job_id: id };
}

function begin_service_action_mode(action, source) {
    let result = begin_service_action_if_idle(action, source || "ui");
    if (result.status == 0)
        print(result.job_id, "\n");
    exit(result.status);
}

function finish_service_action(job_id_value, success, message, exit_code) {
    let path = job_state_path_value(SERVICE_ACTION_DIR, job_id_value);
    if (path == "" || fs.stat(path) == null)
        return false;
    return write_finished_action_state(path, success, message, exit_code);
}

function finish_service_action_mode(job_id_value, success, message, exit_code) {
    exit(finish_service_action(job_id_value, success, message, exit_code) ? 0 : 1);
}

function launch_worker(args) {
    let command_args = [ "ucode", "-L", LIB_DIR, UI_UC ];
    for (let arg in args)
        push(command_args, arg);

    let command = command_env({
        PODKOP_CONFIG_NAME: CONFIG_NAME,
        PODKOP_LIB: LIB_DIR,
        PODKOP_BIN: BIN_PATH,
        PODKOP_SERVICE_INIT: SERVICE_INIT,
        PODKOP_SERVICE_NAME: SERVICE_NAME,
        PODKOP_UI_STATE_DIR: STATE_DIR,
        PODKOP_UI_SERVICE_ACTION_DIR: SERVICE_ACTION_DIR,
        PODKOP_UI_SERVICE_ACTION_LOCK_DIR: SERVICE_ACTION_LOCK_DIR,
        PODKOP_UI_LATENCY_ACTION_DIR: LATENCY_ACTION_DIR,
        PODKOP_UI_COMPONENT_ACTION_DIR: COMPONENT_ACTION_DIR,
        PODKOP_UI_SUBSCRIPTION_ACTION_DIR: SUBSCRIPTION_ACTION_DIR,
        PODKOP_UI_SING_BOX_VERSION_CACHE_FILE: SING_BOX_VERSION_CACHE_FILE,
        PODKOP_UI_SING_BOX_VERSION_STATE_FILE: SING_BOX_VERSION_STATE_FILE,
        PODKOP_UI_SING_BOX_VARIANT_STATE_FILE: SING_BOX_VARIANT_STATE_FILE,
        PODKOP_UI_ACTION_FINISHED_TTL_MINUTES: ACTION_FINISHED_TTL_MINUTES,
        PODKOP_UI_ACTION_ACKED_TTL_SECONDS: ACTION_ACKED_TTL_SECONDS,
        PODKOP_UI_ACTION_STALE_GRACE_SECONDS: ACTION_STALE_GRACE_SECONDS,
        PODKOP_UI_SERVICE_ACTION_TIMEOUT_SECONDS: SERVICE_ACTION_TIMEOUT_SECONDS,
        PODKOP_UI_SERVICE_ACTION_SETTLE_SECONDS: SERVICE_ACTION_SETTLE_SECONDS,
        PODKOP_PENDING_RELOAD_FILE: PENDING_RELOAD_FILE,
        NFT_TABLE_NAME,
        RT_TABLE_NAME,
        NFT_FAKEIP_MARK,
        SB_DNS_INBOUND_ADDRESS,
        ZAPRET_PROVIDER_NFQWS_BIN,
        ZAPRET2_PROVIDER_NFQWS2_BIN,
        BYEDPI_BIN
    }) + " " +
        command_from_args(command_args) +
        " >/dev/null 2>&1 1000>&- & echo $!";
    return trim(command_output("sh -c " + shell_quote(command)));
}

function start_service_action(action, source, reason) {
    let begin = begin_service_action_if_idle(action, source || "ui");
    if (begin.status != 0)
        return { success: false, job_id: "" };

    let path = job_state_path_value(SERVICE_ACTION_DIR, begin.job_id);
    if (path == "")
        return { success: false, job_id: begin.job_id };

    let pid = launch_worker([ "service-action-worker", path, action, begin.job_id, reason || "" ]);
    if (pid == "" || !set_running_job_pid_file(path, pid)) {
        if (pid != "")
            command_success_from_args([ "kill", pid ]);
        write_finished_action_state(path, false, "Failed to write service action worker pid", 1);
        return { success: false, job_id: begin.job_id };
    }

    return { success: true, job_id: begin.job_id };
}

function service_action_allows_pending_reload(action) {
    action = as_string(action);
    return action == "start" || action == "restart" || action == "reload";
}

function consume_pending_reload() {
    return command_success_from_args([
        "ucode",
        "-L", LIB_DIR,
        STATE_UC,
        "consume-pending-reload",
        PENDING_RELOAD_FILE
    ]);
}

function mark_pending_reload(reason) {
    return command_success_from_args([
        "ucode",
        "-L", LIB_DIR,
        STATE_UC,
        "mark-pending-reload",
        PENDING_RELOAD_FILE,
        reason
    ]);
}

function run_pending_reload_after_service_action(action, success) {
    if (!success || !service_action_allows_pending_reload(action) || fs.stat(STATE_UC) == null)
        return;

    if (!consume_pending_reload())
        return;

    command_success_from_args([ "logger", "-t", SERVICE_NAME, "[info] Applying pending Podkop Plus reload" ]);
    let started = start_service_action("reload", "initd", "pending");
    if (!started.success)
        mark_pending_reload("pending");
}

function write_finished_service_action_state(path, action, success, message, exit_code) {
    let written = write_finished_action_state(path, success, message, exit_code);
    if (written)
        run_pending_reload_after_service_action(action, success);
    return written;
}

function finish_service_action_after_command(action, job_id_value, status, spawn_waiter) {
    status = arg_number(status);
    if (as_string(job_id_value) == "")
        return 0;

    let path = job_state_path_value(SERVICE_ACTION_DIR, job_id_value);
    if (path == "" || fs.stat(path) == null)
        return 0;

    if (status != 0) {
        write_finished_service_action_state(path, action, false, "Service " + as_string(action) + " failed", status);
        return 0;
    }

    if (!service_enabled() && !podkop_running()) {
        write_finished_service_action_state(path, action, true, "Service " + as_string(action) + " completed", 0);
        return 0;
    }

    if (spawn_waiter) {
        let pid = launch_worker([ "service-action-wait-worker", path, as_string(action), as_string(job_id_value) ]);
        if (pid != "")
            set_running_job_pid_file(path, pid);
        return 0;
    }

    if (service_action_wait_for_expected_state(action, SERVICE_ACTION_TIMEOUT_SECONDS, SERVICE_ACTION_SETTLE_SECONDS))
        write_finished_service_action_state(path, action, true, "Service " + as_string(action) + " completed", 0);
    else
        write_finished_service_action_state(path, action, false, "Service " + as_string(action) + " did not reach expected state", 1);
    return 0;
}

function finish_service_action_after_command_mode(action, job_id_value, status) {
    finish_service_action_after_command(action, job_id_value, status, true);
}

function update_service_action_pid_mode(job_id_value, pid) {
    let path = job_state_path_value(SERVICE_ACTION_DIR, job_id_value);
    exit(path != "" && set_running_job_pid_file(path, pid) ? 0 : 1);
}

function service_action_worker(path, action, job_id_value, reason) {
    let args = [ SERVICE_INIT, action ];
    reason = as_string(reason || "");
    if (reason != "")
        push(args, reason);
    let command = "PODKOP_UI_ACTION_TRACKED=1 " + command_from_args(args) + " >/dev/null 2>&1";
    let status = command_status(command);
    finish_service_action_after_command(action, job_id_value, status, false);
}

function service_action_wait_worker(path, action, job_id_value) {
    if (service_action_wait_for_expected_state(action, SERVICE_ACTION_TIMEOUT_SECONDS, SERVICE_ACTION_SETTLE_SECONDS))
        write_finished_service_action_state(path, action, true, "Service " + as_string(action) + " completed", 0);
    else
        write_finished_service_action_state(path, action, false, "Service " + as_string(action) + " did not reach expected state", 1);
}

function service_action_async(action) {
    action = as_string(action);
    if (!service_action_valid(action)) {
        action_start_response(false, "", "Invalid service action");
        exit(1);
    }

    let started = start_service_action(action, "ui", "");
    if (!started.success && active_service_action_value() != "") {
        action_start_response(false, "", "Another service action is already running");
        exit(1);
    }
    if (!started.success) {
        action_start_response(false, "", "Failed to write service action worker pid");
        exit(1);
    }

    action_start_response(true, started.job_id, "Service " + action + " started");
}

function service_action_status(job_id_value) {
    let path = job_state_path_value(SERVICE_ACTION_DIR, job_id_value);
    if (path == "") {
        action_start_response(false, "", "Invalid service action job id");
        exit(1);
    }
    if (fs.stat(path) == null) {
        action_start_response(false, "", "Service action job was not found");
        exit(1);
    }

    refresh_pid_job_state(path, "Service action worker exited unexpectedly");
    print(as_string(fs.readfile(path)));
}

function latency_clash_method(latency_type) {
    latency_type = as_string(latency_type);
    if (latency_type == "group")
        return { method: "get_group_latency", timeout: "10000" };
    if (latency_type == "proxy_list")
        return { method: "get_proxy_latencies", timeout: "5000" };
    return { method: "get_proxy_latency", timeout: "5000" };
}

function latency_worker(path, latency_type, tag, timeout) {
    let method = latency_clash_method(latency_type).method;
    let status = command_status(command_from_args([ BIN_PATH, "clash_api", method, tag, timeout, path ]) + " >/dev/null 2>&1");
    if (status == 0)
        write_finished_action_state(path, true, "Latency test completed", status);
    else
        write_finished_action_state(path, false, "Latency test failed", status);
}

function latency_test_async(latency_type, section, tag, requested_timeout) {
    latency_type = as_string(latency_type);
    tag = as_string(tag);
    if (!latency_type_valid(latency_type)) {
        action_start_response(false, "", "Invalid latency test type");
        exit(1);
    }
    if (tag == "") {
        action_start_response(false, "", "Latency test tag is required");
        exit(1);
    }

    ensure_dirs();
    let id = job_id();
    let path = job_state_path_value(LATENCY_ACTION_DIR, id);
    if (path == "" || !write_state_file(path, running_latency_action_value(latency_type, section, tag, now_seconds()))) {
        action_start_response(false, "", "Failed to write latency test state");
        exit(1);
    }

    let plan = latency_clash_method(latency_type);
    let timeout = as_string(requested_timeout) != "" ? as_string(requested_timeout) : plan.timeout;
    let pid = launch_worker([ "latency-worker", path, latency_type, tag, timeout ]);
    if (pid == "" || !set_running_job_pid_file(path, pid)) {
        if (pid != "")
            command_success_from_args([ "kill", pid ]);
        action_start_response(false, "", "Failed to write latency test worker pid");
        exit(1);
    }

    action_start_response(true, id, "Latency test started");
}

function latency_test_status(job_id_value) {
    let path = job_state_path_value(LATENCY_ACTION_DIR, job_id_value);
    if (path == "") {
        action_start_response(false, "", "Invalid latency test job id");
        exit(1);
    }
    if (fs.stat(path) == null) {
        action_start_response(false, "", "Latency test job was not found");
        exit(1);
    }

    refresh_pid_job_state(path, "Latency test worker exited unexpectedly");
    print(as_string(fs.readfile(path)));
}

function action_dir(kind) {
    kind = as_string(kind);
    if (kind == "service")
        return SERVICE_ACTION_DIR;
    if (kind == "latency")
        return LATENCY_ACTION_DIR;
    if (kind == "component")
        return COMPONENT_ACTION_DIR;
    if (kind == "subscription")
        return SUBSCRIPTION_ACTION_DIR;
    return "";
}

function action_ack(kind, job_id_value) {
    let dir = action_dir(kind);
    if (dir == "") {
        action_start_response(false, "", "Invalid UI action kind");
        exit(1);
    }

    let path = job_state_path_value(dir, job_id_value);
    if (path == "") {
        action_start_response(false, "", "Invalid UI action job id");
        exit(1);
    }

    if (fs.stat(path) == null) {
        action_start_response(true, job_id_value, "UI action already acknowledged");
        return;
    }

    let value = read_json_file(path);
    if (type(value) == "object" && value.running === true) {
        action_start_response(false, job_id_value, "UI action is still running");
        exit(1);
    }

    if (!write_state_file(path, ack_action_state_value(path, now_seconds()))) {
        action_start_response(false, job_id_value, "Failed to acknowledge UI action");
        exit(1);
    }

    action_start_response(true, job_id_value, "UI action acknowledged");
}

let mode = ARGV[0] || "";

if (mode == "ui-state-json")
    ui_state_json();
else if (mode == "get-ui-capabilities")
    ui_capabilities_json();
else if (mode == "get-ui-state")
    current_ui_state_json();
else if (mode == "service-status-text")
    print_service_status_text(ARGV[1], ARGV[2]);
else if (mode == "action-start-response")
    action_start_response(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "service-action-valid")
    exit(service_action_valid(ARGV[1]) ? 0 : 1);
else if (mode == "latency-type-valid")
    exit(latency_type_valid(ARGV[1]) ? 0 : 1);
else if (mode == "service-action-expected-running")
    service_action_expected_running(ARGV[1]);
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
else if (mode == "ack-action-state")
    ack_action_state(ARGV[1], ARGV[2]);
else if (mode == "action-ack-expired")
    action_ack_expired(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "json-file-field")
    json_file_field(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "job-state-path")
    job_state_path(ARGV[1], ARGV[2]);
else if (mode == "job-refresh-plan")
    job_refresh_plan(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "active-service-action")
    ARGV[1] == null ? active_service_action_default() : active_service_action(ARGV[1]);
else if (mode == "component-action-running-for")
    exit(component_action_running_for(ARGV[1]) ? 0 : 1);
else if (mode == "service-action-begin-if-idle")
    begin_service_action_mode(ARGV[1], ARGV[2] || "ui");
else if (mode == "service-action-update-pid")
    update_service_action_pid_mode(ARGV[1], ARGV[2]);
else if (mode == "service-action-finish")
    finish_service_action_mode(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "latency-progress-state")
    update_latency_progress_state_mode(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "service-action-finish-after-command")
    finish_service_action_after_command_mode(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "service-action-wait-worker")
    service_action_wait_worker(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "service-action-worker")
    service_action_worker(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "service-action-async")
    service_action_async(ARGV[1]);
else if (mode == "service-action-status")
    service_action_status(ARGV[1]);
else if (mode == "latency-worker")
    latency_worker(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "latency-test-async")
    latency_test_async(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "latency-test-status")
    latency_test_status(ARGV[1]);
else if (mode == "action-ack")
    action_ack(ARGV[1], ARGV[2]);
else if (mode == "cleanup-action-dir-fixture")
    cleanup_dir(ARGV[1]);
else {
    warn("Usage: service/ui.uc <operation> ...\n");
    exit(1);
}
