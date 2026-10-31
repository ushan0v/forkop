let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let constants = require("core.constants");
let core_ip = require("core.ip");
let uci = require("core.uci");
let connections = require("config.connections");
let singbox_constants = require("singbox.constants");
let nft_state = require("nft.state");
let nft_sections = require("nft.sections");

const CONFIG_NAME = "forkop";
const TABLE = constants.NFT_TABLE_NAME;
const RT_TABLE = constants.RT_TABLE_NAME;
const LOCAL4 = constants.NFT_LOCALV4_SET_NAME;
const LOCAL6 = constants.NFT_LOCALV6_SET_NAME;
const INTERFACES = constants.NFT_INTERFACE_SET_NAME;
const PAUSE_CHAIN = constants.NFT_PAUSE_CHAIN_NAME;
const FAKEIP_MARK = constants.NFT_FAKEIP_MARK;
const OUTBOUND_MARK = constants.NFT_OUTBOUND_MARK;
const ROUTER_MARK = constants.NFT_ROUTER_MARK;
const FAKEIP4 = singbox_constants.FAKEIP_INET4_RANGE;
const FAKEIP6 = singbox_constants.FAKEIP_INET6_RANGE;
const TPROXY_PORT = singbox_constants.TPROXY_INBOUND_PORT;
const TPROXY6_ADDRESS = singbox_constants.TPROXY_INBOUND6_ADDRESS;
// Before mwan3's rules, which start at 1001.
const BOUND_RULE_PRIORITY = "106";
const EXCLUDED4 = "forkop_excluded";
const EXCLUDED6 = "forkop_excluded6";
const ELEMENTS_PER_COMMAND = 5000;

const IPV4_SET = "{ type ipv4_addr; flags interval; auto-merge; }";
const IPV6_SET = "{ type ipv6_addr; flags interval; auto-merge; }";
const PORT_SET = "{ type inet_service; flags interval; auto-merge; }";
const IPV4_PORT_SET = "{ type ipv4_addr . inet_service; flags interval; auto-merge; }";
const IPV6_PORT_SET = "{ type ipv6_addr . inet_service; flags interval; auto-merge; }";
// The key carries the transport, so an address a rule set limits to UDP is not matched on TCP.
const IPV4_PROTO_PORT_SET = "{ type ipv4_addr . inet_proto . inet_service; flags interval; auto-merge; }";
const IPV6_PROTO_PORT_SET = "{ type ipv6_addr . inet_proto . inet_service; flags interval; auto-merge; }";

const LOCAL4_RANGES = [
    "0.0.0.0/8", "10.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24",
    "192.88.99.0/24", "192.168.0.0/16", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0-255.255.255.255"
];
const LOCAL6_RANGES = [ "::/128", "::1/128", "64:ff9b::/96", "100::/64", "2001:db8::/32", "fc00::/7", "fe80::/10", "ff00::/8" ];

let paths = {
    rt_tables: "/etc/iproute2/rt_tables"
};

let lines = null;
let skipped = null;

function nft(parts) {
    parts = map(parts, common.as_string);
    for (let part in parts)
        if (index(part, "\n") >= 0)
            die("An nft value carries a line break: " + part);
    push(lines, join(" ", parts));
}

function add_set(name, definition) {
    nft([ "add", "set", "inet", TABLE, name, definition ]);
}

function add_chain(name, definition) {
    nft([ "add", "chain", "inet", TABLE, name, definition ]);
}

function add_rule(chain, args) {
    nft([ "add", "rule", "inet", TABLE, chain, ...args ]);
}

function add_elements(set_name, elements) {
    for (let i = 0; i < length(elements); i += ELEMENTS_PER_COMMAND)
        nft([ "add", "element", "inet", TABLE, set_name, "{ " + join(",", slice(elements, i, i + ELEMENTS_PER_COMMAND)) + " }" ]);
}

function add_addresses(values, set4, set6, owner) {
    let family = { "4": [], "6": [] };
    for (let value in values) {
        let version = core_ip.ip_family(value);
        if (version == 0)
            push(skipped, owner + ": '" + value + "' is not an IP address or subnet and is ignored");
        else
            push(family[version], value);
    }

    add_elements(set4, family["4"]);
    add_elements(set6, family["6"]);
}

function csv_values(csv) {
    return filter(map(split(csv ?? "", ","), (value) => trim(replace(value, /\r/g, ""))), (value) => value != "");
}

