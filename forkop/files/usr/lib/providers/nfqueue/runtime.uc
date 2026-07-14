#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let uci_core = require("core.uci");
let runtime_constants = require("singbox.constants");

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || constants.FORKOP_CONFIG_NAME || "forkop";
const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const SB_TPROXY_INBOUND_TAG = getenv("SB_TPROXY_INBOUND_TAG") || constants.SB_TPROXY_INBOUND_TAG || "tproxy-in";
const NFT_TABLE_NAME = getenv("NFT_TABLE_NAME") || constants.NFT_TABLE_NAME || "ForkopTable";

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

function module_command(args) {
    let command_args = [ "ucode", "-L", LIB_DIR ];
    for (let arg in args)
        push(command_args, arg);
    return command_from_args(command_args);
}

function module_success(args) {
    return command_success(module_command(args));
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "forkop", "[" + level + "] " + as_string(message) ]);
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

function provider_config(provider) {
    let cfg = object_or_empty(provider.config({
        constants,
        lib_dir: LIB_DIR
    }));

    cfg.kind = as_string(cfg.kind);
    cfg.action = as_string(cfg.action || cfg.kind);
    cfg.check_path = as_string(cfg.check_path || (LIB_DIR + "/providers/" + cfg.kind + "/check.uc"));
    cfg.legacy_runtime_base = as_string(cfg.legacy_runtime_base);
    cfg.provider_base_dir = as_string(cfg.provider_base_dir);
    cfg.hostlist_dir = as_string(cfg.hostlist_dir);
    cfg.base_args = array_or_empty(cfg.base_args);
    return cfg;
}

function normalize_strategy(cfg, value) {
    return cfg.validator().strategy_or_default(value, cfg.default_strategy);
}

function strategy_words(value) {
    value = replace(as_string(value), /[\t\r\n]/g, " ");
    value = replace(value, / +/g, " ");
    value = replace(value, /^ /, "");
    value = replace(value, / $/, "");
    return value == "" ? [] : split(value, " ");
}

