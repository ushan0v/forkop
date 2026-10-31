let t = require("t");
let stub = require("stub");
let fixture = require("fixture");
let fs = require("fs");
let uci = require("uci");
let core_uci = require("core.uci");
let packages = require("core.packages");
let runtime = require("singbox.runtime");
let cli = require("service.cli");

function configuration(dir, extra) {
    return {
        settings: fixture.settings({
            config_path: dir + "/etc/sing-box/config.json",
            cache_path: dir + "/tmp/sing-box/cache.db",
            service_listen_address: "127.0.0.1",
            ...(extra ?? {})
        }),
        section: [ { ".name": "main", action: "connection" } ],
        connection_link: fixture.links("main", [ "vless://u@a.example:443#A" ])
    };
}

let logs = [];

function tools(extra) {
    logs = [];
    stub.commands([
        stub.logger(logs),
        ...(extra ?? [])
    ]);
}

// pgrep over a process table: -x by the process name, -f by the whole command line.
function processes(command_lines) {
    return [ "pgrep", (argv) => {
        let hit = argv[1] == "-x"
            ? filter(command_lines, (line) => replace(split(line, " ")[0], /.*\//, "") == argv[2])
            : filter(command_lines, (line) => match(line, regexp(argv[2])) != null);
        return { status: length(hit) > 0 ? 0 : 1 };
    } ];
}

t.test("the running core is the service's sing-box run, not a one-shot command", () => {
    tools([ processes([ "/usr/bin/sing-box version", "/usr/bin/sing-box generate warp-profile --json" ]) ]);
    t.eq(runtime.process_running(), false, "the state service asking the version during an install");
    tools([ processes([ "/usr/bin/sing-box run -c /etc/sing-box/config.json -D /usr/share/sing-box" ]) ]);
    t.eq(runtime.process_running(), true);
    stub.restore();
});

const CHECK = /'sing-box' '--disable-color' '-c' .* 'check'/;

function checks_run() {
    return length(filter(stub.command_lines(), (line) => match(line, / check$/)));
}

t.test("the configuration is written where the service reads it, and only when it changed", () => {
    let dir = stub.tmpdir();
    fixture.seed(configuration(dir));
    tools([ [ CHECK, {} ] ]);
    t.eq(runtime.write_config(false), true);
    let written = fs.readfile(dir + "/etc/sing-box/config.json");
    t.eq(json(written).outbounds != null, true);
    t.ok(fs.stat(dir + "/tmp/sing-box")?.type == "directory", "the cache directory exists for the core to open");

    let inode = fs.stat(dir + "/etc/sing-box/config.json").inode;
    t.eq(runtime.write_config(false), false);
    t.eq(fs.stat(dir + "/etc/sing-box/config.json").inode, inode, "an unchanged configuration is not rewritten");
    t.eq(checks_run(), 1, "the core checked the changed configuration, and only that one");
    t.eq(logs, [], "writing the file is a step of the apply, which reports its outcome");
    stub.restore();
});

// The core follows the memory the system can still give with Go's limit; a memory_limit in the
// configuration would fix it instead.
t.test("the written configuration leaves the memory limit to the core", () => {
    let dir = stub.tmpdir();
    fixture.seed(configuration(dir));
    tools([ [ CHECK, {} ] ]);
    runtime.write_config(false);
    stub.restore();
    t.eq(json(fs.readfile(dir + "/etc/sing-box/config.json")).experimental.debug, null);
});

t.test("a configuration the core refuses is reported by its first line and never written", () => {
    let dir = stub.tmpdir();
    fixture.seed(configuration(dir));
    tools([ [ CHECK, { status: 42, stdout: "\nFATAL[0000] route: missing outbound tag\nmore\n" } ] ]);
    let e = t.throws(() => runtime.write_config(true));
    stub.restore();
    t.eq(e.message, "sing-box refused the generated configuration: FATAL[0000] route: missing outbound tag");
    t.ok(fs.stat(dir + "/etc/sing-box/config.json") == null);
    t.eq(filter(fs.lsdir("/tmp"), (name) => substr(name, 0, 22) == "forkop-sing-box-check." && index(name, ".json") > 0), [],
        "the file checked is removed");
});

t.test("a changed configuration the core refuses leaves the file the running core was started with", () => {
    let dir = stub.tmpdir();
    fixture.seed(configuration(dir));
    tools([ [ CHECK, {} ] ]);
    runtime.write_config(false);
    let running = fs.readfile(dir + "/etc/sing-box/config.json");
    fixture.seed(configuration(dir, { log_level: "debug" }));
    tools([ [ CHECK, { status: 1, stdout: "FATAL[0000] initialize dns router: validate dns rule[9]\n" } ] ]);
    let e = t.throws(() => runtime.write_config(false));
    stub.restore();
    t.eq(e.message, "sing-box refused the generated configuration: FATAL[0000] initialize dns router: validate dns rule[9]");
    t.eq(fs.readfile(dir + "/etc/sing-box/config.json"), running);
});

t.test("a LAN without an IPv4 address is a warning of the configuration, not of whoever asks for the address", () => {
    let dir = stub.tmpdir();
    fixture.seed(configuration(dir, { service_listen_address: "" }));
    tools([ [ CHECK, {} ], [ /network\.interface/, { stdout: "{}" } ], [ "ip -4 addr show", { stdout: "" } ] ]);
    t.eq(runtime.listen_address(), "");
    t.eq(logs, [], "a diagnostics check asking for it");
    runtime.write_config(false);
    stub.restore();
    t.eq(logs, [ "[warn] No IPv4 address found on the LAN, so the Clash API listens on 127.0.0.1 only; set forkop.settings.service_listen_address to choose one" ]);
});

t.test("a checked configuration is checked even when it did not change", () => {
    let dir = stub.tmpdir();
    fixture.seed(configuration(dir));
    tools([ [ CHECK, {} ] ]);
    runtime.write_config(true);
    runtime.write_config(true);
    t.eq(checks_run(), 2);
    stub.restore();
});

t.test("the service runs the generated file as root, committed only when something changed", () => {
    let dir = stub.tmpdir();
    fixture.seed(configuration(dir));
    uci.__seed("sing-box", [ { ".name": "main", ".type": "sing-box", enabled: "0", user: "sing-box", conffile: "/etc/sing-box/config.json" } ]);
    core_uci.reset();
    tools();
    runtime.configure_service();
    core_uci.reset();
    t.eq([ core_uci.get("sing-box.main.enabled"), core_uci.get("sing-box.main.user"), core_uci.get("sing-box.main.conffile") ],
        [ "1", "root", dir + "/etc/sing-box/config.json" ]);
    t.eq(logs, [ "[info] Set up the sing-box service for Forkop: enabled=1, user=root, conffile=" + dir + "/etc/sing-box/config.json" ]);
    let commits = length(uci.__commits());
    runtime.configure_service();
    t.eq(length(uci.__commits()), commits, "a configured service is not committed again");
    t.eq(length(logs), 1, "nor reported again");
    stub.restore();
});

t.test("the devices the core binds are the default interface and every bind_interface of the running file", () => {
    let dir = stub.tmpdir();
    fixture.seed(configuration(dir));
    t.eq(runtime.bound_devices(), [], "no file yet");
    fs.mkdir(dir + "/etc");
    fs.mkdir(dir + "/etc/sing-box");
    fs.writefile(dir + "/etc/sing-box/config.json", sprintf("%J", {
        route: { default_interface: "eth1", final: "direct-out" },
        outbounds: [ { type: "direct", tag: "direct-out" }, { type: "direct", tag: "lte", bind_interface: "wwan0" },
            { type: "vless", tag: "json", bind_interface: "eth1", server: "a.example" } ],
        endpoints: [ { type: "wireguard", tag: "wg", bind_interface: "pppoe-wan" } ]
    }));
    t.eq(runtime.bound_devices(), [ "eth1", "pppoe-wan", "wwan0" ]);
});

t.test("the core version is the package's, with the release spelling", () => {
    let dir = stub.tmpdir();
    packages.paths.opkg_status = dir + "/status";
    fs.writefile(packages.paths.opkg_status, "Package: sing-box-forkop\nVersion: 1.13.14~extended~2.5.3~f1\nStatus: install ok installed\n");
    packages.paths.sing_box_version = dir + "/missing";
    stub.commands([ [ "sh -c command -v apk", { status: 1 } ] ]);
    t.eq(runtime.version(), "1.13.14-extended-2.5.3-f1");
    stub.restore();
});

const WARP_COMMAND = "sing-box --disable-color generate warp-profile --json";
const PROXIED_WARP_COMMAND = "env HTTPS_PROXY=http://127.0.0.1:4536 " + WARP_COMMAND;
const WARP_PROXY_LISTENING = [ "netstat -lnt", { stdout: "tcp 0 0 127.0.0.1:4536 0.0.0.0:* LISTEN\n" } ];
const NOTHING_LISTENING = [ "netstat -lnt", { stdout: "tcp 0 0 127.0.0.1:53 0.0.0.0:* LISTEN\n" } ];
const PROFILE = "{\"id\":\"profile-id\",\"auth_token\":\"auth-token\",\"private_key\":\"private-key\"}";

function warp_settings(through_section) {
    fixture.seed({
        settings: through_section ? { warp_profiles_via_proxy: "1", warp_profiles_via_proxy_section: "proxy" } : {},
        section: [ { ".name": "proxy", label: "Proxy", enabled: "1", action: "connection" } ],
        connection_link: fixture.links("proxy", [ "vless://u@a.example:443#A" ])
    });
    require("config.connections").load();
}

function generate() {
    return stub.capture(() => cli.main([ "generate_warp_profile" ], "/lib"));
}

t.test("a WARP profile is the three fields the core returned, and a failure says nothing of its output", () => {
    warp_settings(false);
    tools([ [ WARP_COMMAND, { stdout: "{\"id\":\"profile-id\",\"auth_token\":\"auth-token\",\"private_key\":\"private-key\",\"extra\":1}" } ] ]);
    let good = generate();
    tools([ [ WARP_COMMAND, { stdout: "{\"id\":\"secret-leak\"}" } ] ]);
    let bad = generate();
    stub.restore();

    t.eq([ good.result, json(good.stdout) ], [ 0, { id: "profile-id", auth_token: "auth-token", private_key: "private-key" } ]);
    t.eq([ bad.result, bad.stdout, bad.stderr ], [ 1, "", "Failed to generate WARP profile: the core returned an incomplete profile\n" ]);
    t.eq(logs, [ "[error] Failed to generate WARP profile: the core returned an incomplete profile" ]);
});

t.test("a WARP profile is registered through the chosen section's service proxy", () => {
    warp_settings(true);
    tools([ WARP_PROXY_LISTENING, [ PROXIED_WARP_COMMAND, { stdout: PROFILE } ] ]);
    let result = generate();
    stub.restore();
    t.eq([ result.result, json(result.stdout).id ], [ 0, "profile-id" ]);
});

t.test("a WARP registration that cannot reach its section says so, and never goes out directly instead", () => {
    warp_settings(true);
    tools([ NOTHING_LISTENING ]);
    let result = generate();
    stub.restore();
    let message = "Failed to generate WARP profile: profiles are requested through section 'Proxy', " +
        "and its service proxy is not running. Apply the settings or start Forkop";
    t.eq([ result.result, result.stderr ], [ 1, message + "\n" ]);
    t.eq(logs, [ "[error] " + message ]);
});

t.test("a WARP registration the core gave up on is logged with the core's reason and the way it went", () => {
    let reason = "FATAL[0010] Post \"https://api.devices.cloudflare.com/v0a4471/reg\": net/http: TLS handshake timeout";
    warp_settings(false);
    tools([ [ WARP_COMMAND, { status: 1, stdout: reason + "\n" } ] ]);
    let direct = generate();
    let direct_logs = logs;
    warp_settings(true);
    tools([ WARP_PROXY_LISTENING, [ PROXIED_WARP_COMMAND, { status: 1, stdout: reason + "\n" } ] ]);
    let proxied = generate();
    stub.restore();

    let hint = ". If the Cloudflare API is blocked on this network, choose a section in Settings to request WARP profiles through";
    t.eq([ direct.result, direct.stderr ], [ 1, "Failed to generate WARP profile: " + reason + hint + "\n" ]);
    t.eq(direct_logs, [ "[error] Failed to generate WARP profile: " + reason + hint ]);
    t.eq(proxied.result, 1);
    t.eq(logs, [ "[error] Failed to generate WARP profile through section 'Proxy': " + reason ]);
});

t.done();
