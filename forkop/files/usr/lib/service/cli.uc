let exec = require("core.exec");
let constants = require("core.constants");
let library = require("core.library");

// Only the init script's start registers the procd triggers Apply and WAN-up depend on.
function init_script(verb) {
    return function(args) {
        return exec.run([ constants.FORKOP_SERVICE_INIT, verb, ...args ]);
    };
}

// A command the page reads as { success, ... } or { success: false, message }.
function reply(fn) {
    return function(args) {
        try {
            print(sprintf("%J\n", { success: true, ...fn(...args) }));
            return 0;
        }
        catch (e) {
            print(sprintf("%J\n", { success: false, message: e.message }));
            return 1;
        }
    };
}

function warp_profile() {
    try {
        print(sprintf("%J\n", require("singbox.runtime").warp_profile()));
        return 0;
    }
    catch (e) {
        warn(e.message, "\n");
        return 1;
    }
}

function json(fn) {
    return function(args) {
        print(sprintf("%J\n", fn(...args)));
        return 0;
    };
}

// An action the page started or acknowledged, answered as { success, job_id, message }.
function action_reply(fn) {
    return function(args) {
        let result = fn(...args);
        print(sprintf("%J\n", result));
        return result.success ? 0 : 1;
    };
}

// A Clash API answer as { status, body }, or the reason it could not be had.
function clash(fn) {
    return function(args) {
        try {
            print(sprintf("%J\n", fn(require("singbox.clash_api"), ...args)));
            return 0;
        }
        catch (e) {
            warn(e.message, "\n");
            return 1;
        }
    };
}

function diagnostics() {
    return require("diagnostics.runtime");
}

function checks() {
    return require("diagnostics.checks");
}

function text(fn) {
    return function(args) {
        let result = fn(...args);
        if (result == null) {
            warn("Configuration file not found\n");
            return 1;
        }
        print(result);
        return 0;
    };
}

function lifecycle() {
    return require("service.lifecycle");
}

function autostart(enabled) {
    if ((enabled ? lifecycle().enable() : lifecycle().disable()) != 0)
        die(enabled ? "Could not enable autostart" : "Could not disable autostart");
    return {};
}

function initd() {
    return require("service.initd");
}

function ui() {
    return require("service.ui");
}

function installer() {
    return require("service.installer");
}

// The state service hands over the page's LuCI session in the environment, which rpcd lets no
// page set itself.
function config_import(step) {
    return action_reply((path) => require("config.import")[step](path, getenv("FORKOP_RPC_SESSION")));
}

function installer_log() {
    let log = installer().log_text();
    if (log == null) {
        warn("install.sh has left no log\n");
        return 1;
    }
    print(log);
    return 0;
}