function add_excluded_returns(chain, excluded) {
    if (length(excluded) > 0) {
        add_rule(chain, [ "ip", "saddr", "@" + EXCLUDED4, "counter", "return" ]);
        add_rule(chain, [ "ip6", "saddr", "@" + EXCLUDED6, "counter", "return" ]);
    }
}

function tproxy_target(family, port) {
    return family == 6 ? core_ip.format_ipv6_tproxy_target(TPROXY6_ADDRESS, port) : ":" + port;
}

function marked(mark) {
    return [ "meta", "mark", "&", mark, "==", mark ];
}

// A reply belongs to a connection the other side opened, or to one sing-box already holds:
// handed to TProxy, it finds no socket of its own and the connection dies.
const REPLY_RETURN = [ "ct", "direction", "reply", "return" ];

// Packets of a flow sing-box holds are marked from the flow: only its first packet is NATed,
// and a later one forwarded directly would let flow offloading take the whole connection.
function add_held_flow_rule(chain, mark) {
    add_rule(chain, [ "ct", "direction", "original", "ct", "mark", "&", mark, "==", mark,
        "meta", "mark", "set", mark, "counter", "accept" ]);
}

// While sing-box rebinds its listeners its traffic is dropped, not sent direct: a forwarded
// packet would be offloaded past this table for good.
function capture_command(active) {
    let chain = [ "inet", TABLE, PAUSE_CHAIN ];
    let commands = [ [ "flush", "chain", ...chain ] ];
    if (!active)
        push(commands, [ "add", "rule", ...chain, ...marked(FAKEIP_MARK), "counter", "drop" ],
            [ "add", "rule", ...chain, ...marked(ROUTER_MARK), "counter", "drop" ], [ "add", "rule", ...chain, "counter", "accept" ]);
    return [ "nft", join("; ", map(commands, (command) => join(" ", command))) ];
}

function add_base(settings, excluded_router, excluded) {
    let system_tproxy_port = singbox_constants.SYSTEM_TPROXY_INBOUND_PORT;

    nft([ "add", "table", "inet", TABLE ]);
    add_set(LOCAL4, IPV4_SET);
    add_elements(LOCAL4, LOCAL4_RANGES);
    add_set(LOCAL6, IPV6_SET);
    add_elements(LOCAL6, LOCAL6_RANGES);
    add_set(INTERFACES, "{ type ifname; flags interval; }");
    for (let name in common.words(common.option(settings, "source_network_interfaces", "br-lan")))
        add_elements(INTERFACES, [ name ]);

    if (length(excluded) > 0) {
        add_set(EXCLUDED4, IPV4_SET);
        add_set(EXCLUDED6, IPV6_SET);
        add_addresses(excluded, EXCLUDED4, EXCLUDED6, "Exclude devices from routing");
    }

    add_chain("mangle", "{ type filter hook prerouting priority -149; policy accept; }");
    add_chain("mangle_output", "{ type route hook output priority -150; policy accept; }");
    add_chain("priority_rules", "{ }");
    add_chain("priority_output_rules", "{ }");
    add_rule("priority_output_rules", [ "meta", "mark", "!=", "0", "return" ]);
    add_chain("proxy", "{ type filter hook prerouting priority -100; policy accept; }");
    add_chain(PAUSE_CHAIN, "{ }");

    add_chain("dns_redirect", "{ type nat hook prerouting priority " + constants.NFT_DNS_REDIRECT_PRIORITY + "; policy accept; }");
    add_rule("dns_redirect", [ "jump", PAUSE_CHAIN ]);
    add_excluded_returns("dns_redirect", excluded);
    for (let proto in [ "tcp", "udp" ])
        add_rule("dns_redirect", [ "iifname", "@" + INTERFACES, proto, "dport", "53", "counter", "redirect", "to", ":" + singbox_constants.SOURCE_DNS_INBOUND_PORT ]);

    add_held_flow_rule("mangle", FAKEIP_MARK);
    add_excluded_returns("mangle", excluded);
    add_rule("mangle", [ "ct", "status", "dnat", "return" ]);
    add_rule("mangle", REPLY_RETURN);
    // nft runs every nat chain at the NAT hook, after this chain, so a query a
    // section marked here would reach the TProxy inbound instead of the DNS one.
    add_rule("mangle", [ "iifname", "@" + INTERFACES, "meta", "l4proto", "{ tcp, udp }", "th", "dport", "53", "return" ]);
    add_rule("mangle", [ "iifname", "@" + INTERFACES, "ip", "daddr", "@" + LOCAL4, "return" ]);
    add_rule("mangle", [ "iifname", "@" + INTERFACES, "ip6", "daddr", "@" + LOCAL6, "return" ]);
    add_rule("mangle", [ "jump", "priority_rules" ]);
    for (let pair in [ [ "ip", FAKEIP4 ], [ "ip6", FAKEIP6 ] ])
        for (let proto in [ "tcp", "udp" ])
            add_rule("mangle", [ "iifname", "@" + INTERFACES, pair[0], "daddr", pair[1], "meta", "l4proto", proto, "meta", "mark", "set", FAKEIP_MARK, "counter" ]);

    add_rule("proxy", [ "jump", PAUSE_CHAIN ]);
    for (let mark in [ FAKEIP_MARK, ROUTER_MARK ])
        add_rule("proxy", [ ...marked(mark), "ct", "mark", "set", "ct", "mark", "|", mark ]);
    for (let family in [ 4, 6 ])
        for (let proto in [ "tcp", "udp" ])
            add_rule("proxy", [ "iifname", "lo", ...marked(ROUTER_MARK), "meta", "l4proto", proto,
                "tproxy", family == 6 ? "ip6" : "ip", "to", tproxy_target(family, system_tproxy_port), "counter", "accept" ]);
    for (let family in [ 4, 6 ])
        for (let proto in [ "tcp", "udp" ])
            add_rule("proxy", [ ...marked(FAKEIP_MARK), "meta", "l4proto", proto,
                "tproxy", family == 6 ? "ip6" : "ip", "to", tproxy_target(family, TPROXY_PORT), "counter" ]);

    add_held_flow_rule("mangle_output", ROUTER_MARK);
    if (excluded_router)
        add_rule("mangle_output", [ "counter", "return" ]);
    add_rule("mangle_output", REPLY_RETURN);
    add_rule("mangle_output", [ "ip", "daddr", "@" + LOCAL4, "return" ]);
    add_rule("mangle_output", [ "ip6", "daddr", "@" + LOCAL6, "return" ]);
    // Under its mask: mwan3 adds its own bits to the mark of what the router sends.
    add_rule("mangle_output", [ "meta", "mark", "&", OUTBOUND_MARK, "==", OUTBOUND_MARK, "counter", "return" ]);
    // The resolver's own upstream queries never go through a section.
    add_rule("mangle_output", [ "meta", "l4proto", "{ tcp, udp }", "th", "dport", "53", "return" ]);
    add_rule("mangle_output", [ "jump", "priority_output_rules" ]);
}

