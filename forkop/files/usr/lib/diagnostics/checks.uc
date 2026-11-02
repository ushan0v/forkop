// The Status tab checks return facts; the page judges them and words the verdict.

let fs = require("fs");
let resolv = require("resolv");
let common = require("core.common");
let exec = require("core.exec");
let constants = require("core.constants");
let core_ip = require("core.ip");
let core_url = require("core.url");
let uci = require("core.uci");
let netstat = require("core.netstat");
let packages = require("core.packages");
let core_version = require("core.version");
let runtime_dns = require("singbox.dns");
let singbox_constants = require("singbox.constants");
let features = require("singbox.features");
let config_status = require("singbox.config_status");
let runtime_servers = require("singbox.servers");
let connections = require("config.connections");
let health = require("service.health");
let mask = require("diagnostics.mask");
let firewall = require("diagnostics.firewall");
let server_rules = require("diagnostics.inbounds");
let conflicts = require("diagnostics.conflicts");
let clash_api = require("singbox.clash_api");

const CONFIG_NAME = constants.FORKOP_CONFIG_NAME;
const STABLE_MIN_AGE = 2;
const DNS_INBOUND = singbox_constants.DNS_INBOUND_ADDRESS;
const FAKEIP_DOMAIN = singbox_constants.FAKEIP_TEST_DOMAIN;
const IP_DOMAIN = singbox_constants.CHECK_PROXY_IP_DOMAIN;
// A name no cache can answer, so a reply proves the upstream server was reached.
const UNCACHED_ZONE = "example.com";
const CGNAT_RANGE = "100.64.0.0/10";

let paths = {
    proc: "/proc",
    meminfo: "/proc/meminfo",
    uptime: "/proc/uptime"
};

function settings() {
    return uci.get_all(CONFIG_NAME, "settings") ?? {};
}

function runtime_config() {
    return common.read_json_file(singbox_constants.config_path(settings()));
}

function output(argv) {
    return exec.output(argv) ?? "";
}

function uptime_seconds() {
    return int(split(trim(fs.readfile(paths.uptime) ?? "0"), " ")[0]);
}

// The first error since Forkop's last info line: every action opens and closes with one, and
// the later errors are mostly the cleanup's. Without an error, the last warning is the reason.
function last_error(log) {
    let error = null;
    let warning = null;
    for (let line in split(log ?? "", "\n")) {
        let entry = match(line, /forkop(\[[0-9]+\])?: \[([a-z]+)\] (.*)$/);
        if (entry == null)
            continue;
        if (entry[2] == "info") {
            error = null;
            warning = null;
        }
        else if (entry[2] == "error" && error == null)
            error = entry[3];
        else if (entry[2] == "warn")
            warning = entry[3];
    }
    return error ?? warning ?? "";
}

function meminfo() {
    let text = fs.readfile(paths.meminfo) ?? "";
    let value = (key) => int(match(text, regexp("(^|\n)" + key + ":[ \t]*([0-9]+)"))?.[2] ?? 0);
    return { total_kb: value("MemTotal"), available_kb: value("MemAvailable") };
}

// Forkop itself runs `sing-box check` and `sing-box version` briefly; those hold no port.
function sing_box_cores() {
    let result = [];
    for (let dir in fs.glob(paths.proc + "/[0-9]*")) {
        let pid = fs.basename(dir);
        if (health.pid_is_sing_box(pid) && index(split(fs.readfile(dir + "/cmdline") ?? "", "\u0000"), "run") >= 0)
            push(result, int(pid));
    }
    return sort(result, (a, b) => a - b);
}

// The core that runs, as the binary reports itself: a package's files outlive a binary copied
// over them. The variant is the package's while the binary is of its build, which a +K suffix
// does not change.
function core() {
    let installed = fs.stat(features.paths.binary) != null;
    let binary = features.version();
    let version = packages.forkop_core_version(binary);
    let build = (value) => split(value, "+")[0];
    return {
        installed,
        binary,
        version,
        variant: version != "" && build(version) == build(packages.sing_box_version()) ? packages.sing_box_variant() : "",
        outdated: version != "" && !core_version.version_at_least(version, constants.SB_REQUIRED_VERSION),
        required: constants.SB_REQUIRED_VERSION,
        problem: installed ? features.core_problem() : ""
    };
}

