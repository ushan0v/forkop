#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let runtime_constants = require("singbox.constants");
let validator_module = null;

const CONFIG_NAME = getenv("PODKOP_CONFIG_NAME") || "podkop-plus";
const LIB_DIR = getenv("PODKOP_LIB") || "/usr/lib/podkop-plus";
const BYEDPI_BIN = getenv("BYEDPI_BIN") || "/usr/bin/ciadpi";
const BYEDPI_SERVICE_INIT = getenv("BYEDPI_SERVICE_INIT") || "/etc/init.d/byedpi";
const BYEDPI_STATE_DIR = getenv("BYEDPI_STATE_DIR") || "/var/run/podkop-plus/byedpi";
const BYEDPI_PID_DIR = getenv("BYEDPI_PID_DIR") || BYEDPI_STATE_DIR + "/pid";
const BYEDPI_CHILD_PID_DIR = getenv("BYEDPI_CHILD_PID_DIR") || BYEDPI_STATE_DIR + "/child-pid";
const BYEDPI_LOG_DIR = getenv("BYEDPI_LOG_DIR") || BYEDPI_STATE_DIR + "/log";
const BYEDPI_LISTEN_ADDRESS = getenv("BYEDPI_LISTEN_ADDRESS") || "127.0.0.1";
const BYEDPI_PORT_BASE = getenv("BYEDPI_PORT_BASE") || "1080";
const BYEDPI_RESPAWN_DELAY = getenv("BYEDPI_RESPAWN_DELAY") || "5";
const BYEDPI_OPEN_FILES_LIMIT = getenv("BYEDPI_OPEN_FILES_LIMIT") || "4096";
const BYEDPI_DEFAULT_CMD_OPTS = getenv("BYEDPI_DEFAULT_CMD_OPTS") || "-o 2 --auto=t,r,a,s -d 2";
const SB_TPROXY_INBOUND_TAG = getenv("SB_TPROXY_INBOUND_TAG") || "tproxy-in";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function bool_value(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
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
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function command_exists(name) {
    return command_success_from_args([ "command", "-v", name ]);
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "podkop-plus", "[" + level + "] " + as_string(message) ]);
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
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

function bool_option(section, key, fallback) {
    let value = object_or_empty(section)[key];
    return value == null ? !!fallback : bool_value(value);
}

function section_name(section) {
    return as_string(object_or_empty(section)[".name"]);
}

function uci_sections(type_name) {
    return uci_core.section_objects(CONFIG_NAME, as_string(type_name));
}

function uci_settings() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function validator() {
    if (validator_module == null)
        validator_module = require("providers.byedpi.validator");
    return validator_module;
}

function normalize_strategy(value) {
    return validator().strategy_or_default(value, BYEDPI_DEFAULT_CMD_OPTS);
}

function strategy_words(value) {
    value = replace(as_string(value), /[\t\r\n]/g, " ");
    value = replace(value, / +/g, " ");
    value = replace(value, /^ /, "");
    value = replace(value, / $/, "");
    return value == "" ? [] : split(value, " ");
}

function enabled_byedpi_sections() {
    let result = [];
    for (let section in uci_sections("section"))
        if (bool_option(section, "enabled", true) && option(section, "action", "") == "byedpi")
            push(result, section);
    return result;
}

function enabled_rule_count() {
    return length(enabled_byedpi_sections());
}

function rule_index(section_name_value, sections) {
    let index_value = 0;
    for (let section in array_or_empty(sections)) {
        index_value++;
        if (section_name(section) == as_string(section_name_value))
            return index_value;
    }
    return 0;
}

function rule_port(index_value) {
    return int(BYEDPI_PORT_BASE) + int(index_value) - 1;
}

function ensure_runtime_dirs() {
    return command_success_from_args([ "mkdir", "-p", BYEDPI_STATE_DIR, BYEDPI_PID_DIR, BYEDPI_CHILD_PID_DIR, BYEDPI_LOG_DIR ]);
}