const COMMANDS = {
    start: { help: "Start Forkop service", run: init_script("start") },
    stop: { help: "Stop Forkop service", run: init_script("stop") },
    reload: { args: 1, help: "Reload Forkop configuration", run: init_script("reload") },
    restart: { help: "Restart Forkop service", run: init_script("restart") },
    enable: { help: "Enable Forkop autostart", run: reply(() => autostart(true)) },
    disable: { help: "Disable Forkop autostart", run: reply(() => autostart(false)) },
    uninstall: { help: "Remove Forkop files installed outside opkg/apk", run: () => lifecycle().uninstall() },
    check_service: { help: "Check the service, memory, clock and conflicting interceptors in JSON format", run: json(() => checks().service()) },
    check_dns: { help: "Check the DNS servers sing-box resolves with in JSON format", run: json(() => checks().dns()) },
    check_traffic: { help: "Check that the router's own traffic goes through Forkop in JSON format", run: json(() => checks().traffic()) },
    check_servers: { help: "Check the listeners of the enabled servers in JSON format", run: json(() => checks().servers()) },
    check_logs: { help: "Show Forkop logs from system journal", run: () => {
        print(diagnostics().logs());
        return 0;
    } },
    report: { args: 2, usage: "[masked|raw] [checks]", help: "Collect the log and configurations of a diagnostic report in JSON format", run: json((visibility, checks) => require("diagnostics.report").report(visibility || "masked", checks)) },
    clash_api: { args: 3, usage: "<method> <path> [body]", help: "Allowlisted Clash API transport fallback", run: clash((api, method, path, body) => api.request(method, path, body)) },
    clash_summary: { help: "Summarize the Clash API state in JSON format", run: clash((api) => api.summary()) },
    show_config: { args: 1, help: "Display current Forkop configuration", run: text((visibility) => diagnostics().show_config(visibility || "masked")) },
    show_version: { help: "Show Forkop version", run: () => { print(constants.FORKOP_VERSION, "\n"); return 0; } },
    show_sing_box_config: { args: 1, help: "Show sing-box configuration", run: text((visibility) => diagnostics().show_sing_box_config(visibility || "masked")) },
    import_config_check: { args: 1, usage: "<path>", help: "Tell in JSON format what loading a Forkop configuration file on the page would change", run: config_import("check") },
    import_config: { args: 1, usage: "<path>", help: "Stage a Forkop configuration file as unsaved changes of the LuCI session in FORKOP_RPC_SESSION", run: config_import("stage") },
    get_status: { help: "Get Forkop service status", run: json(() => diagnostics().status()) },
    get_system_info: { help: "Get system information in JSON format", run: json(() => diagnostics().system_info()) },
    get_subscription_default_headers: { help: "Get default subscription request headers in JSON format", run: json(() => ui().default_headers()) },
    get_ui_state: { help: "Get lightweight UI service/action state in JSON format", run: json(() => ui().current_state()) },
    get_core_features: { help: "Get what the installed sing-box can do, from the tags it was built with, in JSON format", run: json(() => require("singbox.features").report()) },
    service_action_async: { args: 1, usage: "<action>", help: "Start a service action in the background", run: action_reply((action) => ui().start_action(action)) },
    ui_action_ack: { args: 1, usage: "<job>", help: "Acknowledge a finished service action state", run: action_reply((job) => ui().acknowledge(job)) },
    installer_start: { args: 4, usage: "<update|variant|uninstall> <variant> <purge> <lang>", help: "Run install.sh in the background for the Components tab", run: reply((action, variant, purge, lang) => installer().start(action, variant, purge, lang)) },
    installer_status: { args: 1, usage: "[offset]", help: "Show the Components tab's run of install.sh in JSON format", run: json((offset) => installer().status(offset)) },
    installer_run: { args: 1, run: (args) => installer().run(args[0]) },
    installer_log: { help: "Print the log of install.sh's last run", run: installer_log },
    generate_reality_keypair: { help: "Generate a sing-box Reality key pair in JSON format", run: reply(() => require("server.service").reality_keypair()) },
    generate_vless_encryption_keypair: { args: 1, usage: "<x25519|mlkem768>", help: "Generate a VLESS Encryption key pair in JSON format", run: reply((kind) => require("server.service").vless_encryption_keypair(kind)) },
    generate_warp_profile: { help: "Generate a Cloudflare WARP profile in JSON format", run: warp_profile },
    package_prerm: { args: 1, run: (args) => require("service.package").prerm(args[0]) },
    package_postinst: { run: () => require("service.package").postinst() },
    luci_postinst: { run: () => require("service.package").luci_postinst() },
    luci_prerm: { run: () => require("service.package").luci_prerm() },
    sing_box_crash_cleanup: { args: 1, run: (args) => lifecycle().crash_cleanup(args[0]) },
    sing_box_crash_pause: { args: 1, run: (args) => lifecycle().crash_pause(args[0]) },
    sing_box_crash_resume: { run: () => lifecycle().crash_resume() },
    service_action_worker: { args: 3, run: (args) => { ui().worker(args[0], args[1], args[2]); return 0; } },
    initd_start: { args: 1, run: (args) => initd().start(args[0]) },
    initd_stop: { run: () => initd().stop() },
    initd_restart: { run: () => initd().restart() },
    initd_reload: { args: 1, run: (args) => {
        let result = initd().reload(args[0]);
        if (result.sync)
            print("sync\n");
        return result.status;
    } },
    initd_status: { run: () => initd().status() },
    initd_triggers: { run: () => { print(initd().triggers()); return 0; } },
    initd_wan_up: { run: () => initd().wan_up() },
    initd_retry_start: { run: () => initd().retry_start() },
    sing_box_watch: { run: () => require("service.singbox_watch").monitor() },
    sync_rule_sets: { run: () => require("nft.ruleset_sync").worker() }
};

function help() {
    print("Usage: ", constants.FORKOP_BIN, " COMMAND\n\nAvailable commands:\n");
    for (let name, command in COMMANDS) {
        if (command.help == null)
            continue;
        let usage = command.usage == null ? name : name + " " + command.usage;
        print(length(usage) < 28 ? sprintf("    %-28s%s\n", usage, command.help) : sprintf("    %s\n    %28s%s\n", usage, "", command.help));
    }
}

function main(argv, lib) {
    library.set_dir(lib);
    let command = COMMANDS[argv[0] ?? ""];
    if (command == null) {
        help();
        return 1;
    }

    let args = [];
    for (let i = 1; i <= (command.args ?? 0); i++)
        push(args, argv[i] ?? "");
    return command.run(args) ?? 0;
}

return { main, COMMANDS };
