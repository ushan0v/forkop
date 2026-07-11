#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let uci_core = require("core.uci");

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || constants.FORKOP_CONFIG_NAME || "forkop";
const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const BIN_PATH = getenv("FORKOP_BIN") || constants.FORKOP_BIN || "/usr/bin/forkop";
const SERVICE_INIT = getenv("FORKOP_SERVICE_INIT") || constants.FORKOP_SERVICE_INIT || "/etc/init.d/forkop";
const FORKOP_VERSION = getenv("FORKOP_VERSION") || constants.FORKOP_VERSION || "";
const FORKOP_RELEASE_REPO = getenv("FORKOP_RELEASE_REPO") || constants.FORKOP_RELEASE_REPO || "ushan0v/forkop";
const RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const SYSTEM_INFO_CACHE_FILE = getenv("FORKOP_SYSTEM_INFO_CACHE_FILE") || RUNTIME_STATE_DIR + "/system-info.json";
const COMPONENT_JOB_DIR = getenv("UPDATES_JOB_DIR") || getenv("FORKOP_UI_COMPONENT_ACTION_DIR") || RUNTIME_STATE_DIR + "/component-actions";
const COMPONENT_LOCK_DIR = getenv("UPDATES_LOCK_DIR") || RUNTIME_STATE_DIR + "/component-action.lock";
const TMP_STALE_TTL_MINUTES = getenv("UPDATES_TMP_STALE_TTL_MINUTES") || "30";
const TMP_FILE_STALE_TTL_MINUTES = getenv("UPDATES_TMP_FILE_STALE_TTL_MINUTES") || "10";
const SB_MANAGED_SERVICE_MARKER = getenv("SB_MANAGED_SERVICE_MARKER") || constants.SB_MANAGED_SERVICE_MARKER || "Forkop managed sing-box service for binary variants";

let tmp_dir = "";
let lock_held = false;
let forkop_was_running = false;
let forkop_stopped_for_sing_box_change = false;

function as_string(value) {
    return value == null ? "" : "" + value;
}