function provider_available() {
    let stat = fs.stat(BYEDPI_BIN);
    return stat != null && stat.mode != null && (int(stat.mode) & 73) != 0;
}

function package_installed() {
    if (command_exists("apk") && command_success_from_args([ "apk", "info", "-e", "byedpi" ]))
        return true;
    if (!command_exists("opkg"))
        return false;

    for (let line in split(command_output_from_args([ "opkg", "list-installed" ]), "\n")) {
        let matched = match(trim(as_string(line)), /^byedpi[ \t]+-/);
        if (matched)
            return true;
    }
    return false;
}

function first_nonempty_field(value) {
    for (let line in split(as_string(value), "\n")) {
        line = trim(as_string(line));
        if (line == "")
            continue;
        let fields = split(line, /[ \t\r\n]+/);
        return length(fields) > 0 ? as_string(fields[0]) : "";
    }
    return "";
}

function package_version() {
    let output = "";

    if (command_exists("apk") && command_success_from_args([ "apk", "info", "-e", "byedpi" ])) {
        output = command_output_from_args([ "apk", "list", "--installed", "--manifest", "byedpi" ]);
        for (let line in split(output, "\n")) {
            let matched = match(trim(as_string(line)), /^P:byedpi$/);
            if (!matched)
                continue;
            for (let manifest_line in split(output, "\n")) {
                let version_match = match(trim(as_string(manifest_line)), /^V:(.+)$/);
                if (version_match)
                    return as_string(version_match[1]);
            }
        }

        output = command_output_from_args([ "apk", "info", "-v", "byedpi" ]);
        for (let line in split(output, "\n")) {
            line = trim(as_string(line));
            if (line != "")
                return replace(line, /^byedpi-/, "");
        }
    }

    if (command_exists("opkg")) {
        output = command_output_from_args([ "opkg", "list-installed" ]);
        for (let line in split(output, "\n")) {
            let matched = match(trim(as_string(line)), /^byedpi[ \t]+-[ \t]*(.+)$/);
            if (matched)
                return as_string(matched[1]);
        }
    }

    if (provider_available())
        return first_nonempty_field(command_output_from_args([ BYEDPI_BIN, "--version" ]));
    return "";
}

function standalone_service_enabled() {
    return fs.stat(BYEDPI_SERVICE_INIT) != null && command_success_from_args([ BYEDPI_SERVICE_INIT, "enabled" ]);
}

function standalone_service_running() {
    return fs.stat(BYEDPI_SERVICE_INIT) != null && command_success_from_args([ BYEDPI_SERVICE_INIT, "status" ]);
}

function runtime_pid_running(pid) {
    pid = as_string(pid);
    return match(pid, /^[0-9]+$/) != null && command_success_from_args([ "kill", "-0", pid ]);
}

function file_first_line(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return "";
    let newline = index(data, "\n");
    return trim(newline >= 0 ? substr(data, 0, newline) : data);
}

function kill_pidfile_process(path, signal) {
    let pid = file_first_line(path);
    if (pid == "")
        return;
    if (signal == "9") {
        if (runtime_pid_running(pid))
            command_success_from_args([ "kill", "-9", pid ]);
    }
    else {
        command_success_from_args([ "kill", pid ]);
    }
}

function pidfiles_in_dir(path) {
    if (fs.stat(path) == null)
        return [];

    let output = command_output_from_args([ "find", path, "-maxdepth", "1", "-type", "f", "-name", "*.pid" ]);
    let result = [];
    for (let line in split(output, "\n")) {
        line = trim(as_string(line));
        if (line != "")
            push(result, line);
    }
    return result;
}