function service() {
    let running = health.forkop_stably_running(constants.RT_TABLE_NAME, constants.NFT_TABLE_NAME, constants.NFT_FAKEIP_MARK, STABLE_MIN_AGE);
    let pid = health.sing_box_service_pid_runtime();
    let own = pid > 0 && health.pid_is_sing_box(pid) ? pid : 0;
    return {
        running,
        uptime: own > 0 ? (health.process_age_seconds(own) ?? -1) : -1,
        last_error: running ? "" : last_error(output([ "logread", "-e", "^forkop" ])),
        core: core(),
        foreign_sing_box: filter(sing_box_cores(), (found) => found != own),
        conflicts: conflicts.find(output([ "nft", "-t", "list", "ruleset" ])),
        memory: meminfo(),
        router_uptime: uptime_seconds()
    };
}

// One attempt within timeout ms: resolv counts attempts, and the version OpenWrt ships dies on 0.
// NXDOMAIN counts as an answer; SERVFAIL or REFUSED is the server failing.
function lookup(name, servers, timeout) {
    let start = common.monotonic_ms();
    let reply = resolv.query([ name ], { type: [ "A" ], nameserver: servers, timeout, retries: 1 });
    let ms = common.monotonic_ms() - start;
    let status = reply == null ? "" : reply[name]?.rcode ?? "NOERROR";
    if (status == "TIMEOUT")
        status = "";
    return { answered: status == "NOERROR" || status == "NXDOMAIN", status, ms: status == "" ? -1 : ms };
}

// A CNAME's target holds the records under its own name.
function addresses(reply, types) {
    let found = {};
    for (let name, records in reply ?? {})
        for (let kind in types)
            for (let address in records?.[kind] ?? [])
                found[address] = true;
    return keys(found);
}

function uncached_name() {
    let now = clock();
    return sprintf("forkop-%x%x.%s", now[0], now[1], UNCACHED_ZONE);
}

// resolv speaks plain DNS only, and takes the port after a "#".
function plain_server(uri) {
    let parsed = runtime_dns.parse_server_uri(uri, false);
    return parsed.unsupported || parsed.type != "udp" ? null : parsed.server + "#" + parsed.server_port;
}

function bootstrap_host(values, servers, config) {
    for (let server in servers) {
        let host = core_url.host(server) || server;
        if (host != "" && !core_ip.valid_ip(host))
            return host;
    }
    if (!common.bool_option(values, "dns_detour_enabled", false))
        return "";
    for (let outbound in config?.outbounds ?? []) {
        let host = common.as_string(outbound?.server);
        if (host != "" && !core_ip.valid_ip(host))
            return host;
    }
    return "";
}

function dns() {
    let values = settings();
    let servers = runtime_dns.server_list(values, "dns_server", "77.88.8.8");
    let bootstraps = runtime_dns.server_list(values, "bootstrap_dns_server", "77.88.8.8");
    let host = bootstrap_host(values, servers, runtime_config());
    let testable = host == "" ? [] : filter(bootstraps, (server) => plain_server(server) != null);

    let main = lookup(uncached_name(), [ DNS_INBOUND + "#53" ], 4000);
    let local = lookup("localhost", [ "127.0.0.1#53" ], 3000);
    let bootstrap = null;
    if (length(testable) > 0) {
        bootstrap = { servers: join(", ", testable), host, answered: false, ms: -1 };
        for (let server in testable) {
            let result = lookup(host, [ plain_server(server) ], 3000);
            if (result.answered) {
                bootstrap.answered = true;
                bootstrap.ms = result.ms;
                break;
            }
        }
    }

    return {
        main: { servers: join(", ", map(servers, (server) => mask.dns_server(server))), ...main },
        bootstrap,
        local
    };
}

// A single domain is generated as a plain string, so both shapes are read.
function rule_names_domain(rule, domain) {
    return type(rule?.domain) == "array" ? index(rule.domain, domain) >= 0 : rule?.domain == domain;
}

