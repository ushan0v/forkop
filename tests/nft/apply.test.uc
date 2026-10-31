let t = require("t");
let stub = require("stub");
let fixture = require("fixture");
let fs = require("fs");
let nft = require("nft.apply");

function built(data) {
    fixture.seed(data);
    return nft.build();
}

function script_lines(data) {
    return split(built(data).script, "\n");
}

function has(lines, line, label) {
    t.ok(index(lines, line) >= 0, (label ?? "missing line") + ": " + line);
}

function lacks(lines, text, label) {
    t.eq(filter(lines, (line) => index(line, text) >= 0), [], label ?? ("unexpected " + text));
}

function before(lines, first, second, label) {
    let a = index(lines, first), b = index(lines, second);
    t.ok(a >= 0 && b >= 0 && a < b, label + ": " + first + " before " + second);
}

const T = "add rule inet ForkopTable ";

t.test("the base table captures the source interfaces, FakeIP and the TProxy inbounds", () => {
    let lines = script_lines({ settings: { source_network_interfaces: "br-lan tun0" } });
    t.eq(lines[0], "add table inet ForkopTable");
    has(lines, "add set inet ForkopTable localv4 { type ipv4_addr; flags interval; auto-merge; }");
    has(lines, "add set inet ForkopTable localv6 { type ipv6_addr; flags interval; auto-merge; }");
    t.ok(length(filter(lines, (l) => index(l, "add element inet ForkopTable localv4 { 0.0.0.0/8,10.0.0.0/8,127.0.0.0/8") == 0)) == 1);
    has(lines, "add set inet ForkopTable forkop_interfaces { type ifname; flags interval; }");
    has(lines, "add element inet ForkopTable forkop_interfaces { br-lan }");
    has(lines, "add element inet ForkopTable forkop_interfaces { tun0 }");
    has(lines, "add chain inet ForkopTable mangle { type filter hook prerouting priority -149; policy accept; }", "mangle runs after the Tailscale connmark restore");
    has(lines, T + "priority_output_rules meta mark != 0 return", "a provider mark is preserved");
    has(lines, "add chain inet ForkopTable dns_redirect { type nat hook prerouting priority -101; policy accept; }");
    has(lines, T + "dns_redirect iifname @forkop_interfaces udp dport 53 counter redirect to :1603");
    has(lines, T + "dns_redirect iifname @forkop_interfaces tcp dport 53 counter redirect to :1603");
    has(lines, T + "mangle iifname @forkop_interfaces ip6 daddr @localv6 return", "local IPv6 is left alone");
    before(lines, T + "mangle iifname @forkop_interfaces meta l4proto { tcp, udp } th dport 53 return", T + "mangle jump priority_rules",
        "client DNS is left to the capture");
    has(lines, T + "mangle jump priority_rules");
    has(lines, T + "proxy meta mark & 0x04000000 == 0x04000000 meta l4proto tcp tproxy ip to :1602 counter");
    has(lines, T + "proxy meta mark & 0x04000000 == 0x04000000 meta l4proto tcp tproxy ip6 to [::1]:1602 counter");
    before(lines, T + "proxy iifname lo meta mark & 0x10000000 == 0x10000000 meta l4proto tcp tproxy ip to :1604 counter accept",
        T + "proxy meta mark & 0x04000000 == 0x04000000 meta l4proto tcp tproxy ip to :1602 counter", "System TProxy classification");
    has(lines, T + "proxy iifname lo meta mark & 0x10000000 == 0x10000000 meta l4proto tcp tproxy ip6 to [::1]:1604 counter accept");
    has(lines, T + "mangle_output meta mark & 0x08000000 == 0x08000000 counter return", "sing-box's own traffic, whatever bits mwan3 adds");
    before(lines, T + "mangle_output meta l4proto { tcp, udp } th dport 53 return", T + "mangle_output jump priority_output_rules",
        "the resolver reaches its upstream directly");
    has(lines, T + "mangle_output jump priority_output_rules");
    has(lines, "add chain inet ForkopTable system_dns_redirect { type nat hook output priority -100; policy accept; }",
        "the router's own lookups are captured whatever the sections say");
    for (let address in [ "ip daddr 127.0.0.1", "ip6 daddr ::1" ])
        for (let proto in [ "tcp", "udp" ])
            before(lines, T + "system_dns_redirect meta mark != 0 return",
                T + "system_dns_redirect " + address + " " + proto + " dport 53 counter redirect to :1605", "sing-box asking the resolver itself passes");
    lacks(lines, "system_dns_redirect udp dport 53", "the resolver's upstream queries are not taken back");
    for (let pair in [ [ "ip", "198.18.0.0/16" ], [ "ip6", "2001:2::/112" ] ])
        for (let proto in [ "tcp", "udp" ])
            has(lines, T + "mangle_output " + pair[0] + " daddr " + pair[1] + " meta l4proto " + proto + " meta mark set 0x10000000 counter",
                "the router's own FakeIP traffic");
    for (let absent in [ "forkop_subnets", "forkop_ports", "forkop_ip_ports", "forkop_dns_sources", "forkop_excluded" ])
        lacks(lines, absent);
});