function stop_runtime() {
    for (let pidfile in pidfiles_in_dir(BYEDPI_PID_DIR))
        kill_pidfile_process(pidfile, "");
    for (let pidfile in pidfiles_in_dir(BYEDPI_CHILD_PID_DIR))
        kill_pidfile_process(pidfile, "");

    command_success_from_args([ "sleep", "1" ]);

    for (let pidfile in pidfiles_in_dir(BYEDPI_PID_DIR))
        kill_pidfile_process(pidfile, "9");
    for (let pidfile in pidfiles_in_dir(BYEDPI_CHILD_PID_DIR))
        kill_pidfile_process(pidfile, "9");

    command_success_from_args([ "rm", "-rf", BYEDPI_PID_DIR, BYEDPI_CHILD_PID_DIR, BYEDPI_LOG_DIR ]);
}

function supervisor_command(port, raw_opt, child_pidfile) {
    let args = [ BYEDPI_BIN, "--ip", BYEDPI_LISTEN_ADDRESS, "--port", as_string(port) ];
    for (let word in strategy_words(raw_opt))
        push(args, word);

    return "ulimit -n " + shell_quote(BYEDPI_OPEN_FILES_LIMIT) + " >/dev/null 2>&1 || true; " +
        command_from_args(args) + " & child=$!; echo $child > " + shell_quote(child_pidfile) + "; wait $child; rc=$?; rm -f " + shell_quote(child_pidfile) + "; exit $rc";
}

function supervisor(section, port, raw_opt, child_pidfile) {
    while (true) {
        if (!provider_available()) {
            print(command_output_from_args([ "date", "+%Y-%m-%d %H:%M:%S" ]), " Provider ", BYEDPI_BIN, " is not executable; retrying in ", BYEDPI_RESPAWN_DELAY, " seconds\n");
            command_success_from_args([ "sleep", BYEDPI_RESPAWN_DELAY ]);
            continue;
        }

        let rc = command_status("sh -c " + shell_quote(supervisor_command(port, raw_opt, child_pidfile)));
        print(command_output_from_args([ "date", "+%Y-%m-%d %H:%M:%S" ]), " ciadpi for rule ", as_string(section), " exited with code ", rc, "; respawning in ", BYEDPI_RESPAWN_DELAY, " seconds\n");
        command_success_from_args([ "sleep", BYEDPI_RESPAWN_DELAY ]);
    }
}

function start_rule(section, index_value) {
    let name = section_name(section);
    let port = rule_port(index_value);
    let raw_opt = normalize_strategy(option(section, "byedpi_cmd_opts", ""));
    let validation = validator().validate_byedpi_strategy(raw_opt);
    if (!validation.valid) {
        log_message("Invalid ByeDPI strategy for rule '" + name + "': " + validation.message, "fatal");
        exit(1);
    }

    let pidfile = BYEDPI_PID_DIR + "/" + name + ".pid";
    let child_pidfile = BYEDPI_CHILD_PID_DIR + "/" + name + ".pid";
    let logfile = BYEDPI_LOG_DIR + "/" + name + ".log";

    log_message("Starting ciadpi for rule '" + name + "' on " + BYEDPI_LISTEN_ADDRESS + ":" + port, "info");
    let command = command_from_args([
        "ucode",
        "-L", LIB_DIR,
        LIB_DIR + "/providers/byedpi/runtime.uc",
        "supervisor",
        name,
        "" + port,
        raw_opt,
        child_pidfile
    ]) + " >>" + shell_quote(logfile) + " 2>&1 1000>&- & echo $!";
    let pid = trim(command_output("sh -c " + shell_quote(command)));
    if (pid == "" || !fs.writefile(pidfile, pid + "\n")) {
        log_message("ciadpi failed to start for rule '" + name + "'. Check " + logfile + ". Aborted.", "fatal");
        exit(1);
    }

    command_success_from_args([ "sleep", "1" ]);
    if (!runtime_pid_running(pid)) {
        log_message("ciadpi failed to start for rule '" + name + "'. Check " + logfile + ". Aborted.", "fatal");
        exit(1);
    }

    let child_pid = file_first_line(child_pidfile);
    if (child_pid == "" || !runtime_pid_running(child_pid))
        log_message("ciadpi supervisor started for rule '" + name + "', but ciadpi is not running yet. Check " + logfile + ".", "warn");
}