function check_section(config) {
    for (let rule in config?.route?.rules ?? [])
        if (rule_names_domain(rule, IP_DOMAIN) && common.as_string(rule.outbound) != "")
            return common.as_string(rule.outbound);
    return "";
}

function check_answer(text) {
    let value = common.parse_json(text);
    return type(value) == "object" ? { fakeip: value.fakeip === true, ip: common.as_string(value.IP) } : null;
}

function in_fakeip_range(address) {
    return core_ip.prefix_contains(singbox_constants.FAKEIP_INET4_RANGE, address) ||
        core_ip.prefix_contains(singbox_constants.FAKEIP_INET6_RANGE, address);
}

// The router looks the check domain up through its resolver, which must hand out a FakeIP
// address, and fetches it; the endpoint reports whether the connection came through Forkop.
// An excluded router reaches neither the capture nor a section, so nothing here can be seen.
function traffic() {
    if (connections.excluded_devices(settings()).router)
        return { router: { excluded: true, dns_fakeip: false, answered: false, fakeip: false, ip: "" }, exit: null };

    let section = check_section(runtime_config());
    let reply = resolv.query([ FAKEIP_DOMAIN ], { type: [ "A" ], timeout: 3000, retries: 1 });
    let commands = [ [ "uclient-fetch", "-q", "-O", "-", "--timeout=6", "https://" + FAKEIP_DOMAIN + "/check" ] ];
    if (section != "")
        push(commands, [ "uclient-fetch", "-q", "-O", "-", "--timeout=8", "https://" + IP_DOMAIN + "/check" ]);
    let results = exec.capture_parallel(commands);
    let router = check_answer(results[0].stdout);
    let exit = section == "" ? null : check_answer(results[1].stdout);

    return {
        router: {
            excluded: false,
            dns_fakeip: in_fakeip_range(addresses(reply, [ "A" ])[0] ?? ""),
            answered: router != null,
            fakeip: router?.fakeip ?? false,
            ip: router?.ip ?? ""
        },
        exit: section == "" ? null : { section, answered: exit != null, ip: exit?.ip ?? "" }
    };
}