function arg_bool(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
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

function command_status(command) {
    let status = int(system(command));
    return status > 255 ? int(status / 256) : status;
}

function command_success(command) {
    return command_status("(" + command + ") >/dev/null 2>&1") == 0;
}

function command_success_from_args(args) {
    return command_success(command_from_args(args));
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

function command_exists(name) {
    return command_success_from_args([ "command", "-v", name ]);
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function write_file(path, value) {
    return fs.writefile(as_string(path), as_string(value)) != null;
}

function read_file(path) {
    let data = fs.readfile(as_string(path));
    return data == null ? "" : as_string(data);
}

function remove_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function ensure_dir(path) {
    return command_success_from_args([ "mkdir", "-p", as_string(path) ]);
}

function file_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function file_nonempty(path) {
    let stat = fs.stat(as_string(path));
    return stat != null && int(stat.size || 0) > 0;
}

function path_basename(path) {
    let parts = split(as_string(path), "/");
    return length(parts) > 0 ? as_string(parts[length(parts) - 1]) : "";
}

function parent_dir(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash >= 0 ? substr(path, 0, slash) : "";
}

function ensure_parent_dir(path) {
    let dir = parent_dir(path);
    return dir == "" || dir == "." || ensure_dir(dir);
}

function now_seconds() {
    return int(clock()[0]);
}

function owner_pid() {
    let pid = trim(command_output_from_args([ "sh", "-c", "echo $PPID" ]));
    return match(pid, /^[0-9]+$/) != null ? pid : "0";
}

function pid_running(pid) {
    pid = as_string(pid);
    return match(pid, /^[0-9]+$/) != null && command_success_from_args([ "kill", "-0", pid ]);
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "forkop", "[" + level + "] " + as_string(message) ]);
}

function updates_log(message, level) {
    log_message("Updates: " + as_string(message), level || "info");
}

function module_command(args) {
    let command_args = [ "ucode", "-L", LIB_DIR ];
    for (let arg in args)
        push(command_args, arg);
    return command_from_args(command_args);
}

function module_output(args) {
    return command_output(module_command(args));
}

function module_success(args) {
    return command_success(module_command(args));
}

function helper_output(mode, args) {
    let command_args = [ LIB_DIR + "/components/updater.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return module_output(command_args);
}

function helper_success(mode, args) {
    let command_args = [ LIB_DIR + "/components/updater.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return module_success(command_args);
}

function cleanup_stale_tmp_files() {
    command_success_from_args([ "find", "/tmp", "-maxdepth", "1", "-type", "d", "-name", "forkop-updates.*", "-mmin", "+" + as_string(TMP_STALE_TTL_MINUTES), "-exec", "rm", "-rf", "{}", "+" ]);
    command_success_from_args([ "find", "/tmp", "-maxdepth", "1", "-type", "f", "(", "-name", "forkop-updates-command.*", "-o", "-name", "forkop-updates-http.*", ")", "-mmin", "+" + as_string(TMP_FILE_STALE_TTL_MINUTES), "-delete" ]);
}

function init_tmp_dir() {
    if (tmp_dir != "")
        return true;

    cleanup_stale_tmp_files();
    tmp_dir = trim(command_output_from_args([ "mktemp", "-d", "/tmp/forkop-updates.XXXXXX" ]));
    if (tmp_dir == "") {
        tmp_dir = "/tmp/forkop-updates." + owner_pid();
        if (!ensure_dir(tmp_dir)) {
            tmp_dir = "";
            return false;
        }
    }
    return true;
}

function make_tmp_file(prefix) {
    init_tmp_dir();
    let base = tmp_dir != "" ? tmp_dir + "/" + as_string(prefix) + ".XXXXXX" : "/tmp/forkop-updates-" + as_string(prefix) + ".XXXXXX";
    let path = trim(command_output_from_args([ "mktemp", base ]));
    if (path == "") {
        path = (tmp_dir != "" ? tmp_dir : "/tmp") + "/" + as_string(prefix) + "." + owner_pid() + "." + now_seconds();
        if (!write_file(path, ""))
            return "";
    }
    return path;
}

function helper_output_input(input, mode, args) {
    let input_path = make_tmp_file("helper-input");
    if (input_path == "")
        return "";
    write_file(input_path, as_string(input));

    let command_args = [ LIB_DIR + "/components/updater.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    let output = command_output(command_from_args([ "cat", input_path ]) + " | " + module_command(command_args));
    remove_file(input_path);
    return output;
}

function helper_success_input(input, mode, args) {
    let input_path = make_tmp_file("helper-input");
    if (input_path == "")
        return false;
    write_file(input_path, as_string(input));

    let command_args = [ LIB_DIR + "/components/updater.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    let ok = command_success(command_from_args([ "cat", input_path ]) + " | " + module_command(command_args));
    remove_file(input_path);
    return ok;
}

function cleanup_tmp_dir() {
    if (tmp_dir != "") {
        command_success_from_args([ "rm", "-rf", tmp_dir ]);
        tmp_dir = "";
    }
    cleanup_stale_tmp_files();
}

function acquire_component_lock() {
    ensure_dir(RUNTIME_STATE_DIR);
    if (command_success_from_args([ "mkdir", COMPONENT_LOCK_DIR ])) {
        write_file(COMPONENT_LOCK_DIR + "/pid", owner_pid() + "\n");
        lock_held = true;
        return true;
    }

    let current_owner = trim(read_file(COMPONENT_LOCK_DIR + "/pid"));
    if (current_owner != "" && pid_running(current_owner))
        return false;

    remove_file(COMPONENT_LOCK_DIR + "/pid");
    command_success_from_args([ "rmdir", COMPONENT_LOCK_DIR ]);
    if (!command_success_from_args([ "mkdir", COMPONENT_LOCK_DIR ]))
        return false;

    write_file(COMPONENT_LOCK_DIR + "/pid", owner_pid() + "\n");
    lock_held = true;
    return true;
}

function release_component_lock() {
    if (!lock_held)
        return;
    remove_file(COMPONENT_LOCK_DIR + "/pid");
    command_success_from_args([ "rmdir", COMPONENT_LOCK_DIR ]);
    lock_held = false;
}

function cleanup_action() {
    cleanup_tmp_dir();
    release_component_lock();
}

function updates_response(success, component, action, message, current_version, latest_version, changed, status, release_url) {
    write_json({
        success: !!success,
        kind: "component",
        component: as_string(component),
        action: as_string(action),
        message: as_string(message),
        current_version: as_string(current_version),
        latest_version: as_string(latest_version),
        changed: int(changed || 0),
        status: as_string(status),
        release_url: as_string(release_url)
    });
}

function restart_forkop_after_failed_sing_box_change() {
    if (!forkop_stopped_for_sing_box_change || !forkop_was_running || !file_exists(SERVICE_INIT))
        return;
    updates_log("Restarting Forkop after failed sing-box component change");
    if (!command_success_from_args([ SERVICE_INIT, "start" ]))
        command_success_from_args([ SERVICE_INIT, "restart" ]);
}

function action_success(component, action, message, current_version, latest_version, changed, status, release_url) {
    updates_response(true, component, action, message, current_version, latest_version, changed || 0, status || "", release_url || "");
    cleanup_action();
    exit(0);
}

function action_fail(component, action, message, current_version, latest_version, status, release_url) {
    updates_log(message, "error");
    restart_forkop_after_failed_sing_box_change();
    updates_response(false, component, action, message, current_version || "", latest_version || "", 0, status || "", release_url || "");
    cleanup_action();
    exit(1);
}

function run_logged(description, command) {
    init_tmp_dir();
    let output_file = make_tmp_file("command");
    if (output_file == "")
        output_file = "/tmp/forkop-updates-command." + owner_pid();

    updates_log(description);
    let status = command_status(as_string(command) + " >" + shell_quote(output_file) + " 2>&1");
    for (let line in split(read_file(output_file), "\n"))
        if (trim(as_string(line)) != "")
            updates_log(line);
    remove_file(output_file);
    if (status != 0)
        updates_log(description + " failed with exit code " + status, "warn");
    return status == 0;
}

function is_apk() {
    return command_exists("apk");
}

function pkg_is_installed(package_name) {
    package_name = as_string(package_name);
    if (is_apk())
        return command_success_from_args([ "apk", "info", "-e", package_name ]);
    return module_success([ LIB_DIR + "/core/packages.uc", "opkg-installed", package_name ]);
}

function installed_package_version(package_name) {
    package_name = as_string(package_name);
    if (is_apk()) {
        if (!pkg_is_installed(package_name))
            return "";
        return trim(module_output([ LIB_DIR + "/core/packages.uc", "apk-version", package_name ]));
    }
    return trim(module_output([ LIB_DIR + "/core/packages.uc", "opkg-version", package_name ]));
}

function opkg_package_version_from_list(package_name, output) {
    return trim(helper_output_input(output, "updates-opkg-package-version", [ package_name ]));
}

function available_package_version(package_name) {
    package_name = as_string(package_name);
    if (is_apk())
        return trim(helper_output_input(command_output_from_args([ "apk", "policy", package_name ]), "updates-apk-policy-version", []));
    return opkg_package_version_from_list(package_name, command_output_from_args([ "opkg", "list", package_name ]));
}

function pkg_list_update_command() {
    return is_apk() ? "apk update </dev/null" : "opkg update </dev/null";
}

function pkg_install_name_command(package_name) {
    return is_apk() ? command_from_args([ "apk", "add", package_name ]) + " </dev/null" :
        command_from_args([ "opkg", "install", package_name ]) + " </dev/null";
}

function pkg_install_name_downgrade(package_name) {
    package_name = as_string(package_name);
    if (is_apk()) {
        if (pkg_is_installed(package_name))
            return command_success(command_from_args([ "apk", "fix", "--reinstall", "--upgrade", package_name ]) + " </dev/null");
        return command_success(command_from_args([ "apk", "add", package_name ]) + " </dev/null");
    }

    return command_success(command_from_args([ "opkg", "install", "--force-overwrite", "--force-reinstall", "--force-downgrade", package_name ]) + " </dev/null") ||
        command_success(command_from_args([ "opkg", "install", "--force-downgrade", package_name ]) + " </dev/null");
}

function pkg_install_files_command(files) {
    let args = is_apk() ? [ "apk", "add", "--allow-untrusted" ] : [ "opkg", "install", "--force-overwrite", "--force-downgrade" ];
    for (let file in files)
        push(args, file);
    return command_from_args(args) + " </dev/null";
}

function pkg_install_files(files) {
    return command_success(pkg_install_files_command(files));
}

function pkg_remove_name(package_name) {
    package_name = as_string(package_name);
    if (!pkg_is_installed(package_name))
        return true;
    if (is_apk())
        return command_success(command_from_args([ "apk", "del", package_name ]) + " </dev/null");
    return command_success(command_from_args([ "opkg", "remove", "--force-depends", package_name ]) + " </dev/null");
}

function pkg_remove_sing_box_conflict(package_name) {
    package_name = as_string(package_name);
    if (!pkg_is_installed(package_name))
        return true;
    if (is_apk())
        return command_success(command_from_args([ "apk", "del", "--force-broken-world", package_name ]) + " </dev/null");
    return command_success(command_from_args([ "opkg", "remove", "--force-depends", package_name ]) + " </dev/null");
}

function run_logged_pkg_remove_sing_box_conflict(package_name, description) {
    if (!pkg_is_installed(package_name)) {
        updates_log(description);
        return true;
    }

    let command = is_apk() ?
        command_from_args([ "apk", "del", "--force-broken-world", package_name ]) + " </dev/null" :
        command_from_args([ "opkg", "remove", "--force-depends", package_name ]) + " </dev/null";
    return run_logged(description, command);
}

function compare_versions(lhs, rhs) {
    lhs = as_string(lhs);
    rhs = as_string(rhs);
    if (lhs == "" || rhs == "")
        return null;
    if (lhs == rhs)
        return 0;

    if (is_apk()) {
        let apk_result = trim(command_output_from_args([ "apk", "version", "-t", lhs, rhs ]));
        if (apk_result == ">")
            return 1;
        if (apk_result == "<")
            return -1;
        if (apk_result == "=")
            return 0;
    }

    if (command_exists("opkg")) {
        if (command_success_from_args([ "opkg", "compare-versions", lhs, ">", rhs ]))
            return 1;
        if (command_success_from_args([ "opkg", "compare-versions", lhs, "<", rhs ]))
            return -1;
        if (command_success_from_args([ "opkg", "compare-versions", lhs, "=", rhs ]))
            return 0;
    }

    return module_success([ LIB_DIR + "/core/helpers.uc", "version-at-least", lhs, rhs ]) ? 1 : -1;
}

function status_from_compare(compare_result) {
    if (compare_result == -1)
        return "outdated";
    if (compare_result == 0)
        return "latest";
    if (compare_result == 1)
        return "dev";
    return "";
}

function check_success_compared(component, current_version, latest_version, compare_current_version, compare_latest_version, release_url) {
    let compare_result = compare_versions(compare_current_version, compare_latest_version);
    if (compare_result == null)
        action_fail(component, "check_update", "Failed to compare versions", current_version, latest_version);

    let status = status_from_compare(compare_result);
    if (status == "")
        action_fail(component, "check_update", "Failed to compare versions", current_version, latest_version);

    let result_row = trim(helper_output("updates-check-result-row", [ component, current_version, latest_version, status ]));
    if (result_row == "")
        action_fail(component, "check_update", "Failed to compare versions", current_version, latest_version);

    let fields = split(result_row, "\t");
    let message = as_string(fields[0] || "");
    let log_line = length(fields) > 1 ? as_string(fields[1]) : message;
    updates_log(log_line);
    action_success(component, "check_update", message, current_version, latest_version, 0, status, release_url || "");
}

function check_success(component, current_version, latest_version, release_url) {
    check_success_compared(component, current_version, latest_version, current_version, latest_version, release_url || "");
}

function read_openwrt_release_value(key) {
    return trim(helper_output("openwrt-release-value", [ "/etc/openwrt_release", key ]));
}

function service_proxy_address() {
    if (!file_exists(LIB_DIR + "/singbox/runtime.uc"))
        return "";
    if (file_exists(LIB_DIR + "/service/state.uc") &&
        !module_success([ LIB_DIR + "/service/state.uc", "sing-box-service-running" ]))
        return "";
    return trim(module_output([ LIB_DIR + "/singbox/runtime.uc", "service-proxy-address", "components" ]));
}

function http_get_once(url, output_path, proxy_address, timeout) {
    url = as_string(url);
    output_path = as_string(output_path);
    proxy_address = as_string(proxy_address);
    timeout = as_string(timeout || "30");

    if (command_exists("curl")) {
        let args = [ "curl", "--connect-timeout", "5", "-m", timeout, "-fsSL" ];
        if (proxy_address != "") {
            push(args, "-x");
            push(args, "http://" + proxy_address);
        }
        push(args, url);
        push(args, "-o");
        push(args, output_path);
        return command_success_from_args(args);
    }

    if (command_exists("wget")) {
        let command = command_from_args([ "wget", "-T", timeout, "-q", "-O", output_path, url ]);
        if (proxy_address != "")
            command = command_env({ http_proxy: "http://" + proxy_address, https_proxy: "http://" + proxy_address }) + " " + command;
        return command_success(command);
    }

    return false;
}

function http_get(url) {
    init_tmp_dir();
    let output_path = make_tmp_file("http");
    if (output_path == "")
        return "";

    let proxy_address = service_proxy_address();
    if (proxy_address != "") {
        if (http_get_once(url, output_path, proxy_address, "30")) {
            let data = read_file(output_path);
            remove_file(output_path);
            return data;
        }
        remove_file(output_path);
        updates_log("HTTP request via service proxy failed for " + as_string(url) + "; retrying directly", "warn");
    }

    if (http_get_once(url, output_path, "", "30")) {
        let data = read_file(output_path);
        remove_file(output_path);
        return data;
    }

    remove_file(output_path);
    return "";
}

function download_file_once(url, output_path) {
    let proxy_address = service_proxy_address();
    if (proxy_address != "") {
        if (http_get_once(url, output_path, proxy_address, "120"))
            return true;
        remove_file(output_path);
        updates_log("Download via service proxy failed for " + as_string(url) + "; retrying directly", "warn");
    }
    return http_get_once(url, output_path, "", "120");
}

function download_with_retry(url, output_path, label) {
    for (let attempt = 1; attempt <= 3; attempt++) {
        updates_log("Downloading " + as_string(label) + " (" + attempt + "/3)");
        if (download_file_once(url, output_path) && file_nonempty(output_path))
            return true;
        remove_file(output_path);
        updates_log("Retrying " + as_string(label), "warn");
    }
    return false;
}

function fetch_github_release_json(owner, repo) {
    let response = http_get("https://api.github.com/repos/" + as_string(owner) + "/" + as_string(repo) + "/releases/latest");
    if (response == "" || !helper_success_input(response, "github-response-ok", []))
        return "";
    return response;
}

function fetch_github_releases_json(owner, repo, per_page) {
    let response = http_get("https://api.github.com/repos/" + as_string(owner) + "/" + as_string(repo) + "/releases?per_page=" + as_string(per_page || "30"));
    if (response == "" || !helper_success_input(response, "github-response-ok", []))
        return "";
    return response;
}

function latest_forkop_release_json() {
    let parts = split(FORKOP_RELEASE_REPO, "/");
    if (length(parts) != 2 || as_string(parts[0]) == "" || as_string(parts[1]) == "")
        return "";
    return fetch_github_release_json(parts[0], parts[1]);
}

function latest_forkop_version() {
    let response = latest_forkop_release_json();
    if (response == "")
        return "";
    return trim(helper_output_input(response, "object-get-default", [ "tag_name", "" ]));
}

function fetch_forkop_latest_release_metadata() {
    let response = latest_forkop_release_json();
    if (response == "")
        return "";
    return trim(helper_output_input(response, "release-metadata-tsv", []));
}

function write_forkop_latest_version_cache(value, timestamp) {
    if (as_string(value) == "")
        return;
    write_file("/tmp/forkop.latest-version.cache", as_string(value) + "\n" + as_string(timestamp) + "\n");
}

function retry_resolve(description, fn) {
    for (let attempt = 1; attempt <= 3; attempt++) {
        if (fn())
            return true;
        updates_log(as_string(description) + " failed (" + attempt + "/3)", "warn");
        command_success_from_args([ "sleep", "2" ]);
    }
    return false;
}

function ensure_package_tool(tool_name, package_name, component, action) {
    if (command_exists(tool_name))
        return true;
    if (!run_logged("Updating package lists before installing " + as_string(package_name), pkg_list_update_command()))
        return false;
    return run_logged("Installing bootstrap package " + as_string(package_name), pkg_install_name_command(package_name));
}

function clear_version_caches() {
    remove_file("/tmp/forkop.latest-version.cache");
    remove_file(SYSTEM_INFO_CACHE_FILE);
    remove_file("/tmp/forkop/system-info.json");
}

function managed_sing_box_service_installed() {
    return file_exists("/etc/init.d/sing-box") && index(read_file("/etc/init.d/sing-box"), SB_MANAGED_SERVICE_MARKER) >= 0;
}

function managed_sing_box_service_text() {
    return "#!/bin/sh /etc/rc.common\n" +
        "# " + SB_MANAGED_SERVICE_MARKER + "\n\n" +
        "USE_PROCD=1\n" +
        "START=99\n" +
        "PROG=\"/usr/bin/sing-box\"\n\n" +
        "start_service() {\n" +
        "    config_load \"sing-box\"\n" +
        "    local enabled config_file working_directory\n" +
        "    local log_stderr\n\n" +
        "    config_get_bool enabled \"main\" \"enabled\" \"0\"\n" +
        "    [ \"$enabled\" -eq \"1\" ] || return 0\n\n" +
        "    config_get config_file \"main\" \"conffile\" \"/etc/sing-box/config.json\"\n" +
        "    config_get working_directory \"main\" \"workdir\" \"/usr/share/sing-box\"\n" +
        "    config_get_bool log_stderr \"main\" \"log_stderr\" \"1\"\n\n" +
        "    procd_open_instance\n" +
        "    procd_set_param command \"$PROG\" run -c \"$config_file\" -D \"$working_directory\"\n" +
        "    procd_set_param file \"$config_file\"\n" +
        "    procd_set_param stderr \"$log_stderr\"\n" +
        "    procd_set_param limits core=\"unlimited\"\n" +
        "    procd_set_param limits nofile=\"1000000 1000000\"\n" +
        "    procd_set_param respawn\n" +
        "    procd_close_instance\n" +
        "}\n\n" +
        "service_triggers() {\n" +
        "    procd_add_reload_trigger \"sing-box\"\n" +
        "}\n";
}

function install_managed_sing_box_service_script() {
    let tmp = "/etc/init.d/sing-box.forkop." + owner_pid();
    if (!write_file(tmp, managed_sing_box_service_text()))
        return false;
    if (!command_success_from_args([ "chmod", "0755", tmp ])) {
        remove_file(tmp);
        return false;
    }
    return fs.rename(tmp, "/etc/init.d/sing-box");
}

function remove_managed_sing_box_service_script() {
    if (!managed_sing_box_service_installed())
        return true;
    command_success_from_args([ "/etc/init.d/sing-box", "stop" ]);
    command_success_from_args([ "/etc/init.d/sing-box", "disable" ]);
    remove_file("/etc/init.d/sing-box");
    return true;
}

function disable_sing_box_service_config() {
    if (!uci_core.available())
        return true;
    if (!uci_core.exists("sing-box.main") && !uci_core.set_section("sing-box.main", "sing-box"))
        return false;
    if (!uci_core.set("sing-box.main.enabled", "0"))
        return false;
    return uci_core.commit("sing-box");
}

function prepare_sing_box_service_disabled() {
    disable_sing_box_service_config();
    if (file_exists("/etc/init.d/sing-box")) {
        command_success_from_args([ "/etc/init.d/sing-box", "stop" ]);
        command_success_from_args([ "/etc/init.d/sing-box", "disable" ]);
    }
}

function prepare_sing_box_package_service_install() {
    prepare_sing_box_service_disabled();
    remove_managed_sing_box_service_script();
}

function forkop_status_running_with_timeout() {
    init_tmp_dir();
    let output_file = make_tmp_file("forkop-status");
    if (output_file == "")
        return false;

    let command = command_from_args([ BIN_PATH, "get_status" ]) + " >" + shell_quote(output_file) + " 2>/dev/null & pid=$!; " +
        "( sleep 6; kill $pid 2>/dev/null || true ) & watcher=$!; " +
        "wait $pid 2>/dev/null; rc=$?; kill $watcher 2>/dev/null || true; wait $watcher 2>/dev/null || true; exit $rc";
    let ok = command_status("sh -c " + shell_quote(command)) == 0 &&
        match(read_file(output_file), /"running"[ \t]*:[ \t]*1/) != null;
    remove_file(output_file);
    return ok;
}

function capture_forkop_running_state() {
    forkop_was_running = file_exists(BIN_PATH) && forkop_status_running_with_timeout();
}

function restart_forkop_after_successful_change() {
    if (!file_exists(SERVICE_INIT))
        return;
    if (!forkop_was_running) {
        updates_log("Forkop was not running before component change; restart skipped");
        prepare_sing_box_service_disabled();
        return;
    }
    run_logged("Restarting Forkop after successful component change", command_from_args([ SERVICE_INIT, "restart" ]));
}

function stop_forkop_before_sing_box_change() {
    if (forkop_stopped_for_sing_box_change)
        return;
    forkop_stopped_for_sing_box_change = true;

    if (forkop_was_running && file_exists(SERVICE_INIT))
        run_logged("Stopping Forkop before sing-box package change", command_from_args([ SERVICE_INIT, "stop" ]));

    if (forkop_was_running && file_exists(BIN_PATH))
        command_success_from_args([ BIN_PATH, "restore_dnsmasq" ]);

    prepare_sing_box_service_disabled();
}

function wait_forkop_running_after_sing_box_change() {
    if (!forkop_was_running)
        return true;
    if (!file_exists(BIN_PATH))
        return false;

    let waited = 0;
    while (waited < 60) {
        if (forkop_status_running_with_timeout()) {
            command_success_from_args([ "sleep", "8" ]);
            if (forkop_status_running_with_timeout())
                return true;
        }
        command_success_from_args([ "sleep", "4" ]);
        waited += 4;
    }
    return false;
}

function opkg_arch_list() {
    return trim(helper_output_input(command_output_from_args([ "opkg", "print-architecture" ]), "updates-opkg-arch-list", []));
}

function resolve_arch_candidates() {
    let arch_list = "";
    if (is_apk()) {
        if (file_exists("/etc/apk/arch"))
            arch_list += " " + trim(helper_output("file-whitespace-list", [ "/etc/apk/arch" ]));
        arch_list += " " + trim(command_output_from_args([ "apk", "--print-arch" ]));
    }
    else {
        arch_list = opkg_arch_list();
    }

    let release_arch = read_openwrt_release_value("DISTRIB_ARCH");
    if (release_arch != "")
        arch_list += " " + release_arch;
    if (!helper_success("string-has-whitespace-field", [ arch_list ]))
        arch_list = trim(command_output_from_args([ "uname", "-m" ]));

    let resolved = trim(helper_output("updates-arch-candidates", [ arch_list ]));
    let fields = split(resolved, "\t");
    if (length(fields) < 2 || as_string(fields[0]) == "" || as_string(fields[1]) == "")
        return null;

    updates_log("Detected package architecture candidates: " + fields[1]);
    return {
        target: as_string(fields[0]),
        candidates: as_string(fields[1])
    };
}

function select_inner_package_path(bundle_file, component, arch, ext) {
    return trim(helper_output_input(command_output_from_args([ "unzip", "-l", bundle_file ]), "updates-zip-inner-package-path", [ component, arch, ext ]));
}

function select_archive_member_path(archive_file, member_name) {
    return trim(helper_output_input(command_output_from_args([ "tar", "-tzf", archive_file ]), "updates-archive-member-path", [ member_name ]));
}

function extract_arch_package_version(package_name, package_arch) {
    return trim(helper_output("updates-arch-package-version", [ package_name, package_arch ]));
}

function extract_zapret_bundle_version(bundle_name) {
    return trim(helper_output("updates-zapret-bundle-version", [ bundle_name ]));
}

function extract_zapret2_bundle_version(bundle_name) {
    return trim(helper_output("updates-zapret2-bundle-version", [ bundle_name ]));
}

function normalize_zapret_version(value) {
    return trim(helper_output("updates-normalize-zapret-version", [ value ]));
}

function normalize_sing_box_version(value) {
    return trim(helper_output("updates-normalize-sing-box-version", [ value ]));
}

function resolve_zapret_release(arch) {
    let release_json = fetch_github_release_json("remittor", "zapret-openwrt");
    if (release_json == "")
        return null;
    let resolved = trim(helper_output_input(release_json, "release-select-arch-suffix-asset", [ "zip", arch.candidates ]));
    let fields = split(resolved, "\t");
    if (length(fields) < 4)
        return null;
    let version = extract_zapret_bundle_version(fields[1]);
    if (version == "")
        version = trim(helper_output("string-remove-suffix", [ fields[1], ".zip" ]));
    return {
        arch: fields[0],
        bundle_name: fields[1],
        bundle_url: fields[2],
        release_url: fields[3],
        version
    };
}

function resolve_zapret2_release(arch) {
    let releases_json = fetch_github_releases_json("remittor", "zapret-openwrt", "30");
    if (releases_json == "")
        return null;
    let resolved = trim(helper_output_input(releases_json, "named-release-select-asset", [ "zapret2 ", "zapret2", "zip", arch.candidates ]));
    let fields = split(resolved, "\t");
    if (length(fields) < 4)
        return null;
    let version = extract_zapret2_bundle_version(fields[1]);
    if (version == "")
        version = trim(helper_output("string-remove-suffix", [ fields[1], ".zip" ]));
    return {
        arch: fields[0],
        bundle_name: fields[1],
        bundle_url: fields[2],
        release_url: fields[3],
        version
    };
}

function download_and_extract_zip_package(release, component) {
    let bundle_file = tmp_dir + "/" + release.bundle_name;
    if (!download_with_retry(release.bundle_url, bundle_file, release.bundle_name))
        return null;

    let inner_package_path = is_apk() ?
        select_inner_package_path(bundle_file, component, "", "apk") :
        select_inner_package_path(bundle_file, component, release.arch, "ipk");
    if (inner_package_path == "")
        return null;

    let package_name = path_basename(inner_package_path);
    let package_file = tmp_dir + "/" + package_name;
    if (!command_success(command_from_args([ "unzip", "-p", bundle_file, inner_package_path ]) + " >" + shell_quote(package_file)) ||
        !file_nonempty(package_file))
        return null;

    let version = as_string(release.version || "");
    if (version == "")
        version = component == "zapret2" ? extract_zapret2_bundle_version(release.bundle_name) : extract_zapret_bundle_version(release.bundle_name);
    if (version == "")
        version = extract_arch_package_version(package_name, release.arch);

    return {
        name: package_name,
        file: package_file,
        version
    };
}

function resolve_byedpi_release(arch) {
    let asset_ext = is_apk() ? "apk" : "ipk";
    let release_series = trim(helper_output("openwrt-release-series", [ "/etc/openwrt_release" ]));
    let releases_json = fetch_github_releases_json("DPITrickster", "ByeDPI-OpenWrt", "30");
    if (releases_json == "")
        return null;
    let resolved = trim(helper_output_input(releases_json, "byedpi-select-asset", [ release_series, asset_ext, arch.candidates ]));
    let fields = split(resolved, "\t");
    if (length(fields) < 4)
        return null;
    return {
        arch: fields[0],
        package_name: fields[1],
        package_url: fields[2],
        release_url: fields[3],
        version: extract_arch_package_version(fields[1], fields[0])
    };
}

function download_byedpi_package(release) {
    let package_file = tmp_dir + "/" + release.package_name;
    if (!download_with_retry(release.package_url, package_file, release.package_name) || !file_nonempty(package_file))
        return null;
    let version = as_string(release.version || "");
    if (version == "")
        version = extract_arch_package_version(release.package_name, release.arch);
    return {
        name: release.package_name,
        file: package_file,
        version
    };
}

function disable_standalone_service(name) {
    let init = "/etc/init.d/" + as_string(name);
    if (!file_exists(init))
        return;
    run_logged("Stopping standalone " + as_string(name) + " service", command_from_args([ init, "stop" ]));
    run_logged("Disabling standalone " + as_string(name) + " autostart", command_from_args([ init, "disable" ]));
}

function provider_installed(runtime_module) {
    return module_success([ runtime_module, "installed" ]);
}

function provider_package_version(runtime_module) {
    return trim(module_output([ runtime_module, "package-version" ]));
}

function install_zapret_like(component, action, runtime_module, resolve_fn, label) {
    init_tmp_dir() || action_fail(component, action, "Failed to create temporary directory");
    let arch = resolve_arch_candidates();
    if (arch == null)
        action_fail(component, action, "Failed to detect package architecture");
    let release = null;
    retry_resolve("Resolving " + label + " package", function() {
        release = resolve_fn(arch);
        return release != null;
    });
    if (release == null)
        action_fail(component, action, "Failed to resolve " + label + " package for this router architecture");

    let installed = provider_installed(runtime_module);
    let current_version = provider_package_version(runtime_module);
    if (action == "check_update") {
        if (!installed)
            action_fail(component, action, label + " is not installed", current_version, release.version, "", release.release_url || "");
        check_success_compared(component, current_version, release.version, normalize_zapret_version(current_version), normalize_zapret_version(release.version), release.release_url || "");
    }

    if (!ensure_package_tool("unzip", "unzip", component, action))
        action_fail(component, action, "Failed to install unzip");
    let pkg = download_and_extract_zip_package(release, component);
    if (pkg == null)
        action_fail(component, action, "Failed to download " + label + " package", current_version, release.version, "", release.release_url || "");

    if (!run_logged("Installing " + label + " package " + pkg.name, pkg_install_files_command([ pkg.file ])))
        action_fail(component, action, "Failed to install " + label + " package", current_version, pkg.version, "", release.release_url || "");

    disable_standalone_service(component);
    restart_forkop_after_successful_change();
    clear_version_caches();
    current_version = provider_package_version(runtime_module);
    if (current_version == "")
        current_version = "unknown";
    action_success(component, action, label + " package has been installed", current_version, pkg.version, 1, "latest", release.release_url || "");
}

function install_zapret(action) {
    install_zapret_like("zapret", action, LIB_DIR + "/providers/zapret/runtime.uc", resolve_zapret_release, "zapret");
}

function install_zapret2(action) {
    install_zapret_like("zapret2", action, LIB_DIR + "/providers/zapret2/runtime.uc", resolve_zapret2_release, "zapret2");
}

function install_byedpi(action) {
    init_tmp_dir() || action_fail("byedpi", action, "Failed to create temporary directory");
    let arch = resolve_arch_candidates();
    if (arch == null)
        action_fail("byedpi", action, "Failed to detect package architecture");
    let release = null;
    retry_resolve("Resolving ByeDPI package", function() {
        release = resolve_byedpi_release(arch);
        return release != null;
    });
    if (release == null)
        action_fail("byedpi", action, "Failed to resolve ByeDPI package for this router architecture");

    let runtime_module = LIB_DIR + "/providers/byedpi/runtime.uc";
    let installed = provider_installed(runtime_module);
    let current_version = provider_package_version(runtime_module);
    if (action == "check_update") {
        if (!installed)
            action_fail("byedpi", action, "ByeDPI is not installed", current_version, release.version);
        check_success("byedpi", current_version, release.version, release.release_url || "");
    }

    let pkg = download_byedpi_package(release);
    if (pkg == null)
        action_fail("byedpi", action, "Failed to download ByeDPI package");
    if (!run_logged("Installing ByeDPI package " + pkg.name, pkg_install_files_command([ pkg.file ])))
        action_fail("byedpi", action, "Failed to install ByeDPI package", current_version, pkg.version);

    disable_standalone_service("byedpi");
    restart_forkop_after_successful_change();
    clear_version_caches();
    current_version = provider_package_version(runtime_module);
    if (current_version == "")
        current_version = "unknown";
    action_success("byedpi", action, "ByeDPI package has been installed", current_version, pkg.version, 1, "latest", release.release_url || "");
}

function remove_optional_component(component, package_name, label, runtime_module) {
    if (!pkg_is_installed(package_name)) {
        if (provider_installed(runtime_module))
            action_fail(component, "remove", label + " exists outside the package manager and was not removed automatically");
        action_success(component, "remove", label + " is already removed", "", "", 0);
    }

    let current_version = provider_package_version(runtime_module);
    let command = is_apk() ?
        command_from_args([ "apk", "del", package_name ]) + " </dev/null" :
        command_from_args([ "opkg", "remove", "--force-depends", package_name ]) + " </dev/null";
    if (!run_logged("Removing " + label + " package", command))
        action_fail(component, "remove", "Failed to remove " + label + " package", current_version);

    clear_version_caches();
    if (provider_installed(runtime_module))
        action_fail(component, "remove", label + " package was removed, but provider files are still present", current_version);
    restart_forkop_after_successful_change();
    action_success(component, "remove", label + " package has been removed", current_version, "", 1);
}

function read_sing_box_binary_version(binary, library_dir) {
    binary = as_string(binary);
    if (binary == "" || !file_exists(binary))
        return "";

    let command = command_from_args([ binary, "version" ]);
    if (as_string(library_dir || "") != "")
        command = command_env({ LD_LIBRARY_PATH: as_string(library_dir) }) + " " + command;

    return trim(helper_output_input(command_output(command), "stdin-first-line-last-field", []));
}

function validate_sing_box_extended_binary(binary, library_dir) {
    let version = read_sing_box_binary_version(binary, library_dir || "");
    return index(version, "extended") >= 0 ? version : "";
}

function move_file_to_backup(target_path, backup_path) {
    if (!file_exists(target_path))
        return true;
    remove_file(backup_path);
    return fs.rename(target_path, backup_path);
}

function restore_sing_box_backup(backup_binary) {
    if (as_string(backup_binary) != "" && file_nonempty(backup_binary)) {
        if (!fs.rename(backup_binary, "/usr/bin/sing-box"))
            return false;
        return command_success_from_args([ "chmod", "0755", "/usr/bin/sing-box" ]);
    }
    remove_file("/usr/bin/sing-box");
    return true;
}

function restore_file_backup(target_path, backup_path) {
    if (as_string(backup_path) != "" && file_nonempty(backup_path))
        return fs.rename(backup_path, target_path);
    remove_file(target_path);
    return true;
}

function restore_sing_box_service_from_marker(marker) {
    if (as_string(marker) == "extended-compressed")
        return install_managed_sing_box_service_script();
    remove_managed_sing_box_service_script();
    return true;
}

function resolve_sing_box_extended_arch_suffix() {
    let host_arch = trim(command_output_from_args([ "uname", "-m" ]));
    let distrib_arch = read_openwrt_release_value("DISTRIB_ARCH");
    return trim(helper_output("sing-box-extended-arch-suffix", [ host_arch, distrib_arch ]));
}

function sing_box_extended_tag_is_stable(tag) {
    tag = lc(as_string(tag));
    return tag != "" && index(tag, "alpha") < 0 && index(tag, "beta") < 0 && index(tag, "rc") < 0;
}

function set_sing_box_extended_release_from_json(release_json, compressed) {
    if (as_string(release_json) == "")
        return null;
    let tag = trim(helper_output_input(release_json, "object-get-default", [ "tag_name", "" ]));
    if (!sing_box_extended_tag_is_stable(tag))
        return null;

    let asset_url = "";
    if (compressed) {
        let arch_suffix = resolve_sing_box_extended_arch_suffix();
        if (arch_suffix == "")
            return null;
        asset_url = trim(helper_output_input(release_json, "sing-box-extended-asset-url", [ arch_suffix, "0", "1" ]));
    }
    else {
        let distrib_arch = read_openwrt_release_value("DISTRIB_ARCH");
        if (distrib_arch == "")
            return null;
        let asset_ext = is_apk() ? "apk" : "ipk";
        asset_url = trim(helper_output_input(release_json, "sing-box-extended-package-asset-url", [ distrib_arch, asset_ext ]));
    }

    if (asset_url == "")
        return null;

    return {
        tag,
        release_url: trim(helper_output_input(release_json, "object-get-default", [ "html_url", "" ])),
        asset_url,
        asset_name: path_basename(asset_url)
    };
}

function resolve_sing_box_extended_release(compressed) {
    let release_json = fetch_github_release_json("shtorm-7", "sing-box-extended");
    let resolved = set_sing_box_extended_release_from_json(release_json, compressed);
    if (resolved != null)
        return resolved;

    let releases_json = fetch_github_releases_json("shtorm-7", "sing-box-extended", "30");
    if (releases_json == "")
        return null;
    let tag = trim(helper_output_input(releases_json, "sing-box-extended-release-tag", []));
    if (tag == "")
        return null;
    release_json = helper_output_input(releases_json, "release-by-tag", [ tag ]);
    return set_sing_box_extended_release_from_json(release_json, compressed);
}

function sing_box_runtime_output(mode, args) {
    let command_args = [ LIB_DIR + "/singbox/runtime.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return trim(module_output(command_args));
}

function sing_box_runtime_success(mode, args) {
    let command_args = [ LIB_DIR + "/singbox/runtime.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return module_success(command_args);
}

function write_sing_box_variant_state(marker, version) {
    if (!sing_box_runtime_success("write-variant-marker", [ marker ]))
        updates_log("Failed to write sing-box variant marker", "warn");
    if (!sing_box_runtime_success("write-version-state", [ version ]))
        updates_log("Failed to write sing-box version state", "warn");
}

function restore_sing_box_variant_state(previous_marker, previous_version_state) {
    sing_box_runtime_success("restore-variant-marker", [ previous_marker ]);
    sing_box_runtime_success("restore-version-state", [ previous_version_state ]);
}

function restore_sing_box_extended_package_variant() {
    init_tmp_dir();
    let release = resolve_sing_box_extended_release(false);
    if (release == null)
        return false;
    let package_file = tmp_dir + "/" + release.asset_name;
    if (!download_with_retry(release.asset_url, package_file, release.asset_name))
        return false;
    prepare_sing_box_package_service_install();
    pkg_remove_sing_box_conflict("sing-box-tiny");
    pkg_remove_sing_box_conflict("sing-box");
    if (!pkg_install_files([ package_file ])) {
        remove_file(package_file);
        return false;
    }
    remove_file(package_file);
    let new_version = validate_sing_box_extended_binary("/usr/bin/sing-box", "/usr/lib");
    if (new_version == "")
        return false;
    write_sing_box_variant_state("extended", new_version);
    return true;
}

function replace_sing_box_package_variant(target_package, conflict_package) {
    prepare_sing_box_package_service_install();
    if ((as_string(conflict_package) == "" || !pkg_is_installed(conflict_package)) &&
        (target_package == "sing-box-extended" || !pkg_is_installed("sing-box-extended")))
        return pkg_install_name_downgrade(target_package);

    if (target_package != "sing-box-extended" && !pkg_remove_sing_box_conflict("sing-box-extended"))
        return false;
    if (as_string(conflict_package) != "" && !pkg_remove_sing_box_conflict(conflict_package))
        return false;
    return pkg_install_name_downgrade(target_package);
}

function restore_sing_box_package_variant(previous_variant) {
    if (previous_variant == "tiny")
        return replace_sing_box_package_variant("sing-box-tiny", "sing-box");
    if (previous_variant == "stable")
        return replace_sing_box_package_variant("sing-box", "sing-box-tiny");
    if (previous_variant == "extended")
        return restore_sing_box_extended_package_variant();
    if (previous_variant == "not-installed") {
        pkg_remove_sing_box_conflict("sing-box-extended");
        pkg_remove_sing_box_conflict("sing-box-tiny");
        pkg_remove_sing_box_conflict("sing-box");
        remove_managed_sing_box_service_script();
        remove_file("/usr/bin/sing-box");
        return true;
    }
    return false;
}

function sing_box_variant_is_package_managed(variant) {
    return variant == "stable" || variant == "tiny" || variant == "extended";
}

function restore_sing_box_install_backup(previous_variant, backup_binary) {
    if (sing_box_variant_is_package_managed(previous_variant)) {
        if (restore_sing_box_package_variant(previous_variant))
            return true;
        if (as_string(backup_binary) != "")
            restore_sing_box_backup(backup_binary);
        return false;
    }

    if (as_string(backup_binary) != "")
        return restore_sing_box_backup(backup_binary);
    return restore_sing_box_package_variant(previous_variant);
}

function restore_sing_box_after_failed_extended_install(previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched) {
    if (as_string(archive_file) != "")
        remove_file(archive_file);
    let restore_status = true;
    if (cronet_touched)
        restore_file_backup("/usr/lib/libcronet.so", backup_cronet);
    if (!restore_sing_box_install_backup(previous_variant, backup_binary))
        restore_status = false;
    restore_sing_box_variant_state(previous_marker, previous_version_state);
    restore_sing_box_service_from_marker(previous_marker);
    clear_version_caches();
    return restore_status;
}

function restore_sing_box_after_failed_extended_package_install(previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched) {
    if (as_string(package_file) != "")
        remove_file(package_file);
    pkg_remove_sing_box_conflict("sing-box-extended");
    let restore_status = restore_sing_box_install_backup(previous_variant, backup_binary);
    if (cronet_touched) {
        restore_file_backup("/usr/lib/libcronet.so", backup_cronet);
        if (file_nonempty("/usr/lib/libcronet.so"))
            command_success_from_args([ "chmod", "0644", "/usr/lib/libcronet.so" ]);
    }
    restore_sing_box_variant_state(previous_marker, previous_version_state);
    restore_sing_box_service_from_marker(previous_marker);
    clear_version_caches();
    return restore_status;
}

function restore_sing_box_after_failed_package_install(target_package, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched) {
    pkg_remove_sing_box_conflict(target_package);
    let restore_status = restore_sing_box_install_backup(previous_variant, backup_binary);
    if (cronet_touched) {
        if (!restore_file_backup("/usr/lib/libcronet.so", backup_cronet))
            restore_status = false;
        if (file_nonempty("/usr/lib/libcronet.so") && !command_success_from_args([ "chmod", "0644", "/usr/lib/libcronet.so" ]))
            restore_status = false;
    }
    restore_sing_box_variant_state(previous_marker, previous_version_state);
    if (!restore_sing_box_service_from_marker(previous_marker))
        restore_status = false;
    if (restore_status) {
        remove_file(backup_binary);
        remove_file(backup_cronet);
    }
    clear_version_caches();
    return restore_status;
}

function fail_package_sing_box_install(action, tiny, reason, current_version, latest_version,
    target_package, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched) {
    let restored = restore_sing_box_after_failed_package_install(
        target_package,
        previous_variant,
        backup_binary,
        backup_cronet,
        previous_marker,
        previous_version_state,
        cronet_touched
    );

    let prefix = tiny ? "sing-box-tiny" : "Stable sing-box";
    if (restored)
        action_fail("sing_box", action, prefix + " " + reason + "; previous sing-box variant was restored", current_version, latest_version);
    action_fail("sing_box", action, prefix + " " + reason + " and previous sing-box variant could not be restored", current_version, latest_version);
}

function install_sing_box_extended_package(action) {
    init_tmp_dir() || action_fail("sing_box", action, "Failed to create temporary directory");
    let current_version = sing_box_runtime_output("version", []);
    let current_variant = sing_box_runtime_output("variant", []);
    let previous_marker = sing_box_runtime_output("read-variant-marker", []);
    let previous_version_state = sing_box_runtime_output("read-version-state", []);
    let release = resolve_sing_box_extended_release(false);
    if (release == null)
        action_fail("sing_box", action, "Failed to resolve sing-box-extended package release", current_version);
    let latest_version = normalize_sing_box_version(release.tag);

    if (action == "check_update") {
        if (!sing_box_runtime_success("is-extended", [ current_version ]))
            action_fail("sing_box", action, "sing-box-extended is not installed", current_version, latest_version);
        check_success("sing_box", normalize_sing_box_version(current_version), normalize_sing_box_version(latest_version), release.release_url);
    }

    let package_file = tmp_dir + "/" + release.asset_name;
    if (!download_with_retry(release.asset_url, package_file, release.asset_name))
        action_fail("sing_box", action, "Failed to download sing-box-extended package", current_version, latest_version);

    if (!run_logged("Updating package lists before sing-box-extended package installation", pkg_list_update_command()))
        action_fail("sing_box", action, "Failed to update package lists", current_version, latest_version);

    stop_forkop_before_sing_box_change();
    prepare_sing_box_package_service_install();

    let backup_binary = "";
    let backup_cronet = "";
    let cronet_touched = false;
    if (current_variant == "extended" || current_variant == "extended-compressed") {
        if (file_exists("/usr/bin/sing-box")) {
            backup_binary = "/usr/bin/sing-box.forkop-backup." + owner_pid();
            if (!move_file_to_backup("/usr/bin/sing-box", backup_binary))
                action_fail("sing_box", action, "Failed to backup current sing-box binary", current_version, latest_version);
        }
        if (file_exists("/usr/lib/libcronet.so")) {
            cronet_touched = true;
            backup_cronet = "/usr/lib/libcronet.so.forkop-backup." + owner_pid();
            if (!move_file_to_backup("/usr/lib/libcronet.so", backup_cronet)) {
                restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched);
                action_fail("sing_box", action, "Failed to backup current libcronet.so", current_version, latest_version);
            }
        }
    }

    if (!run_logged_pkg_remove_sing_box_conflict("sing-box-tiny", "Removing sing-box-tiny before sing-box-extended package installation")) {
        restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched);
        action_fail("sing_box", action, "Failed to remove sing-box-tiny before sing-box-extended package installation", current_version, latest_version);
    }
    if (!run_logged_pkg_remove_sing_box_conflict("sing-box", "Removing sing-box before sing-box-extended package installation")) {
        restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched);
        action_fail("sing_box", action, "Failed to remove sing-box before sing-box-extended package installation", current_version, latest_version);
    }

    if (backup_binary == "" && file_exists("/usr/bin/sing-box")) {
        backup_binary = "/usr/bin/sing-box.forkop-backup." + owner_pid();
        if (!move_file_to_backup("/usr/bin/sing-box", backup_binary)) {
            restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched);
            action_fail("sing_box", action, "Failed to backup existing sing-box binary", current_version, latest_version);
        }
    }
    if (!cronet_touched && file_exists("/usr/lib/libcronet.so")) {
        cronet_touched = true;
        backup_cronet = "/usr/lib/libcronet.so.forkop-backup." + owner_pid();
        if (!move_file_to_backup("/usr/lib/libcronet.so", backup_cronet)) {
            restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched);
            action_fail("sing_box", action, "Failed to backup current libcronet.so", current_version, latest_version);
        }
    }

    if (!run_logged("Installing sing-box-extended package " + release.asset_name, pkg_install_files_command([ package_file ]))) {
        restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched);
        action_fail("sing_box", action, "Failed to install sing-box-extended package", current_version, latest_version);
    }
    remove_file(package_file);

    let new_version = validate_sing_box_extended_binary("/usr/bin/sing-box", "/usr/lib");
    if (new_version == "") {
        if (restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched))
            action_fail("sing_box", action, "Installed sing-box-extended package failed validation; previous sing-box variant was restored", current_version, latest_version);
        action_fail("sing_box", action, "Installed sing-box-extended package failed validation and previous sing-box variant could not be restored", current_version, latest_version);
    }

    write_sing_box_variant_state("extended", new_version);
    restart_forkop_after_successful_change();
    if (!wait_forkop_running_after_sing_box_change()) {
        updates_log("sing-box-extended package did not start cleanly; restoring previous sing-box variant", "error");
        if (file_exists(SERVICE_INIT))
            command_success_from_args([ SERVICE_INIT, "stop" ]);
        if (restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched)) {
            remove_file(backup_binary);
            remove_file(backup_cronet);
            action_fail("sing_box", action, "sing-box-extended package was installed but Forkop did not start cleanly; previous sing-box variant was restored", current_version, latest_version);
        }
        action_fail("sing_box", action, "sing-box-extended package was installed but Forkop did not start cleanly and previous sing-box variant could not be restored", current_version, latest_version);
    }

    remove_file(backup_binary);
    remove_file(backup_cronet);
    clear_version_caches();
    updates_log("Installed sing-box-extended " + (new_version != "" ? new_version : "unknown") + " from package");
    action_success("sing_box", action, "sing-box-extended has been installed", new_version, latest_version, new_version == current_version ? 0 : 1, "latest", release.release_url);
}

