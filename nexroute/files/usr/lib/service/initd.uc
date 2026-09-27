#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let uci_core = require("core.uci");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function constant_value(name, fallback) {
    let value = constants[name];
    return value == null ? as_string(fallback) : as_string(value);
}

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || constant_value("FORKOP_CONFIG_NAME", "forkop");
const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const BIN_PATH = getenv("FORKOP_BIN") || constant_value("FORKOP_BIN", "/usr/bin/forkop");
const SERVICE_INIT = getenv("FORKOP_SERVICE_INIT") || constant_value("FORKOP_SERVICE_INIT", "/etc/init.d/forkop");
const SERVICE_NAME = getenv("FORKOP_SERVICE_NAME") || constant_value("FORKOP_SERVICE_NAME", "forkop");
const CONFIG_FILE = getenv("FORKOP_CONFIG_FILE") || "/etc/config/" + CONFIG_NAME;
const RELOAD_LOCK_DIR = getenv("FORKOP_RELOAD_LOCK_DIR") || "/var/run/forkop.reload.lock";
const RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const PENDING_RELOAD_FILE = getenv("FORKOP_PENDING_RELOAD_FILE") || RUNTIME_STATE_DIR + "/reload.pending";
const START_RETRY_FILE = getenv("FORKOP_START_RETRY_FILE") || RUNTIME_STATE_DIR + "/start.retry";
const START_RETRY_PID_FILE = getenv("FORKOP_START_RETRY_PID_FILE") || RUNTIME_STATE_DIR + "/start-retry.pid";
const START_RETRY_DELAY_SECONDS = getenv("FORKOP_START_RETRY_DELAY_SECONDS") || "30";
const SERVICE_TRIGGER_SYNC_FILE = getenv("FORKOP_SERVICE_TRIGGER_SYNC_FILE") || RUNTIME_STATE_DIR + "/service-triggers.sync";
const INTERNAL_CONFIG_TRIGGER_GUARD = getenv("FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD") || "/var/run/forkop.internal-config-change";
const CONFIG_CHANGE_REASON = getenv("FORKOP_CONFIG_CHANGE_REASON") || "on_config_change";

