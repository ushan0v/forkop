// Every action holds the lifecycle lock. A reload changes only what would come out different:
// the nft script against the one applied last, the sing-box config against the service's file.

let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let constants = require("core.constants");
let netstat = require("core.netstat");
let uci = require("core.uci");
let validator = require("config.validator");
let server = require("server.service");
let tailscale = require("singbox.tailscale");
let generator = require("singbox.generator");
let singbox_constants = require("singbox.constants");
let runtime = require("singbox.runtime");
let nft = require("nft.apply");
let nft_state = require("nft.state");
let rulesets = require("nft.ruleset_sync");
let health = require("service.health");
let lock = require("service.lock");
let watch = require("service.singbox_watch");

const CONFIG_NAME = "forkop";
const RT_TABLE = constants.RT_TABLE_NAME;
const NFT_TABLE = constants.NFT_TABLE_NAME;
const FAKEIP_MARK = constants.NFT_FAKEIP_MARK;
const ROUTER_MARK = constants.NFT_ROUTER_MARK;
const LOCK_TIMEOUT = 360;
// A start watches a fresh sing-box long enough to see an early crash; a reload only has to
// outlast the gap between the HUP and the ports dropping. The hold counts the consecutive
// one-second looks that must see readiness.
const START_READY_WINDOW = 8;
const RELOAD_READY_WINDOW = 2;
const READY_HOLD = 2;
// procd announces an instance right after its fork, before the child has run sing-box.
const EXEC_GRACE = 3;
const MAX_READY_WAIT = 300;
const STOP_TIMEOUT = 15;
const NOT_CAPTURING = "Forkop was not fully running after the nftables rules were applied";
const NOTHING_TO_RUN = "Forkop has nothing to run: no section with servers and no VPN server is enabled. Set up a section or a VPN server, then start Forkop";

let paths = {
    config: "/etc/config/forkop",
    shipped_config: "/usr/share/forkop/default-config",
    sing_box_init: "/etc/init.d/sing-box",
    lock: "/var/run/forkop/start.lock",
    pending_reload: "/var/run/forkop/reload.pending",
    // Written before Forkop stops sing-box itself, so the crash watcher does not
    // mistake the stop for a crash.
    planned_stop: "/var/run/forkop/sing-box-watch.planned-stop",
    // The nft script the live table was built from.
    applied_nft: "/var/run/forkop/runtime.nft",
    rc_dir: "/etc/rc.d"
};

// An error goes to stderr as well, for whoever runs the init script in a terminal.
function log(level, message) {
    exec.log(level, message);
    if (level == "error")
        warn(message, "\n");
}

function config_fingerprint() {
    return fs.readfile(paths.config) ?? "";
}

function queue_reload_if_changed(fingerprint, context) {
    if (fingerprint == "" || config_fingerprint() == "" || config_fingerprint() == fingerprint)
        return;
    let during = context == "reload" ? "while it was being applied" : "while Forkop was starting";
    if (lock.mark_request(paths.pending_reload, context == "reload" ? "config_changed_during_reload" : "config_changed_during_start"))
        log("info", "The configuration changed " + during + "; applying it next");
    else
        log("warn", "The configuration changed " + during + ", and applying it could not be queued; apply it again");
}

// A configuration restored from a backup, or kept by a sysupgrade, missed the migration the
// package runs at its install; its version then differs from the one the package ships.
function migrate_restored_config() {
    let shipped = match(fs.readfile(paths.shipped_config) ?? "", /option config_version '([^']*)'/);
    if (shipped != null && uci.get(CONFIG_NAME + ".settings.config_version") == shipped[1])
        return true;
    let migrated = require("config.migration").start();
    uci.reset();
    return migrated;
}

// The server ports open only once the configuration is known good.
function validate() {
    try {
        validator.check_requirements();
        server.prepare();
        validator.validate();
    }
    catch (e) {
        log("error", e.message);
        return false;
    }
    server.remove_orphans();
    tailscale.remove_orphaned_states();
    server.sync_firewall(false);
    return true;
}