function install_sing_box_extended(action, compressed) {
    if (!compressed) {
        install_sing_box_extended_package(action);
        return;
    }

    init_tmp_dir() || action_fail("sing_box", action, "Failed to create temporary directory");
    let label = "sing-box-extended compressed";
    let current_version = sing_box_runtime_output("version", []);
    let current_variant = sing_box_runtime_output("variant", []);
    let previous_marker = sing_box_runtime_output("read-variant-marker", []);
    let previous_version_state = sing_box_runtime_output("read-version-state", []);
    let release = resolve_sing_box_extended_release(true);
    if (release == null)
        action_fail("sing_box", action, "Failed to resolve " + label + " release", current_version);
    let latest_version = normalize_sing_box_version(release.tag);

    if (action == "check_update") {
        if (!sing_box_runtime_success("is-extended", [ current_version ]))
            action_fail("sing_box", action, "sing-box-extended is not installed", current_version, latest_version);
        if (!sing_box_runtime_success("marker-is", [ "extended-compressed" ]))
            action_fail("sing_box", action, "sing-box-extended compressed is not installed", current_version, latest_version);
        check_success("sing_box", normalize_sing_box_version(current_version), normalize_sing_box_version(latest_version), release.release_url);
    }

    let archive_file = tmp_dir + "/" + release.asset_name;
    if (!download_with_retry(release.asset_url, archive_file, release.asset_name))
        action_fail("sing_box", action, "Failed to download " + label, current_version, latest_version);

    let binary_path = select_archive_member_path(archive_file, "sing-box");
    if (binary_path == "") {
        remove_file(archive_file);
        action_fail("sing_box", action, "sing-box binary was not found in the downloaded archive", current_version, latest_version);
    }
    let cronet_path = select_archive_member_path(archive_file, "libcronet.so");
    let extract_error = tmp_dir + "/sing-box-extract.err";
    let tmp_binary = tmp_dir + "/sing-box.compressed." + owner_pid();
    let tmp_cronet = "";
    if (!command_success(command_from_args([ "tar", "-xzf", archive_file, "-O", binary_path ]) + " >" + shell_quote(tmp_binary) + " 2>" + shell_quote(extract_error)) ||
        !file_nonempty(tmp_binary) ||
        !command_success_from_args([ "chmod", "0755", tmp_binary ])) {
        for (let line in split(read_file(extract_error), "\n"))
            if (trim(as_string(line)) != "")
                updates_log(line);
        remove_file(tmp_binary);
        remove_file(archive_file);
        action_fail("sing_box", action, "Failed to extract " + label, current_version, latest_version);
    }

    if (cronet_path != "") {
        tmp_cronet = tmp_dir + "/libcronet.so";
        if (!command_success(command_from_args([ "tar", "-xzf", archive_file, "-O", cronet_path ]) + " >" + shell_quote(tmp_cronet) + " 2>" + shell_quote(extract_error)) ||
            !file_nonempty(tmp_cronet) ||
            !command_success_from_args([ "chmod", "0644", tmp_cronet ])) {
            for (let line in split(read_file(extract_error), "\n"))
                if (trim(as_string(line)) != "")
                    updates_log(line);
            remove_file(tmp_binary);
            remove_file(tmp_cronet);
            remove_file(archive_file);
            action_fail("sing_box", action, "Failed to extract libcronet.so from sing-box-extended archive", current_version, latest_version);
        }
    }

    let new_version = validate_sing_box_extended_binary(tmp_binary, tmp_dir);
    if (new_version == "") {
        remove_file(tmp_binary);
        remove_file(tmp_cronet);
        remove_file(archive_file);
        action_fail("sing_box", action, "Downloaded " + label + " failed validation", current_version, latest_version);
    }

    stop_forkop_before_sing_box_change();
    let backup_binary = "";
    let backup_cronet = "";
    let cronet_touched = false;
    if (file_exists("/usr/bin/sing-box")) {
        backup_binary = "/usr/bin/sing-box.forkop-backup." + owner_pid();
        if (!move_file_to_backup("/usr/bin/sing-box", backup_binary)) {
            remove_file(backup_binary);
            remove_file(tmp_binary);
            remove_file(tmp_cronet);
            remove_file(archive_file);
            action_fail("sing_box", action, "Failed to backup current sing-box binary", current_version, latest_version);
        }
    }
    if (cronet_path != "") {
        cronet_touched = true;
        if (file_exists("/usr/lib/libcronet.so")) {
            backup_cronet = "/usr/lib/libcronet.so.forkop-backup." + owner_pid();
            if (!move_file_to_backup("/usr/lib/libcronet.so", backup_cronet)) {
                restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched);
                remove_file(tmp_binary);
                remove_file(tmp_cronet);
                action_fail("sing_box", action, "Failed to backup current libcronet.so", current_version, latest_version);
            }
        }
    }

    for (let item in [
        [ "sing-box-extended", "Removing sing-box-extended package before " + label + " installation" ],
        [ "sing-box-tiny", "Removing sing-box-tiny package before " + label + " installation" ],
        [ "sing-box", "Removing sing-box package before " + label + " installation" ]
    ]) {
        if (!run_logged_pkg_remove_sing_box_conflict(item[0], item[1])) {
            restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched);
            remove_file(tmp_binary);
            remove_file(tmp_cronet);
            action_fail("sing_box", action, "Failed to remove " + item[0] + " before " + label + " installation", current_version, latest_version);
        }
    }

    remove_managed_sing_box_service_script();
    if (!install_managed_sing_box_service_script()) {
        restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched);
        remove_file(tmp_binary);
        remove_file(tmp_cronet);
        action_fail("sing_box", action, "Failed to install managed sing-box service for " + label, current_version, latest_version);
    }

    remove_file("/usr/bin/sing-box");
    if (!fs.rename(tmp_binary, "/usr/bin/sing-box") || !command_success_from_args([ "chmod", "0755", "/usr/bin/sing-box" ])) {
        remove_file("/usr/bin/sing-box");
        restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched);
        action_fail("sing_box", action, "Failed to install " + label + " binary", current_version, latest_version);
    }
    if (tmp_cronet != "") {
        remove_file("/usr/lib/libcronet.so");
        if (!fs.rename(tmp_cronet, "/usr/lib/libcronet.so") || !command_success_from_args([ "chmod", "0644", "/usr/lib/libcronet.so" ])) {
            remove_file("/usr/lib/libcronet.so");
            restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched);
            action_fail("sing_box", action, "Failed to install libcronet.so for " + label, current_version, latest_version);
        }
    }
    remove_file(archive_file);

    new_version = validate_sing_box_extended_binary("/usr/bin/sing-box", "/usr/lib");
    if (new_version == "") {
        if (restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched))
            action_fail("sing_box", action, "Installed " + label + " failed validation; previous sing-box variant was restored", current_version, latest_version);
        action_fail("sing_box", action, "Installed " + label + " failed validation and previous sing-box variant could not be restored", current_version, latest_version);
    }

    write_sing_box_variant_state("extended-compressed", new_version);
    restart_forkop_after_successful_change();
    if (!wait_forkop_running_after_sing_box_change()) {
        updates_log(label + " did not start cleanly; restoring previous sing-box binary", "error");
        if (file_exists(SERVICE_INIT))
            command_success_from_args([ SERVICE_INIT, "stop" ]);
        if (restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched)) {
            remove_file(backup_binary);
            remove_file(backup_cronet);
            action_fail("sing_box", action, label + " was installed but Forkop did not start cleanly; previous sing-box variant was restored", current_version, latest_version);
        }
        action_fail("sing_box", action, label + " was installed but Forkop did not start cleanly and previous sing-box variant could not be restored", current_version, latest_version);
    }

    remove_file(backup_binary);
    remove_file(backup_cronet);
    clear_version_caches();
    updates_log("Installed " + label + " " + (new_version != "" ? new_version : "unknown"));
    action_success("sing_box", action, label + " has been installed", new_version, latest_version, 1, "latest", release.release_url);
}

