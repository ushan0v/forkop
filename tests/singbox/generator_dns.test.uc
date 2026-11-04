let t = require("t");
let fixture = require("fixture");
let q = require("sbconfig");
let generator = require("singbox.generator");

function build(data) {
    fixture.seed(data);
    return generator.build({ service_address: "192.168.1.1" });
}

t.test("a single DNS server is used directly", () => {
    let single = build({
        settings: { dns_server: [ "77.88.8.8" ], bootstrap_dns_server: [ "77.88.8.8" ] },
        section: [ { ".name": "direct", enabled: "1", action: "bypass", destinations: "example.org" } ]
    });
    t.eq(q.tags(single.dns.servers), [ "bootstrap-dns-server", "dns-server", "fakeip-server", "dnsmasq-server" ]);
    t.eq(q.dns_server_tag(single, "dns-server").server, "77.88.8.8");
    t.eq(q.dns_server_tag(single, "bootstrap-dns-server").server, "77.88.8.8");
    t.eq(length(single.inbounds), 7);
});

t.test("an external resolver can still use the DNS listener and domain rules with client capture disabled", () => {
    let data = {
        settings: { intercept_client_dns: "0", dns_server: [ "192.168.1.2" ] },
        section: [ { ".name": "secure_dns", action: "dns", destinations: "example.org", dns_server: [ "https://dns.google/dns-query" ] } ]
    };
    let config = build(data);
    t.eq(q.inbound(config, "dns-in"), { type: "direct", tag: "dns-in", listen: "127.0.0.42", listen_port: 53 });
    t.eq(q.dns_server_tag(config, "dns-server").server, "192.168.1.2");
    t.ok(q.dns_rule(config, (rule) => q.has(rule.domain_suffix, "example.org") && rule.inbound == null) != null,
        "domain rules without device restrictions also match queries forwarded by a resolver");
    t.eq(q.dns_server(config, (server) => server.server == "dns.google").type, "https");
    data.settings.intercept_client_dns = "1";
    t.eq(build(data), config, "the switch does not alter listeners, DNS rules or FakeIP");
});

t.test("the router asks the bootstrap servers for its NTP servers, whatever the main DNS needs a clock for", () => {
    let ntp = (system_ntp) => filter(build({
        settings: { dns_server: [ "https://dns.google/dns-query" ] },
        section: [ { ".name": "direct", enabled: "1", action: "bypass", destinations: "example.org" } ],
        system_ntp
    }).dns.rules, (rule) => rule.server == "bootstrap-dns-server");
    t.eq(ntp({ enabled: "1", server: [ "0.openwrt.pool.ntp.org", "192.0.2.123", "time.example" ] }), [
        { inbound: "system-dns-in", action: "route", server: "bootstrap-dns-server", domain: [ "0.openwrt.pool.ntp.org", "time.example" ] }
    ], "names only: an address needs no lookup");
    t.eq(ntp({ enabled: "0", server: [ "0.openwrt.pool.ntp.org" ] }), [], "sysntpd turned off");
    t.eq(ntp({ server: [ "192.0.2.123" ] }), [], "addresses only");
    t.eq(ntp(null), [], "no NTP section");
});

t.test("several DNS servers become native fallback groups with their own query modes", () => {
    let multi = build({
        settings: {
            dns_server: [ "https://dns.google/dns-query", "https://cloudflare-dns.com/dns-query" ],
            bootstrap_dns_server: [ "1.1.1.1", "8.8.8.8" ],
            dns_main_fallback_strategy: "sequential", dns_bootstrap_fallback_strategy: "parallel",
            dns_detour_enabled: "1", dns_detour_section: "proxy"
        },
        section: [ {
            ".name": "proxy", enabled: "1", action: "connection",
            outbound_jsons: [ "{\"type\":\"direct\",\"tag\":\"fixture\"}" ], destinations: "example.org"
        } ]
    });
    t.eq(length(multi.dns.servers), 8, "four candidates, two groups, the local resolver and FakeIP");
    t.eq(length(multi.inbounds), 7);
    let bootstrap = q.dns_server_tag(multi, "bootstrap-dns-server");
    let main = q.dns_server_tag(multi, "dns-server");
    t.eq([ bootstrap.type, bootstrap.strategy, bootstrap.servers ], [ "fallback", "parallel", [ "bootstrap-dns-server-1", "bootstrap-dns-server-2" ] ]);
    t.eq([ main.type, main.strategy, main.servers ], [ "fallback", "sequential", [ "dns-server-1", "dns-server-2" ] ]);
    for (let tag in main.servers) {
        let candidate = q.dns_server_tag(multi, tag);
        t.eq([ candidate.detour, candidate.domain_resolver ], [ "proxy", "bootstrap-dns-server" ]);
    }
    t.eq(multi.route.default_domain_resolver, "bootstrap-dns-server", "a detoured DNS resolves endpoints through the bootstrap");
});