t.test("a flow handed to sing-box stays captured whatever the sets hold, and a pause holds back what goes to it", () => {
    let lines = script_lines({ settings: { routing_excluded_ips: "192.168.1.50 @system" } });
    let held = (mark) => "ct direction original ct mark & " + mark + " == " + mark + " meta mark set " + mark + " counter accept";
    for (let pair in [ [ "mangle", "0x04000000" ], [ "mangle_output", "0x10000000" ] ]) {
        let first = filter(lines, (line) => index(line, T + pair[0] + " ") == 0)[0];
        t.eq(first, T + pair[0] + " " + held(pair[1]), pair[0] + ": a held flow is not matched against the sets or the exclusions");
    }
    has(lines, "add chain inet ForkopTable capture_pause { }");
    for (let chain in [ "proxy", "dns_redirect", "system_dns_redirect" ]) {
        let first = filter(lines, (line) => index(line, T + chain + " ") == 0)[0];
        t.eq(first, T + chain + " jump capture_pause", chain + " asks the pause first");
    }
    for (let mark in [ "0x04000000", "0x10000000" ])
        before(lines, T + "proxy meta mark & " + mark + " == " + mark + " ct mark set ct mark | " + mark,
            T + "proxy iifname lo meta mark & 0x10000000 == 0x10000000 meta l4proto tcp tproxy ip to :1604 counter accept",
            "the flow is marked before any TProxy rule accepts its packet");

    t.eq(nft.capture_command(true), [ "nft", "flush chain inet ForkopTable capture_pause" ]);
    t.eq(nft.capture_command(false), [ "nft", "flush chain inet ForkopTable capture_pause; " +
        "add rule inet ForkopTable capture_pause meta mark & 0x04000000 == 0x04000000 counter drop; " +
        "add rule inet ForkopTable capture_pause meta mark & 0x10000000 == 0x10000000 counter drop; " +
        "add rule inet ForkopTable capture_pause counter accept" ], "paused: traffic for sing-box waits, lookups go to their resolver");
});

t.test("excluded devices leave every capture before anything matches them", () => {
    let lines = script_lines({ settings: { routing_excluded_ips: "192.168.1.50 2001:db8::5/128" } });
    has(lines, "add set inet ForkopTable forkop_excluded { type ipv4_addr; flags interval; auto-merge; }");
    has(lines, "add element inet ForkopTable forkop_excluded { 192.168.1.50 }");
    has(lines, "add element inet ForkopTable forkop_excluded6 { 2001:db8::5/128 }");
    before(lines, T + "dns_redirect ip saddr @forkop_excluded counter return", T + "dns_redirect iifname @forkop_interfaces tcp dport 53 counter redirect to :1603",
        "the DNS exclusion");
    before(lines, T + "mangle ip saddr @forkop_excluded counter return", T + "mangle jump priority_rules", "the capture exclusion");
    has(lines, T + "mangle ip6 saddr @forkop_excluded6 counter return");
    lacks(lines, T + "mangle_output counter return", "the router is not excluded with them");
});

t.test("the excluded System device keeps the router's own traffic and lookups out of every capture", () => {
    let result = built({ settings: { routing_excluded_ips: "@system 192.168.1.50" } });
    let lines = split(result.script, "\n");
    t.eq(result.skipped, [], "the System device is not an address to skip");
    has(lines, "add element inet ForkopTable forkop_excluded { 192.168.1.50 }");
    before(lines, T + "mangle_output counter return", T + "mangle_output ip daddr @localv4 return", "the router's traffic");
    before(lines, T + "system_dns_redirect counter return", T + "system_dns_redirect meta mark != 0 return", "the router's lookups");
    lacks(lines, T + "mangle counter return", "clients stay captured");
    lacks(lines, T + "dns_redirect counter return", "client DNS stays captured");
});