function start_runtime() {
    stop_runtime();

    let sections = enabled_byedpi_sections();
    if (length(sections) == 0 || !provider_available())
        return;

    if (standalone_service_enabled())
        log_message("Standalone byedpi service is enabled. Podkop Plus manages ciadpi itself for action 'byedpi'; disable standalone byedpi autostart to avoid boot-time port conflicts.", "warn");

    if (standalone_service_running()) {
        log_message("Stopping standalone byedpi service before starting Podkop Plus-managed ciadpi runtime", "info");
        command_success_from_args([ BYEDPI_SERVICE_INIT, "stop" ]);
        command_success_from_args([ "sleep", "1" ]);
        if (standalone_service_running()) {
            log_message("Standalone byedpi service is still running and may conflict with Podkop Plus-managed ciadpi runtime. Aborted.", "fatal");
            exit(1);
        }
    }

    if (!ensure_runtime_dirs()) {
        log_message("Failed to prepare the Podkop Plus ByeDPI state directory in " + BYEDPI_STATE_DIR + ". Aborted.", "fatal");
        exit(1);
    }

    let index_value = 1;
    for (let section in sections) {
        start_rule(section, index_value);
        index_value++;
    }
}

function live_pid_count(path) {
    let count = 0;
    for (let pidfile in pidfiles_in_dir(path)) {
        let pid = file_first_line(pidfile);
        if (runtime_pid_running(pid))
            count++;
        else
            fs.unlink(pidfile);
    }
    return count;
}

function restart_count() {
    let count = 0;
    if (fs.stat(BYEDPI_LOG_DIR) == null)
        return count;

    let output = command_output_from_args([ "find", BYEDPI_LOG_DIR, "-maxdepth", "1", "-type", "f", "-name", "*.log" ]);
    for (let path in split(output, "\n")) {
        path = trim(as_string(path));
        if (path == "")
            continue;
        let data = fs.readfile(path);
        if (data == null)
            continue;
        for (let line in split(data, "\n"))
            if (match(as_string(line), /ciadpi for rule .* exited with code/) != null)
                count++;
    }
    return count;
}

