let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let netstat = require("core.netstat");
let uci = require("core.uci");
let singbox_constants = require("singbox.constants");
let packages = require("core.packages");
let connections = require("config.connections");
let generator = require("singbox.generator");

const CONFIG_NAME = "forkop";

function settings() {
    return uci.get_all(CONFIG_NAME, "settings") ?? {};
}

// Forkop starts sing-box itself; the core's own autostart would start it without the rules
// around it.
function configure_service() {
    if (!uci.exists("sing-box.main") && !uci.set_section("sing-box.main", "sing-box"))
        die("Failed to create the sing-box service section in /etc/config/sing-box");

    let changed = [];
    for (let option in [ [ "enabled", "1" ], [ "user", "root" ], [ "conffile", singbox_constants.config_path(settings()) ] ]) {
        if (trim(uci.get("sing-box.main." + option[0])) == option[1])
            continue;
        if (!uci.set("sing-box.main." + option[0], option[1]))
            die("Failed to set sing-box.main." + option[0] + " in /etc/config/sing-box");
        push(changed, option[0] + "=" + option[1]);
    }
    if (length(changed) > 0) {
        if (!uci.commit("sing-box"))
            die("Failed to save the sing-box service settings in /etc/config/sing-box");
        exec.log("info", "Set up the sing-box service for Forkop: " + join(", ", changed));
    }

    if (fs.stat("/etc/rc.d/S99sing-box") == null)
        return;
    if (exec.ok([ "/etc/init.d/sing-box", "disable" ]))
        exec.log("info", "Disabled the sing-box autostart; Forkop starts sing-box itself");
    else
        exec.log("warn", "Failed to disable the sing-box autostart; at boot sing-box may start without Forkop");
}

function interface_ipv4_address(name) {
    let status = common.parse_json(exec.output([ "ubus", "call", "network.interface." + name, "status" ]));
    return common.as_string(status?.["ipv4-address"]?.[0]?.address);
}

