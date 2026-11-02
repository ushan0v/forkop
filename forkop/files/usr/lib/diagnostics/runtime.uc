let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let constants = require("core.constants");
let uci = require("core.uci");
let packages = require("core.packages");
let singbox_constants = require("singbox.constants");
let singbox_runtime = require("singbox.runtime");
let health = require("service.health");
let mask = require("diagnostics.mask");

const CONFIG_NAME = "forkop";
const STABLE_MIN_AGE = 2;

let paths = {
    forkop_config: "/etc/config/forkop",
    luci_view: constants.FORKOP_LUCI_VIEW_DIR,
    rc_dir: "/etc/rc.d"
};

function settings() {
    return uci.get_all(CONFIG_NAME, "settings") ?? {};
}

function executable(path) {
    return ((fs.stat(path)?.mode ?? 0) & 0111) != 0;
}

function has_command(name) {
    return exec.ok([ "sh", "-c", "command -v \"$1\"", "sh", name ]);
}

function status() {
    let running = health.forkop_stably_running(constants.RT_TABLE_NAME, constants.NFT_TABLE_NAME, constants.NFT_FAKEIP_MARK, STABLE_MIN_AGE) ? 1 : 0;
    let enabled = executable(paths.rc_dir + "/S99forkop") ? 1 : 0;
    return { running, enabled, status: health.service_status_text(running, enabled) };
}

// postinst may start Forkop while the package manager is locked; the version file still
// proves the core is installed.
function sing_box_installed() {
    return packages.installed("sing-box-forkop") || (packages.sing_box_version() != "" && has_command("sing-box"));
}

function luci_app_version() {
    let data = fs.readfile(paths.luci_view + "/main.js");
    if (data == null)
        return "not installed";
    let matched = match(data, /(^|\n)[ \t]*var[ \t]+FORKOP_LUCI_APP_VERSION[ \t]*=[ \t]*"([^"]*)"/);
    return matched ? matched[2] : "";
}

function openwrt_release() {
    let matched = match(fs.readfile("/etc/os-release") ?? "", /(^|\n)OPENWRT_RELEASE=["']?([^"'\n]*)/);
    return matched && matched[2] != "" ? matched[2] : "unknown";
}

function system_info() {
    let installed = sing_box_installed();
    return {
        forkop_version: constants.FORKOP_VERSION,
        luci_app_version: luci_app_version(),
        sing_box_version: installed ? (singbox_runtime.version() || "unknown") : "not installed",
        sing_box_variant: installed ? packages.sing_box_variant() : "",
        openwrt_version: openwrt_release(),
        device_model: common.read_first_line("/tmp/sysinfo/model") || "unknown",
        generated_at: common.now_seconds()
    };
}

function sing_box_config_path() {
    return singbox_constants.config_path(settings());
}

function show_config(visibility) {
    let data = fs.readfile(paths.forkop_config);
    if (data == null)
        return null;
    return visibility == "raw" ? data : mask.names(mask.forkop_config(data), mask.hosts(common.read_json_file(sing_box_config_path())));
}

function show_sing_box_config(visibility) {
    let data = fs.readfile(sing_box_config_path());
    if (data == null || visibility == "raw")
        return data;
    let config = common.parse_json(data);
    return mask.names(sprintf("%.2J\n", mask.sing_box_config(config)), mask.hosts(config));
}

function logs() {
    return exec.output([ "logread", "-e", constants.FORKOP_LOG_PATTERN ]) ?? "";
}

return { paths, status, system_info, show_config, show_sing_box_config, logs };