function enabled_sections(cfg) {
    let result = [];
    for (let section in uci_sections("section"))
        if (bool_option(section, "enabled", true) && option(section, "action", "") == cfg.action)
            push(result, section);
    return result;
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

function route_mark_value(cfg, index_value) {
    return parse_number(cfg.route_mark_base) + int(index_value);
}

function route_mark_hex(cfg, index_value) {
    return sprintf("0x%08x", route_mark_value(cfg, index_value));
}

function queue_number(cfg, index_value) {
    return int(cfg.queue_base) + int(index_value) - 1;
}

function queue_range_end(cfg) {
    return int(cfg.queue_base) + int(cfg.queue_range_size) - 1;
}

function provider_available(cfg) {
    let stat = fs.stat(cfg.provider_bin);
    return stat != null && stat.mode != null && (int(stat.mode) & 73) != 0;
}

function package_installed(cfg) {
    return module_success([ LIB_DIR + "/core/packages.uc", "installed", cfg.package_name ]);
}

function package_version_from_manager(cfg) {
    return trim(command_output_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/core/packages.uc", "version", cfg.package_name ]));
}

function first_line_version_field(value) {
    let newline = index(value, "\n");
    let line = newline >= 0 ? substr(value, 0, newline) : value;
    if (match(line, /^.*version[ \t]*/) == null)
        return "";
    let fields = split(trim(replace(line, /^.*version[ \t]*/, "")), /[ \t\r\n]+/);
    return length(fields) > 0 ? as_string(fields[0]) : "";
}

function package_version(cfg) {
    let version = package_version_from_manager(cfg);
    if (version == "" && provider_available(cfg))
        version = first_line_version_field(command_output_from_args([ cfg.provider_bin, "--version" ]));
    return version;
}

function standalone_service_enabled(cfg) {
    return fs.stat(cfg.service_init) != null && command_success_from_args([ cfg.service_init, "enabled" ]);
}

function standalone_service_running(cfg) {
    return fs.stat(cfg.service_init) != null && command_success_from_args([ cfg.service_init, "status" ]);
}

function standalone_uci_config_present(cfg) {
    return fs.stat("/etc/config/" + cfg.config_name) != null && uci_core.exists(cfg.config_name + ".config");
}

function luci_app_installed(cfg) {
    return module_success([ LIB_DIR + "/core/packages.uc", "installed", cfg.luci_package ]) ||
        fs.stat(cfg.luci_menu) != null ||
        fs.stat(cfg.luci_acl) != null;
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

function live_pid_count(path) {
    let count = 0;
    for (let pidfile in pidfiles_in_dir(path)) {
        let pid = file_first_line(pidfile);
        if (runtime_pid_running(pid))
            count++;
        else {
            try { fs.unlink(pidfile); } catch (e) {}
        }
    }
    return count;
}

function ensure_runtime_dirs(cfg) {
    return command_success_from_args([ "mkdir", "-p", cfg.state_dir, cfg.pid_dir, cfg.child_pid_dir, cfg.log_dir ]);
}

function uci_value_contains(value, needle) {
    needle = as_string(needle);
    if (needle == "")
        return false;

    if (type(value) == "array") {
        for (let item in value)
            if (uci_value_contains(item, needle))
                return true;
        return false;
    }

    if (type(value) == "object") {
        for (let key in keys(value))
            if (uci_value_contains(value[key], needle))
                return true;
        return false;
    }

    return index(as_string(value), needle) >= 0;
}

function legacy_runtime_path_present(cfg) {
    if (cfg.legacy_runtime_base == "")
        return false;

    if (uci_value_contains(uci_settings(), cfg.legacy_runtime_base))
        return true;
    for (let section in uci_sections("section"))
        if (uci_value_contains(section, cfg.legacy_runtime_base))
            return true;

    return fs.stat(cfg.legacy_runtime_base) != null;
}

function stop_legacy_runtime_processes(cfg) {
    if (cfg.legacy_runtime_base == "")
        return;
    let needle = cfg.legacy_runtime_base + "/nfq/nfqws";
    for (let line in split(command_output_from_args([ "ps", "w" ]), "\n")) {
        if (index(line, needle) < 0)
            continue;
        let fields = split(trim(as_string(line)), /[ \t\r\n]+/);
        if (length(fields) > 0)
            command_success_from_args([ "kill", fields[0] ]);
    }
}

function cleanup_legacy_runtime(cfg) {
    if (cfg.legacy_runtime_base == "")
        return;
    stop_legacy_runtime_processes(cfg);
    command_success_from_args([ "rm", "-rf", cfg.legacy_runtime_base ]);
}

function expand_strategy(cfg, value) {
    value = as_string(value);
    if (cfg.legacy_runtime_base == "" || cfg.provider_base_dir == "")
        return value;
    return replace(value, cfg.legacy_runtime_base, cfg.provider_base_dir);
}

function base_args(cfg) {
    return cfg.base_args;
}

function raw_strategy(cfg, section) {
    return normalize_strategy(cfg, option(section, cfg.strategy_option, ""));
}

function validate_strategy_or_exit(cfg, section_name_value, raw_opt) {
    let result = cfg.validator().validate_strategy(cfg.validator_kind, raw_opt, cfg.legacy_default_strategy);
    if (result.valid)
        return;
    log_message("Invalid " + cfg.binary_name + " strategy for rule '" + section_name_value + "': " + result.message, "fatal");
    exit(1);
}

function supervisor_command(cfg, queue, raw_opt, child_pidfile) {
    let args = [ cfg.binary, "--qnum=" + as_string(queue) ];
    for (let arg in base_args(cfg))
        push(args, arg);
    for (let word in strategy_words(raw_opt))
        push(args, word);

    return command_from_args(args) + " & child=$!; echo $child > " + shell_quote(child_pidfile) + "; wait $child; rc=$?; rm -f " + shell_quote(child_pidfile) + "; exit $rc";
}

function supervisor(cfg, section, queue, raw_opt, child_pidfile) {
    while (true) {
        if (!provider_available(cfg)) {
            print(command_output_from_args([ "date", "+%Y-%m-%d %H:%M:%S" ]), " Provider ", cfg.binary, " is not executable; retrying in ", cfg.respawn_delay, " seconds\n");
            command_success_from_args([ "sleep", cfg.respawn_delay ]);
            continue;
        }

        let rc = command_status("sh -c " + shell_quote(supervisor_command(cfg, queue, raw_opt, child_pidfile)));
        print(command_output_from_args([ "date", "+%Y-%m-%d %H:%M:%S" ]), " ", cfg.binary_name, " for rule ", as_string(section), " exited with code ", rc, "; respawning in ", cfg.respawn_delay, " seconds\n");
        command_success_from_args([ "sleep", cfg.respawn_delay ]);
    }
}

function stop_runtime(cfg) {
    for (let pidfile in pidfiles_in_dir(cfg.pid_dir))
        kill_pidfile_process(pidfile, "");
    for (let pidfile in pidfiles_in_dir(cfg.child_pid_dir))
        kill_pidfile_process(pidfile, "");

    command_success_from_args([ "sleep", "1" ]);

    for (let pidfile in pidfiles_in_dir(cfg.pid_dir))
        kill_pidfile_process(pidfile, "9");
    for (let pidfile in pidfiles_in_dir(cfg.child_pid_dir))
        kill_pidfile_process(pidfile, "9");

    let remove_args = [ "rm", "-rf", cfg.pid_dir, cfg.child_pid_dir, cfg.log_dir ];
    if (cfg.hostlist_dir != "")
        push(remove_args, cfg.hostlist_dir);
    if (cfg.legacy_runtime_base != "")
        push(remove_args, cfg.legacy_runtime_base);
    command_success_from_args(remove_args);
}

function start_rule(cfg, section, index_value) {
    let name = section_name(section);
    let queue = queue_number(cfg, index_value);
    let mark = route_mark_hex(cfg, index_value);
    let raw_opt = expand_strategy(cfg, raw_strategy(cfg, section));
    validate_strategy_or_exit(cfg, name, raw_opt);

    let pidfile = cfg.pid_dir + "/" + name + ".pid";
    let child_pidfile = cfg.child_pid_dir + "/" + name + ".pid";
    let logfile = cfg.log_dir + "/" + name + ".log";

    log_message("Starting " + cfg.binary_name + " for rule '" + name + "' on queue " + queue + " with mark " + mark, "info");
    let command = command_from_args([
        "ucode",
        "-L", LIB_DIR,
        cfg.runtime_path,
        "supervisor",
        name,
        "" + queue,
        raw_opt,
        child_pidfile
    ]) + " >>" + shell_quote(logfile) + " 2>&1 1000>&- & echo $!";
    let pid = trim(command_output("sh -c " + shell_quote(command)));
    if (pid == "" || fs.writefile(pidfile, pid + "\n") == null) {
        log_message(cfg.binary_name + " failed to start for rule '" + name + "'. Check " + logfile + ". Aborted.", "fatal");
        exit(1);
    }

    command_success_from_args([ "sleep", "1" ]);
    if (!runtime_pid_running(pid)) {
        log_message(cfg.binary_name + " failed to start for rule '" + name + "'. Check " + logfile + ". Aborted.", "fatal");
        exit(1);
    }

    let child_pid = file_first_line(child_pidfile);
    if (child_pid == "" || !runtime_pid_running(child_pid))
        log_message(cfg.binary_name + " supervisor started for rule '" + name + "', but " + cfg.binary_name + " is not running yet. Check " + logfile + ".", "warn");
}

function start_runtime(cfg) {
    stop_runtime(cfg);

    let sections = enabled_sections(cfg);
    if (length(sections) == 0 || !provider_available(cfg))
        return;

    cleanup_legacy_runtime(cfg);
    if (!ensure_runtime_dirs(cfg)) {
        log_message("Failed to prepare the Forkop " + cfg.status_label + " state directory in " + cfg.state_dir + ". Aborted.", "fatal");
        exit(1);
    }

    let index_value = 1;
    for (let section in sections) {
        start_rule(cfg, section, index_value);
        index_value++;
    }
}

function runtime_tag(base, postfix) {
    return runtime_constants.tag(base, postfix);
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

function value_contains(value, needle) {
    if (type(value) == "array") {
        for (let item in value)
            if (as_string(item) == needle)
                return true;
        return false;
    }
    return as_string(value) == needle;
}

function has_direct_mark_outbound(config, tag, routing_mark) {
    for (let outbound in array_or_empty(config && config.outbounds)) {
        if (type(outbound) == "object" &&
            outbound.type == "direct" &&
            outbound.tag == tag &&
            int(outbound.routing_mark || 0) == int(routing_mark))
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

function runtime_config_status(cfg, sections) {
    let config_path = option(uci_settings(), "config_path", "");
    let config = read_json_file(config_path);
    let rules_configured = length(sections) > 0;
    let outbounds_configured = rules_configured;
    let routes_configured = rules_configured;

    let index_value = 1;
    for (let section in sections) {
        let outbound = runtime_tag(section_name(section), "out");
        let mark = route_mark_value(cfg, index_value);
        if (!has_direct_mark_outbound(config, outbound, mark))
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

function external_queue_overlap(cfg) {
    let command = "nft list ruleset 2>/dev/null | " + module_command([
        cfg.check_path,
        "nft-queue-overlap",
        NFT_TABLE_NAME,
        cfg.queue_base,
        "" + queue_range_end(cfg)
    ]);
    return command_success(command);
}

function status_json(cfg) {
    let sections = enabled_sections(cfg);
    let configured = length(sections) > 0;
    let provider = provider_available(cfg);
    let pkg = package_installed(cfg);
    let version = pkg || provider ? package_version(cfg) : "not installed";
    if (version == "")
        version = "unknown";

    let expected = length(sections);
    let running = live_pid_count(cfg.child_pid_dir);
    let supervisors = live_pid_count(cfg.pid_dir);
    let standalone_enabled = standalone_service_enabled(cfg);
    let standalone_running = standalone_service_running(cfg);
    let standalone_config = standalone_uci_config_present(cfg);
    let queue_overlap = external_queue_overlap(cfg);
    let standalone_conflict = configured && standalone_running;
    let legacy_runtime = legacy_runtime_path_present(cfg);
    let luci_installed = luci_app_installed(cfg);
    let config_state = runtime_config_status(cfg, sections);
    let conflict = running > expected || queue_overlap || legacy_runtime;
    let ready = configured &&
        provider &&
        !conflict &&
        config_state.outbounds_configured &&
        config_state.routes_configured &&
        expected > 0 &&
        running == expected;

    let message = cfg.status_label + " provider status is normal";
    if (configured && !provider)
        message = "action=" + cfg.action + " is configured, but " + cfg.status_label + " provider is not available at " + cfg.provider_bin;
    else if (queue_overlap)
        message = "external NFQUEUE rules overlap with the Forkop " + cfg.status_label + " range " + cfg.queue_base + "-" + queue_range_end(cfg);
    else if (legacy_runtime)
        message = "legacy zapret runtime paths are still present and should be migrated";
    else if (running > expected || supervisors > expected)
        message = "unexpected Forkop-managed " + cfg.binary_name + " processes are running without matching action=" + cfg.action + " rules";
    else if (configured && !ready)
        message = "action=" + cfg.action + " is configured, but the Forkop-managed " + cfg.binary_name + " runtime is not ready";
    else if (standalone_conflict)
        message = "standalone " + cfg.status_label + " is active together with Forkop action=" + cfg.action + "; queues are separate, but packet-level policy overlap is possible";
    else if (!configured && !provider && pkg)
        message = cfg.status_label + " package is installed, but the provider binary is not available at " + cfg.provider_bin;
    else if (!configured && !provider)
        message = cfg.status_label + " provider is not installed; action=" + cfg.action + " is unavailable";

    let value = {
        installed: provider,
        package_installed: pkg,
        provider_available: provider,
        provider_path: cfg.provider_bin,
        files_available: fs.stat(cfg.provider_files_dir) != null,
        ipset_available: fs.stat(cfg.provider_ipset_dir) != null,
        version,
        configured,
        enabled_rule_count: expected,
        expected_process_count: expected,
        running_process_count: running,
        supervisor_process_count: supervisors,
        standalone_service_enabled: standalone_enabled,
        standalone_service_running: standalone_running,
        standalone_config_present: standalone_config,
        standalone_conflict,
        luci_app_installed: luci_installed,
        queue_base: int(cfg.queue_base),
        queue_range_end: queue_range_end(cfg),
        queue_overlap,
        ready,
        conflict,
        outbounds_configured: config_state.outbounds_configured,
        routes_configured: config_state.routes_configured,
        status_message: message
    };

    if (cfg.legacy_runtime_base != "")
        value.legacy_runtime_present = legacy_runtime;

    write_json(value);
}

function check_json(cfg) {
    let value = {};
    value[cfg.check_prefix + "_installed"] = provider_available(cfg);
    value[cfg.check_prefix + "_package_installed"] = package_installed(cfg);
    value[cfg.check_prefix + "_provider_path"] = cfg.provider_bin;
    write_json(value);
}

function create_nft_rules(cfg) {
    let sections = enabled_sections(cfg);
    if (length(sections) == 0 || !provider_available(cfg))
        return;

    command_success_from_args([ "nft", "add", "rule", "inet", NFT_TABLE_NAME, "mangle_output", "meta", "mark", "&", cfg.desync_mark, "==", cfg.desync_mark, "return" ]);
    command_success_from_args([ "nft", "add", "rule", "inet", NFT_TABLE_NAME, "mangle_output", "meta", "mark", "&", cfg.desync_mark_postnat, "==", cfg.desync_mark_postnat, "return" ]);

    let index_value = 1;
    for (let section in sections) {
        let mark = route_mark_hex(cfg, index_value);
        let queue = "" + queue_number(cfg, index_value);
        command_success_from_args([ "nft", "add", "rule", "inet", NFT_TABLE_NAME, "mangle_output", "meta", "mark", mark, "meta", "l4proto", "tcp", "counter", "queue", "num", queue, "bypass" ]);
        command_success_from_args([ "nft", "add", "rule", "inet", NFT_TABLE_NAME, "mangle_output", "meta", "mark", mark, "meta", "l4proto", "udp", "counter", "queue", "num", queue, "bypass" ]);
        index_value++;
    }
}

function run(provider, argv) {
    argv = type(argv) == "array" ? argv : [];
    let mode = argv[0] || "";
    let cfg = provider_config(provider);
    let kind = cfg.kind;

    if (mode == "supervisor")
        supervisor(cfg, argv[1], argv[2], argv[3], argv[4]);
    else if (mode == "start-runtime")
        start_runtime(cfg);
    else if (mode == "stop-runtime")
        stop_runtime(cfg);
    else if (mode == "create-nft-rules")
        create_nft_rules(cfg);
    else if (mode == "status")
        status_json(cfg);
    else if (mode == "check")
        check_json(cfg);
    else if (mode == "installed" || mode == "provider-available")
        exit(provider_available(cfg) ? 0 : 1);
    else if (mode == "package-installed")
        exit(package_installed(cfg) ? 0 : 1);
    else if (mode == "package-version")
        print(package_version(cfg), "\n");
    else if (mode == "enabled-rule-count")
        print(length(enabled_sections(cfg)), "\n");
    else {
        warn("Usage: providers/" + kind + "/runtime.uc <start-runtime|stop-runtime|create-nft-rules|status|check|installed|package-installed|package-version|enabled-rule-count>\n");
        exit(1);
    }
}

return {
    run
};