t.test("static records answer from a hosts server after the sections and before the local resolver", () => {
    let records = build({
        settings: {
            dns_server: [ "77.88.8.8" ], bootstrap_dns_server: [ "77.88.8.8" ],
            static_hosts_text: "# pinned by hand\n130.255.77.28 ntc.party www.ntc.party\n2a03:4000::1 NTC.party\n\n198.51.100.7 example.com # trailing note\n"
        },
        section: [
            { ".name": "pinned", enabled: "1", action: "bypass", destinations: "ntc.party" },
            { ".name": "direct_rule", enabled: "1", action: "bypass", destinations: "example.org" }
        ]
    });
    let hosts = q.dns_server_tag(records, "hosts-server");
    t.eq([ hosts.type, hosts.path ], [ "hosts", null ], "only the records Forkop was given, from no file");
    t.eq(hosts.predefined["ntc.party"], [ "130.255.77.28", "2a03:4000::1" ], "a repeated domain collects every address");
    t.eq(hosts.predefined["www.ntc.party"], [ "130.255.77.28" ]);
    t.ok(hosts.predefined["example.com"] != null, "a trailing comment keeps its record");
    t.eq(hosts.predefined["NTC.party"], null, "domains are lower-cased");

    let hosts_at = q.dns_rule_index(records, (r) => r.server == "hosts-server");
    let last_fakeip = -1;
    for (let i, rule in records.dns.rules)
        if (rule.server == "fakeip-server")
            last_fakeip = i;
    t.ok(hosts_at > last_fakeip, "sections keep their FakeIP answers");
    t.ok(hosts_at < q.dns_rule_index(records, (r) => r.server == "dnsmasq-server"), "records answer before the local resolver");
    t.eq(records.dns.rules[hosts_at].domain, [ "ntc.party", "www.ntc.party", "example.com" ]);
    t.eq(records.dns.rules[hosts_at].query_type, null, "the rule also matches the lookups sing-box makes to dial");

    let resolve_at = q.route_rule_index(records, (r) => r.action == "resolve" && r.server == "hosts-server");
    let section_at = q.route_rule_index(records, (r) => r.action == "route" && r.domain_suffix != null && r.domain_suffix[0] == "ntc.party");
    t.ok(resolve_at >= 0 && resolve_at < section_at, "records pin the address before a section routes the connection");
    for (let rule in records.route.rules)
        if (rule.action == "resolve" && rule.server != "hosts-server" && rule.domain != "ip.podkop.fyi")
            t.eq(rule.server, null, "section resolve rules follow dns.rules");
});

t.test("no records, no hosts server", () => {
    let empty = build({
        settings: { dns_server: [ "77.88.8.8" ], bootstrap_dns_server: [ "77.88.8.8" ] },
        section: [ { ".name": "pinned", enabled: "1", action: "bypass", destinations: "ntc.party" } ]
    });
    t.eq(q.dns_server_tag(empty, "hosts-server"), null);
    t.eq(q.dns_rule(empty, (r) => r.server == "hosts-server"), null);
    t.eq(q.route_rule(empty, (r) => r.server == "hosts-server"), null);
});

const DNS = { dns_server: [ "77.88.8.8" ], bootstrap_dns_server: [ "77.88.8.8" ] };
const BYPASS = [ { ".name": "direct", enabled: "1", action: "bypass", destinations: "example.org" } ];

t.test("a DNS inbound refuses what is not hijacked", () => {
    let config = build({ settings: DNS, section: BYPASS });
    let hijack = q.route_rule_index(config, (r) => r.action == "hijack-dns");
    for (let tag in [ "dns-in", "source-dns-in", "system-dns-in" ]) {
        let reject = q.route_rule_index(config, (r) => r.action == "reject" && r.inbound == tag);
        t.ok(reject > hijack, tag + " refuses the rest after hijack-dns");
    }
});