function priority_sections() {
    return [
        { ".name": "bypass_first", action: "bypass", destinations: "198.51.100.0/24", fully_routed_ips: [ "192.168.1.10/32", "2001:db8::10/128", "@system" ] },
        { ".name": "wide_proxy", action: "connection", destinations: "0.0.0.0/0", fully_routed_ips: [ "192.168.1.20/32", "2001:db8::20/128", "@system" ] },
        { ".name": "port_bypass", action: "bypass", ports: [ "8443" ] },
        { ".name": "system_filter", action: "connection", destinations: "203.0.113.0/24", source_ip_cidr: [ "@system" ] },
        { ".name": "client_filter", action: "connection", destinations: "192.0.2.0/24", source_ip_cidr: [ "192.168.1.50/32" ] },
        { ".name": "builtin_subnets", action: "connection", community_lists: [ "discord" ] },
        { ".name": "ip_and_ports", action: "connection", destinations: "203.0.113.0/24", ports: [ "8080" ] }
    ];
}

t.test("an answer to a connection the other side opened never reaches the section rules", () => {
    let lines = script_lines({ settings: {}, section: priority_sections() });
    before(lines, T + "mangle ct direction reply return", T + "mangle jump priority_rules", "a device answering from behind the router");
    before(lines, T + "mangle_output ct direction reply return", T + "mangle_output jump priority_output_rules",
        "a server on the router and sing-box answering a client it captured");
});

t.test("section rules keep configuration order and reach only the traffic their devices send", () => {
    let lines = script_lines({ settings: {}, section: priority_sections() });
    let local = "ip daddr != @localv4 ";
    has(lines, "add set inet ForkopTable forkop_rule_bypass_first_subnets { type ipv4_addr; flags interval; auto-merge; }");
    has(lines, T + "priority_rules iifname @forkop_interfaces ip saddr @forkop_rule_bypass_first_fully_sources " + local + "ip daddr != 198.18.0.0/16 counter accept",
        "a fully routed bypass takes real addresses");
    has(lines, T + "priority_rules iifname @forkop_interfaces ip6 saddr @forkop_rule_bypass_first_fully_sources6 ip6 daddr != @localv6 ip6 daddr != 2001:2::/112 counter accept");
    has(lines, T + "priority_rules iifname @forkop_interfaces ip saddr @forkop_rule_wide_proxy_fully_sources " + local + "meta l4proto tcp meta mark set 0x04000000 counter accept");
    has(lines, T + "priority_output_rules " + local + "ip daddr != 198.18.0.0/16 counter accept", "the System device fully routed around the proxy");
    has(lines, T + "priority_output_rules " + local + "meta l4proto tcp meta mark set 0x10000000 counter accept", "the System device fully routed through it");
    has(lines, T + "priority_output_rules " + local + "ip daddr @forkop_rule_system_filter_subnets meta mark set 0x10000000 counter accept");
    has(lines, T + "priority_rules iifname @forkop_interfaces ip saddr @forkop_rule_client_filter_sources " + local + "ip daddr @forkop_rule_client_filter_subnets meta mark set 0x04000000 counter accept");
    t.eq(filter(lines, (l) => index(l, "priority_rules iifname") >= 0 && index(l, "system_filter") >= 0), [], "a System-only filter on forwarded traffic");
    t.eq(filter(lines, (l) => index(l, "priority_output_rules") >= 0 && index(l, "client_filter") >= 0), [], "a client filter on the router's traffic");
    lacks(lines, "@system", "the System sentinel is not an address");
    has(lines, T + "priority_rules iifname @forkop_interfaces " + local + "ip daddr != 198.18.0.0/16 tcp dport @forkop_rule_port_bypass_ports counter accept");
    before(lines, T + "priority_rules iifname @forkop_interfaces " + local + "ip daddr != 198.18.0.0/16 ip daddr @forkop_rule_bypass_first_subnets counter accept",
        T + "priority_rules iifname @forkop_interfaces " + local + "ip daddr @forkop_rule_wide_proxy_subnets meta mark set 0x04000000 counter accept", "bypass order");

    has(lines, "add set inet ForkopTable forkop_rule_builtin_subnets_ip_ports { type ipv4_addr . inet_service; flags interval; auto-merge; }",
        "a built-in list's port-scoped addresses have a set a rule reads");
    has(lines, T + "priority_rules iifname @forkop_interfaces " + local + "ip daddr . udp dport @forkop_rule_builtin_subnets_ip_ports meta mark set 0x04000000 counter accept");
    has(lines, "add set inet ForkopTable forkop_rule_builtin_subnets_proto6_ports { type ipv6_addr . inet_proto . inet_service; flags interval; auto-merge; }");
    t.eq(length(filter(lines, (l) => index(l, "th dport @forkop_rule_builtin_subnets_proto_ports") >= 0)), 2, "one rule per chain covers both transports");
    has(lines, T + "priority_rules iifname @forkop_interfaces " + local + "ip daddr @forkop_rule_ip_and_ports_subnets tcp dport @forkop_rule_ip_and_ports_ports meta mark set 0x04000000 counter accept",
        "an address with a port is matched against both plain sets");
    has(lines, T + "priority_output_rules ip6 daddr != @localv6 ip6 daddr @forkop_rule_ip_and_ports_subnets6 udp dport @forkop_rule_ip_and_ports_ports meta mark set 0x10000000 counter accept");
    lacks(lines, "ip daddr @forkop_rule_ip_and_ports_subnets meta mark", "an address with a port is never matched without it");
    lacks(lines, T + "priority_rules iifname @forkop_interfaces " + local + "tcp dport @forkop_rule_ip_and_ports_ports", "a port next to an address on its own");

    for (let absent in [ "forkop_rule_port_bypass_subnets", "forkop_rule_port_bypass_sources", "forkop_rule_bypass_first_ports",
        "forkop_rule_bypass_first_sources", "forkop_rule_client_filter_fully_sources", "forkop_rule_system_filter_sources",
        "forkop_rule_ip_and_ports_ip_ports", "forkop_rule_ip_and_ports_proto_ports",
        "forkop_rule_bypass_first_proto_ports", "forkop_rule_builtin_subnets_ports" ])
        lacks(lines, "add set inet ForkopTable " + absent + " ", "no rule reads " + absent);
});