function install_package_sing_box(action, tiny) {
    let package_name = tiny ? "sing-box-tiny" : "sing-box";
    let conflict = tiny ? "sing-box" : "sing-box-tiny";
    let label = tiny ? "tiny sing-box" : "stable sing-box";
    let package_version = installed_package_version(package_name);
    let binary_version = sing_box_runtime_output("version", []);
    let current_version = package_version;
    if (sing_box_runtime_success("is-extended", [ binary_version ]))
        current_version = binary_version;
    if (current_version == "")
        current_version = binary_version;
    let latest_version = available_package_version(package_name);
    if (latest_version == "")
        latest_version = installed_package_version(package_name);

    if (action == "check_update") {
        if (latest_version == "")
            action_fail("sing_box", action, "Failed to resolve " + (tiny ? "tiny" : "stable") + " sing-box package version", current_version);
        if (tiny && !sing_box_runtime_success("is-tiny", [ binary_version ]))
            action_fail("sing_box", action, "sing-box-tiny is not installed", current_version, latest_version);
        check_success("sing_box", current_version, latest_version, "");
    }

    if (!run_logged("Updating package lists before " + package_name + " installation", pkg_list_update_command()))
        action_fail("sing_box", action, "Failed to update package lists", current_version, latest_version);
    latest_version = available_package_version(package_name);
    if (latest_version == "")
        latest_version = installed_package_version(package_name);
    if (latest_version == "")
        action_fail("sing_box", action, "Failed to resolve " + (tiny ? "tiny" : "stable") + " sing-box package version", current_version);

    let previous_variant = sing_box_runtime_output("variant", []);
    let previous_marker = sing_box_runtime_output("read-variant-marker", []);
    let previous_version_state = sing_box_runtime_output("read-version-state", []);
    stop_forkop_before_sing_box_change();

    let backup_binary = "";
    let backup_cronet = "";
    let cronet_touched = false;
    if (file_exists("/usr/bin/sing-box")) {
        backup_binary = "/usr/bin/sing-box.forkop-backup." + owner_pid();
        if (!move_file_to_backup("/usr/bin/sing-box", backup_binary))
            action_fail("sing_box", action, "Failed to backup current sing-box binary", current_version, latest_version);
    }
    if (file_exists("/usr/lib/libcronet.so")) {
        cronet_touched = true;
        backup_cronet = "/usr/lib/libcronet.so.forkop-backup." + owner_pid();
        if (!move_file_to_backup("/usr/lib/libcronet.so", backup_cronet)) {
            restore_sing_box_backup(backup_binary);
            action_fail("sing_box", action, "Failed to backup current libcronet.so", current_version, latest_version);
        }
    }

    if (!run_logged("Installing " + label + " package", "sh -c " + shell_quote("exit 0")) ||
        !replace_sing_box_package_variant(package_name, conflict))
        fail_package_sing_box_install(action, tiny, "package installation failed", current_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched);

    let new_version = read_sing_box_binary_version("/usr/bin/sing-box", "");
    if (new_version == "")
        fail_package_sing_box_install(action, tiny, "package was installed, but sing-box binary is not available", current_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched);
    if (sing_box_runtime_success("is-extended", [ new_version ]))
        fail_package_sing_box_install(action, tiny, "package was installed, but the active binary is still sing-box-extended", new_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched);
    write_sing_box_variant_state(tiny ? "tiny" : "stable", new_version);
    restart_forkop_after_successful_change();
    if (!wait_forkop_running_after_sing_box_change())
        fail_package_sing_box_install(action, tiny, "was installed, but Forkop did not start cleanly", new_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched);
    remove_file(backup_binary);
    remove_file(backup_cronet);
    clear_version_caches();
    action_success("sing_box", action, label + " has been installed", new_version, latest_version, new_version == current_version ? 0 : 1, "latest");
}