t.test("the router's own lookups reach sing-box whatever the sections say, and leave the way a client's do", () => {
    let config = build({ settings: DNS, section: BYPASS });
    t.eq(q.inbound(config, "system-dns-in").listen_port, 1605);
    t.ok(q.route_rule(config, (r) => r.action == "sniff" && q.has(r.inbound, "system-dns-in")) != null);
    t.ok(q.route_rule(config, (r) => r.action == "reject" && r.inbound == "system-dns-in") != null);
    let fallback = q.dns_rule(config, (r) => r.server == "dns-server" && q.has(r.inbound, "system-dns-in") &&
        r.domain_regex == null && r.domain_suffix == null && r.query_type == null);
    t.ok(fallback != null && q.has(fallback.inbound, "source-dns-in"), "one fallback for clients and the router");
    t.ok(q.dns_rule(config, (r) => r.server == "dnsmasq-server" && q.has(r.inbound, "system-dns-in") && r.domain_regex == "^[^.]+$") != null,
        "the router's local zone stays with its resolver");

    let router = build({
        settings: { ...DNS, unmatched_dns_mode: "router" },
        section: [ { ".name": "direct", enabled: "1", action: "bypass", destinations: "example.org", source_ip_cidr: [ "@system" ] } ]
    });
    t.ok(q.dns_rule(router, (r) => r.server == "dnsmasq-server" && q.has(r.inbound, "system-dns-in") &&
        r.type == null && r.domain_regex == null && r.domain_suffix == null && r.query_type == null) != null,
        "router mode hands the router's unmatched lookups back to its resolver too");
    t.ok(q.dns_rule(router, (r) => r.server == "dns-server" && q.has(r.inbound, "system-dns-in") && q.has(r.domain_suffix, "example.org") &&
        r.query_type == null) != null, "a System bypass takes real addresses the way any bypass does");
});

function response_matchers(rule) {
    let found = [];
    for (let part in rule.type == "logical" ? rule.rules : [ rule ])
        if (part.match_response == null)
            for (let key in [ "ip_cidr", "ip_is_private", "ip_accept_any" ])
                if (part[key] != null)
                    push(found, key);
    return found;
}

t.test("no DNS rule matches the answer without asking for it, which the core refuses", () => {
    let sections = [
        { ".name": "direct_some", enabled: "1", action: "bypass", destinations: "example.org", source_ip_cidr: [ "@system", "192.168.1.10/32" ] },
        { ".name": "direct_all", enabled: "1", action: "bypass", fully_routed_ips: [ "@system", "192.168.1.20/32" ] },
        { ".name": "dns_all", enabled: "1", action: "dns", dns_server: [ "8.8.8.8" ], fully_routed_ips: [ "192.168.1.30/32" ] }
    ];
    for (let mode in [ "forkop", "router" ]) {
        let config = build({ settings: { ...DNS, unmatched_dns_mode: mode }, section: sections });
        for (let rule in config.dns.rules)
            t.eq(response_matchers(rule), [], mode + ": " + sprintf("%J", rule));
    }
});

t.test("a device whose every query goes to one server keeps the local zone with the local resolver", () => {
    let config = build({ settings: DNS, dhcp_dnsmasq: { domain: "home" }, section: [
        { ".name": "dns_all", enabled: "1", action: "dns", dns_server: [ "8.8.8.8" ], fully_routed_ips: [ "@system", "192.168.1.20/32" ] },
        { ".name": "direct_all", enabled: "1", action: "bypass", fully_routed_ips: [ "192.168.1.30/32" ] }
    ] });
    let catch_all = (server, device) => q.dns_rule_index(config, (r) => r.server == server && device(r) &&
        r.domain == null && r.domain_suffix == null && r.domain_regex == null && r.query_type == null);
    let devices = [
        [ "dns_all-dns-server", "the router", (r) => q.has(r.inbound, "system-dns-in") && r.source_ip_cidr == null ],
        [ "dns_all-dns-server", "a client", (r) => q.has(r.source_ip_cidr, "192.168.1.20/32") ],
        [ "dns-server", "a bypassed client", (r) => q.has(r.source_ip_cidr, "192.168.1.30/32") ]
    ];
    for (let entry in devices) {
        let at = catch_all(entry[0], entry[2]);
        t.ok(at >= 0, entry[1] + ": every query goes to " + entry[0]);
        for (let zone in [ (r) => r.domain_regex == "^[^.]+$", (r) => r.domain_suffix == ".home", (r) => q.has(r.query_type, "PTR") ]) {
            let local = q.dns_rule_index(config, (r) => r.server == "dnsmasq-server" && entry[2](r) && zone(r));
            t.ok(local >= 0 && local < at, entry[1] + ": the local zone is answered first");
        }
    }

    let router = build({ settings: { ...DNS, unmatched_dns_mode: "router" }, section: [
        { ".name": "direct_all", enabled: "1", action: "bypass", fully_routed_ips: [ "192.168.1.30/32" ] }
    ] });
    t.ok(q.dns_rule(router, (r) => r.server == "dnsmasq-server" && q.has(r.source_ip_cidr, "192.168.1.30/32") && r.domain_regex == null) != null,
        "router mode: a bypassed client asks the local resolver for everything");
    t.eq(q.dns_rule(router, (r) => q.has(r.source_ip_cidr, "192.168.1.30/32") && r.domain_regex != null), null, "with nothing to carve out");
});