function create_section_sets(m) {
    let s = m.sets;
    if (m.needs_subnet_sets) {
        add_set(s.subnets, IPV4_SET);
        add_set(s.subnets6, IPV6_SET);
    }
    if (m.needs_ip_port_sets) {
        add_set(s.ip_ports, IPV4_PORT_SET);
        add_set(s.ip6_ports, IPV6_PORT_SET);
    }
    if (m.needs_proto_port_sets) {
        add_set(s.proto_ports, IPV4_PROTO_PORT_SET);
        add_set(s.proto6_ports, IPV6_PROTO_PORT_SET);
    }
    if (m.needs_port_set)
        add_set(s.ports, PORT_SET);
    if (m.needs_source_sets) {
        add_set(s.sources, IPV4_SET);
        add_set(s.sources6, IPV6_SET);
    }
    if (m.needs_fully_source_sets) {
        add_set(s.fully_sources, IPV4_SET);
        add_set(s.fully_sources6, IPV6_SET);
    }
}

// Bypass leaves FakeIP traffic alone: those addresses mean something only to sing-box.
function section_rule(m, family, match_args, match_source, mark) {
    let ip = family == 6 ? "ip6" : "ip";
    let args = [];
    if (match_source && m.needs_source_sets)
        push(args, ip, "saddr", "@" + (family == 6 ? m.sets.sources6 : m.sets.sources));
    push(args, ip, "daddr", "!=", "@" + (family == 6 ? LOCAL6 : LOCAL4));
    if (m.action == "bypass")
        push(args, ip, "daddr", "!=", family == 6 ? FAKEIP6 : FAKEIP4);
    push(args, ...match_args);
    if (m.action == "bypass")
        push(args, "counter", "accept");
    else
        push(args, "meta", "mark", "set", mark, "counter", "accept");
    return args;
}