const DNS_APPLY_UC = LIB_DIR + "/dns/apply.uc";
const UI_UC = LIB_DIR + "/service/ui.uc";

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function shell_assignment(name, value) {
    print(as_string(name), "=", shell_quote(value), "\n");
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function normalize_status(status) {
    status = int(status);
    return status > 255 ? int(status / 256) : status;
}

function command_status(command) {
    return normalize_status(system(command));
}

function command_capture(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return { status: 1, output: "" };

    let data = pipe.read("all");
    let status = normalize_status(pipe.close());
    return { status, output: data == null ? "" : as_string(data) };
}

function command_output(command) {
    let result = command_capture(command);
    return result.status == 0 ? result.output : "";
}

function command_output_from_args(args) {
    return command_output(command_from_args(args) + " 2>/dev/null");
}

function command_success_from_args(args) {
    return command_status(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function command_status_from_args(args) {
    return command_status(command_from_args(args));
}

function module_args(module_path, args) {
    let result = [ "ucode", "-L", LIB_DIR, module_path ];
    for (let arg in (type(args) == "array" ? args : []))
        push(result, arg);
    return result;
}

function module_command(module_path, args) {
    return command_from_args(module_args(module_path, args));
}

function module_status(module_path, args) {
    return command_status(module_command(module_path, args));
}

function module_output(module_path, args) {
    let result = command_capture(module_command(module_path, args));
    return result.status == 0 ? result.output : "";
}

function trim(value) {
    return replace(as_string(value), /^[ \t\r\n]+|[ \t\r\n]+$/g, "");
}

function numeric_text(value) {
    return match(as_string(value), /^[0-9]+$/) != null;
}

function current_epoch() {
    return as_string(int(clock()[0]));
}

function bool_text(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function option(section, key, fallback) {
    if (fallback == null)
        fallback = "";
    let value = object_or_empty(section)[key];
    if (value == null)
        return as_string(fallback);
    if (type(value) == "array")
        return join(" ", value);
    return as_string(value);
}

function file_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function file_executable(path) {
    return command_success_from_args([ "test", "-x", as_string(path) ]);
}

function unlink_file(path) {
    fs.unlink(as_string(path));
}

function ensure_parent_dir(path) {
    let dir = replace(as_string(path), /\/[^\/]*$/, "");
    if (dir == "" || dir == path)
        return true;
    return fs.mkdir(dir, 0755) || fs.stat(dir) != null;
}

function write_text_file(path, text) {
    return fs.writefile(as_string(path), as_string(text));
}

function first_line_value(path) {
    let data = fs.readfile(path);
    if (data == null)
        return "";

    let newline = index(data, "\n");
    return newline >= 0 ? substr(data, 0, newline) : data;
}

function config_file_hash(path) {
    let fields = split(trim(command_output_from_args([ "md5sum", as_string(path) ])), " ");
    return length(fields) > 0 ? as_string(fields[0]) : "";
}

function pid_alive(pid) {
    pid = as_string(pid);
    return match(pid, /^[0-9]+$/) != null && command_success_from_args([ "kill", "-0", pid ]);
}

function lock_dir_write_owner(lock_dir, owner_pid) {
    return write_text_file(as_string(lock_dir) + "/pid", as_string(owner_pid) + "\n");
}

function acquire_runtime_dir_lock(lock_dir, owner_pid) {
    lock_dir = as_string(lock_dir);
    owner_pid = as_string(owner_pid);
    if (lock_dir == "" || owner_pid == "")
        return false;

    if (command_success_from_args([ "mkdir", lock_dir ])) {
        if (lock_dir_write_owner(lock_dir, owner_pid))
            return true;
        release_runtime_dir_lock(lock_dir);
        return false;
    }

    if (pid_alive(first_line_value(lock_dir + "/pid")))
        return false;

    command_success_from_args([ "rm", "-f", lock_dir + "/pid" ]);
    if (!command_success_from_args([ "rmdir", lock_dir ]))
        return false;
    if (!command_success_from_args([ "mkdir", lock_dir ]))
        return false;

    if (lock_dir_write_owner(lock_dir, owner_pid))
        return true;

    release_runtime_dir_lock(lock_dir);
    return false;
}

function release_runtime_dir_lock(lock_dir) {
    lock_dir = as_string(lock_dir);
    if (lock_dir == "")
        return;

    command_success_from_args([ "rm", "-f", lock_dir + "/pid" ]);
    command_success_from_args([ "rmdir", lock_dir ]);
}

function mark_pending_reload(path, reason) {
    path = as_string(path || PENDING_RELOAD_FILE);
    reason = as_string(reason || "pending");

    if (!ensure_parent_dir(path))
        return false;

    return write_text_file(path, "reason=" + reason + "\nupdated_at=" + current_epoch() + "\n");
}

function mark_start_retry(path, reason) {
    path = as_string(path || START_RETRY_FILE);
    reason = as_string(reason || "start_failed");

    if (!ensure_parent_dir(path))
        return false;

    return write_text_file(path, "reason=" + reason + "\nupdated_at=" + current_epoch() + "\n");
}

function clear_start_retry(path) {
    path = as_string(path || START_RETRY_FILE);
    if (file_exists(path))
        unlink_file(path);
}

function start_retry_pending(path) {
    return file_exists(as_string(path || START_RETRY_FILE));
}

function cancel_scheduled_start_retry(path) {
    path = as_string(path || START_RETRY_PID_FILE);
    let pid = first_line_value(path);
    if (pid_alive(pid))
        command_success_from_args([ "kill", pid ]);
    if (file_exists(path))
        unlink_file(path);
}

function schedule_start_retry(path, delay_seconds) {
    path = as_string(path || START_RETRY_PID_FILE);
    delay_seconds = as_string(delay_seconds || START_RETRY_DELAY_SECONDS);
    if (!numeric_text(delay_seconds))
        delay_seconds = "30";

    let scheduled_pid = first_line_value(path);
    if (pid_alive(scheduled_pid))
        return true;
    if (file_exists(path))
        unlink_file(path);
    if (!ensure_parent_dir(path))
        return false;

    let worker = command_from_args([ "sleep", delay_seconds ]) +
        "; " + command_from_args([ "rm", "-f", path ]) +
        "; exec " + command_from_args([ SERVICE_INIT, "retry_start_on_wan_up" ]);
    let result = command_capture(command_from_args([ "sh", "-c", worker ]) + " >/dev/null 2>&1 & echo $!");
    let pid = trim(result.output);
    if (result.status != 0 || !numeric_text(pid))
        return false;

    return write_text_file(path, pid + "\n");
}

function consume_pending_reload(path) {
    path = as_string(path || PENDING_RELOAD_FILE);
    if (!file_exists(path))
        return false;

    unlink_file(path);
    return true;
}

function run_pending_reload_if_requested(path, init_script) {
    path = as_string(path || PENDING_RELOAD_FILE);
    init_script = as_string(init_script || SERVICE_INIT);

    if (!consume_pending_reload(path))
        return;

    command_success_from_args([ "logger", "-t", SERVICE_NAME, "[info] Applying pending Forkop reload" ]);
    system(shell_quote(init_script) + " reload pending >/dev/null 2>&1 1000>&- &");
}

function uci_settings() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function settings_from_fixture(path) {
    let data = fs.readfile(path);
    if (data == null)
        return {};
    try {
        data = json(data);
    }
    catch (e) {
        return {};
    }
    return object_or_empty(object_or_empty(data).settings);
}

function initd_service_trigger_sync_requested(path) {
    path = as_string(path);
    if (!file_exists(path))
        return false;

    let value = first_line_value(path);
    unlink_file(path);
    return value == "1";
}

function initd_guard_matches_current_config(guard_path, config_path, now_value) {
    let guard_timestamp = first_line_value(guard_path);
    if (!numeric_text(guard_timestamp))
        return false;

    now_value = now_value == null ? current_epoch() : as_string(now_value);
    if (!numeric_text(now_value))
        return true;

    if (int(now_value, 10) - int(guard_timestamp, 10) > 30)
        return false;

    let data = fs.readfile(guard_path);
    if (data == null)
        return false;

    let lines = split(data, "\n");
    let guard_hash = length(lines) > 1 ? as_string(lines[1]) : "";
    if (guard_hash == "")
        return false;

    return guard_hash == config_file_hash(config_path);
}

function initd_should_skip_internal_config_reload(reason, guard_path, config_path, expected_reason, now_value) {
    if (as_string(reason) != as_string(expected_reason || CONFIG_CHANGE_REASON))
        return false;
    if (!file_exists(as_string(guard_path)))
        return false;

    let matches = initd_guard_matches_current_config(guard_path, config_path, now_value);
    unlink_file(guard_path);
    return matches;
}

function initd_should_restore_dnsmasq_on_start_from_value(reason, shutdown_correctly) {
    if (as_string(reason) == "triggered")
        return false;

    shutdown_correctly = as_string(shutdown_correctly);
    if (shutdown_correctly == "")
        shutdown_correctly = "1";
    return shutdown_correctly == "0";
}

function initd_should_ignore_config_change_reload(reason, expected_reason, runtime_running, service_enabled) {
    return as_string(reason) == as_string(expected_reason || CONFIG_CHANGE_REASON) &&
        !bool_text(runtime_running);
}

function initd_should_queue_config_change_reload(reason, expected_reason, runtime_running, active_service_action) {
    return as_string(reason) == as_string(expected_reason || CONFIG_CHANGE_REASON) &&
        !bool_text(runtime_running) &&
        as_string(active_service_action) != "";
}

function initd_should_sync_service_triggers(reason, expected_reason, sync_file) {
    if (as_string(reason) != as_string(expected_reason || CONFIG_CHANGE_REASON))
        return false;
    return initd_service_trigger_sync_requested(sync_file);
}

function restore_dnsmasq_failsafe() {
    if (!file_exists(DNS_APPLY_UC))
        return 0;
    return module_status(DNS_APPLY_UC, [ "failsafe-restore" ]);
}

function begin_external_service_action(action, source, owner_pid) {
    if (as_string(getenv("FORKOP_UI_ACTION_TRACKED") || "0") == "1")
        return "";
    if (!file_exists(UI_UC))
        return "";

    let job_id = trim(module_output(UI_UC, [ "service-action-begin-if-idle", action, source || "initd" ]));
    if (job_id != "")
        module_status(UI_UC, [ "service-action-update-pid", job_id, owner_pid || owner_pid_value() ]);

    return job_id;
}

function finish_external_service_action(action, job_id, status) {
    if (as_string(job_id) == "" || !file_exists(UI_UC))
        return 0;
    return module_status(UI_UC, [ "service-action-finish-after-command", action, job_id, as_string(status) ]);
}

function owner_pid_value() {
    let pid = trim(command_output_from_args([ "sh", "-c", "echo $PPID" ]));
    return match(pid, /^[0-9]+$/) != null ? pid : "0";
}

function runtime_status_object() {
    let data = command_output_from_args([ BIN_PATH, "get_status" ]);
    try {
        data = json(data);
    }
    catch (e) {
        return {};
    }
    return object_or_empty(data);
}

function runtime_is_running() {
    return bool_text(runtime_status_object().running);
}

function status_service() {
    if (runtime_is_running()) {
        print("running\n");
        return 0;
    }

    print("not running\n");
    return 1;
}

function service_is_enabled() {
    return file_exists("/etc/rc.d/S99" + SERVICE_NAME);
}

function retry_start_on_wan_up_action(runtime_running_value, service_enabled_value, retry_pending_value) {
    if (bool_text(runtime_running_value))
        return "skip_running";
    if (!bool_text(service_enabled_value))
        return "skip_disabled";
    if (!bool_text(retry_pending_value))
        return "skip_no_retry";
    return "restart";
}

function retry_start_on_wan_up(owner_pid) {
    let action = retry_start_on_wan_up_action(
        runtime_is_running() ? "1" : "0",
        service_is_enabled() ? "1" : "0",
        start_retry_pending(START_RETRY_FILE) ? "1" : "0"
    );

    if (action == "skip_running" || action == "skip_disabled") {
        clear_start_retry(START_RETRY_FILE);
        return 0;
    }

    if (action != "restart")
        return 0;

    command_success_from_args([ "logger", "-t", SERVICE_NAME, "[info] Retrying failed Forkop start after WAN came up" ]);
    return command_status_from_args([ SERVICE_INIT, "restart", "triggered" ]);
}

function badwan_interface_monitored(settings, interface_name) {
    settings = object_or_empty(settings);
    if (option(settings, "enable_badwan_interface_monitoring", "") != "1")
        return false;

    let interfaces = split(replace(trim(option(settings, "badwan_monitored_interfaces", "")), /[ \t\r\n]+/g, " "), " ");
    for (let iface in interfaces)
        if (trim(iface) == interface_name)
            return true;
    return false;
}

function wan_up_action(runtime_running_value, service_enabled_value, retry_pending_value, monitoring_value) {
    if (bool_text(runtime_running_value))
        return bool_text(monitoring_value) ? "reload" : "skip_running";
    return retry_start_on_wan_up_action(runtime_running_value, service_enabled_value, retry_pending_value);
}

function handle_wan_up(owner_pid) {
    let settings = uci_settings();
    let running = runtime_is_running() ? "1" : "0";
    let action = wan_up_action(
        running,
        service_is_enabled() ? "1" : "0",
        start_retry_pending(START_RETRY_FILE) ? "1" : "0",
        badwan_interface_monitored(settings, "wan") ? "1" : "0"
    );

    if (action == "reload") {
        clear_start_retry(START_RETRY_FILE);
        cancel_scheduled_start_retry(START_RETRY_PID_FILE);
        command_success_from_args([ "logger", "-t", SERVICE_NAME, "[info] Reloading Forkop after monitored WAN came up" ]);
        return command_status_from_args([ SERVICE_INIT, "reload", "badwan_interface_up" ]);
    }

    if (action == "skip_running") {
        clear_start_retry(START_RETRY_FILE);
        cancel_scheduled_start_retry(START_RETRY_PID_FILE);
        return 0;
    }

    return retry_start_on_wan_up(owner_pid);
}

function active_service_action_value() {
    if (!file_exists(UI_UC))
        return "";

    return trim(module_output(UI_UC, [ "active-service-action" ]));
}

function ui_action_tracked() {
    return as_string(getenv("FORKOP_UI_ACTION_TRACKED") || "0") == "1";
}

function start_plan_value(reason, owner_pid, settings, bin_ok) {
    settings = object_or_empty(settings);
    let job_id = begin_external_service_action("start", "initd", owner_pid);
    bin_ok = bin_ok == null ? file_executable(BIN_PATH) : bool_text(bin_ok);

    if (!bin_ok) {
        restore_dnsmasq_failsafe();
        finish_external_service_action("start", job_id, 1);
    }
    else if (initd_should_restore_dnsmasq_on_start_from_value(reason, option(settings, "shutdown_correctly", "1"))) {
        restore_dnsmasq_failsafe();
    }

    return {
        job_id,
        bin_ok
    };
}

function start_plan(reason, owner_pid, settings, bin_ok) {
    let plan = start_plan_value(reason, owner_pid, settings, bin_ok);
    shell_assignment("INITD_UI_JOB_ID", plan.job_id);
    shell_assignment("INITD_BIN_OK", plan.bin_ok ? "1" : "0");
}

function start_service(reason, owner_pid) {
    print("Start Forkop\n");
    let plan = start_plan_value(reason, owner_pid, uci_settings(), null);
    if (!plan.bin_ok)
        return 1;

    let status = command_status_from_args([ BIN_PATH, "start" ]);
    if (status == 0) {
        clear_start_retry(START_RETRY_FILE);
        cancel_scheduled_start_retry(START_RETRY_PID_FILE);
    }
    else {
        mark_start_retry(START_RETRY_FILE, as_string(reason) == "triggered" ? "wan_retry_failed" : "start_failed");
        schedule_start_retry(START_RETRY_PID_FILE, START_RETRY_DELAY_SECONDS);
        command_success_from_args([ "logger", "-t", SERVICE_NAME, "[warn] Forkop start failed; scheduled an automatic retry" ]);
    }
    finish_external_service_action("start", plan.job_id, status);
    return status;
}

function stop_plan(owner_pid, bin_ok) {
    let job_id = begin_external_service_action("stop", "initd", owner_pid);
    bin_ok = bin_ok == null ? file_executable(BIN_PATH) : bool_text(bin_ok);

    if (!bin_ok) {
        restore_dnsmasq_failsafe();
        finish_external_service_action("stop", job_id, 1);
    }

    shell_assignment("INITD_UI_JOB_ID", job_id);
    shell_assignment("INITD_BIN_OK", bin_ok ? "1" : "0");
}

function stop_finish(job_id, status) {
    status = int(status || 0);
    if (status != 0)
        restore_dnsmasq_failsafe();
    finish_external_service_action("stop", job_id, status);
    return status;
}

function stop_service(owner_pid) {
    clear_start_retry(START_RETRY_FILE);
    cancel_scheduled_start_retry(START_RETRY_PID_FILE);
    let job_id = begin_external_service_action("stop", "initd", owner_pid);
    if (!file_executable(BIN_PATH)) {
        restore_dnsmasq_failsafe();
        finish_external_service_action("stop", job_id, 1);
        return 1;
    }

    let status = command_status_from_args([ BIN_PATH, "stop" ]);
    return stop_finish(job_id, status);
}

function reload_begin_value(reason, owner_pid, runtime_running_value, service_enabled_value, active_service_action) {
    reason = as_string(reason);

    if (initd_should_skip_internal_config_reload(
        reason,
        INTERNAL_CONFIG_TRIGGER_GUARD,
        CONFIG_FILE,
        CONFIG_CHANGE_REASON,
        null
    )) {
        return { action: "skip", job_id: "" };
    }

    active_service_action = active_service_action == null ? active_service_action_value() : as_string(active_service_action);
    if (reason == "pending" && active_service_action != "" && !ui_action_tracked()) {
        mark_pending_reload(PENDING_RELOAD_FILE, reason);
        return { action: "skip", job_id: "" };
    }

    if (reason == "pending") {
        if (!acquire_runtime_dir_lock(RELOAD_LOCK_DIR, owner_pid || owner_pid_value())) {
            mark_pending_reload(PENDING_RELOAD_FILE, reason || "reload_busy");
            return { action: "skip", job_id: "" };
        }

        unlink_file(SERVICE_TRIGGER_SYNC_FILE);
        let job_id = begin_external_service_action("reload", "initd", owner_pid);
        return { action: "run", job_id };
    }

    let running = runtime_running_value == null ? runtime_is_running() : bool_text(runtime_running_value);
    let enabled = service_enabled_value == null ? service_is_enabled() : bool_text(service_enabled_value);

    if (initd_should_queue_config_change_reload(reason, CONFIG_CHANGE_REASON, running, active_service_action)) {
        mark_pending_reload(PENDING_RELOAD_FILE, reason || "reload_queued");
        return { action: "skip", job_id: "" };
    }

    if (initd_should_ignore_config_change_reload(reason, CONFIG_CHANGE_REASON, running, enabled)) {
        return { action: "skip", job_id: "" };
    }

    if (!acquire_runtime_dir_lock(RELOAD_LOCK_DIR, owner_pid || owner_pid_value())) {
        mark_pending_reload(PENDING_RELOAD_FILE, reason || "reload_busy");
        return { action: "skip", job_id: "" };
    }

    unlink_file(SERVICE_TRIGGER_SYNC_FILE);
    let job_id = begin_external_service_action("reload", "initd", owner_pid);
    return { action: "run", job_id };
}

function reload_begin(reason, owner_pid, runtime_running_value, service_enabled_value) {
    let plan = reload_begin_value(reason, owner_pid, runtime_running_value, service_enabled_value, null);
    shell_assignment("INITD_RELOAD_ACTION", plan.action);
    if (plan.action == "run")
        shell_assignment("INITD_UI_JOB_ID", plan.job_id);
    return 0;
}

function reload_finish_value(reason, job_id, status) {
    status = int(status || 0);
    finish_external_service_action("reload", job_id, status);
    let sync = status == 0 && initd_should_sync_service_triggers(reason, CONFIG_CHANGE_REASON, SERVICE_TRIGGER_SYNC_FILE);
    release_runtime_dir_lock(RELOAD_LOCK_DIR);
    if (active_service_action_value() == "")
        run_pending_reload_if_requested(PENDING_RELOAD_FILE, SERVICE_INIT);
    return { status, sync };
}

function reload_finish(reason, job_id, status) {
    let plan = reload_finish_value(reason, job_id, status);
    shell_assignment("INITD_SYNC_SERVICE_TRIGGERS", plan.sync ? "1" : "0");
    return plan.status;
}

function reload_service(reason, owner_pid) {
    let plan = reload_begin_value(reason, owner_pid, null, null);
    if (plan.action != "run")
        return 0;

    let status = command_status(command_from_args([ "env", "FORKOP_UI_ACTION_TRACKED=1", BIN_PATH, "reload", reason ]) + " >/dev/null 2>&1");
    let finish = reload_finish_value(reason, plan.job_id, status);
    if (finish.sync)
        print("sync\n");
    return finish.status;
}

function reload_release() {
    release_runtime_dir_lock(RELOAD_LOCK_DIR);
    return 0;
}

function trigger_plan(settings) {
    settings = object_or_empty(settings);
    let badwan_enabled = option(settings, "enable_badwan_interface_monitoring", "") == "1";
    let badwan_interfaces = split(replace(trim(option(settings, "badwan_monitored_interfaces", "")), /[ \t\r\n]+/g, " "), " ");
    let delay = option(settings, "badwan_reload_delay", "2000");
    if (delay == "")
        delay = "2000";

    print("delay\t", delay, "\n");
    print("config\tconfig.change\t", CONFIG_NAME, "\t", SERVICE_INIT, "\treload\t", CONFIG_CHANGE_REASON, "\n");
    print("interface\tinterface.*.up\twan\t", SERVICE_INIT, "\thandle_wan_up\t\n");

    if (badwan_enabled) {
        for (let iface in badwan_interfaces) {
            iface = trim(iface);
            if (iface == "" || iface == "wan")
                continue;
            print("interface\tinterface.*.up\t", iface, "\t", SERVICE_INIT, "\treload\t\n");
        }
    }
}

let mode = ARGV[0] || "";

if (mode == "restore-dnsmasq-failsafe")
    exit(restore_dnsmasq_failsafe());
else if (mode == "runtime-running")
    exit(runtime_is_running() ? 0 : 1);
else if (mode == "status-service")
    exit(status_service());
else if (mode == "retry-start-on-wan-up")
    exit(retry_start_on_wan_up(ARGV[1]));
else if (mode == "handle-wan-up")
    exit(handle_wan_up(ARGV[1]));
else if (mode == "retry-start-on-wan-up-action")
    print(retry_start_on_wan_up_action(ARGV[1], ARGV[2], ARGV[3]), "\n");
else if (mode == "wan-up-action")
    print(wan_up_action(ARGV[1], ARGV[2], ARGV[3], ARGV[4]), "\n");
else if (mode == "service-enabled")
    exit(service_is_enabled() ? 0 : 1);
else if (mode == "mark-start-retry")
    exit(mark_start_retry(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "clear-start-retry")
    clear_start_retry(ARGV[1]);
else if (mode == "start-retry-pending")
    exit(start_retry_pending(ARGV[1]) ? 0 : 1);
else if (mode == "schedule-start-retry")
    exit(schedule_start_retry(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "cancel-scheduled-start-retry")
    cancel_scheduled_start_retry(ARGV[1]);
else if (mode == "begin-action") {
    let job_id = begin_external_service_action(ARGV[1], ARGV[2] || "initd", ARGV[3]);
    if (job_id != "")
        print(job_id, "\n");
}
else if (mode == "finish-action")
    exit(finish_external_service_action(ARGV[1], ARGV[2], ARGV[3]));
else if (mode == "start-plan")
    start_plan(ARGV[1], ARGV[2], uci_settings(), null);
else if (mode == "start-service")
    exit(start_service(ARGV[1], ARGV[2]));
else if (mode == "start-plan-fixture") {
    let settings = {
        shutdown_correctly: ARGV[2],
        enable_badwan_interface_monitoring: ARGV[3],
        badwan_monitored_interfaces: ARGV[4]
    };
    start_plan(ARGV[1], ARGV[5] || "0", settings, ARGV[6] == null ? "1" : ARGV[6]);
}
else if (mode == "stop-plan")
    stop_plan(ARGV[1], null);
else if (mode == "stop-plan-fixture")
    stop_plan(ARGV[1] || "0", ARGV[2] == null ? "1" : ARGV[2]);
else if (mode == "stop-finish")
    exit(stop_finish(ARGV[1], ARGV[2]));
else if (mode == "stop-service")
    exit(stop_service(ARGV[1]));
else if (mode == "reload-begin")
    exit(reload_begin(ARGV[1], ARGV[2], null, null));
else if (mode == "reload-begin-fixture") {
    let plan = reload_begin_value(ARGV[1], ARGV[2] || "0", ARGV[3], ARGV[4], ARGV[5]);
    shell_assignment("INITD_RELOAD_ACTION", plan.action);
    if (plan.action == "run")
        shell_assignment("INITD_UI_JOB_ID", plan.job_id);
    exit(plan.action == "run" ? 0 : 1);
}
else if (mode == "reload-finish")
    exit(reload_finish(ARGV[1], ARGV[2], ARGV[3]));
else if (mode == "reload-service")
    exit(reload_service(ARGV[1], ARGV[2]));
else if (mode == "reload-release")
    exit(reload_release());
else if (mode == "trigger-plan")
    trigger_plan(uci_settings());
else if (mode == "trigger-plan-fixture")
    trigger_plan(settings_from_fixture(ARGV[1]));
else if (mode == "initd-service-trigger-sync-requested")
    exit(initd_service_trigger_sync_requested(ARGV[1]) ? 0 : 1);
else if (mode == "initd-guard-matches-current-config")
    exit(initd_guard_matches_current_config(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
else if (mode == "initd-should-skip-internal-config-reload")
    exit(initd_should_skip_internal_config_reload(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]) ? 0 : 1);
else if (mode == "initd-should-restore-dnsmasq-on-start-fixture")
    exit(initd_should_restore_dnsmasq_on_start_from_value(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "initd-should-ignore-config-change-reload")
    exit(initd_should_ignore_config_change_reload(ARGV[1], ARGV[2], ARGV[3], ARGV[4]) ? 0 : 1);
else if (mode == "initd-should-queue-config-change-reload")
    exit(initd_should_queue_config_change_reload(ARGV[1], ARGV[2], ARGV[3], ARGV[4]) ? 0 : 1);
else if (mode == "initd-should-sync-service-triggers")
    exit(initd_should_sync_service_triggers(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
else {
    warn("Usage: service/initd.uc <operation> ...\n");
    exit(1);
}