// Dated from the call, since a live reload keeps the process. The process is pinned by its
// start ticks from the first look (procd answers before it forks); one replaced mid-wait fails.
function wait_ready(window, hold, with_network) {
    let pid = 0;
    let ticks = null;
    let waited = 0;
    let held = 0;
    while (true) {
        if (pid <= 0) {
            let found = health.sing_box_service_pid_runtime();
            if (found > 0 && health.pid_is_sing_box(found)) {
                ticks = health.start_ticks(found);
                if (ticks != null)
                    pid = found;
            }
            if (pid <= 0 && waited >= window && (found <= 0 || waited >= EXEC_GRACE))
                return false;
        }
        else if (health.start_ticks(pid) != ticks)
            return false;

        if (pid > 0 && health.sing_box_runtime_ports_ready() &&
            (!with_network || health.forkop_runtime_network_configured(RT_TABLE, NFT_TABLE, FAKEIP_MARK)))
            held++;
        else
            held = 0;

        // Looks are a second apart, so `held` of them span `held - 1` seconds.
        if (waited >= window && held > hold)
            return true;
        if (waited >= MAX_READY_WAIT)
            return false;
        sleep(1000);
        waited++;
    }
}

// A core that exits on the way up has written its reason to the log.
function not_ready(after) {
    return health.sing_box_service_running()
        ? "sing-box did not become ready after it was " + after
        : "sing-box exited after it was " + after + "; its own log lines above say why";
}

function wait_stopped() {
    for (let i = 0; i < STOP_TIMEOUT; i++) {
        if (!runtime.process_running() && !health.sing_box_service_running())
            return true;
        sleep(1000);
    }
    return !runtime.process_running() && !health.sing_box_service_running();
}

function clash_controller_free() {
    let settings = uci.get_all(CONFIG_NAME, "settings") ?? {};
    let config = common.read_json_file(singbox_constants.config_path(settings));
    let controller = common.as_string(config?.experimental?.clash_api?.external_controller);
    if (controller == "" || !netstat.tcp_endpoint_in_use(exec.output([ "netstat", "-lnt" ]) ?? "", controller))
        return true;
    log("error", "Clash API address " + controller + " is already in use by another process");
    return false;
}

function build_nft() {
    try {
        return nft.build();
    }
    catch (e) {
        log("error", "Failed to build the nftables rules: " + e.message);
        return null;
    }
}

function apply_nft(built) {
    nft.apply(built);
    if (!common.write_file_atomic(paths.applied_nft, built.script))
        log("warn", "Failed to record the applied nftables rules; the next apply rebuilds them");
}

// The routing lives outside nft and is removed with the binary that added it.
function cleanup_network() {
    let ok = true;
    let ip = nft_state.IP_BIN;
    let mark = FAKEIP_MARK + "/" + FAKEIP_MARK;
    let router_mark = ROUTER_MARK + "/" + ROUTER_MARK;
    let steps = [
        [ () => nft_state.table_present(NFT_TABLE), [ "nft", "delete", "table", "inet", NFT_TABLE ], "Failed to remove the Forkop nftables table" ],
        [ () => nft_state.tproxy_marking_rule4_present(RT_TABLE, FAKEIP_MARK), [ ip, "-4", "rule", "del", "fwmark", mark, "table", RT_TABLE, "priority", "105" ],
            "Failed to remove the Forkop IPv4 routing rule" ],
        [ () => nft_state.tproxy_marking_rule6_present(RT_TABLE, FAKEIP_MARK), [ ip, "-6", "rule", "del", "fwmark", mark, "table", RT_TABLE, "priority", "105" ],
            "Failed to remove the Forkop IPv6 routing rule" ],
        [ () => nft_state.tproxy_marking_rule4_present(RT_TABLE, ROUTER_MARK), [ ip, "-4", "rule", "del", "fwmark", router_mark, "table", RT_TABLE, "priority", "105" ],
            "Failed to remove the Forkop IPv4 routing rule of the router's own traffic" ],
        [ () => nft_state.tproxy_marking_rule6_present(RT_TABLE, ROUTER_MARK), [ ip, "-6", "rule", "del", "fwmark", router_mark, "table", RT_TABLE, "priority", "105" ],
            "Failed to remove the Forkop IPv6 routing rule of the router's own traffic" ],
        [ () => nft_state.source_check_rule4_present(FAKEIP_MARK), [ ip, "-4", "rule", "del", "iif", "lo", "fwmark", mark, "lookup", "main",
            "priority", nft_state.SOURCE_CHECK_PRIORITY ], "Failed to remove the Forkop IPv4 routing rule for the source check" ],
        [ () => nft_state.tproxy_route4_present(RT_TABLE), [ ip, "route", "flush", "table", RT_TABLE ], "Failed to flush the Forkop IPv4 routing table" ],
        [ () => nft_state.tproxy_route6_present(RT_TABLE), [ ip, "-6", "route", "flush", "table", RT_TABLE ], "Failed to flush the Forkop IPv6 routing table" ]
    ];
    for (let step in steps)
        if (step[0]() && (!exec.ok(step[1]) || step[0]())) {
            log("error", step[2]);
            ok = false;
        }
    try {
        nft.route_bound_devices([]);
    }
    catch (e) {
        log("error", e.message);
        ok = false;
    }
    fs.unlink(paths.applied_nft);
    return ok;
}