function add_section_rule_pair(m, match4, match6) {
    if (!m.sources.selected || length(m.sources.ips) > 0)
        for (let family in [ 4, 6 ])
            add_rule("priority_rules", [ "iifname", "@" + INTERFACES, ...section_rule(m, family, family == 6 ? match6 : match4, true, FAKEIP_MARK) ]);
    if (!m.sources.selected || m.sources.system)
        for (let family in [ 4, 6 ])
            add_rule("priority_output_rules", section_rule(m, family, family == 6 ? match6 : match4, false, ROUTER_MARK));
}

function add_fully_routed_rules(m) {
    if (!m.fully.selected)
        return;
    let protocols = m.action == "bypass" ? [ "" ] : [ "tcp", "udp" ];
    let transport = (proto) => proto == "" ? [] : [ "meta", "l4proto", proto ];

    if (m.needs_fully_source_sets)
        for (let family in [ 4, 6 ])
            for (let proto in protocols)
                add_rule("priority_rules", [ "iifname", "@" + INTERFACES, family == 6 ? "ip6" : "ip", "saddr",
                    "@" + (family == 6 ? m.sets.fully_sources6 : m.sets.fully_sources), ...section_rule(m, family, transport(proto), false, FAKEIP_MARK) ]);

    if (m.fully.system)
        for (let family in [ 4, 6 ])
            for (let proto in protocols)
                add_rule("priority_output_rules", section_rule(m, family, transport(proto), false, ROUTER_MARK));
}

function add_section_rules(m) {
    let s = m.sets;
    create_section_sets(m);
    add_fully_routed_rules(m);

    let port = (proto) => [ proto, "dport", "@" + s.ports ];
    if (m.needs_subnet_sets && !m.needs_port_set)
        add_section_rule_pair(m, [ "ip", "daddr", "@" + s.subnets ], [ "ip6", "daddr", "@" + s.subnets6 ]);
    for (let proto in [ "tcp", "udp" ]) {
        if (m.needs_subnet_sets && m.needs_port_set)
            add_section_rule_pair(m, [ "ip", "daddr", "@" + s.subnets, ...port(proto) ], [ "ip6", "daddr", "@" + s.subnets6, ...port(proto) ]);
        else if (m.needs_port_set)
            add_section_rule_pair(m, port(proto), port(proto));
    }
    if (m.needs_ip_port_sets)
        for (let proto in [ "tcp", "udp" ])
            add_section_rule_pair(m, [ "ip", "daddr", ".", proto, "dport", "@" + s.ip_ports ], [ "ip6", "daddr", ".", proto, "dport", "@" + s.ip6_ports ]);
    if (m.needs_proto_port_sets)
        add_section_rule_pair(m, [ "ip", "daddr", ".", "meta", "l4proto", ".", "th", "dport", "@" + s.proto_ports ],
            [ "ip6", "daddr", ".", "meta", "l4proto", ".", "th", "dport", "@" + s.proto6_ports ]);
}

function add_fakeip_output() {
    for (let pair in [ [ "ip", FAKEIP4 ], [ "ip6", FAKEIP6 ] ])
        for (let proto in [ "tcp", "udp" ])
            add_rule("mangle_output", [ pair[0], "daddr", pair[1], "meta", "l4proto", proto, "meta", "mark", "set", ROUTER_MARK, "counter" ]);
}

// Only loopback is captured, so the resolver's upstream queries never come back here;
// sing-box marks its own sockets, so its queries to the resolver pass.
function add_router_dns(excluded_router) {
    add_chain("system_dns_redirect", "{ type nat hook output priority " + constants.NFT_SYSTEM_DNS_REDIRECT_PRIORITY + "; policy accept; }");
    add_rule("system_dns_redirect", [ "jump", PAUSE_CHAIN ]);
    if (excluded_router)
        add_rule("system_dns_redirect", [ "counter", "return" ]);
    add_rule("system_dns_redirect", [ "meta", "mark", "!=", "0", "return" ]);
    for (let address in [ [ "ip", "127.0.0.1" ], [ "ip6", "::1" ] ])
        for (let proto in [ "tcp", "udp" ])
            add_rule("system_dns_redirect", [ address[0], "daddr", address[1], proto, "dport", "53", "counter", "redirect", "to", ":" + singbox_constants.SYSTEM_DNS_INBOUND_PORT ]);
}