function wan_addresses() {
    let result = [];
    let add = (address) => { if (address != "" && index(result, address) < 0) push(result, address); };

    for (let name in [ "wan", "wwan" ]) {
        let interface_status = common.parse_json(exec.output([ "ubus", "-S", "call", "network.interface." + name, "status" ]));
        for (let key in [ "ipv4-address", "ipv6-address" ])
            for (let item in interface_status?.[key] ?? [])
                add(common.as_string(item?.address));
    }

    // The device the default routes leave through, so a WAN not called wan is found.
    for (let family in [ [ "-4", /(^|\n)[ \t]*inet[ \t]+([0-9.]+)\//g ], [ "-6", /(^|\n)[ \t]*inet6[ \t]+([^\/ \t]+)\//g ] ]) {
        let device = match(output([ "ip", family[0], "route", "show", "default" ]), /[ \t]dev[ \t]+([^ \t\n]+)/);
        if (device == null)
            continue;
        let argv = [ "ip", family[0], "addr", "show", "dev", device[1] ];
        if (family[0] == "-6")
            push(argv, "scope", "global");
        for (let found in match(output(argv), family[1]) ?? [])
            add(found[2]);
    }
    return join(" ", result);
}

function resolve_host(host) {
    host = replace(host, /^\[(.*)\]$/, "$1");
    if (host == "" || core_ip.valid_ip(host))
        return host;
    let reply = resolv.query([ host ], { type: [ "A", "AAAA" ], timeout: 2000, retries: 1 });
    return join(" ", sort(addresses(reply, [ "A", "AAAA" ])));
}

function firewall_opens(port, transports, input_chain) {
    return firewall.required_protocols_open(uci.section_objects("firewall", "rule"), port, transports) ||
        firewall.forkop_accepts_port(input_chain, singbox_constants.SERVER_FIREWALL_COMMENT, port, transports);
}

// The core's Tailscale endpoints by tag; none when the core cannot be asked.
function tailscale_endpoints() {
    let reply;
    try {
        reply = clash_api.request("GET", "/tailscale", "");
    }
    catch (e) {
        return {};
    }
    let result = {};
    for (let endpoint in common.parse_json(reply.status == 200 ? reply.body : "")?.endpoints ?? [])
        result[endpoint?.tag] = endpoint;
    return result;
}

// A Tailscale server dials out and listens on nothing, so it is judged by its state in the tailnet.
function tailscale_item(label, endpoint) {
    let running = endpoint?.state == "Running";
    let key_expiry = int(endpoint?.keyExpiry ?? 0);
    return {
        label,
        protocol: "tailscale",
        runtime: endpoint != null,
        state: endpoint?.state ?? "",
        connected: endpoint?.connected === true,
        name: endpoint?.name ?? "",
        exit_node_pending: running && endpoint.advertisesExitNode === true && endpoint.exitNodeApproved !== true,
        pending_routes: join(" ", map(filter(endpoint?.routes ?? [], (route) => route?.approved !== true), (route) => route.prefix)),
        key_expired: key_expiry > 0 && key_expiry < time()
    };
}

// A router whose only WAN address is the provider's shared one is behind its NAT, where no port
// can be opened.
function servers() {
    let config = runtime_config();
    let wan = wan_addresses();
    let wan_public = length(filter(common.words(wan), (address) => core_ip.valid_public_ip(address))) > 0;
    let behind_cgnat = !wan_public && length(filter(common.words(wan), (address) => core_ip.prefix_contains(CGNAT_RANGE, address))) > 0;
    let listeners = output([ "netstat", "-ln" ]);
    let owners = output([ "netstat", "-lnp" ]);
    let input_chain = null;
    let tailscale = null;
    let items = [];

    for (let section in uci.section_objects(CONFIG_NAME, "server")) {
        let protocol = common.option(section, "protocol", "vless");
        if (!common.bool_option(section, "enabled", false))
            continue;

        let label = connections.server_display_name(section);
        if (protocol == "tailscale") {
            tailscale ??= tailscale_endpoints();
            push(items, tailscale_item(label, tailscale[label]));
            continue;
        }
        let runtime = config_status.summary(config, server_rules.runtime_kind(protocol), label);
        let declared = protocol == "json_inbound";
        let listen = declared ? (runtime.listen || "::") : common.option(section, "listen", "::");
        let port = declared ? int(runtime.listen_port ?? 0) : int(common.option(section, "listen_port", "0"));
        let transports = declared ? [ "tcp", "udp" ] : runtime_servers.listen_transports(section);
        let open = filter(transports, (proto) => port > 0 && netstat.port_listening(listeners, listen, port, proto));
        let listening = declared ? length(open) > 0 : length(open) == length(transports);

        // A port another program holds reads as listening too.
        let holders = [];
        for (let proto in transports)
            push(holders, ...netstat.port_conflict_owners(owners, listen, port, proto));

        let exposed = !declared && server_rules.listen_requires_firewall(listen, wan);
        let firewall_open = true;
        if (exposed) {
            input_chain ??= output([ "nft", "list", "chain", "inet", "fw4", "input" ]);
            firewall_open = firewall_opens(port, join(" ", transports), input_chain);
        }

        let public_host = declared ? "" : common.option(section, "public_host", "");
        let public_ips = public_host == "" ? "" : resolve_host(public_host);
        let host = server_rules.public_host_flags(public_host, public_ips, wan, wan_public ? 1 : 0);
        push(items, {
            label,
            protocol,
            port,
            transports: join(" ", declared && listening ? open : transports),
            runtime: runtime.exists == 1,
            listening,
            owners: join(" ", netstat.sorted_unique(holders)),
            exposed,
            open_firewall: common.bool_option(section, "open_firewall", true),
            firewall_open,
            public_host,
            public_ips,
            resolved: host.resolved,
            public: host.public_ip,
            matches_wan: host.matches_wan
        });
    }
    return { wan, behind_cgnat, items };
}

return { paths, last_error, core, service, dns, traffic, servers };