function runtime_tag(base, postfix) {
    return runtime_constants.tag(base, postfix);
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

function value_contains(value, needle) {
    if (type(value) == "array") {
        for (let item in value)
            if (as_string(item) == needle)
                return true;
        return false;
    }
    return as_string(value) == needle;
}

function has_socks_outbound(config, tag, address, port) {
    for (let outbound in array_or_empty(config && config.outbounds)) {
        if (type(outbound) == "object" &&
            outbound.type == "socks" &&
            outbound.tag == tag &&
            outbound.server == address &&
            int(outbound.server_port || 0) == int(port))
            return true;
    }
    return false;
}

function has_route_rule(config, inbound, outbound) {
    for (let rule in array_or_empty(config && config.route && config.route.rules)) {
        if (type(rule) == "object" &&
            rule.action == "route" &&
            value_contains(rule.inbound, inbound) &&
            value_contains(rule.outbound, outbound))
            return true;
    }
    return false;
}

function runtime_config_status(sections) {
    let config_path = option(uci_settings(), "config_path", "");
    let config = read_json_file(config_path);
    let rules_configured = length(sections) > 0;
    let outbounds_configured = rules_configured;
    let routes_configured = rules_configured;

    let index_value = 1;
    for (let section in sections) {
        let outbound = runtime_tag(section_name(section), "out");
        let port = rule_port(index_value);
        if (!has_socks_outbound(config, outbound, BYEDPI_LISTEN_ADDRESS, port))
            outbounds_configured = false;
        if (!has_route_rule(config, SB_TPROXY_INBOUND_TAG, outbound))
            routes_configured = false;
        index_value++;
    }

    return {
        rules_configured,
        outbounds_configured,
        routes_configured
    };
}

function status_json() {
    let sections = enabled_byedpi_sections();
    let configured = length(sections) > 0;
    let provider = provider_available();
    let pkg = package_installed();
    let version = pkg || provider ? package_version() : "not installed";
    if (version == "")
        version = "unknown";

    let expected = length(sections);
    let running = live_pid_count(BYEDPI_CHILD_PID_DIR);
    let supervisors = live_pid_count(BYEDPI_PID_DIR);
    let restarts = restart_count();
    let standalone_enabled = standalone_service_enabled();
    let standalone_running = standalone_service_running();
    let config_state = runtime_config_status(sections);
    let conflict = running > expected || standalone_running;
    let unstable = configured && restarts > 0;
    let ready = configured &&
        provider &&
        !standalone_running &&
        !conflict &&
        !unstable &&
        config_state.outbounds_configured &&
        config_state.routes_configured &&
        expected > 0 &&
        running == expected;

    let message = "byedpi provider status is normal";
    if (configured && !provider)
        message = "action=byedpi is configured, but ciadpi is not available at " + BYEDPI_BIN;
    else if (configured && standalone_running)
        message = "standalone byedpi service is active together with Podkop Plus action=byedpi; port conflicts are possible";
    else if (configured && standalone_enabled)
        message = "standalone byedpi service autostart is enabled; disable it to avoid boot-time port conflicts with Podkop Plus action=byedpi";
    else if (running > expected || supervisors > expected)
        message = "unexpected Podkop Plus-managed ciadpi processes are running without matching action=byedpi rules";
    else if (configured && unstable)
        message = "Podkop Plus-managed ciadpi has restarted after exiting; the ByeDPI strategy or traffic load may be unstable";
    else if (configured && !ready)
        message = "action=byedpi is configured, but the Podkop Plus-managed ciadpi runtime is not ready";
    else if (!configured && !provider && pkg)
        message = "byedpi package is installed, but ciadpi is not available at " + BYEDPI_BIN;
    else if (!configured && !provider)
        message = "byedpi package is not installed; action=byedpi is unavailable";

    write_json({
        installed: provider,
        package_installed: pkg,
        provider_available: provider,
        provider_path: BYEDPI_BIN,
        version,
        configured,
        enabled_rule_count: expected,
        expected_process_count: expected,
        running_process_count: running,
        supervisor_process_count: supervisors,
        restart_count: restarts,
        runtime_unstable: unstable,
        standalone_service_enabled: standalone_enabled,
        standalone_service_running: standalone_running,
        listen_address: BYEDPI_LISTEN_ADDRESS,
        port_base: int(BYEDPI_PORT_BASE),
        outbounds_configured: config_state.outbounds_configured,
        routes_configured: config_state.routes_configured,
        ready,
        conflict,
        status_message: message
    });
}

function check_json() {
    write_json({
        byedpi_installed: provider_available(),
        byedpi_package_installed: package_installed(),
        byedpi_provider_path: BYEDPI_BIN
    });
}

let mode = ARGV[0] || "";

if (mode == "start-runtime")
    start_runtime();
else if (mode == "stop-runtime")
    stop_runtime();
else if (mode == "supervisor")
    supervisor(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "status")
    status_json();
else if (mode == "check")
    check_json();
else if (mode == "installed" || mode == "provider-available")
    exit(provider_available() ? 0 : 1);
else if (mode == "package-installed")
    exit(package_installed() ? 0 : 1);
else if (mode == "package-version")
    print(package_version(), "\n");
else if (mode == "enabled-rule-count")
    print(enabled_rule_count(), "\n");
else {
    warn("Usage: providers/byedpi/runtime.uc <start-runtime|stop-runtime|status|check|installed|package-installed|package-version> ...\n");
    exit(1);
}