function fill_section_sets(section, m) {
    let s = m.sets;
    let owner = "Section '" + connections.section_display_name(section) + "'";
    if (m.needs_source_sets)
        add_addresses(m.sources.ips, s.sources, s.sources6, owner);
    if (m.needs_fully_source_sets)
        add_addresses(m.fully.ips, s.fully_sources, s.fully_sources6, owner);
    if (m.subnets != "")
        add_addresses(csv_values(m.subnets), s.subnets, s.subnets6, owner);
    if (m.needs_port_set)
        nft([ "add", "element", "inet", TABLE, s.ports, "{ " + m.ports + " }" ]);
}

// Returns { script, skipped, kept }; kept names the sets the rule-set worker fills.
function build() {
    let settings = uci.get_all(CONFIG_NAME, "settings") ?? {};
    let sections = uci.section_objects(CONFIG_NAME, "section");
    let planned = nft_sections.with_priority_sets(sections);
    if (planned.error != "")
        die(planned.error);

    let excluded = connections.excluded_devices(settings);
    let kept = [];
    for (let entry in planned.sections)
        push(kept, ...nft_sections.provider_sets(entry.matchers));
    lines = [];
    skipped = [];
    add_base(settings, excluded.router, excluded.addresses);
    for (let entry in planned.sections)
        add_section_rules(entry.matchers);
    add_fakeip_output();
    add_router_dns(excluded.router);
    for (let entry in planned.sections)
        fill_section_sets(entry.section, entry.matchers);

    let result = { script: join("\n", lines) + "\n", skipped, kept };
    lines = null;
    skipped = null;
    return result;
}

