#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");
let core_ip = require("core.ip");
let runtime_dns = require("singbox.dns");

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const STATE_FILE = getenv("FORKOP_DNS_FAILOVER_STATE_FILE") || RUNTIME_STATE_DIR + "/dns-failover.json";
const PID_FILE = getenv("FORKOP_DNS_FAILOVER_PID_FILE") || RUNTIME_STATE_DIR + "/dns-failover.pid";
const DNS_FAILOVER_UC = getenv("FORKOP_DNS_FAILOVER_UC") || LIB_DIR + "/singbox/dns_failover.uc";
const SERVICE_BIN = getenv("FORKOP_BIN") || "/usr/bin/forkop";
const CHECK_DOMAIN = "example.com";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let result = [];
    for (let arg in args)
        push(result, shell_quote(arg));
    return join(" ", result);
}

function command_status(command) {
    let status = int(system(command));
    return status > 255 ? int(status / 256) : status;
}

function command_success_from_args(args) {
    return command_status(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function command_output_from_args(args) {
    let pipe = fs.popen(command_from_args(args), "r");
    if (!pipe)
        return "";
    let data = pipe.read("all");
    let status = pipe.close();
    return status == 0 && data != null ? as_string(data) : "";
}

function settings() {
    return common.object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function ensure_dir(path) {
    return command_success_from_args([ "mkdir", "-p", path ]);
}

function remove_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function write_state(path, value) {
    if (!ensure_dir(RUNTIME_STATE_DIR))
        return false;
    let stamp = clock();
    let temporary = as_string(path) + ".tmp." + as_string(stamp[0]) + "." + as_string(stamp[1]);
    if (!common.write_json_file(temporary, value))
        return false;
    if (!fs.rename(temporary, path)) {
        remove_file(temporary);
        return false;
    }
    return true;
}

function log_message(message, level) {
    command_success_from_args([ "logger", "-t", "forkop", "[" + as_string(level || "info") + "] DNS failover: " + as_string(message) ]);
}

function duration_milliseconds(value, fallback) {
    let rest = as_string(value);
    let total = 0.0;
    let units = { ns: 0.000001, us: 0.001, ms: 1, s: 1000, m: 60000, h: 3600000, d: 86400000 };
    while (rest != "") {
        let matched = match(rest, /^([0-9]+(\.[0-9]+)?)(ns|us|ms|s|m|h|d)/);
        if (!matched)
            return fallback;
        total += (matched[1] * 1) * units[matched[3]];
        rest = substr(rest, length(matched[0]));
    }
    return total > 0 ? int(total + 0.5) : fallback;
}

function duration_seconds(value, fallback) {
    let milliseconds = duration_milliseconds(value, fallback * 1000);
    return int((milliseconds + 999) / 1000);
}

function probe_timeout(settings_value) {
    return duration_seconds(settings_value, 2);
}

function probe_port(kind, index_value, timeout_seconds) {
    let args = [
        "dig", "-p", as_string(runtime_dns.health_port(kind, index_value)),
        "@" + runtime_dns.DNS_HEALTH_ADDRESS,
        CHECK_DOMAIN, "A", "+short",
        "+timeout=" + as_string(timeout_seconds), "+tries=1"
    ];
    for (let line in split(command_output_from_args(args), "\n"))
        if (core_ip.valid_ipv4(trim(as_string(line))))
            return true;
    return false;
}

function probe_canonical_main(timeout_seconds) {
    let args = [
        "dig", "-p", as_string(runtime_dns.health_port("active", 0)),
        "@" + runtime_dns.DNS_HEALTH_ADDRESS, CHECK_DOMAIN, "A", "+short",
        "+timeout=" + as_string(timeout_seconds), "+tries=1"
    ];
    for (let line in split(command_output_from_args(args), "\n"))
        if (core_ip.valid_ipv4(trim(as_string(line))))
            return true;
    return false;
}

function verification_plan(previous, candidate) {
    previous = common.object_or_empty(previous);
    candidate = common.object_or_empty(candidate);
    return {
        main: int(candidate.main_index || 0) != int(previous.main_index || 0),
        bootstrap: int(candidate.bootstrap_index || 0) != int(previous.bootstrap_index || 0) &&
            length(candidate.bootstrap_servers || []) > 1
    };
}

function verify_state(path) {
    let cfg = settings();
    let state = common.read_json_file(path);
    let expected = runtime_dns.state_template(cfg);
    if (!runtime_dns.state_matches(expected, state))
        return false;

    state = runtime_dns.normalize_state(cfg, state);
    let previous = runtime_dns.normalize_state(cfg, common.read_json_file(STATE_FILE));
    let plan = verification_plan(previous, state);
    let timeout_seconds = probe_timeout(common.option(cfg, "dns_check_timeout", "2s"));
    if (plan.main && !probe_canonical_main(timeout_seconds))
        return false;
    if (plan.bootstrap && !probe_port("bootstrap", state.bootstrap_index, timeout_seconds))
        return false;
    return true;
}

function commit_state(path) {
    let cfg = settings();
    let state = common.read_json_file(path);
    if (!runtime_dns.state_matches(runtime_dns.state_template(cfg), state))
        return false;
    return fs.rename(path, STATE_FILE);
}

function now_seconds() {
    return int(clock()[0]);
}

function choose_index(kind, state, current_index, timeout_seconds, recovery) {
    let values = kind == "main" ? state.main_servers : state.bootstrap_servers;
    if (length(values) <= 1)
        return { index: 0, reason: "single", alive: true };

    if (recovery && current_index > 0) {
        for (let i = 0; i < current_index; i++)
            if (probe_port(kind, i, timeout_seconds))
                return { index: i, reason: "recovery", alive: true };
        return { index: current_index, reason: "unchanged", alive: true };
    }

    if (probe_port(kind, current_index, timeout_seconds))
        return { index: current_index, reason: "alive", alive: true };

    for (let i = 0; i < length(values); i++) {
        if (i == current_index)
            continue;
        if (probe_port(kind, i, timeout_seconds))
            return { index: i, reason: i < current_index ? "recovery" : "active_dead", alive: true };
    }
    return { index: current_index, reason: "all_down", alive: false };
}

function threshold_value(value) {
    value = int(value || 3);
    return value >= 1 && value <= 10 ? value : 3;
}

function new_threshold_state() {
    return { failures: 0, recovery_successes: 0, recovery_index: -1 };
}

function pending_selection(current_index, reason) {
    return { index: current_index, reason, alive: true };
}

function qualify_active_selection(current_index, selected, tracker, threshold) {
    if (selected.alive && int(selected.index) == current_index) {
        tracker.failures = 0;
        return selected;
    }

    tracker.failures++;
    if (tracker.failures < threshold)
        return pending_selection(current_index, "failure_pending");

    tracker.failures = threshold;
    return selected;
}

function qualify_recovery_selection(current_index, selected, tracker, threshold) {
    if (!selected.alive || int(selected.index) == current_index) {
        tracker.recovery_successes = 0;
        tracker.recovery_index = -1;
        return selected;
    }

    if (tracker.recovery_index != int(selected.index)) {
        tracker.recovery_index = int(selected.index);
        tracker.recovery_successes = 0;
    }
    tracker.recovery_successes++;
    if (tracker.recovery_successes < threshold)
        return pending_selection(current_index, "recovery_pending");

    return selected;
}

function reset_tracker(tracker) {
    tracker.failures = 0;
    tracker.recovery_successes = 0;
    tracker.recovery_index = -1;
}

function reset_changed_trackers(state, previous, trackers) {
    for (let kind in [ "bootstrap", "main" ]) {
        let key = kind + "_index";
        if (int(state[key]) != int(previous[key]))
            reset_tracker(trackers[kind]);
    }
}

function clone_state(value) {
    return json(sprintf("%J", value));
}

function apply_selections(state, selections) {
    let candidate = clone_state(state);
    let changed = [];
    for (let kind in [ "bootstrap", "main" ]) {
        let selected = common.object_or_empty(common.object_or_empty(selections)[kind]);
        if (selected.index == null)
            continue;
        let key = kind == "main" ? "main_index" : "bootstrap_index";
        if (int(candidate[key]) == int(selected.index))
            continue;
        candidate[key] = int(selected.index);
        push(changed, { kind, selected });
    }
    if (length(changed) == 0)
        return true;

    let stamp = clock();
    let candidate_path = STATE_FILE + ".candidate." + as_string(stamp[0]) + "." + as_string(stamp[1]);
    if (!write_state(candidate_path, candidate))
        return false;

    let status = command_status(command_from_args([ SERVICE_BIN, "dns_failover_apply", candidate_path ]) + " >/dev/null 2>&1");
    remove_file(candidate_path);
    if (status != 0)
        return false;

    state.main_index = candidate.main_index;
    state.bootstrap_index = candidate.bootstrap_index;
    for (let item in changed) {
        let values = item.kind == "main" ? state.main_servers : state.bootstrap_servers;
        let selected = item.selected;
        log_message("switched " + item.kind + " DNS to priority " + as_string(selected.index + 1) + " (" + values[selected.index] + ", " + selected.reason + ")", "info");
    }
    return true;
}

function worker() {
    let cfg = settings();
    let state = runtime_dns.normalize_state(cfg, common.read_json_file(STATE_FILE));
    if (length(state.main_servers) <= 1 && length(state.bootstrap_servers) <= 1)
        return 0;
    if (!write_state(STATE_FILE, state))
        return 1;

    let active_interval = duration_seconds(common.option(cfg, "dns_check_interval", "10s"), 10);
    let recovery_interval = duration_seconds(common.option(cfg, "dns_recovery_check_interval", "60s"), 60);
    let timeout_seconds = probe_timeout(common.option(cfg, "dns_check_timeout", "2s"));
    let failure_threshold = threshold_value(common.option(cfg, "dns_failure_threshold", "3"));
    let recovery_threshold = threshold_value(common.option(cfg, "dns_recovery_threshold", "3"));
    let next_active = now_seconds();
    let next_recovery = now_seconds() + recovery_interval;
    let all_down = { main: false, bootstrap: false };
    let trackers = { main: new_threshold_state(), bootstrap: new_threshold_state() };

    while (true) {
        let now = now_seconds();
        let current_cfg = settings();
        if (!runtime_dns.state_matches(runtime_dns.state_template(current_cfg), state))
            return 0;

        if (now >= next_active) {
            let bootstrap = qualify_active_selection(
                int(state.bootstrap_index),
                choose_index("bootstrap", state, int(state.bootstrap_index), timeout_seconds, false),
                trackers.bootstrap,
                failure_threshold
            );
            if (!bootstrap.alive && !all_down.bootstrap)
                log_message("all configured bootstrap DNS servers are unavailable", "warn");
            all_down.bootstrap = !bootstrap.alive;

            if (bootstrap.index != int(state.bootstrap_index)) {
                let main = qualify_active_selection(
                    int(state.main_index),
                    choose_index("main", state, int(state.main_index), timeout_seconds, false),
                    trackers.main,
                    failure_threshold
                );
                let selections = { bootstrap };
                if (main.alive)
                    selections.main = main;
                let previous = { main_index: state.main_index, bootstrap_index: state.bootstrap_index };
                let applied = apply_selections(state, selections);
                if (applied)
                    reset_changed_trackers(state, previous, trackers);
                next_active = now_seconds() + (applied && !main.alive ? 1 : active_interval);
            }
            else {
                let main = qualify_active_selection(
                    int(state.main_index),
                    choose_index("main", state, int(state.main_index), timeout_seconds, false),
                    trackers.main,
                    failure_threshold
                );
                if (!main.alive && !all_down.main)
                    log_message("all configured main DNS servers are unavailable", "warn");
                all_down.main = !main.alive;
                let previous = { main_index: state.main_index, bootstrap_index: state.bootstrap_index };
                let applied = apply_selections(state, { main });
                if (applied)
                    reset_changed_trackers(state, previous, trackers);
                next_active = now_seconds() + active_interval;
            }
        }

        if (now >= next_recovery) {
            let bootstrap = int(state.bootstrap_index) > 0
                ? qualify_recovery_selection(
                    int(state.bootstrap_index),
                    choose_index("bootstrap", state, int(state.bootstrap_index), timeout_seconds, true),
                    trackers.bootstrap,
                    recovery_threshold
                )
                : pending_selection(int(state.bootstrap_index), "unchanged");
            let main = int(state.main_index) > 0
                ? qualify_recovery_selection(
                    int(state.main_index),
                    choose_index("main", state, int(state.main_index), timeout_seconds, true),
                    trackers.main,
                    recovery_threshold
                )
                : pending_selection(int(state.main_index), "unchanged");
            let has_changes = bootstrap.index != int(state.bootstrap_index) || main.index != int(state.main_index);
            let previous = { main_index: state.main_index, bootstrap_index: state.bootstrap_index };
            let applied = apply_selections(state, { bootstrap, main });
            if (applied)
                reset_changed_trackers(state, previous, trackers);
            let completed = now_seconds();
            if (has_changes && applied)
                next_active = completed + active_interval;
            next_recovery = completed + recovery_interval;
        }

        command_success_from_args([ "sleep", "1" ]);
    }
}

function file_first_line(path) {
    let data = fs.readfile(path);
    if (data == null)
        return "";
    return trim(split(as_string(data), "\n")[0]);
}

function process_running(pid) {
    return match(as_string(pid), /^[0-9]+$/) != null && command_success_from_args([ "kill", "-0", pid ]);
}

function stop_runtime() {
    let pid = file_first_line(PID_FILE);
    if (process_running(pid))
        command_success_from_args([ "kill", pid ]);
    remove_file(PID_FILE);
    return 0;
}

function start_runtime() {
    let cfg = settings();
    stop_runtime();
    if (!runtime_dns.failover_enabled(cfg)) {
        remove_file(STATE_FILE);
        return 0;
    }
    if (!ensure_dir(RUNTIME_STATE_DIR))
        return 1;

    let command = command_from_args([ "ucode", "-L", LIB_DIR, DNS_FAILOVER_UC, "worker" ]) +
        " >/dev/null 2>&1 1000>&- & echo $! >" + shell_quote(PID_FILE);
    return command_status(command);
}

function select_fixture(state_path, alive_path, kind, recovery) {
    let state = common.object_or_empty(common.read_json_file(state_path));
    let alive = common.object_or_empty(common.read_json_file(alive_path));
    let key = kind == "main" ? "main_index" : "bootstrap_index";
    let values = kind == "main" ? state.main_servers : state.bootstrap_servers;
    let current = int(state[key] || 0);
    let selected = { index: current, reason: "all_down", alive: false };
    let probe = function(index_value) { return alive[as_string(index_value)] === true || alive[as_string(index_value)] == 1; };

    if (as_string(recovery) == "1" && current > 0) {
        for (let i = 0; i < current; i++)
            if (probe(i)) {
                selected = { index: i, reason: "recovery", alive: true };
                break;
            }
    }
    else if (probe(current)) {
        selected = { index: current, reason: "alive", alive: true };
    }
    else {
        for (let i = 0; i < length(values); i++)
            if (i != current && probe(i)) {
                selected = { index: i, reason: i < current ? "recovery" : "active_dead", alive: true };
                break;
            }
    }
    common.write_json(selected);
}

function threshold_fixture(path, current_index, threshold, recovery) {
    let sequence = common.read_json_file(path);
    let tracker = new_threshold_state();
    let selected = pending_selection(int(current_index), "unchanged");
    for (let item in sequence || [])
        selected = as_string(recovery) == "1"
            ? qualify_recovery_selection(int(current_index), item, tracker, threshold_value(threshold))
            : qualify_active_selection(int(current_index), item, tracker, threshold_value(threshold));
    common.write_json({ selected, tracker });
}

let mode = ARGV[0] || "";

if (mode == "start-runtime")
    exit(start_runtime());
else if (mode == "stop-runtime")
    exit(stop_runtime());
else if (mode == "worker")
    exit(worker());
else if (mode == "verify-state")
    exit(verify_state(ARGV[1]) ? 0 : 1);
else if (mode == "commit-state")
    exit(commit_state(ARGV[1]) ? 0 : 1);
else if (mode == "select-fixture")
    select_fixture(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "threshold-fixture")
    threshold_fixture(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "verification-plan-fixture")
    common.write_json(verification_plan(common.read_json_file(ARGV[1]), common.read_json_file(ARGV[2])));
else {
    warn("Usage: singbox/dns_failover.uc <start-runtime|stop-runtime|worker|verify-state|commit-state|select-fixture|threshold-fixture|verification-plan-fixture> ...\n");
    exit(1);
}