t.test("the sets are filled in the same transaction from what the configuration lists", () => {
    let lines = script_lines({ settings: {}, section: [
        { ".name": "disabled", enabled: "0", action: "connection", destinations: "192.0.2.1", ports: [ "53" ] },
        { ".name": "inline", action: "connection", destinations: "198.51.100.1\nexample.org\n203.0.113.0/24, 2001:db8::1", source_ip_cidr: [ "192.168.1.60/32" ],
            ports: [ "80", "443-444" ], fully_routed_ips: [ "192.168.1.20/32", "192.168.1.20/32", "2001:db8::20/128", "@system" ] },
        { ".name": "inline_no_ports", action: "bypass", destinations: "198.51.100.200 2001:db8::200", fully_routed_ips: [ "192.168.1.21/32" ] },
        { ".name": "ports_only", action: "connection", ports: [ "53", "853", "5353", "853" ] },
        { ".name": "ports_with_domain", action: "connection", destinations: "example.org", ports: [ "8443" ] },
        { ".name": "dns_only", action: "dns", destinations: "dns-only.example\n192.0.2.53", fully_routed_ips: [ "192.168.1.53/32" ] },
        { ".name": "vpn", action: "connection", fully_routed_ips: [ "@system" ] }
    ] });
    has(lines, "add element inet ForkopTable forkop_rule_inline_subnets { 198.51.100.1,203.0.113.0/24 }", "addresses and ports are not multiplied");
    has(lines, "add element inet ForkopTable forkop_rule_inline_subnets6 { 2001:db8::1 }");
    has(lines, "add element inet ForkopTable forkop_rule_inline_ports { 80,443-444 }");
    lacks(lines, "forkop_rule_inline_ip_ports", "only a provider limits addresses to ports of its own");
    has(lines, "add element inet ForkopTable forkop_rule_inline_no_ports_subnets { 198.51.100.200 }");
    has(lines, "add element inet ForkopTable forkop_rule_inline_no_ports_subnets6 { 2001:db8::200 }");
    has(lines, "add element inet ForkopTable forkop_rule_ports_only_ports { 53,853,5353 }");
    has(lines, "add element inet ForkopTable forkop_rule_inline_fully_sources { 192.168.1.20/32 }");
    has(lines, "add element inet ForkopTable forkop_rule_inline_fully_sources6 { 2001:db8::20/128 }");
    has(lines, "add element inet ForkopTable forkop_rule_inline_sources { 192.168.1.60/32 }");
    before(lines, "add set inet ForkopTable forkop_rule_inline_subnets { type ipv4_addr; flags interval; auto-merge; }",
        "add element inet ForkopTable forkop_rule_inline_subnets { 198.51.100.1,203.0.113.0/24 }", "a set exists before it is filled");
    lacks(lines, "192.0.2.1", "a disabled section");
    lacks(lines, "forkop_rule_ports_with_domain_ports", "a port next to a domain is sing-box's to match");
    lacks(lines, "192.0.2.53", "a DNS section's addresses");
    lacks(lines, "@system");
});