function device_ipv4_address(device) {
    let matched = match(exec.output([ "ip", "-4", "addr", "show", "dev", device ]) ?? "", /inet[ \t]+([0-9.]+)\//);
    return matched ? matched[1] : "";
}

// The address the service inbounds listen on: the one configured, else the LAN's.
function listen_address(values) {
    values ??= settings();
    let configured = common.option(values, "service_listen_address", "");
    if (configured != "")
        return configured;

    let address = interface_ipv4_address("lan");
    for (let name in common.words(common.option(values, "source_network_interfaces", "br-lan"))) {
        if (address != "")
            break;
        address = interface_ipv4_address(name) || device_ipv4_address(name);
    }
    return address;
}

// While mwan3 has an enabled interface and runs or will start, it owns egress routing, which a
// pinned output interface bypasses.
function mwan3_active() {
    if (((fs.stat("/etc/init.d/mwan3")?.mode ?? 0) & 0111) == 0 || (fs.stat("/etc/config/mwan3")?.size ?? 0) == 0)
        return false;
    if (length(filter(uci.section_objects("mwan3", "interface"), (s) => common.option(s, "enabled", "0") == "1")) == 0)
        return false;
    return exec.ok([ "/etc/init.d/mwan3", "status" ]) || exec.ok([ "/etc/init.d/mwan3", "enabled" ]);
}

// The first line a failed core command printed, which is its fatal error.
function failure_reason(result) {
    return filter(split(result.output, "\n"), (line) => trim(line) != "")[0] ?? "exit status " + result.status;
}

function check(text) {
    let now = clock();
    let path = sprintf("/tmp/forkop-sing-box-check.%d.%d.json", now[0], now[1]);
    if (!common.write_file(path, text))
        die("Failed to write the generated sing-box configuration to " + path);
    let result = exec.combined([ "sing-box", "--disable-color", "-c", path, "check" ]);
    fs.unlink(path);
    if (result.status == 0)
        return;
    die("sing-box refused the generated configuration: " + failure_reason(result));
}

// The file is written only once the core accepted it. Returns whether it changed; a start
// checks it regardless, since the core may have been replaced.
function write_config(checked) {
    let values = settings();
    let path = singbox_constants.config_path(values);
    if (path == "")
        die("The sing-box configuration file path is not set in Settings");

    // sing-box needs its cache directory, and a reboot empties /tmp.
    let cache_dir = common.parent_dir(common.option(values, "cache_path", singbox_constants.TMP_SING_BOX_FOLDER + "/cache.db"));
    if (!common.ensure_dir(cache_dir))
        die("Failed to create " + cache_dir + " for the sing-box cache file");

    let output_interface = common.option(values, "output_network_interface", "");
    if (output_interface != "" && mwan3_active())
        exec.log("warn", "mwan3 is active, but the output interface is set to '" + output_interface + "': sing-box sends its traffic out of it, past mwan3");

    let address = listen_address(values);
    if (address == "")
        exec.log("warn", "No IPv4 address found on the LAN, so the Clash API listens on 127.0.0.1 only; set forkop.settings.service_listen_address to choose one");

    let text;
    try {
        text = sprintf("%J\n", generator.build({ service_address: address }));
    }
    catch (e) {
        die("Failed to generate the sing-box configuration: " + e.message);
    }
    let unchanged = fs.readfile(path) == text;
    if (checked || !unchanged)
        check(text);

    if (unchanged)
        return false;
    if (!common.write_file_atomic(path, text))
        die("Failed to write the sing-box configuration to " + path);
    return true;
}

// The devices the running configuration binds the core's own sockets to.
function bound_devices() {
    let config = common.read_json_file(singbox_constants.config_path(settings()));
    let bound = map([ ...(config?.outbounds ?? []), ...(config?.endpoints ?? []) ], (item) => item?.bind_interface);
    let devices = [];
    for (let name in [ config?.route?.default_interface, ...bound ])
        if (type(name) == "string" && name != "" && index(devices, name) < 0)
            push(devices, name);
    return sort(devices);
}

function version() {
    let value = packages.version("sing-box-forkop") || trim(fs.readfile(packages.paths.sing_box_version) ?? "");
    return replace(value, /~/g, "-");
}

// The service's core only: the state service runs the binary for its version on every restart.
function process_running() {
    return exec.ok([ "pgrep", "-f", "^/usr/bin/sing-box[[:space:]]+run([[:space:]]|$)" ]);
}

// Cloudflare's registration API is blocked on some networks: with a section chosen the request
// goes through the core's inbound for it, never directly; without one it is the router's own.
function warp_profile() {
    let values = settings();
    let section = connections.download_via_proxy_enabled(values, "warp_profiles")
        ? connections.download_via_proxy_section(values, "warp_profiles") : null;
    let through = section == null ? "" : " through section '" + connections.section_display_name(section) + "'";
    let fail = function(detail) {
        let message = "Failed to generate WARP profile" + detail;
        exec.log("error", message);
        die(message);
    };

    let argv = [ "sing-box", "--disable-color", "generate", "warp-profile", "--json" ];
    if (section != null) {
        let proxy = singbox_constants.SERVICE_MIXED_INBOUND_ADDRESS + ":" + singbox_constants.WARP_PROFILES_MIXED_INBOUND_PORT;
        if (!netstat.tcp_endpoint_in_use(exec.output([ "netstat", "-lnt" ]), proxy))
            fail(": profiles are requested through section '" + connections.section_display_name(section) +
                "', and its service proxy is not running. Apply the settings or start Forkop");
        argv = [ "env", "HTTPS_PROXY=http://" + proxy, ...argv ];
    }
    let output = exec.combined(argv);
    if (output.status != 0)
        fail(through + ": " + failure_reason(output) + (section == null
            ? ". If the Cloudflare API is blocked on this network, choose a section in Settings to request WARP profiles through" : ""));

    let profile = common.parse_json(output.output);
    let result = { id: profile?.id, auth_token: profile?.auth_token, private_key: profile?.private_key };
    for (let key, value in result)
        if (type(value) != "string" || value == "")
            fail(through + ": the core returned an incomplete profile");
    return result;
}

return {
    configure_service, write_config, listen_address, device_ipv4_address,
    mwan3_active, bound_devices, version, process_running, warp_profile
};