// The sets the rule-set worker fills keep their elements across a rebuild; emptied, they
// would let provider traffic go direct until the worker wrote them again.
function reset_lines(kept) {
    let result = [ "add table inet " + TABLE, "flush table inet " + TABLE ];
    for (let line in split(exec.output([ "nft", "-t", "list", "table", "inet", TABLE ]) ?? "", "\n")) {
        let item = match(trim(line), /^(set|chain) ([^ ]+) \{$/);
        if (item != null && (item[1] == "chain" || index(kept, item[2]) < 0))
            push(result, "delete " + item[1] + " inet " + TABLE + " " + item[2]);
    }
    return result;
}

function ensure_rt_table_entry() {
    let data = fs.readfile(paths.rt_tables) ?? "";
    if (nft_state.rt_table_has_entry(data, "105", RT_TABLE))
        return true;
    if (data != "" && substr(data, -1) != "\n")
        data += "\n";
    return common.write_file(paths.rt_tables, data + "105 " + RT_TABLE + "\n");
}

function remove_rt_table_entry() {
    let data = fs.readfile(paths.rt_tables);
    if (data == null || !nft_state.rt_table_has_entry(data, "105", RT_TABLE))
        return true;
    let kept = filter(split(data, "\n"), (line) => !nft_state.rt_table_has_entry(line, "105", RT_TABLE));
    return common.write_file(paths.rt_tables, join("\n", kept));
}

function ensure_route(present, argv, failed) {
    if (!present() && !exec.ok(argv) && !present())
        die(failed);
}

function ensure_tproxy_routing() {
    let ip = nft_state.IP_BIN;
    let mark = FAKEIP_MARK + "/" + FAKEIP_MARK;
    let router_mark = ROUTER_MARK + "/" + ROUTER_MARK;
    if (!ensure_rt_table_entry())
        die("Failed to add the " + RT_TABLE + " routing table to " + paths.rt_tables);
    ensure_route(() => nft_state.tproxy_route4_present(RT_TABLE), [ ip, "route", "add", "local", "0.0.0.0/0", "dev", "lo", "table", RT_TABLE ],
        "Failed to add the IPv4 TProxy route");
    ensure_route(() => nft_state.tproxy_marking_rule4_present(RT_TABLE, FAKEIP_MARK), [ ip, "-4", "rule", "add", "fwmark", mark, "table", RT_TABLE, "priority", "105" ],
        "Failed to add the IPv4 TProxy routing rule");
    ensure_route(() => nft_state.tproxy_marking_rule4_present(RT_TABLE, ROUTER_MARK), [ ip, "-4", "rule", "add", "fwmark", router_mark, "table", RT_TABLE, "priority", "105" ],
        "Failed to add the IPv4 TProxy routing rule of the router's own traffic");
    // With src_valid_mark on (tailscaled turns it on) the kernel checks the source of a packet it routes
    // to itself by a lookup from lo with the packet's mark, which rule 105 would answer with its own address.
    ensure_route(() => nft_state.source_check_rule4_present(FAKEIP_MARK), [ ip, "-4", "rule", "add", "iif", "lo", "fwmark", mark, "lookup", "main",
        "priority", nft_state.SOURCE_CHECK_PRIORITY ], "Failed to add the IPv4 routing rule for the source check");

    let ipv6 = nft_state.ipv6_interfaces() ?? [];
    if (length(ipv6) == 0)
        return;
    // The kernel refuses a route through lo while lo has IPv6 disabled.
    if (index(ipv6, "lo") < 0)
        die("IPv6 is disabled on the loopback interface lo but enabled on " + join(", ", ipv6) +
            ", so Forkop cannot route that IPv6 traffic. Disable IPv6 on every interface or enable it on lo");
    ensure_route(() => nft_state.tproxy_route6_present(RT_TABLE), [ ip, "-6", "route", "add", "local", "::/0", "dev", "lo", "table", RT_TABLE ],
        "Failed to add the IPv6 TProxy route");
    ensure_route(() => nft_state.tproxy_marking_rule6_present(RT_TABLE, FAKEIP_MARK), [ ip, "-6", "rule", "add", "fwmark", mark, "table", RT_TABLE, "priority", "105" ],
        "Failed to add the IPv6 TProxy routing rule");
    ensure_route(() => nft_state.tproxy_marking_rule6_present(RT_TABLE, ROUTER_MARK), [ ip, "-6", "rule", "add", "fwmark", router_mark, "table", RT_TABLE, "priority", "105" ],
        "Failed to add the IPv6 TProxy routing rule of the router's own traffic");
}

function bound_rule(family, action, device) {
    return [ nft_state.IP_BIN, family, "rule", action, "priority", BOUND_RULE_PRIORITY,
        "fwmark", OUTBOUND_MARK + "/" + OUTBOUND_MARK, "oif", device, "lookup", "main" ];
}

// mwan3 marks the router's own packets for the uplink its policy chose, whose table has no route
// through another one: what the core sends bound to a device goes by the main table before that.
function route_bound_devices(devices) {
    let ipv6 = length(nft_state.ipv6_interfaces() ?? []) > 0;
    for (let family in [ "-4", "-6" ]) {
        let name = family == "-6" ? "IPv6" : "IPv4";
        let wanted = family == "-4" || ipv6 ? devices : [];
        let present = nft_state.bound_rule_devices(family, BOUND_RULE_PRIORITY, OUTBOUND_MARK);
        for (let device in present)
            if (index(wanted, device) < 0 && !exec.ok(bound_rule(family, "del", device)))
                die("Failed to remove the " + name + " routing rule of interface " + device);
        for (let device in wanted)
            if (index(present, device) < 0 && !exec.ok(bound_rule(family, "add", device)))
                die("Failed to add the " + name + " routing rule of interface " + device);
    }
}

// nft repeats the refused command, which for a set line is thousands of addresses, so only
// the first line is the reason. A large transaction can also get nft killed for memory.
function refusal(result) {
    let signal = common.signal_from_status(result.status);
    if (signal == 9)
        return "nft ran out of memory; the rules and addresses of this configuration do not fit in this router's memory";
    if (signal != 0)
        return "nft was killed by signal " + signal;
    let first = filter(map(split(result.stderr, "\n"), (line) => trim(line)), (line) => line != "")[0];
    return first == null ? "no output" : substr(first, 0, 200);
}

function apply(built) {
    for (let message in built.skipped)
        exec.log("warn", message);
    ensure_tproxy_routing();
    let result = exec.feed([ "nft", "-f", "-" ], join("\n", reset_lines(built.kept)) + "\n" + built.script);
    if (result.status != 0)
        die("nft refused the ruleset: " + refusal(result));
}

function ensure_bridge_netfilter_disabled() {
    if (index(exec.output([ "lsmod" ]) ?? "", "br_netfilter") < 0 ||
        trim(exec.output([ "sysctl", "-n", "net.bridge.bridge-nf-call-iptables" ]) ?? "") != "1")
        return true;
    if (!exec.ok([ "sysctl", "-w", "net.bridge.bridge-nf-call-iptables=0" ]) ||
        !exec.ok([ "sysctl", "-w", "net.bridge.bridge-nf-call-ip6tables=0" ]))
        return false;
    exec.log("info", "Disabled bridge netfilter (net.bridge.bridge-nf-call-iptables) for transparent proxying");
    return true;
}

return { paths, build, apply, capture_command, refusal, ensure_tproxy_routing, route_bound_devices, ensure_bridge_netfilter_disabled, remove_rt_table_entry };