t.test("the script is the same for the same configuration and moves with anything nft matches on", () => {
    let base = { source_network_interfaces: "br-lan" };
    let script = (sections, settings) => built({ settings: settings ?? base, section: sections ?? [] }).script;
    let baseline = script();
    t.eq(script(), baseline);
    for (let section in [
        { ".name": "s", action: "connection" },
        { ".name": "s", action: "connection", destinations: "a.example\nb.example" },
        { ".name": "s", action: "connection", label: "Renamed" },
        { ".name": "s", enabled: "0", action: "connection", destinations: "192.0.2.0/24" },
        { ".name": "s", action: "connection", rule_set: "https://example.com/domains.lst" }
    ])
        t.eq(script([ section ]), baseline, "nothing of " + sprintf("%J", section) + " reaches nft");
    for (let section in [
        { ".name": "s", action: "connection", destinations: "192.0.2.0/24" },
        { ".name": "s", action: "connection", ports: "443" },
        { ".name": "s", action: "connection", rule_set_with_subnets: "https://example.com/subnets.srs" },
        { ".name": "s", action: "connection", community_lists: "telegram" },
        { ".name": "s", action: "bypass", fully_routed_ips: "192.168.1.10/32" }
    ])
        t.ok(script([ section ]) != baseline, sprintf("%J", section) + " reaches nft");
    t.ok(script(null, { source_network_interfaces: "br-lan tun0" }) != baseline);
    t.ok(script([ { ".name": "s", action: "connection", destinations: "192.0.2.0/24" } ]) != script([ { ".name": "s", action: "connection", destinations: "198.51.100.0/24" } ]),
        "the elements are part of the table");
});

t.test("a value nft cannot take is left out and reported when the table is applied", () => {
    let result = built({ settings: { routing_excluded_ips: "192.168.1.50 phone" } });
    t.eq(result.skipped, [ "Exclude devices from routing: 'phone' is not an IP address or subnet and is ignored" ]);
    t.contains(split(result.script, "\n"), "add element inet ForkopTable forkop_excluded { 192.168.1.50 }");
});

function routing(ip_state) {
    let dir = stub.tmpdir();
    nft.paths.rt_tables = dir + "/rt_tables";
    fixture.kernel_ipv6(ip_state != null && exists(ip_state, "ipv6") ? ip_state.ipv6 : { lo: "0", "br-lan": "0" });
    let logs = [];
    let handlers = [
        stub.logger(logs),
        [ "/sbin/ip route list table forkop", { stdout: ip_state?.route4 ?? "" } ],
        [ "/sbin/ip -6 route list table forkop", { stdout: ip_state?.route6 ?? "" } ],
        [ "/sbin/ip -4 rule list table forkop", { stdout: ip_state?.rule4 ?? "" } ],
        [ "/sbin/ip -6 rule list table forkop", { stdout: ip_state?.rule6 ?? "" } ],
        [ "/sbin/ip -4 rule list priority 104", { stdout: ip_state?.rule104 ?? "" } ],
        [ /'\/sbin\/ip'.* 'add' /, {} ],
        [ "nft -t list table inet ForkopTable", { status: 1 } ],
        [ /^'nft' '-f' '-'/, { status: ip_state?.nft_status ?? 0 } ]
    ];
    return { dir, logs, handlers };
}