t.test("unmatched client DNS goes to Forkop, with the local zone left to whoever owns loopback 53", () => {
    let moved = build({ settings: DNS, dhcp_dnsmasq: { port: "5353", domain: "home" }, section: BYPASS });
    let local = q.dns_server_tag(moved, "dnsmasq-server");
    t.eq([ local.server, local.server_port ], [ "127.0.0.1", 53 ], "a moved dnsmasq port changes nothing about the fallback");
    t.ok(q.dns_rule(moved, (r) => r.server == "dns-server" && q.has(r.inbound, "source-dns-in") && r.domain_regex == null && r.domain_suffix == null && r.query_type == null) != null);
    t.ok(q.dns_rule(moved, (r) => r.server == "dnsmasq-server" && q.has(r.inbound, "source-dns-in") && r.domain_regex == "^[^.]+$") != null, "single-label names");
    t.ok(q.dns_rule(moved, (r) => r.server == "dnsmasq-server" && q.has(r.inbound, "source-dns-in") && r.domain_suffix == ".home") != null, "the DHCP domain");
    t.ok(q.dns_rule(moved, (r) => r.server == "dnsmasq-server" && q.has(r.inbound, "source-dns-in") && q.has(r.query_type, "PTR")) != null, "reverse lookups");
    let forkop_at = q.dns_rule_index(moved, (r) => r.server == "dns-server" && q.has(r.inbound, "source-dns-in") && r.domain_regex == null);
    for (let i, rule in moved.dns.rules)
        if (rule.server == "dnsmasq-server" && q.has(rule.inbound, "source-dns-in"))
            t.ok(i < forkop_at, "the local zone is answered before the Forkop fallback");

    let disabled = build({ settings: DNS, dhcp_dnsmasq: { port: "0" }, section: BYPASS });
    t.eq(q.dns_server_tag(disabled, "dnsmasq-server").server_port, 53, "a disabled dnsmasq port changes nothing either");
});

t.test("router mode hands every unmatched client query back to the local resolver", () => {
    let config = build({ settings: { ...DNS, unmatched_dns_mode: "router" }, dhcp_dnsmasq: { port: "5353", domain: "home" }, section: BYPASS });
    t.ok(q.dns_rule(config, (r) => r.server == "dnsmasq-server" && q.has(r.inbound, "source-dns-in") && r.domain_regex == null && r.domain_suffix == null && r.query_type == null) != null);
    t.eq(q.dns_rule(config, (r) => r.server == "dns-server" && q.has(r.inbound, "source-dns-in") && r.domain == null && r.domain_suffix == null && r.rule_set == null), null);
    t.eq(q.dns_rule(config, (r) => r.server == "dnsmasq-server" && r.domain_regex == "^[^.]+$"), null, "there is no local zone to carve out");
});

t.test("DNS timeout reaches the core as configured", () => {
    let config = build({
        settings: { dns_server: [ "1.1.1.1" ], bootstrap_dns_server: [ "1.1.1.1" ], dns_timeout: "4s" },
        section: [ { ".name": "direct", enabled: "1", action: "bypass", destinations: "example.org" } ]
    });
    t.eq(config.dns.timeout, "4s");
    t.eq(config.dns.optimistic, null);
    t.eq(config.dns.independent_cache, null);
    t.eq(config.experimental.cache_file.store_subscriptions, true);
});

t.done();