function check_forkop() {
    let metadata = fetch_forkop_latest_release_metadata();
    let fields = split(metadata, "\t");
    let latest_version = length(fields) > 0 && as_string(fields[0]) != "" ? as_string(fields[0]) : "unknown";
    let release_url = length(fields) > 1 ? as_string(fields[1]) : "";
    if (latest_version == "unknown")
        action_fail("forkop", "check_update", "Failed to check Forkop updates", FORKOP_VERSION, latest_version);

    write_forkop_latest_version_cache(latest_version, now_seconds());
    if (!helper_success("forkop-release-version-valid", [ FORKOP_VERSION ])) {
        updates_log("Forkop current version is not a release version (" + FORKOP_VERSION + ")");
        action_success("forkop", "check_update", "Installed version is newer than release", FORKOP_VERSION, latest_version, 0, "dev", release_url);
    }

    let compare = trim(helper_output("forkop-release-version-compare", [ FORKOP_VERSION, latest_version ]));
    if (compare == "")
        action_fail("forkop", "check_update", "Failed to compare Forkop versions", FORKOP_VERSION, latest_version);
    let status = status_from_compare(int(compare));
    if (status == "")
        action_fail("forkop", "check_update", "Failed to compare Forkop versions", FORKOP_VERSION, latest_version);
    if (status == "latest") {
        updates_log("Forkop is already up to date (" + FORKOP_VERSION + ")");
        action_success("forkop", "check_update", "Latest version is installed", FORKOP_VERSION, latest_version, 0, status, release_url);
    }
    if (status == "outdated") {
        updates_log("Forkop update found: " + FORKOP_VERSION + " -> " + latest_version);
        action_success("forkop", "check_update", "Update is available", FORKOP_VERSION, latest_version, 0, status, release_url);
    }
    updates_log("Forkop installed version is newer than upstream release: " + FORKOP_VERSION + " -> " + latest_version);
    action_success("forkop", "check_update", "Installed version is newer than release", FORKOP_VERSION, latest_version, 0, status, release_url);
}