t.test("applying the table sets up its routing once and hands nft the whole script", () => {
    fixture.seed({ settings: {} });
    let r = routing();
    stub.commands(r.handlers);
    nft.apply(nft.build());
    let calls = stub.calls();
    stub.restore();
    t.eq(fs.readfile(nft.paths.rt_tables), "105 forkop\n");
    let commands = map(calls, (c) => join(" ", c.argv));
    for (let line in [ "/sbin/ip route add local 0.0.0.0/0 dev lo table forkop", "/sbin/ip -6 route add local ::/0 dev lo table forkop",
        "/sbin/ip -4 rule add fwmark 0x04000000/0x04000000 table forkop priority 105", "/sbin/ip -6 rule add fwmark 0x04000000/0x04000000 table forkop priority 105",
        "/sbin/ip -4 rule add fwmark 0x10000000/0x10000000 table forkop priority 105", "/sbin/ip -6 rule add fwmark 0x10000000/0x10000000 table forkop priority 105",
        "/sbin/ip -4 rule add iif lo fwmark 0x04000000/0x04000000 lookup main priority 104" ])
        t.contains(commands, line);
    t.eq(filter(commands, (line) => index(line, "-6 rule add iif lo") >= 0), [], "IPv6 checks no source by a lookup");
    let transactions = filter(calls, (c) => c.argv[0] == "nft" && c.argv[1] == "-f");
    t.eq(length(transactions), 1, "one transaction");
    t.eq(split(transactions[0].stdin, "\n")[0], "add table inet ForkopTable");
    t.eq(r.logs, [], "setting the routing up is a routine step and is not reported");

    let present = routing({ route4: "local default dev lo scope host", route6: "local default dev lo metric 1024 pref medium",
        rule4: "105: from all fwmark 0x4000000/0x4000000 lookup forkop\n105: from all fwmark 0x10000000/0x10000000 lookup forkop",
        rule6: "105: from all fwmark 0x4000000/0x4000000 lookup podkop\n105: from all fwmark 0x10000000/0x10000000 lookup podkop",
        rule104: "104:\tfrom all fwmark 0x4000000/0x4000000 iif lo lookup main" });
    fs.writefile(nft.paths.rt_tables, "105 forkop\n");
    stub.commands(present.handlers);
    nft.apply(nft.build());
    commands = stub.command_lines();
    stub.restore();
    t.eq(filter(commands, (line) => index(line, " add ") >= 0), [], "routing that is in place is left alone");
    t.eq(present.logs, [], "and nothing is reported about it");
});

t.test("a router with IPv6 off everywhere, or a kernel without IPv6, gets IPv4 routing only", () => {
    fixture.seed({ settings: {} });
    for (let ipv6 in [ { lo: "1", "br-lan": "1", wan: "1" }, null ]) {
        let r = routing({ ipv6: ipv6 });
        stub.commands(r.handlers);
        nft.apply(nft.build());
        let calls = stub.calls();
        stub.restore();
        let commands = map(calls, (c) => join(" ", c.argv));
        t.contains(commands, "/sbin/ip route add local 0.0.0.0/0 dev lo table forkop");
        t.contains(commands, "/sbin/ip -4 rule add fwmark 0x04000000/0x04000000 table forkop priority 105");
        t.contains(commands, "/sbin/ip -4 rule add fwmark 0x10000000/0x10000000 table forkop priority 105");
        t.contains(commands, "/sbin/ip -4 rule add iif lo fwmark 0x04000000/0x04000000 lookup main priority 104");
        t.eq(filter(commands, (line) => index(line, " -6 ") >= 0), [], "nothing is asked of IPv6");
        t.eq(length(filter(calls, (c) => c.argv[0] == "nft" && c.argv[1] == "-f")), 1, "the table is applied");
    }
});

t.test("IPv6 left on some interfaces but off on lo is refused, since that traffic would bypass Forkop", () => {
    fixture.seed({ settings: {} });
    let r = routing({ ipv6: { lo: "1", "br-lan": "0", wan: "0", "wan.30": "1" } });
    stub.commands(r.handlers);
    let e = t.throws(() => nft.apply(nft.build()));
    let calls = stub.calls();
    stub.restore();
    t.eq(e.message, "IPv6 is disabled on the loopback interface lo but enabled on br-lan, wan, so Forkop cannot route that IPv6 traffic. " +
        "Disable IPv6 on every interface or enable it on lo");
    t.eq(filter(calls, (c) => c.argv[0] == "nft" && c.argv[1] == "-f"), [], "the table is not applied");
});

const BOUND = "priority 106 fwmark 0x08000000/0x08000000 oif ";

// The rules route_bound_devices finds at its priority, as iproute2 lists them; no_ipv6 is a
// kernel without IPv6, whose rule list fails.
function bound_rules(options) {
    fixture.kernel_ipv6(options?.no_ipv6 ? null : options?.ipv6 ?? { lo: "0", "br-lan": "0" });
    stub.commands([
        [ "/sbin/ip -4 rule list priority 106", { stdout: options?.listed4 ?? "" } ],
        [ "/sbin/ip -6 rule list priority 106", options?.no_ipv6 ? { status: 2 } : { stdout: options?.listed6 ?? "" } ],
        [ (argv) => argv[0] == "/sbin/ip" && argv[2] == "rule" && (argv[3] == "add" || argv[3] == "del"), { status: options?.refused ? 2 : 0 } ]
    ]);
}