function stop_runtime(keep_watcher) {
    let ok = true;
    if (!keep_watcher)
        watch.stop_worker();
    rulesets.stop_worker();
    if (!cleanup_network())
        ok = false;
    // The init script's stop has procd delete the service, and ubus complains of one it lacks.
    let held = ((fs.stat(paths.sing_box_init)?.mode ?? 0) & 0111) != 0 && health.sing_box_service_registered();
    if (held && exec.run([ paths.sing_box_init, "stop" ]) != 0) {
        log("error", "Failed to stop sing-box");
        ok = false;
    }
    if (!wait_stopped()) {
        log("error", "sing-box is still running after it was stopped");
        ok = false;
    }
    return ok;
}

function cleanup_failed_runtime(keep_watcher) {
    server.sync_firewall(true);
    return stop_runtime(keep_watcher);
}

// A Forkop not set up yet has not failed: the action succeeds, so the WAN coming up does not
// retry it.
function nothing_to_run() {
    if (generator.runnable())
        return false;
    log("warn", NOTHING_TO_RUN);
    cleanup_failed_runtime();
    return true;
}

let start_fingerprint = "";

// Every step that gives up logs one error line, which the page raises as an alert.
function start_runtime() {
    if (runtime.process_running()) {
        log("error", "Another sing-box process is running outside Forkop; stop it before starting Forkop");
        return false;
    }

    if (!validate())
        return false;
    start_fingerprint = config_fingerprint();
    if (!nft.ensure_bridge_netfilter_disabled()) {
        log("error", "Failed to disable bridge netfilter for transparent proxying");
        return false;
    }

    try {
        runtime.configure_service();
        runtime.write_config(true);
        nft.route_bound_devices(runtime.bound_devices());
    }
    catch (e) {
        log("error", e.message);
        return false;
    }
    let built = build_nft();
    if (built == null)
        return false;
    if (!clash_controller_free())
        return false;

    if (!exec.ok([ paths.sing_box_init, "start" ])) {
        log("error", "Failed to start sing-box");
        return false;
    }
    if (!wait_ready(START_READY_WINDOW, READY_HOLD, false)) {
        log("error", not_ready("started"));
        return false;
    }

    // Only once sing-box answers does the table start sending it traffic.
    try {
        apply_nft(built);
    }
    catch (e) {
        log("error", e.message);
        return false;
    }
    if (!nft_state.ipv6_enabled())
        log("info", "IPv6 is off on the router; only IPv4 traffic is routed");
    if (!wait_ready(0, 0, true)) {
        log("error", NOT_CAPTURING);
        return false;
    }
    if (!watch.start_worker()) {
        log("error", "Failed to start the sing-box crash watcher");
        return false;
    }
    if (!rulesets.start_worker()) {
        log("error", "Failed to start the rule-set sync worker");
        return false;
    }

    fs.unlink(paths.planned_stop);
    if (fs.stat(paths.planned_stop) != null) {
        log("error", "Failed to arm the sing-box crash watcher");
        return false;
    }
    return true;
}