function resolve_forkop_release(latest_version) {
    let release_json = latest_forkop_release_json();
    if (release_json == "")
        return null;
    let asset_ext = is_apk() ? "apk" : "ipk";
    let i18n_required = pkg_is_installed("luci-i18n-forkop-ru") ? "1" : "0";
    let plan = trim(helper_output_input(release_json, "forkop-release-plan", [ latest_version, asset_ext, i18n_required ]));
    let fields = split(plan, "\t");
    if (length(fields) < 7 || as_string(fields[1]) == "" || as_string(fields[2]) == "" || as_string(fields[3]) == "" || as_string(fields[4]) == "")
        return null;
    return {
        release_url: fields[0],
        backend_name: fields[1],
        backend_url: fields[2],
        app_name: fields[3],
        app_url: fields[4],
        i18n_name: fields[5],
        i18n_url: fields[6]
    };
}

function install_forkop() {
    let latest_version = latest_forkop_version();
    if (latest_version == "")
        latest_version = "unknown";
    if (latest_version == "unknown")
        action_fail("forkop", "install", "Failed to resolve Forkop release", FORKOP_VERSION, latest_version);

    write_forkop_latest_version_cache(latest_version, now_seconds());
    init_tmp_dir() || action_fail("forkop", "install", "Failed to create temporary directory", FORKOP_VERSION, latest_version);
    updates_log("Resolving Forkop release " + latest_version + " packages");
    let release = resolve_forkop_release(latest_version);
    if (release == null)
        action_fail("forkop", "install", "Failed to resolve Forkop release packages", FORKOP_VERSION, latest_version);

    let backend_file = tmp_dir + "/" + release.backend_name;
    let app_file = tmp_dir + "/" + release.app_name;
    let i18n_file = release.i18n_url != "" ? tmp_dir + "/" + release.i18n_name : "";
    if (!download_with_retry(release.backend_url, backend_file, release.backend_name) ||
        !download_with_retry(release.app_url, app_file, release.app_name) ||
        (release.i18n_url != "" && !download_with_retry(release.i18n_url, i18n_file, release.i18n_name)))
        action_fail("forkop", "install", "Failed to download Forkop release packages", FORKOP_VERSION, latest_version);

    if (!run_logged("Installing LuCI app package " + release.app_name, pkg_install_files_command([ app_file ])))
        action_fail("forkop", "install", "Failed to install LuCI app package", FORKOP_VERSION, latest_version);
    if (i18n_file != "" && !run_logged("Installing LuCI Russian i18n package " + release.i18n_name, pkg_install_files_command([ i18n_file ])))
        action_fail("forkop", "install", "Failed to install LuCI Russian i18n package", FORKOP_VERSION, latest_version);
    if (!run_logged("Installing Forkop package " + release.backend_name, pkg_install_files_command([ backend_file ])))
        action_fail("forkop", "install", "Failed to install Forkop package", FORKOP_VERSION, latest_version);

    remove_file("/var/luci-indexcache");
    command_success("rm -f /var/luci-indexcache* /tmp/luci-indexcache* 2>/dev/null");
    command_success("rm -rf /tmp/luci-modulecache/ 2>/dev/null");
    if (file_exists("/etc/init.d/rpcd") && !command_success_from_args([ "/etc/init.d/rpcd", "reload" ]))
        command_success_from_args([ "/etc/init.d/rpcd", "restart" ]);
    command_success_from_args([ "killall", "-HUP", "rpcd" ]);

    restart_forkop_after_successful_change();
    clear_version_caches();
    let new_version = installed_package_version("forkop");
    if (new_version == "")
        new_version = latest_version;
    updates_log("Forkop updated to " + new_version);
    action_success("forkop", "install", "Forkop has been installed", new_version, latest_version, 1, "latest", release.release_url);
}