function rule_changes() {
    let lines = filter(stub.command_lines(), (line) => match(line, / rule (add|del) /) != null);
    stub.restore();
    return map(lines, (line) => replace(line, BOUND, "... "));
}

t.test("what the core sends bound to a device goes by the main table, in both families", () => {
    bound_rules();
    nft.route_bound_devices([ "eth1", "pppoe-wan" ]);
    t.eq(rule_changes(), [
        "/sbin/ip -4 rule add ... eth1 lookup main", "/sbin/ip -4 rule add ... pppoe-wan lookup main",
        "/sbin/ip -6 rule add ... eth1 lookup main", "/sbin/ip -6 rule add ... pppoe-wan lookup main"
    ]);
});

t.test("the rules follow the devices, and other rules at that priority are left alone", () => {
    let listed = "106:\tfrom all fwmark 0x8000000/0x8000000 oif eth1 lookup main\n" +
        "106:\tfrom all fwmark 0x8000000/0x8000000 oif gone0 [detached] lookup main\n" +
        "106:\tfrom all fwmark 0x200000/0x200000 oif usb0 lookup main\n" +
        "106:\tfrom all oif wwan0 lookup 100\n";
    bound_rules({ listed4: listed, listed6: listed });
    nft.route_bound_devices([ "eth1", "wwan0" ]);
    t.eq(rule_changes(), [
        "/sbin/ip -4 rule del ... gone0 lookup main", "/sbin/ip -4 rule add ... wwan0 lookup main",
        "/sbin/ip -6 rule del ... gone0 lookup main", "/sbin/ip -6 rule add ... wwan0 lookup main"
    ]);

    bound_rules({ listed4: listed, listed6: listed });
    nft.route_bound_devices([]);
    t.eq(rule_changes(), [
        "/sbin/ip -4 rule del ... eth1 lookup main", "/sbin/ip -4 rule del ... gone0 lookup main",
        "/sbin/ip -6 rule del ... eth1 lookup main", "/sbin/ip -6 rule del ... gone0 lookup main"
    ], "none bound: every one of them goes");
});

t.test("IPv6 off leaves only IPv4 rules, and a kernel without IPv6 is asked nothing of it", () => {
    let listed = "106:\tfrom all fwmark 0x8000000/0x8000000 oif eth1 lookup main\n";
    bound_rules({ ipv6: { lo: "1", "br-lan": "1", eth1: "1" }, listed6: listed });
    nft.route_bound_devices([ "eth1" ]);
    t.eq(rule_changes(), [ "/sbin/ip -4 rule add ... eth1 lookup main", "/sbin/ip -6 rule del ... eth1 lookup main" ]);

    bound_rules({ no_ipv6: true });
    nft.route_bound_devices([ "eth1" ]);
    t.eq(rule_changes(), [ "/sbin/ip -4 rule add ... eth1 lookup main" ]);
});

t.test("a rule the kernel refuses fails with its family and interface", () => {
    bound_rules({ refused: true });
    let e = t.throws(() => nft.route_bound_devices([ "eth1" ]));
    stub.restore();
    t.eq(e.message, "Failed to add the IPv4 routing rule of interface eth1");
});