function locked(action) {
    let owner = common.own_pid();
    if (!lock.acquire_wait(paths.lock, owner, LOCK_TIMEOUT)) {
        log("error", "Timed out waiting for another Forkop action to finish");
        return 1;
    }
    let status = action();
    lock.release(paths.lock, owner);
    return status;
}

function forkop_running() {
    return health.forkop_running(RT_TABLE, NFT_TABLE, FAKEIP_MARK);
}

function start() {
    if (forkop_running()) {
        log("info", "Forkop is already running");
        return 0;
    }
    return locked(function() {
        if (forkop_running()) {
            log("info", "Forkop is already running");
            return 0;
        }
        log("info", "Starting Forkop");
        if (!migrate_restored_config()) {
            cleanup_failed_runtime();
            return 1;
        }
        if (nothing_to_run())
            return 0;
        if (health.sing_box_service_running() && (!cleanup_failed_runtime() || health.sing_box_service_running())) {
            log("error", "A sing-box left from an earlier run could not be stopped; not starting a second one");
            return 1;
        }
        if (!start_runtime()) {
            cleanup_failed_runtime();
            return 1;
        }
        log("info", "Forkop started");
        queue_reload_if_changed(start_fingerprint, "start");
        return 0;
    });
}

function stop() {
    return locked(function() {
        let active = health.sing_box_service_running() || nft_state.table_present(NFT_TABLE);
        if (active)
            log("info", "Stopping Forkop");
        // The server ports close with the runtime. A reload keeps them: closing
        // them in between would cost a second firewall reload.
        server.sync_firewall(true);
        if (!common.write_file_atomic(paths.planned_stop, common.own_pid() + "\n"))
            log("warn", "Failed to mark the stop as planned");
        watch.stop_worker();
        if (!stop_runtime(true))
            return 1;
        if (active)
            log("info", "Forkop stopped");
        return 0;
    });
}

// Called by the crash watcher once procd gave up on sing-box.
function crash_cleanup(exit_code) {
    return locked(function() {
        if (fs.stat(paths.planned_stop) != null || forkop_running())
            return 0;
        let suffix = match(common.as_string(exit_code), /^[0-9]+$/) ? " (exit code " + exit_code + ")" : "";
        log("error", "sing-box stopped after repeated crashes" + suffix + "; Forkop is stopped");
        return cleanup_failed_runtime(true) && watch.stop_worker() ? 0 : 1;
    });
}

// What a failed reload left: the runtime it never touched, or none at all.
function reload_failed(runtime_touched) {
    log("warn", runtime_touched ? "Configuration not applied; Forkop is stopped" : "Configuration not applied; Forkop keeps running the previous one");
    return 1;
}

function abort_reload(reason, runtime_touched) {
    log("error", reason);
    if (runtime_touched)
        cleanup_failed_runtime();
    return reload_failed(runtime_touched);
}

function restart_runtime() {
    log("info", "Forkop is not fully running; restarting it");
    if (!stop_runtime())
        return false;
    if (start_runtime())
        return true;
    cleanup_failed_runtime();
    return false;
}

function capture(active) {
    return exec.ok(nft.capture_command(active));
}