function dispatch_sing_box(action) {
    if (action == "install_extended") {
        install_sing_box_extended(action, false);
        return;
    }
    if (action == "install_extended_compressed") {
        install_sing_box_extended(action, true);
        return;
    }
    if (action == "install_tiny") {
        install_package_sing_box(action, true);
        return;
    }
    if (action == "install_stable") {
        install_package_sing_box(action, false);
        return;
    }

    let variant = sing_box_runtime_output("variant", []);
    if (variant == "extended-compressed")
        install_sing_box_extended(action, true);
    else if (variant == "extended")
        install_sing_box_extended(action, false);
    else if (variant == "tiny")
        install_package_sing_box(action, true);
    else
        install_package_sing_box(action, false);
}

function normalize_component_name(component) {
    component = as_string(component);
    if (component == "sing-box" || component == "singbox")
        return "sing_box";
    if (component == "forkop")
        return "forkop";
    return component;
}

function component_action(component, action) {
    component = normalize_component_name(component);
    action = as_string(action);
    if (!acquire_component_lock())
        action_fail(component != "" ? component : "unknown", action != "" ? action : "unknown", "Another component action is already running");
    if (!init_tmp_dir())
        action_fail(component != "" ? component : "unknown", action != "" ? action : "unknown", "Failed to create temporary directory");
    capture_forkop_running_state();

    if (component == "forkop" && action == "check_update")
        check_forkop();
    else if (component == "forkop" && action == "install")
        install_forkop();
    else if (component == "sing_box" && (action == "check_update" || action == "install" ||
        action == "install_extended" || action == "install_extended_compressed" ||
        action == "install_tiny" || action == "install_stable"))
        dispatch_sing_box(action);
    else if (component == "zapret" && (action == "check_update" || action == "install"))
        install_zapret(action);
    else if (component == "zapret" && action == "remove")
        remove_optional_component("zapret", "zapret", "zapret", LIB_DIR + "/providers/zapret/runtime.uc");
    else if (component == "zapret2" && (action == "check_update" || action == "install"))
        install_zapret2(action);
    else if (component == "zapret2" && action == "remove")
        remove_optional_component("zapret2", "zapret2", "zapret2", LIB_DIR + "/providers/zapret2/runtime.uc");
    else if (component == "byedpi" && (action == "check_update" || action == "install"))
        install_byedpi(action);
    else if (component == "byedpi" && action == "remove")
        remove_optional_component("byedpi", "byedpi", "ByeDPI", LIB_DIR + "/providers/byedpi/runtime.uc");
    else
        action_fail(component != "" ? component : "unknown", action != "" ? action : "unknown", "Unknown component action");
}

let mode = ARGV[0] || "";

if (mode == "component-action")
    component_action(ARGV[1], ARGV[2]);
else if (mode == "latest-forkop-release-json")
    print(latest_forkop_release_json());
else if (mode == "latest-forkop-version")
    print(latest_forkop_version(), "\n");
else if (mode == "forkop-release-metadata")
    print(fetch_forkop_latest_release_metadata(), "\n");
else {
    warn("Usage: components/action.uc <component-action|latest-forkop-version|forkop-release-metadata> ...\n");
    exit(1);
}