t.test("a rebuilt table keeps what the rule-set worker wrote and defines everything else again", () => {
    fixture.seed({ settings: {}, section: [
        { ".name": "fed", action: "connection", community_lists: [ "telegram" ], destinations: "192.0.2.0/24" },
        { ".name": "own", action: "connection", destinations: "198.51.100.0/24" }
    ] });
    let result = nft.build();
    let fed = [ "subnets", "subnets6", "ip_ports", "ip6_ports", "proto_ports", "proto6_ports" ];
    t.eq(result.kept, map(fed, (suffix) => "forkop_rule_fed_" + suffix), "only a section a provider feeds has sets to keep");
    t.eq(split(result.script, "\n")[0], "add table inet ForkopTable");

    let live = "table inet ForkopTable {\n\tset localv4 {\n\t\ttype ipv4_addr\n\t}\n\tset forkop_rule_fed_subnets {\n\t\ttype ipv4_addr\n\t}\n" +
        "\tset forkop_rule_fed_proto_ports {\n\t\ttype ipv4_addr . inet_proto . inet_service\n\t}\n\tset forkop_rule_own_subnets {\n\t}\n" +
        "\tset forkop_rule_gone_subnets {\n\t}\n\tchain mangle {\n\t\ttype filter hook prerouting priority mangle + 1; policy accept;\n\t}\n" +
        "\tchain priority_rules {\n\t}\n}\n";
    let r = routing({ route4: "local default dev lo scope host", route6: "local default dev lo metric 1024 pref medium",
        rule4: "105: from all fwmark 0x4000000/0x4000000 lookup forkop", rule6: "105: from all fwmark 0x4000000/0x4000000 lookup forkop" });
    fs.writefile(nft.paths.rt_tables, "105 forkop\n");
    stub.commands([ [ "nft -t list table inet ForkopTable", { stdout: live } ], ...r.handlers ]);
    nft.apply(result);
    let fed_script = filter(stub.calls(), (c) => c.argv[1] == "-f")[0].stdin;
    stub.restore();
    let lines = split(fed_script, "\n");
    t.eq(slice(lines, 0, 7), [ "add table inet ForkopTable", "flush table inet ForkopTable",
        "delete set inet ForkopTable localv4", "delete set inet ForkopTable forkop_rule_own_subnets", "delete set inet ForkopTable forkop_rule_gone_subnets",
        "delete chain inet ForkopTable mangle", "delete chain inet ForkopTable priority_rules" ],
        "the rules go, every chain is defined again, and a set goes unless the worker fills it");
    has(lines, "add set inet ForkopTable forkop_rule_fed_subnets { type ipv4_addr; flags interval; auto-merge; }", "a kept set is declared as before");
    lacks(lines, "flush set", "a kept set keeps its addresses");
    t.eq(join("\n", slice(lines, 7)), result.script, "followed by the table as built");

    stub.commands([ [ "nft -t list table inet ForkopTable", { status: 1 } ], ...r.handlers ]);
    nft.apply(result);
    fed_script = filter(stub.calls(), (c) => c.argv[1] == "-f")[0].stdin;
    stub.restore();
    t.eq(slice(split(fed_script, "\n"), 0, 3), [ "add table inet ForkopTable", "flush table inet ForkopTable", "add table inet ForkopTable" ],
        "a missing table has nothing to take apart");
});

t.test("a value left out is a warning each time the table is applied", () => {
    let result = built({ settings: { routing_excluded_ips: "192.168.1.50 phone" } });
    let r = routing();
    stub.commands(r.handlers);
    nft.apply(result);
    stub.restore();
    t.eq(r.logs, [ "[warn] Exclude devices from routing: 'phone' is not an IP address or subnet and is ignored" ]);
});

t.test("a refused transaction fails with the first line nft gave", () => {
    fixture.seed({ settings: {} });
    let r = routing({ route4: "local default dev lo scope host", route6: "local default dev lo metric 1024 pref medium",
        rule4: "105: from all fwmark 0x4000000/0x4000000 lookup forkop", rule6: "105: from all fwmark 0x4000000/0x4000000 lookup forkop" });
    fs.writefile(nft.paths.rt_tables, "105 forkop\n");
    stub.commands([ [ /^'nft' '-f' '-'/, (argv, command) => {
        fs.writefile(match(command, /2>'([^']+)'/)[1], "Error: syntax error, unexpected junk\nadd element inet ForkopTable localv4 { junk }\n");
        return { status: 1 };
    } ], ...r.handlers ]);
    let e = t.throws(() => nft.apply(nft.build()));
    stub.restore();
    t.eq(e.message, "nft refused the ruleset: Error: syntax error, unexpected junk");
});

t.test("bridge netfilter is switched off only where it is on", () => {
    let logs = [];
    let calls = (lsmod) => {
        stub.commands([ [ "lsmod", { stdout: lsmod } ], [ "sysctl -n", { stdout: "1\n" } ], [ "sysctl -w", {} ], stub.logger(logs) ]);
        nft.ensure_bridge_netfilter_disabled();
        let lines = stub.command_lines();
        stub.restore();
        return filter(lines, (line) => substr(line, 0, 6) == "sysctl");
    };
    t.eq(calls("br_netfilter 32768 0\n"), [ "sysctl -n net.bridge.bridge-nf-call-iptables", "sysctl -w net.bridge.bridge-nf-call-iptables=0",
        "sysctl -w net.bridge.bridge-nf-call-ip6tables=0" ]);
    t.eq(logs, [ "[info] Disabled bridge netfilter (net.bridge.bridge-nf-call-iptables) for transparent proxying" ], "a change to the system is reported");
    t.eq(calls(""), []);
    t.eq(length(logs), 1);
});

t.done();