// The kernel logs "Killed process <pid> (<name>)" for each process the OOM killer ends.
function last_oom_kill(kernel_log) {
    let pid = 0;
    for (let line in split(kernel_log ?? "", "\n")) {
        let kill = match(line, /Killed process ([0-9]+) \(/);
        if (kill != null)
            pid = int(kill[1]);
    }
    return pid;
}

function crash_reason(pid) {
    return pid > 0 && last_oom_kill(exec.output([ "dmesg" ])) == pid
        ? "The router ran out of memory and the kernel killed sing-box"
        : "sing-box exited unexpectedly";
}

// procd brings a crashed sing-box back a few seconds later; until the new one listens the
// capture pauses, as during a reload. An action holding the lifecycle lock owns the runtime,
// so neither step waits for one.
function crash_pause(pid) {
    let owner = common.own_pid();
    if (!lock.acquire(paths.lock, owner))
        return 0;
    if (fs.stat(paths.planned_stop) == null && nft_state.table_present(NFT_TABLE) && !health.sing_box_service_running()) {
        if (capture(false))
            log("warn", crash_reason(int(pid)) + "; the capture is paused until procd restarts it");
        else
            log("error", "Failed to pause the traffic capture after sing-box exited");
    }
    lock.release(paths.lock, owner);
    return 0;
}

function crash_resume() {
    if (!wait_ready(0, 1, false))
        return 0;
    let owner = common.own_pid();
    if (!lock.acquire(paths.lock, owner))
        return 0;
    if (fs.stat(paths.planned_stop) == null && nft_state.table_present(NFT_TABLE) && !forkop_running()) {
        if (capture(true))
            log("info", "sing-box restarted; traffic capture resumed");
        else
            log("error", "Failed to resume the traffic capture after sing-box restarted");
    }
    lock.release(paths.lock, owner);
    return 0;
}

// netifd flushes every ip rule as it starts and a device going down takes its routes: after a
// network restart the core and its table run with nothing routing to them.
function restore_routing() {
    let owner = common.own_pid();
    if (!lock.acquire(paths.lock, owner))
        return false;
    let lost = fs.stat(paths.planned_stop) == null && nft_state.table_present(NFT_TABLE) &&
        health.sing_box_service_running() && !forkop_running();
    if (lost) {
        try {
            nft.ensure_tproxy_routing();
            nft.route_bound_devices(runtime.bound_devices());
            log("info", "The WAN came up without Forkop's routing; restored it");
        }
        catch (e) {
            log("error", e.message);
        }
    }
    let restored = lost && forkop_running();
    lock.release(paths.lock, owner);
    return restored;
}

// A forced reload reapplies the configuration whether or not it changed.
function reload_announcement(reason, forced) {
    if (!forced)
        return "Applying configuration";
    let interface_up = match(reason, /^interface_up:(.+)$/);
    return "Reapplying configuration" + (interface_up ? ": interface '" + interface_up[1] + "' came up" : "");
}

// Everything that can be refused is built before anything is applied, so a refused
// configuration leaves the running one as it was. Reasons other than a config change or a
// queued reload also reload sing-box.
function reload_runtime(reason) {
    let forced = reason != "on_config_change" && reason != "pending";
    log("info", reload_announcement(reason, forced));
    if (!migrate_restored_config() || !validate())
        return reload_failed(false);
    // After validation, which writes the defaults a new server needs, so this reload's own
    // writing is not taken for somebody else's change.
    let fingerprint = config_fingerprint();

    if (!forkop_running()) {
        if (nothing_to_run())
            return 0;
        if (!restart_runtime())
            return reload_failed(true);
        log("info", "Configuration applied");
        queue_reload_if_changed(fingerprint, "reload");
        return 0;
    }

    let built = build_nft();
    if (built == null)
        return reload_failed(false);

    // The running core reads the file only when it is reloaded below.
    let config_changed;
    try {
        runtime.configure_service();
        config_changed = runtime.write_config(false);
    }
    catch (e) {
        return abort_reload(e.message, false);
    }
    try {
        nft.route_bound_devices(runtime.bound_devices());
    }
    catch (e) {
        return abort_reload(e.message, true);
    }

    let nft_changed = fs.readfile(paths.applied_nft) != built.script;
    if (nft_changed) {
        rulesets.stop_worker();
        try {
            apply_nft(built);
        }
        catch (e) {
            return abort_reload(e.message, true);
        }
    }

    // Paused while sing-box rebinds, so nothing reaches closed ports.
    if (config_changed || forced) {
        if (!capture(false))
            return abort_reload("Failed to pause the traffic capture before reloading sing-box", true);
        log("info", "Reloading sing-box");
        if (!exec.ok([ paths.sing_box_init, "reload" ]))
            return abort_reload("Failed to reload sing-box", true);
        if (!wait_ready(RELOAD_READY_WINDOW, READY_HOLD, false))
            return abort_reload(not_ready("reloaded"), true);
        if (!capture(true))
            return abort_reload("Failed to resume the traffic capture after reloading sing-box", true);
        if (!wait_ready(0, 0, true))
            return abort_reload(NOT_CAPTURING, true);
    }

    // A rebuilt table may change a section's own addresses and ports, so the worker restarts and
    // writes every section; otherwise it follows the core across its reload on its own.
    let worker_changed = nft_changed || !rulesets.worker_current();
    if (worker_changed && !rulesets.start_worker())
        return abort_reload("Failed to start the rule-set sync worker", true);

    if (nft_changed || config_changed || forced || worker_changed)
        log("info", "Configuration applied");
    else
        log("info", "Configuration already applied; nothing changed");
    queue_reload_if_changed(fingerprint, "reload");
    return 0;
}

function reload(reason) {
    return locked(() => reload_runtime(reason ?? ""));
}

// Autostart is the rc.d link. The init script's enable would wait on procd's per-service lock
// for as long as any other command on the service runs.
const AUTOSTART_PRIORITY = constants.FORKOP_START_PRIORITY;

function enable() {
    let link = paths.rc_dir + "/S" + AUTOSTART_PRIORITY + "forkop";
    common.ensure_dir(paths.rc_dir);
    fs.unlink(link);
    return fs.symlink("../init.d/forkop", link) ? 0 : 1;
}

function disable() {
    fs.unlink(paths.rc_dir + "/K" + AUTOSTART_PRIORITY + "forkop");
    fs.unlink(paths.rc_dir + "/S" + AUTOSTART_PRIORITY + "forkop");
    return fs.stat(paths.rc_dir + "/S" + AUTOSTART_PRIORITY + "forkop") == null ? 0 : 1;
}

function remove_package(name) {
    if (exec.ok([ "sh", "-c", "command -v apk" ])) {
        if (exec.ok([ "apk", "info", "-e", name ]))
            exec.ok([ "apk", "del", name ]);
    }
    else if (require("core.packages").opkg_installed(name))
        exec.ok([ "opkg", "remove", "--force-depends", name ]);
}

// What a manual install put on the router, removed the way a package removal
// would.
function uninstall() {
    let init = constants.FORKOP_SERVICE_INIT;
    let domain = constants.FORKOP_LUCI_I18N_DOMAIN;
    log("info", "Uninstalling Forkop");
    if (fs.stat(init) != null) {
        exec.ok([ init, "stop" ]);
        exec.ok([ init, "disable" ]);
    }
    remove_package("luci-i18n-forkop-ru");
    remove_package("luci-app-forkop");

    common.remove_tree("/usr/lib/forkop");
    common.remove_tree(constants.FORKOP_LUCI_VIEW_DIR);
    for (let path in [ init, constants.FORKOP_BIN, "/usr/share/luci/menu.d/luci-app-forkop.json",
        "/usr/share/rpcd/acl.d/luci-app-forkop.json", "/etc/uci-defaults/50_luci-forkop",
        "/usr/lib/lua/luci/i18n/" + domain + ".ru.lua", "/usr/lib/lua/luci/i18n/" + domain + ".en.lua",
        ...fs.glob("/usr/lib/lua/luci/i18n/" + domain + ".*.lmo"), ...fs.glob("/var/luci-indexcache*"), ...fs.glob("/tmp/luci-indexcache*") ])
        fs.unlink(path);
    if (fs.stat("/etc/init.d/rpcd") != null)
        exec.ok([ "/etc/init.d/rpcd", "reload" ]);

    print("{\"removed\":true}\n");
    return 0;
}

return { paths, start, stop, reload, crash_cleanup, crash_pause, crash_resume, restore_routing, enable, disable, uninstall, wait_ready };
