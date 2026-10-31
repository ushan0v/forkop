let t = require("t");
let stub = require("stub");
let fs = require("fs");
let migration = require("config.migration");
let v2 = require("config.migrations.v2_0_0");

// The HWID a subscription is fetched with is a hash of the router, which md5sum computes.
function run(data) {
    let path = stub.tmpdir() + "/fixture.json";
    fs.writefile(path, sprintf("%J", data));
    stub.commands([ [ /\| md5sum$/, { stdout: "0123456789abcdef0123456789abcdef  -\n" } ] ]);
    let result = stub.capture(() => migration.main([ "migrate-fixture", path ]));
    stub.restore();
    return { status: result.result, out: json(result.stdout) };
}

function migrated(data) {
    let result = run(data);
    t.eq([ result.status, result.out.decision.result ], [ 0, "migrate" ], result.out.error);
    return result.out;
}

function released(data, version) {
    return { ...data, settings: { config_version: version ?? "1.0.5", ...(data.settings ?? {}) } };
}

function by_name(list) {
    let result = {};
    for (let item in list ?? [])
        result[item[".name"]] = item;
    return result;
}

function owned(list, key, owner) {
    return filter(list ?? [], (item) => item[key] == owner);
}

function absent(item, keys) {
    for (let key in keys)
        t.ok(!exists(item, key), (item[".name"] ?? "settings") + " kept " + key);
}

/* ------------------------------------------------------------------------- versions */

t.test("a configuration of this release is left alone", () => {
    let result = run({ settings: { config_version: "2.0.0", stray: "1" }, section: [ { ".name": "main", action: "connection" } ] });
    t.eq([ result.status, result.out.decision.result, result.out.operations ], [ 0, "current", null ]);
});

t.test("1.0.2 and 1.0.5 are migrated to 2.0.0", () => {
    for (let version in [ "1.0.2", "1.0.5" ]) {
        let out = migrated(released({}, version));
        t.eq([ out.decision.from, out.config.settings.config_version ], [ version, "2.0.0" ]);
    }
});

t.test("a configuration whose version is missing, invalid, older, unknown or newer is kept aside", () => {
    let cases = [
        [ null, "missing", "unknown" ],
        [ "", "missing", "unknown" ],
        [ "NEXT", "invalid", "unknown" ],
        [ "1.0", "invalid", "unknown" ],
        [ "1.0.1", "below_min", "1.0.1" ],
        [ "0.7.21", "below_min", "0.7.21" ],
        [ "1.0.3", "unknown", "1.0.3" ],
        [ "1.0.4", "unknown", "1.0.4" ],
        [ "2.0.1", "newer", "2.0.1" ],
        [ "3.0.0", "newer", "3.0.0" ]
    ];
    for (let entry in cases) {
        let settings = entry[0] == null ? {} : { config_version: entry[0] };
        let result = run({ settings, section: [ { ".name": "main", action: "connection" } ] });
        t.eq([ result.status, result.out.decision ], [ 0, { result: "reset", from: entry[2], reason: entry[1] } ], entry[0]);
        t.eq(result.out.config, null);
    }
    t.eq(run({ section: [] }).out.decision.reason, "missing", "no settings at all");
});

t.test("a released configuration holding a section type its release never wrote is refused", () => {
    let result = run(released({ connection_link: [ { section: "main", uri: "vless://u@a.example:443" } ] }));
    t.eq(result.status, 1);
    t.contains(result.out.error, "has the type 'connection_link', which the 1.0.5 schema has no");
    t.eq(result.out.config, null);
});

/* ---------------------------------------------------------------- 1.0.2 → 1.0.5 */

t.test("1.0.2's HTTP links become HTTP outbounds as 1.0.5 converted them, before the 2.0.0 steps", () => {
    let out = migrated(released({ section: [ {
        ".name": "main", action: "connection",
        selector_proxy_links: [
            "https://alice:p%40ss@proxy.example.com:8443#My+Proxy",
            "http://proxy.example.com:3128",
            "http://example.com/path",
            "vless://u@a.example:443#VLESS"
        ],
        outbound_jsons: [ "{\"type\":\"socks\",\"tag\":\"http\",\"server\":\"127.0.0.1\",\"server_port\":1080}" ]
    } ] }, "1.0.2"));
    let outbounds = map(out.config.section[0].outbound_jsons, (value) => json(value));
    t.eq(outbounds[0], { type: "http", tag: "My Proxy", server: "proxy.example.com", server_port: 8443,
        username: "alice", password: "p@ss", tls: { enabled: true } });
    t.eq(outbounds[1], { type: "http", tag: "http-1", server: "proxy.example.com", server_port: 3128 },
        "an unnamed one takes 'http', numbered past the tag a JSON outbound held");
    t.eq(outbounds[2].tag, "http");
    t.eq(map(out.config.connection_link, (link) => link.uri), [ "http://example.com/path", "vless://u@a.example:443#VLESS" ],
        "a link with a path stays a link");
});

t.test("a 1.0.5 configuration does not repeat the 1.0.5 step", () => {
    let out = migrated(released({ section: [ { ".name": "main", action: "connection", selector_proxy_links: [ "http://proxy.example.com:3128" ] } ] }));
    t.eq(map(out.config.connection_link, (link) => link.uri), [ "http://proxy.example.com:3128" ]);
    t.eq(out.config.section[0].outbound_jsons, null);
});

/* ------------------------------------------------------ forms 1.0.5 still read */

t.test("the proxy, outbound and vpn actions become connection, and a single outbound_json joins the list", () => {
    let socks = "{\"type\":\"socks\",\"tag\":\"S\",\"server\":\"127.0.0.1\",\"server_port\":1080}";
    let other = "{\"type\":\"socks\",\"tag\":\"T\",\"server\":\"127.0.0.1\",\"server_port\":1081}";
    let out = migrated(released({ section: [
        { ".name": "a", action: "proxy" },
        { ".name": "b", action: "outbound", outbound_json: socks },
        { ".name": "c", action: "vpn", outbound_json: socks, outbound_jsons: [ other ] }
    ] }));
    let section = by_name(out.config.section);
    t.eq(map([ "a", "b", "c" ], (name) => section[name].action), [ "connection", "connection", "connection" ]);
    t.eq(section.b.outbound_jsons, [ socks ]);
    t.eq(section.c.outbound_jsons, [ other ], "1.0.5 read the single one only while the list was empty");
    absent(section.b, [ "outbound_json" ]);
    absent(section.c, [ "outbound_json" ]);
});

t.test("subscriptions, interfaces and a URLTest kept on the section become its children", () => {
    let out = migrated(released({ section: [ {
        ".name": "main", action: "connection",
        subscription_urls: "https://a.example/sub https://b.example/sub",
        subscription_url_settings: "{\"https://a.example/sub\":{\"user_agent\":\"Agent\",\"auto_user_agent\":\"0\",\"prefix_nodes\":\"1\",\"node_prefix\":\"A\"}}",
        subscription_update_enabled: "0",
        interfaces: [ "wg0", "awg0" ],
        interface_settings: "{\"awg0\":{\"domain_resolver_enabled\":true,\"domain_resolver_dns_type\":\"dot\",\"domain_resolver_dns_server\":\"1.1.1.1\"}}",
        urltest_enabled: "1",
        urltest_settings: "{\"urltest\":{\"display_name\":\"Auto\",\"idle_timeout\":\"10m\"}}",
        urltest_check_interval: "1m", urltest_filter_mode: "include", urltest_include_outbounds: [ "S1" ]
    } ] }));
    let subscriptions = out.config.subscription_url;
    t.eq(map(subscriptions, (item) => [ item.url, item.tag, item.subscription_update_enabled, item.override_prefix ]),
        [ [ "https://a.example/sub", "A", "0", "A " ], [ "https://b.example/sub", "sub2", "0", null ] ]);
    t.eq(subscriptions[0].header[0], "User-Agent: Agent");
    t.eq(map(out.config.section_interface, (item) => [ item.name, item.display_name, item.domain_resolver_enabled, item.domain_resolver_dns_server ]),
        [ [ "wg0", "wg0", "0", [ "8.8.8.8" ] ], [ "awg0", "awg0", "1", [ "tls://1.1.1.1" ] ] ]);
    let urltest = out.config.urltest[0];
    t.eq([ urltest.name, urltest.check_interval, urltest.idle_timeout, urltest.server_filter_mode, urltest.include_outbounds ],
        [ "Auto", "1m", "10m", "include", [ "S1" ] ]);
    absent(out.config.section[0], [ "subscription_urls", "subscription_url_settings", "subscription_update_enabled", "interfaces",
        "interface_settings", "urltest_enabled", "urltest_settings", "urltest_check_interval", "urltest_filter_mode", "urltest_include_outbounds" ]);
});

t.test("children of a kind keep the section's own options of that kind from counting", () => {
    let out = migrated(released({
        section: [ { ".name": "main", action: "connection", subscription_urls: [ "https://old.example/sub" ], interface: "wg9", urltest_enabled: "1" } ],
        subscription_url: [ { section: "main", url: "https://new.example/sub" } ],
        section_interface: [ { section: "main", name: "wg0" } ],
        urltest: [ { section: "main", name: "Fast" } ]
    }));
    t.eq(map(out.config.subscription_url, (item) => item.url), [ "https://new.example/sub" ]);
    t.eq(map(out.config.section_interface, (item) => item.name), [ "wg0" ]);
    t.eq(map(out.config.urltest, (item) => item.name), [ "Fast" ]);
    absent(out.config.section[0], [ "subscription_urls", "interface", "urltest_enabled" ]);
});

t.test("a URLTest option under its older name counts where the newer one is missing", () => {
    let out = migrated(released({ section: [ { ".name": "main", action: "connection" } ], urltest: [
        { ".name": "old", section: "main", display_name: "Old", urltest_check_interval: "2m", urltest_tolerance: "100" },
        { ".name": "both", section: "main", name: "Both", check_interval: "5m", urltest_check_interval: "2m" }
    ] }));
    let urltest = by_name(out.config.urltest);
    t.eq([ urltest.old.name, urltest.old.check_interval, urltest.old.tolerance ], [ "Old", "2m", "100" ]);
    t.eq(urltest.both.check_interval, "5m");
    absent(urltest.old, [ "display_name", "urltest_check_interval", "urltest_tolerance" ]);
    absent(urltest.both, [ "urltest_check_interval" ]);
});

/* -------------------------------------------------------------- Zapret and ByeDPI */

t.test("Zapret, Zapret2 and ByeDPI sections go with what they own, and whatever pointed at them is switched off", () => {
    let out = migrated(released({
        settings: { dns_detour_enabled: "1", dns_detour_section: "zap", download_lists_via_proxy: "1", download_lists_via_proxy_section: "zap" },
        section: [
            { ".name": "zap", label: "Zapret", action: "zapret", nfqws_opt: "--filter-tcp=443", mixed_proxy_enabled: "1", mixed_proxy_port: "2081" },
            { ".name": "zap2", label: "Zapret2", action: "zapret2", nfqws2_opt: "--filter-tcp=443" },
            { ".name": "bye", action: "byedpi", byedpi_cmd_opts: "--auto=t" },
            { ".name": "main", action: "connection", outbound_detour_enabled: "1", outbound_detour_section: "zap",
                selector_proxy_links: [ "vless://u@a.example:443#A" ] }
        ],
        subscription_url: [ { section: "zap", url: "https://zap.example/sub" },
            { section: "main", url: "https://main.example/sub", download_via_proxy_enabled: "1", download_via_proxy_section: "bye" } ],
        priority_group: [ { ".name": "g", section: "zap", name: "G" } ],
        priority_level: [ { ".name": "l", group: "g", name: "L" } ],
        server: [ { ".name": "srv", label: "Srv", protocol: "vless", routing_mode: "section", routing_section: "zap2", server_uuid: "u" } ]
    }));
    t.eq(map(out.config.section, (item) => item[".name"]), [ "main" ]);
    t.eq([ out.config.fallback_group, out.config.fallback_level ], [ null, null ]);
    t.eq(map(out.config.subscription_url, (item) => [ item.url, item.download_via_proxy_enabled, item.download_via_proxy_section ]),
        [ [ "https://main.example/sub", "0", null ] ]);
    t.eq([ out.config.settings.dns_detour_enabled, out.config.settings.dns_detour_section ], [ "0", null ]);
    t.eq([ out.config.settings.download_lists_via_proxy, out.config.settings.download_lists_via_proxy_section ], [ "0", null ]);
    t.eq(out.config.connection_link[0].detour_section, null, "a cascade through it is gone");
    let server = by_name(out.config.server).srv;
    t.eq([ server.routing_mode, server.routing_section ], [ "direct", null ]);
    t.eq(length(filter(out.config.server, (item) => item.protocol == "mixed")), 0, "its own mixed proxy goes with it");
    for (let line in [
        "Removed the Zapret section 'Zapret': Forkop no longer runs DPI bypass",
        "Removed the Zapret2 section 'Zapret2': Forkop no longer runs DPI bypass",
        "Removed the ByeDPI section 'bye': Forkop no longer runs DPI bypass",
        "Server 'Srv' was routed through a removed DPI section and now goes direct"
    ])
        t.contains(out.warnings, line);
});

/* ------------------------------------------------------------------------- settings */

t.test("DNS servers become URIs that keep their hosts, ports, paths and order", () => {
    let settings = (dns_type, servers) => migrated(released({ settings: { dns_type, dns_server: servers } })).config.settings.dns_server;
    t.eq(settings("doh", [ "dns.google/dns-query", "1.1.1.1:444/custom", "dns.example" ]),
        [ "https://dns.google/dns-query", "https://1.1.1.1:444/custom", "https://dns.example" ]);
    t.eq(settings("dot", [ "dns.adguard-dns.com", "9.9.9.9:8853", "2620:fe::fe" ]),
        [ "tls://dns.adguard-dns.com", "tls://9.9.9.9:8853", "tls://[2620:fe::fe]" ]);
    t.eq(settings("udp", "77.88.8.8 [2a02:6b8::feed:0ff]:53"), [ "77.88.8.8", "[2a02:6b8::feed:0ff]:53" ]);
    let out = migrated(released({ settings: { dns_server: [ "8.8.8.8" ], bootstrap_dns_server: [ "1.1.1.1" ] } }));
    t.eq([ out.config.settings.dns_server, out.config.settings.bootstrap_dns_server ], [ [ "8.8.8.8" ], [ "1.1.1.1" ] ],
        "without a protocol they stay plain UDP");
});

t.test("settings 2.0.0 has no use for leave, and dont_touch_dhcp leaves unmatched queries with the router", () => {
    let out = migrated(released({ settings: {
        applied_migrations: [ "interface_sections" ], dns_type: "udp", dont_touch_dhcp: "1", shutdown_correctly: "1",
        exclude_ntp: "1", dns_check_interval: "10s", dns_recovery_check_interval: "60s", dns_check_timeout: "2s",
        component_update_check_enabled: "1", component_update_check_interval: "1d",
        download_components_via_proxy: "1", download_components_via_proxy_section: "main",
        dns_rewrite_ttl: "120", dns_strategy: "ipv4_only", enable_yacd: "1", yacd_secret_key: "secret",
        source_network_interfaces: [ "br-lan", "br-guest" ], update_interval: "12h", log_level: "info"
    } }));
    let settings = out.config.settings;
    t.eq(settings.unmatched_dns_mode, "router");
    absent(settings, [ "applied_migrations", "dns_type", "dont_touch_dhcp", "shutdown_correctly", "exclude_ntp",
        "dns_check_interval", "dns_recovery_check_interval", "dns_check_timeout", "component_update_check_enabled",
        "component_update_check_interval", "download_components_via_proxy", "download_components_via_proxy_section" ]);
    t.eq([ settings.dns_rewrite_ttl, settings.dns_strategy, settings.enable_yacd, settings.yacd_secret_key,
        settings.source_network_interfaces, settings.update_interval, settings.log_level ],
        [ "120", "ipv4_only", "1", "secret", [ "br-lan", "br-guest" ], "12h", "info" ]);
    t.eq(migrated(released({ settings: { dont_touch_dhcp: "0" } })).config.settings.unmatched_dns_mode, null);
});

/* ------------------------------------------------------------------------- sections */

t.test("a DNS section's server becomes a URI, and domain and IP lists become rule sets", () => {
    let dir = stub.tmpdir();
    fs.writefile(dir + "/dns.txt", "example.com\n");
    fs.writefile(dir + "/b.txt", "# office\n192.0.2.0/24\n");
    let out = migrated(released({ section: [
        { ".name": "dns", action: "dns", dns_type: "doh", dns_server: "dns.quad9.net/dns-query",
            domain_ip_lists: [ dir + "/dns.txt" ], rule_set: [ dir + "/dns.txt", "https://x.example/a.srs" ] },
        { ".name": "main", action: "connection", domain_ip_lists: [ "https://x.example/list.txt", dir + "/b.txt" ],
            rule_set_with_subnets: [ dir + "/b.txt" ] }
    ] }));
    let section = by_name(out.config.section);
    t.eq(section.dns.dns_server, [ "https://dns.quad9.net/dns-query" ]);
    t.eq(section.dns.rule_set, [ dir + "/dns.txt", "https://x.example/a.srs" ], "a DNS section matched their domains only");
    t.eq(section.main.rule_set_with_subnets, [ dir + "/b.txt", "https://x.example/list.txt" ]);
    absent(section.dns, [ "dns_type", "domain_ip_lists" ]);
    absent(section.main, [ "domain_ip_lists" ]);
    t.eq(out.warnings, []);
});

t.test("a list file 1.0.5 skipped as missing or empty goes with a warning", () => {
    let dir = stub.tmpdir();
    fs.writefile(dir + "/empty.txt", "# filled later\n\n  // nothing yet\n");
    let out = migrated(released({ section: [ { ".name": "main", label: "Main", action: "connection",
        domain_ip_lists: [ dir + "/missing.txt", dir + "/empty.txt", "https://x.example/list.txt" ] } ] }));
    t.eq(out.config.section[0].rule_set_with_subnets, [ "https://x.example/list.txt" ]);
    t.contains(out.warnings, "Section 'Main' no longer lists '" + dir + "/missing.txt': the file is missing or holds no entry, " +
        "which Forkop no longer starts with. Add it again once it holds the list");
    t.contains(out.warnings, "Section 'Main' no longer lists '" + dir + "/empty.txt': the file is missing or holds no entry, " +
        "which Forkop no longer starts with. Add it again once it holds the list");
    let gone = migrated(released({ section: [ { ".name": "main", action: "connection", domain_ip_lists: [ dir + "/missing.txt" ] } ] }));
    absent(gone.config.section[0], [ "domain_ip_lists", "rule_set_with_subnets" ]);
});

t.test("lists no release ever applied go with a warning", () => {
    let out = migrated(released({ section: [ { ".name": "main", label: "Main", action: "connection", remote_domain_lists: [ "https://x.example" ] } ] }));
    absent(out.config.section[0], [ "remote_domain_lists" ]);
    t.contains(out.warnings, "Removed 'remote_domain_lists' from section 'Main': no Forkop release ever applied it; add those lists as rule sets");
});

t.test("built-in lists 2.0.0 carries go under their new names, the others stay as the files 1.0.5 used", () => {
    let itdog = "https://github.com/itdoginfo/allow-domains/releases/latest/download/";
    let out = migrated(released({ section: [
        { ".name": "main", action: "connection",
            community_lists: [ "russia_inside", "youtube", "twitter", "meta", "geoblock", "hodca", "ads_hagezi_pro", "ovh" ],
            rule_set: [ "https://x.example/a.srs", "google_ai" ], rule_set_with_subnets: [ "hetzner", "cloudfront" ] },
        { ".name": "dns", action: "dns", community_lists: "meta ukraine_inside digitalocean" }
    ] }));
    let section = by_name(out.config.section);
    t.eq(section.main.community_lists, [ "youtube", "x", "ru_blocked_geo", "ads", "ovh", "gemini", "hetzner" ]);
    t.eq(section.main.rule_set, [ "https://x.example/a.srs", itdog + "russia_inside.srs", itdog + "hodca.srs" ]);
    t.eq(section.main.rule_set_with_subnets, [ itdog + "cloudfront.srs", itdog + "meta.srs" ], "with the subnets 1.0.5 applied");
    t.eq(section.dns.community_lists, [ "ua_blocked", "digitalocean" ]);
    t.eq(section.dns.rule_set, [ itdog + "meta.srs" ], "a DNS section matched the list's domains only");
    t.eq(out.warnings, []);
});

t.test("the Dashboard filter goes, with a warning only where it narrowed the section", () => {
    let out = migrated(released({ section: [
        { ".name": "on", label: "On", action: "connection", dashboard_filter_mode: "include", dashboard_include_outbounds: [ "A" ],
            dashboard_detect_server_country: "flag_emoji", sort_by_latency: "1", resolve_real_ip_for_routing: "1", detect_server_country: "flag_emoji" },
        { ".name": "off", label: "Off", action: "connection", dashboard_filter_mode: "disabled", dashboard_include_outbounds: [ "A" ] }
    ] }));
    let section = by_name(out.config.section);
    absent(section.on, [ "dashboard_filter_mode", "dashboard_include_outbounds", "dashboard_detect_server_country", "sort_by_latency",
        "resolve_real_ip_for_routing", "detect_server_country" ]);
    absent(section.off, [ "dashboard_filter_mode", "dashboard_include_outbounds" ]);
    t.eq(length(filter(out.warnings, (line) => index(line, "Dashboard server filter") >= 0)), 1);
    t.contains(out.warnings, "Section 'On' offers all its servers now: the Dashboard server filter is gone, so the server it uses by default may change. A URLTest or fallback group with the same filter keeps to those servers");
});

/* ------------------------------------------------------------------------ conditions */

t.test("a section's domains and addresses become its destinations, written as they were", () => {
    let out = migrated(released({ section: [
        { ".name": "main", action: "connection", domain: "example.com # the site\nkeyword:video, regex:^cdn[0-9]+\\.example\\.net$",
            ip_cidr: "192.0.2.0/24 // office\n2001:db8::/32" },
        { ".name": "dns", action: "dns", domain: "example.org", ip_cidr: "198.51.100.1" },
        { ".name": "addresses", action: "bypass", ip_cidr: [ "10.0.0.0/8", "192.168.0.0/16" ] },
        { ".name": "none", action: "connection" }
    ] }));
    let section = by_name(out.config.section);
    t.eq(section.main.destinations, "example.com # the site\nkeyword:video, regex:^cdn[0-9]+\\.example\\.net$\n192.0.2.0/24 // office\n2001:db8::/32");
    t.eq(section.dns.destinations, "example.org", "a DNS section never matched an address");
    t.eq(section.addresses.destinations, "10.0.0.0/8\n192.168.0.0/16");
    absent(section.none, [ "destinations" ]);
    for (let item in out.config.section)
        absent(item, [ "domain", "ip_cidr" ]);
});

t.test("the older domain and address forms count as 1.0.5 matched them", () => {
    let out = migrated(released({ section: [
        { ".name": "lists", action: "connection", domain: [ "exact.example.com" ], domain_suffix: "a.example b.example",
            domain_keyword: [ "video" ], domain_regex: [ "^x\\.example$" ], ip_cidr_text: "198.51.100.0/24" },
        { ".name": "texts", action: "connection", domain_suffix_text: "c.example", domain_text: "d.example",
            domain_keyword_text: "music", domain_keyword_text_mode: "1", domain_keyword: [ "ignored" ] },
        { ".name": "all_text", action: "connection", conditions_text_mode: "1", domain_text: "e.example",
            domain: [ "ignored.example" ], ip_cidr: [ "192.0.2.1" ], ip_cidr_text: "192.0.2.2" }
    ] }));
    let section = by_name(out.config.section);
    t.eq(section.lists.destinations, "a.example\nb.example\nfull:exact.example.com\nkeyword:video\nregex:^x\\.example$\n198.51.100.0/24");
    t.eq(section.texts.destinations, "c.example\nfull:d.example\nkeyword:music");
    t.eq(section.all_text.destinations, "full:e.example\n192.0.2.2", "the text mode switch made 1.0.5 read the texts alone");
    for (let item in out.config.section)
        absent(item, [ "domain_suffix", "domain_suffix_text", "domain_keyword", "domain_keyword_text", "domain_keyword_text_mode",
            "domain_regex", "domain_text", "ip_cidr_text", "conditions_text_mode" ]);
});

t.test("what 2.0.0 cannot read in destinations goes with a warning, keeping the rest of its line", () => {
    let out = migrated(released({ section: [
        { ".name": "main", label: "Main", action: "connection", domain: "good.example, bad..example # note\nhost.123" },
        { ".name": "dns", label: "DNS", action: "dns", domain: "example.org 192.0.2.1\nregex:a(" },
        { ".name": "regex", label: "R", action: "connection", domain_regex: [ "a b" ] }
    ] }));
    let section = by_name(out.config.section);
    t.eq(section.main.destinations, "good.example # note");
    t.eq(section.dns.destinations, "example.org");
    t.contains(out.warnings, "Section 'Main' dropped from its destinations what Forkop cannot read there: bad..example, host.123");
    t.contains(out.warnings, "Section 'DNS' dropped from its destinations what Forkop cannot read there: 192.0.2.1, regex:a(");
    t.contains(out.warnings, "Section 'R' no longer matches 'regex:a b': a value with a space, a comma, '#' or '//' cannot be written in its destinations");
    absent(section.regex, [ "destinations" ]);
});

t.test("ports, devices and fully routed devices keep the values 1.0.5 matched", () => {
    let out = migrated(released({ section: [
        { ".name": "a", action: "connection", ports: [ "443", "1000-2000", "8080-8080", "bad" ], ports_text: "443, 53 70000",
            source_ip_cidr: "192.168.1.10, 192.168.1.11", fully_routed_ips_text: "192.168.1.20" },
        { ".name": "b", action: "connection", source_ip_cidr: [ "192.168.1.30" ], source_ip_cidr_text: "192.168.1.31",
            source_ip_cidr_text_mode: "1", fully_routed_ips: "192.168.1.40 192.168.1.41", ports_text: "bad" }
    ] }));
    let section = by_name(out.config.section);
    t.eq(section.a.ports, [ "443", "1000-2000", "8080", "53" ]);
    t.eq(section.a.source_ip_cidr, [ "192.168.1.10", "192.168.1.11" ]);
    t.eq(section.a.fully_routed_ips, [ "192.168.1.20" ], "1.0.5 showed the older text in the field and saved it so");
    t.eq(section.b.source_ip_cidr, [ "192.168.1.31" ]);
    t.eq(section.b.fully_routed_ips, [ "192.168.1.40", "192.168.1.41" ]);
    t.eq(section.b.ports, null);
    for (let item in out.config.section)
        absent(item, [ "ports_text", "source_ip_cidr_text", "source_ip_cidr_text_mode", "fully_routed_ips_text" ]);
});

/* ---------------------------------------------------------------------- JSON outbounds */

const OPENVPN = {
    type: "openvpn", tag: "Office", servers: [ { server: "vpn.example", server_port: 1194 } ], proto: "udp",
    username: "alice", password: " secret ", auth: "SHA256", cipher: "AES-256-CBC",
    tls: { ca: "CA", certificate: "CERT", key: "KEY", verify_x509_name: "server", verify_x509_name_mode: "name-prefix" },
    tls_auth: "CONTROL", key_direction: 1
};

function json_section(outbounds, settings) {
    return released({ settings: settings ?? {}, section: [ { ".name": "main", label: "Main", action: "connection",
        outbound_jsons: map(outbounds, (outbound) => type(outbound) == "string" ? outbound : sprintf("%J", outbound)) } ] });
}

t.test("a JSON outbound sing-box still reads is kept as written, and an untagged one takes the name 1.0.5 showed", () => {
    let plain = "{\"type\":\"socks\",\"tag\":\"Local\",\"server\":\"127.0.0.1\",\"server_port\":1080}";
    let out = migrated(json_section([ plain, { type: "block" }, { type: "socks", server: "127.0.0.1", server_port: 1081 } ]));
    let values = out.config.section[0].outbound_jsons;
    t.eq(values[0], plain);
    t.eq(map(values, (value) => json(value).tag), [ "Local", "JSON outbound 2", "JSON outbound 3" ]);
});

t.test("a dial domain_strategy becomes a domain resolver of the DNS server 1.0.5 resolved through", () => {
    let out = migrated(json_section([
        { type: "socks", tag: "A", server: "a.example", server_port: 1, domain_strategy: "ipv4_only" },
        { type: "socks", tag: "B", server: "b.example", server_port: 1, domain_strategy: "prefer_ipv6", domain_resolver: "local" }
    ]));
    let values = map(out.config.section[0].outbound_jsons, (value) => json(value));
    t.eq([ values[0].domain_strategy, values[0].domain_resolver ], [ null, { server: "dns-server", strategy: "ipv4_only" } ]);
    t.eq(values[1].domain_resolver, { server: "local", strategy: "prefer_ipv6" });
    let detoured = migrated(json_section([ { type: "socks", tag: "A", server: "a.example", server_port: 1, domain_strategy: "ipv4_only" } ],
        { dns_detour_enabled: "1", dns_detour_section: "main" }));
    t.eq(json(detoured.config.section[0].outbound_jsons[0]).domain_resolver.server, "bootstrap-dns-server");
});

t.test("a DNS outbound goes with a warning, since sing-box has none", () => {
    let out = migrated(json_section([ { type: "dns", tag: "D" }, { type: "socks", tag: "S", server: "127.0.0.1", server_port: 1 } ]));
    t.eq(map(out.config.section[0].outbound_jsons, (value) => json(value).tag), [ "S" ]);
    t.contains(out.warnings, "Removed the JSON outbound 'D' of section 'Main': sing-box has no DNS outbound any more");
});

t.test("an OpenVPN outbound becomes a tunnel the native client reads", () => {
    let out = migrated(json_section([ OPENVPN ]));
    t.eq(out.config.section[0].outbound_jsons, null);
    let tunnel = out.config.tunnel[0];
    t.eq([ tunnel.section, tunnel.kind, tunnel.name, tunnel.order ], [ "main", "openvpn-client", "Office", "0" ]);
    let endpoint = json(tunnel.endpoint_json);
    t.eq([ endpoint.type, endpoint.password, endpoint.network, endpoint.cipher, endpoint.data_ciphers_fallback, endpoint.auth ],
        [ "openvpn-client", " secret ", "udp", null, "AES-256-CBC", "SHA256" ]);
    t.eq(endpoint.tls, { certificate: "CA", client_certificate: "CERT", client_key: "KEY", server_name: "server",
        server_name_type: "name-prefix", control_wrap: { type: "tls_auth", key: "CONTROL", direction: "client" } });
});

t.test("an OpenVPN field the native client has not stops the migration and names it", () => {
    let result = run(json_section([ { ...OPENVPN, system: true } ]));
    t.eq(result.status, 1);
    t.contains(result.out.error, "JSON outbound 'Office' of section 'Main' uses OpenVPN system routes or reconnect_delay");
    t.eq(result.out.config, null);
});

t.test("a WireGuard outbound becomes a WireGuard endpoint tunnel, by sing-box's own mapping", () => {
    let out = migrated(json_section([
        { type: "wireguard", tag: "WG", server: "198.51.100.1", server_port: 51820, local_address: [ "10.0.0.2/32" ],
            private_key: "PRIVATE", peer_public_key: "PEER", pre_shared_key: "PSK", reserved: [ 1, 2, 3 ], mtu: 1408,
            domain_strategy: "prefer_ipv4", detour: "Other" },
        { type: "wireguard", tag: "Peers", local_address: [ "10.0.1.2/32" ], private_key: "P2",
            peers: [ { server: "198.51.100.2", server_port: 51821, public_key: "K2", allowed_ips: [ "10.0.0.0/8" ] } ] }
    ]));
    let tunnels = out.config.tunnel;
    t.eq(map(tunnels, (tunnel) => [ tunnel.kind, tunnel.name, tunnel.order ]), [ [ "json", "WG", "0" ], [ "json", "Peers", "1" ] ]);
    t.eq(json(tunnels[0].endpoint_json), {
        type: "wireguard", tag: "WG", private_key: "PRIVATE", mtu: 1408, detour: "Other", address: [ "10.0.0.2/32" ],
        domain_resolver: { server: "dns-server", strategy: "prefer_ipv4" },
        peers: [ { address: "198.51.100.1", port: 51820, public_key: "PEER", allowed_ips: [ "0.0.0.0/0", "::/0" ],
            pre_shared_key: "PSK", reserved: [ 1, 2, 3 ] } ]
    });
    t.eq(json(tunnels[1].endpoint_json).peers, [ { address: "198.51.100.2", port: 51821, public_key: "K2", allowed_ips: [ "10.0.0.0/8" ] } ]);
});

t.test("a Snell outbound speaks the version the core does and flattens its obfuscation", () => {
    let out = migrated(json_section([
        { type: "snell", tag: "S4", version: 4, server: "s.example", server_port: 1, psk: "p", obfs: { mode: "http", host: "cdn.example" } },
        { type: "snell", tag: "S5", version: 5, server: "s.example", server_port: 2, psk: "p" }
    ]));
    let values = map(out.config.section[0].outbound_jsons, (value) => json(value));
    t.eq([ values[0].obfs, values[0].obfs_mode, values[0].obfs_host ], [ null, "http", "cdn.example" ]);
    t.eq(values[1].version, 4);
    let result = run(json_section([ { type: "snell", tag: "Old", version: 3, server: "s.example", server_port: 1 } ]));
    t.eq(result.status, 1);
    t.contains(result.out.error, "is Snell 3, which sing-box no longer speaks");
});

/* ------------------------------------------------------------------ links and names */

t.test("each link becomes a link of its own, named as 1.0.5 named its server", () => {
    let vmess = "vmess://" + b64enc(sprintf("%J", { v: "2", ps: "VMess name", add: "example.com", port: "443", id: "00000000-0000-4000-8000-000000000001" }));
    let out = migrated(released({ section: [
        { ".name": "main", action: "connection", selector_proxy_links: [
            "vless://u@a.example:443#My+Server%21", "trojan://p@b.example:443", vmess, vmess + "#Fragment" ] },
        { ".name": "plain", action: "connection", selector_proxy_links: "socks5://127.0.0.1:1080#S socks5://127.0.0.1:1081" }
    ] }));
    let links = (owner) => map(owned(out.config.connection_link, "section", owner), (link) => [ link.name, link.order ]);
    t.eq(links("main"), [ [ "My Server!", "0" ], [ "Node #2", "1" ], [ "VMess name", "2" ], [ "Fragment", "3" ] ]);
    t.eq(links("plain"), [ [ "S", "0" ], [ "Node #2", "1" ] ], "a single option splits on spaces, as 1.0.5 read it");
    for (let item in out.config.section)
        absent(item, [ "selector_proxy_links" ]);
});

t.test("a server keeps its name before a group, a clash is numbered, and filters follow every renamed server", () => {
    let out = migrated(released({
        section: [ { ".name": "main", action: "connection",
            selector_proxy_links: [ "vless://u@a.example:443#US%2FLA", "vless://u@b.example:443#Fast", "vless://u@c.example:443#Fast", "socks5://127.0.0.1:1#awg0" ],
            outbound_jsons: [ "{\"type\":\"socks\",\"tag\":\"Fast\",\"server\":\"127.0.0.1\",\"server_port\":2}",
                "{\"type\":\"socks\",\"tag\":\"Chain\",\"server\":\"127.0.0.1\",\"server_port\":3,\"detour\":\"Fast\"}" ] } ],
        section_interface: [ { section: "main", name: "awg0" } ],
        urltest: [ { ".name": "fast", section: "main", name: "Fast", filter_mode: "include", include_outbounds: [ "US/LA", "Fast", "awg0" ] } ]
    }));
    t.eq(map(out.config.connection_link, (link) => link.name), [ "US／LA", "Fast", "Fast #2", "awg0" ]);
    t.eq(out.config.section_interface[0].display_name, "awg0 #2");
    let jsons = map(out.config.section[0].outbound_jsons, (value) => json(value));
    t.eq([ jsons[0].tag, jsons[1].tag, jsons[1].detour ], [ "Fast #3", "Chain", "Fast #3" ],
        "a JSON detour reached the JSON outbound of that tag");
    let urltest = out.config.urltest[0];
    t.eq(urltest.name, "Fast #4");
    t.eq(urltest.include_outbounds, [ "US/LA", "Fast", "awg0", "US／LA", "Fast #2", "Fast #3", "awg0 #2" ]);
});

t.test("a JSON outbound reaches a section or another JSON outbound by the names 2.0.0 resolves", () => {
    let out = migrated(released({ section: [
        { ".name": "hop", action: "connection", selector_proxy_links: [ "socks5://127.0.0.1:1#H" ] },
        { ".name": "main", action: "connection", outbound_jsons: [
            "{\"type\":\"socks\",\"tag\":\"A\",\"server\":\"127.0.0.1\",\"server_port\":2,\"detour\":\"hop-out\"}",
            "{\"type\":\"socks\",\"server\":\"127.0.0.1\",\"server_port\":3,\"detour\":\"main-json-1-out\"}",
            "{\"type\":\"selector\",\"tag\":\"Pick\",\"outbounds\":[\"main-json-2-out\",\"A\",\"unknown-out\"]}" ] }
    ] }));
    let jsons = map(by_name(out.config.section).main.outbound_jsons, (value) => json(value));
    t.eq([ jsons[0].detour, jsons[1].tag, jsons[1].detour, jsons[2].outbounds ],
        [ "hop", "JSON outbound 2", "A", [ "JSON outbound 2", "A", "unknown-out" ] ]);
});

t.test("a section's cascade goes to its links and subscriptions alone", () => {
    let out = migrated(released({ section: [
        { ".name": "hop", action: "connection", selector_proxy_links: [ "socks5://127.0.0.1:1#Hop" ] },
        { ".name": "main", action: "connection", outbound_detour_enabled: "1", outbound_detour_section: "hop",
            selector_proxy_links: [ "vless://u@a.example:443#A" ], interfaces: [ "wg0" ],
            outbound_jsons: [ "{\"type\":\"socks\",\"tag\":\"Local\",\"server\":\"127.0.0.1\",\"server_port\":1081}" ] },
        { ".name": "off", action: "connection", outbound_detour_enabled: "0", outbound_detour_section: "hop",
            selector_proxy_links: [ "vless://u@b.example:443#B" ] }
    ], subscription_url: [ { section: "main", url: "https://main.example/sub" }, { section: "off", url: "https://off.example/sub" } ] }));
    let cascade = (type_name, owner) => map(owned(out.config[type_name], "section", owner), (item) => item.detour_section);
    t.eq([ cascade("connection_link", "main"), cascade("subscription_url", "main") ], [ [ "hop" ], [ "hop" ] ]);
    t.eq([ cascade("connection_link", "off"), cascade("subscription_url", "off") ], [ [ null ], [ null ] ]);
    t.eq(json(by_name(out.config.section).main.outbound_jsons[0]).detour, null, "1.0.5 never cascaded a JSON outbound");
    for (let item in out.config.section)
        absent(item, [ "outbound_detour_enabled", "outbound_detour_section" ]);
});

t.test("labels of sections and servers become unique runtime names without a slash", () => {
    let out = migrated(released({
        section: [ { ".name": "a", label: "Main/Primary", action: "connection" }, { ".name": "b", label: "Main/Primary", action: "connection" },
            { ".name": "c", action: "connection" }, { ".name": "d", label: "dns-server", action: "connection" } ],
        server: [ { ".name": "s", label: "c", protocol: "vless", server_uuid: "u" } ]
    }));
    t.eq(map(out.config.section, (item) => item.label), [ "Main／Primary", "Main／Primary #2", "c", "dns-server #2" ]);
    t.eq(out.config.server[0].label, "c #2");
});

/* --------------------------------------------------------------------- subscriptions */

t.test("a subscription sends the headers 1.0.5 sent: the core's User-Agent when it chose one itself", () => {
    let defaults = require("singbox.subscription_headers").default_header_lines;
    let out = migrated(released({ section: [ { ".name": "main", action: "connection" } ], subscription_url: [
        { ".name": "auto", section: "main", url: "https://a.example/sub", auto_user_agent: "1", user_agent: "Ignored", auto_hwid: "1" },
        { ".name": "custom", section: "main", url: "https://b.example/sub", auto_user_agent: "0", user_agent: "Happ/1.0", auto_hwid: "0", hwid: "MY-HWID" },
        { ".name": "implied", section: "main", url: "https://c.example/sub", user_agent: "v2rayN", hwid: "H2" },
        { ".name": "blank", section: "main", url: "https://d.example/sub", auto_user_agent: "0", user_agent: "" },
        { ".name": "file", section: "main", url: "/etc/forkop/sub.txt", auto_user_agent: "0", user_agent: "X" }
    ] }));
    let subscription = by_name(out.config.subscription_url);
    stub.commands([ [ /\| md5sum$/, { stdout: "0123456789abcdef0123456789abcdef  -\n" } ] ]);
    let generated = defaults();
    let with_hwid = (hwid) => defaults(hwid);
    stub.restore();
    let extra = [ "Accept-Language: ru-RU,en,*", "X-Device-Locale: EN" ];
    t.eq(subscription.auto.header, [ ...generated, ...extra ]);
    t.matches(subscription.auto.header[0], /^User-Agent: sing-box/);
    t.eq(subscription.custom.header, [ "User-Agent: Happ/1.0", ...slice(with_hwid("MY-HWID"), 1), ...extra ]);
    t.eq(subscription.implied.header, [ "User-Agent: v2rayN", ...slice(with_hwid("H2"), 1), ...extra ]);
    t.eq(subscription.blank.header[0], "User-Agent: sing-box", "1.0.5 sent this literal when told to choose none");
    t.eq(subscription.file.header, null, "a local file is not fetched");
    for (let name, item in subscription)
        absent(item, [ "auto_user_agent", "user_agent", "auto_hwid", "hwid" ]);
});

t.test("a subscription keeps the client a panel needed when 1.0.x chose the User-Agent itself", () => {
    let cache = stub.tmpdir() + "/";
    let saved = v2.paths.subscription_cache;
    v2.paths.subscription_cache = cache;
    let cached = (name, address, agent) => {
        fs.writefile(cache + name + ".url", address);
        fs.writefile(cache + name + ".user_agent", agent);
    };
    cached("main-subscription-1", "https://a.example/sub", "Happ");
    cached("main-subscription-2", "https://old.example/sub", "v2rayN");
    cached("main-subscription-3", "https://c.example/sub", "sing-box/1.12.12");
    cached("other-subscription-1", "https://d.example/sub", "Clash.Meta");
    let out = migrated(released({ section: [ { ".name": "main", action: "connection" }, { ".name": "other", action: "connection" } ],
        subscription_url: [
            { ".name": "a", section: "main", url: "https://a.example/sub", auto_user_agent: "1" },
            { ".name": "empty", section: "main", url: "" },
            { ".name": "b", section: "main", url: "https://b.example/sub", auto_user_agent: "1" },
            { ".name": "c", section: "main", url: "https://c.example/sub", auto_user_agent: "1" },
            { ".name": "d", section: "other", url: "https://d.example/sub", auto_user_agent: "0", user_agent: "Mine" }
        ] }));
    v2.paths.subscription_cache = saved;
    let subscription = by_name(out.config.subscription_url);
    t.eq(subscription.a.header[0], "User-Agent: Happ", "the first one with an address was the first source");
    t.matches(subscription.b.header[0], /^User-Agent: sing-box/, "a download of another address says nothing");
    t.matches(subscription.c.header[0], /^User-Agent: sing-box/, "the core's own one becomes the installed core's");
    t.eq(subscription.d.header[0], "User-Agent: Mine", "a User-Agent the user chose stays");
});

t.test("a subscription's prefix becomes the provider's and names it, the rest of 1.0.5's options go", () => {
    let out = migrated(released({ section: [ { ".name": "main", action: "connection" }, { ".name": "other", action: "connection" } ], subscription_url: [
        { section: "main", url: "https://a.example/sub", prefix_nodes: "1", node_prefix: " Premium ", include_urltest_groups: "1",
            hide_urltest_group_outbounds: "1", hide_detour_outbounds: "1", show_dashboard_metadata: "0",
            subscription_update_enabled: "1", subscription_update_interval: "6h" },
        { section: "main", url: "https://b.example/sub", prefix_nodes: "0", node_prefix: "Named" },
        { section: "main", url: "https://c.example/sub" },
        { section: "main", url: "https://d.example/sub", prefix_nodes: "1", node_prefix: "Premium" },
        { section: "other", url: "https://e.example/sub" }
    ] }));
    t.eq(map(out.config.subscription_url, (item) => [ item.tag, item.override_prefix ]),
        [ [ "Premium", "Premium " ], [ "Named", null ], [ "sub3", null ], [ "Premium #2", "Premium " ], [ "sub1", null ] ]);
    let first = out.config.subscription_url[0];
    t.eq([ first.show_dashboard_metadata, first.subscription_update_enabled, first.subscription_update_interval ], [ "0", "1", "6h" ]);
    for (let item in out.config.subscription_url)
        absent(item, [ "prefix_nodes", "node_prefix", "include_urltest_groups", "hide_urltest_group_outbounds", "hide_detour_outbounds" ]);
});

/* ------------------------------------------------------------------------ interfaces */

t.test("an interface keeps its name as the display name and its resolver as a URI", () => {
    let out = migrated(released({ section: [ { ".name": "main", action: "connection" } ], section_interface: [
        { section: "main", name: "awg0", domain_resolver_enabled: "1", domain_resolver_dns_type: "doh", domain_resolver_dns_server: "dns.example/dns-query" },
        { section: "main", name: "wg0", display_name: "Office", domain_resolver_enabled: "0" }
    ] }));
    let items = out.config.section_interface;
    t.eq([ items[0].display_name, items[0].domain_resolver_dns_server, items[0].domain_resolver_dns_type ],
        [ "awg0", [ "https://dns.example/dns-query" ], null ]);
    t.eq([ items[1].display_name, items[1].domain_resolver_dns_server ], [ "Office", null ]);
});

/* --------------------------------------------------------------------- server filters */

function urltest_filter(urltest) {
    let out = migrated(released({ section: [ { ".name": "main", label: "Main", action: "connection" } ],
        urltest: [ { section: "main", name: "Fast", ...urltest } ] }));
    return { group: out.config.urltest[0], warnings: out.warnings };
}

t.test("a URLTest filter by name, pattern and country becomes the 2.0.0 filter, countries as their flags", () => {
    let include = urltest_filter({ filter_mode: "include", include_outbounds: [ "A" ], include_regex: [ "^B", "C$" ],
        include_countries: [ "nl", "N1" ], exclude_outbounds: [ "ignored" ] }).group;
    t.eq([ include.server_filter_mode, include.include_outbounds, include.include_regex, include.exclude_outbounds ],
        [ "include", [ "A" ], "(?:^B)|(?:C$)|(?:🇳🇱)", null ], "an include filter never read its exclude side");
    let exclude = urltest_filter({ filter_mode: "exclude", include_outbounds: [ "ignored" ], exclude_countries: [ "US" ] }).group;
    t.eq([ exclude.server_filter_mode, exclude.include_outbounds, exclude.exclude_regex ], [ "exclude", null, "🇺🇸" ]);
    let mixed = urltest_filter({ filter_mode: "mixed", include_regex: [ "DE" ], exclude_outbounds: [ "DE-3" ] }).group;
    t.eq([ mixed.server_filter_mode, mixed.include_regex, mixed.exclude_outbounds ], [ "include", "DE", [ "DE-3" ] ]);
    let disabled = urltest_filter({ filter_mode: "disabled", include_outbounds: [ "A" ] }).group;
    t.eq([ disabled.server_filter_mode, disabled.include_outbounds ], [ "all", null ]);
    absent(include, [ "filter_mode", "include_countries", "detect_server_country" ]);
});

t.test("protocol filters become the types a group leaves out; transports and securities go with a warning", () => {
    let types = require("singbox.constants").FILTERABLE_GROUP_TYPES;
    let only = urltest_filter({ filter_mode: "include", include_proxy_parameters: "1", include_protocols: [ "vless", "trojan" ] }).group;
    t.eq([ only.server_filter_mode, only.exclude_types ], [ "exclude", sort(filter(types, (value) => !(value in [ "vless", "trojan" ]))) ],
        "without a name to match, an include filter kept every server of its protocols");
    let named = urltest_filter({ filter_mode: "include", include_outbounds: [ "A" ], include_proxy_parameters: "1", include_protocols: [ "vless" ] }).group;
    t.eq([ named.server_filter_mode, named.include_outbounds, length(named.exclude_types) ], [ "include", [ "A" ], length(types) - 1 ]);
    let excluded = urltest_filter({ filter_mode: "exclude", exclude_proxy_parameters: "1", exclude_protocols: [ "shadowsocks" ] }).group;
    t.eq([ excluded.server_filter_mode, excluded.exclude_types ], [ "exclude", [ "shadowsocks" ] ]);
    let lost = urltest_filter({ filter_mode: "include", include_proxy_parameters: "1", include_transports: [ "ws" ], include_securities: [ "reality" ] });
    t.eq([ lost.group.server_filter_mode, lost.group.exclude_types ], [ "all", null ]);
    t.contains(lost.warnings, "URLTest 'Fast' in section 'Main' no longer tells servers apart by transport or security (ws, reality)");
    let off = urltest_filter({ filter_mode: "include", include_outbounds: [ "A" ], include_proxy_parameters: "0", include_protocols: [ "vless" ] }).group;
    t.eq(off.exclude_types, null, "lists behind a switch that was off never counted");
});

t.test("a country matched by address and a pattern the core cannot read come with a warning", () => {
    let result = urltest_filter({ filter_mode: "include", detect_server_country: "country_is", include_countries: [ "DE" ],
        include_regex: [ "a(", "ok" ] });
    t.eq(result.group.include_regex, "(?:ok)|(?:🇩🇪)");
    t.contains(result.warnings, "URLTest 'Fast' in section 'Main' matched countries by the server's address; it now matches the country flag in the server's name");
    t.contains(result.warnings, "URLTest 'Fast' in section 'Main' dropped the regular expressions Forkop cannot read: a(");
});

/* ---------------------------------------------------------------------------- groups */

t.test("a URLTest keeps its checks and its interrupt choice, and loses the Dashboard options", () => {
    let out = migrated(released({ section: [ { ".name": "main", action: "connection" } ], urltest: [
        { ".name": "a", section: "main", name: "A", check_interval: "1m", tolerance: "100", testing_url: "https://cp.cloudflare.com",
            idle_timeout: "5m", interrupt_exist_connections: "1", pin_dashboard: "1", hide_added_outbounds: "1" },
        { ".name": "b", section: "main", interrupt_exist_connections: "0" },
        { ".name": "c", section: "main", name: "C" }
    ] }));
    let urltest = by_name(out.config.urltest);
    t.eq([ urltest.a.check_interval, urltest.a.tolerance, urltest.a.testing_url, urltest.a.idle_timeout ],
        [ "1m", "100", "https://cp.cloudflare.com", "5m" ]);
    absent(urltest.a, [ "pin_dashboard", "hide_added_outbounds" ]);
    t.eq(map([ "a", "b", "c" ], (name) => urltest[name].interrupt_exist_connections), [ "1", "0", "1" ],
        "1.0.5 interrupted unless told not to, 2.0.0 does not unless told to");
    t.eq(urltest.b.name, "b");
});

t.test("priority groups become fallback groups that keep their check address and interrupt choice", () => {
    let out = migrated(released({ section: [ { ".name": "main", action: "connection" } ],
        priority_group: [
            { ".name": "g", section: "main", name: "Backup", health_url: "https://example.com/ping", active_check_interval: "30s",
                check_timeout: "2s", recovery_check_interval: "60s", pick_fastest: "1", switch_to_faster_same_priority: "1",
                fastest_check_interval: "5s", interrupt_exist_connections: "1", pin_dashboard: "1" },
            { ".name": "h", section: "main" },
            { ".name": "k", section: "main", name: "Calm", interrupt_exist_connections: "0", pick_fastest: "0" }
        ],
        priority_level: [
            { ".name": "direct", group: "g", name: "Direct", order: "0", direct: "1", country: "US" },
            { ".name": "aliases", group: "g", order: "1", server_name: [ "A" ], include_outbounds: [ "B" ], country: "DE", regex: [ "^x" ] },
            { ".name": "default", group: "g", name: "Default", order: "2", server_name: [ "C" ], exclude_outbounds: [ "D" ] },
            { ".name": "orphan", group: "missing", name: "Lost" }
        ]
    }));
    let group = by_name(out.config.fallback_group);
    t.eq(group.g, { ".name": "g", section: "main", name: "Backup", health_check_url: "https://example.com/ping",
        interrupt_exist_connections: "1" });
    t.eq([ group.h.name, group.h.interrupt_exist_connections ], [ "h", "1" ], "1.0.5 interrupted unless told not to");
    t.eq(group.k.interrupt_exist_connections, "0");
    t.eq(out.config.priority_group, null);
    t.eq(filter(out.warnings, (line) => index(line, "first working server") >= 0), [
        "Fallback group 'Backup' in section 'main' takes the first working server of a level in its order, not the fastest one: " +
        "add a URLTest group to a level to pick by speed there"
    ]);
    let level = by_name(out.config.fallback_level);
    t.eq(keys(level), [ "direct", "aliases", "default" ], "a level without its group was never read");
    t.eq([ level.direct.server_filter_mode, level.direct.include_regex ], [ "direct", null ]);
    t.eq([ level.aliases.name, level.aliases.server_filter_mode, level.aliases.include_outbounds, level.aliases.include_regex ],
        [ "aliases", "include", [ "B" ], "(?:^x)|(?:🇩🇪)" ], "the newer name of each option came first");
    t.eq([ level.default.server_filter_mode, level.default.include_outbounds, level.default.exclude_outbounds ], [ "include", [ "C" ], null ],
        "a level's default filter was include");
    absent(level.aliases, [ "server_name", "country", "regex", "direct" ]);
});

/* --------------------------------------------------------------------------- servers */

function servers(list) {
    let out = migrated(released({ server: list }));
    return { server: by_name(out.config.server), clients: out.config.server_client ?? [], warnings: out.warnings, out };
}

t.test("a server takes the switch, address and closed port 1.0.5 gave it", () => {
    let result = servers([
        { ".name": "bare", protocol: "vless", server_uuid: "u" },
        { ".name": "off", protocol: "trojan", enabled: "0", listen: "192.168.1.1", security: "tls", server_password: "p" },
        { ".name": "ts", protocol: "tailscale" },
        { ".name": "json", protocol: "json_inbound", inbound_json: "{\"type\":\"mixed\",\"listen_port\":1}" }
    ]);
    t.eq([ result.server.bare.enabled, result.server.bare.listen, result.server.bare.open_firewall, result.server.bare.security ],
        [ "1", "0.0.0.0", "0", "reality" ]);
    t.eq([ result.server.off.enabled, result.server.off.listen, result.server.off.open_firewall ], [ "0", "192.168.1.1", "0" ]);
    t.eq([ result.server.ts.open_firewall, result.server.json.open_firewall, result.server.ts.listen ], [ null, null, null ]);
});

t.test("a released server's account becomes a client, and fields 2.0.0 does without go", () => {
    let result = servers([
        { ".name": "vless", label: "VLESS", protocol: "vless", server_uuid: "44444444-4444-4444-8444-444444444444", vless_flow: "xtls-rprx-vision" },
        { ".name": "noflow", label: "No flow", protocol: "vless", server_uuid: "55555555-5555-4555-8555-555555555555", vless_flow: "none" },
        { ".name": "vmess", label: "VMess", protocol: "vmess", server_uuid: "66666666-6666-4666-8666-666666666666", vmess_alter_id: "0" },
        { ".name": "trojan", protocol: "trojan", security: "tls", server_password: "t" },
        { ".name": "hy2", protocol: "hysteria2", server_password: "h", hysteria2_obfs_type: "salamander", hysteria2_obfs_password: "o" },
        { ".name": "ts", protocol: "tailscale", tailscale_advertise_exit_node: "0", tailscale_accept_routes: "1" }
    ]);
    let client = (server) => filter(result.clients, (item) => item.server == server);
    t.eq(map(client("vless"), (item) => [ item.name, item.uuid, item.flow ]), [ [ "VLESS", "44444444-4444-4444-8444-444444444444", "xtls-rprx-vision" ] ]);
    t.eq(client("noflow")[0].flow, null);
    t.eq(map(client("vmess"), (item) => item.uuid), [ "66666666-6666-4666-8666-666666666666" ]);
    t.eq(map(client("trojan"), (item) => [ item.name, item.password ]), [ [ "trojan", "t" ] ]);
    t.eq(client("hy2")[0].password, "h");
    t.eq([ result.server.hy2.hysteria2_obfs_type, result.server.hy2.hysteria2_obfs_password ], [ "salamander", "o" ]);
    for (let name, item in result.server)
        absent(item, [ "server_uuid", "server_password", "server_username", "vless_flow", "vmess_alter_id",
            "tailscale_advertise_exit_node", "tailscale_accept_routes" ]);
});

t.test("an account kept in the older server_users entry counts as 1.0.5 filled it in", () => {
    let result = servers([
        { ".name": "vless", label: "V", protocol: "vless", server_users: [ "phone|77777777-7777-4777-8777-777777777777|xtls-rprx-vision" ] },
        { ".name": "socks", label: "S", protocol: "socks", server_users: [ "secret-only" ] },
        { ".name": "set", label: "Set", protocol: "trojan", server_password: "kept", server_users: [ "ignored|other" ] }
    ]);
    let client = (server) => filter(result.clients, (item) => item.server == server)[0];
    t.eq([ client("vless").name, client("vless").uuid, client("vless").flow ], [ "phone", "77777777-7777-4777-8777-777777777777", "xtls-rprx-vision" ]);
    t.eq([ client("socks").name, client("socks").password ], [ "client", "secret-only" ], "1.0.5 named a SOCKS account 'client'");
    t.eq(client("set").password, "kept");
});

t.test("a SOCKS server becomes a mixed one with the same account, renamed where 2.0.0 refuses the name", () => {
    let result = servers([
        { ".name": "auth", label: "My SOCKS", protocol: "socks", server_password: "p" },
        { ".name": "valid", label: "Valid", protocol: "socks", socks_auth_enabled: "1", server_username: "Admin.User", server_password: "p" },
        { ".name": "open", label: "Open", protocol: "socks", socks_auth_enabled: "0", server_username: "x", server_password: "y" }
    ]);
    t.eq([ result.server.auth.protocol, result.server.auth.mixed_auth_enabled ], [ "mixed", "1" ]);
    let client = (server) => filter(result.clients, (item) => item.server == server);
    t.eq(map(client("auth"), (item) => [ item.name, item.password ]), [ [ "My-SOCKS", "p" ] ], "1.0.5 used the label as the account");
    t.eq(map(client("valid"), (item) => item.name), [ "Admin.User" ], "a name that fits stays as typed");
    t.eq([ result.server.open.mixed_auth_enabled, client("open") ], [ "0", [] ]);
    t.contains(result.warnings, "Server 'My SOCKS' accepts the account 'My-SOCKS' instead of 'My SOCKS', since an account name holds only letters, digits, '.', '_' and '-': use it in its clients");
    t.eq(length(filter(result.warnings, (line) => index(line, "accepts the account") >= 0)), 1);
    for (let name, item in result.server)
        absent(item, [ "socks_auth_enabled" ]);
});

t.test("a Shadowsocks server keeps its method, and a 2022 key moves to the listener with a warning", () => {
    let result = servers([
        { ".name": "legacy", protocol: "shadowsocks", server_password: "p" },
        { ".name": "aead", protocol: "shadowsocks", shadowsocks_method: "chacha20-ietf-poly1305", server_password: "p" },
        { ".name": "2022", label: "SS", protocol: "shadowsocks", shadowsocks_method: "2022-blake3-aes-128-gcm",
            server_password: "ajXWye37k0IsLRrpEhB3pA==" }
    ]);
    t.eq([ result.server.legacy.shadowsocks_method, result.server.aead.shadowsocks_method ], [ "aes-128-gcm", "chacha20-ietf-poly1305" ]);
    t.eq(result.server["2022"].shadowsocks_psk, "ajXWye37k0IsLRrpEhB3pA==");
    t.eq(map(filter(result.clients, (client) => client.server == "2022"), (client) => client.password), [ "ajXWye37k0IsLRrpEhB3pA==" ]);
    t.eq(result.server.legacy.shadowsocks_psk, null);
    t.eq(filter(result.warnings, (line) => index(line, "Shadowsocks 2022") >= 0), [
        "Server 'SS' gives each Shadowsocks 2022 client a key of its own now, which a link holds next to the server key: hand its clients the new link"
    ], "a 1.0.5 link held the one key, which the core refuses from a client of a server with keys of its clients");
});

t.test("a Reality server takes its handshake target as the SNI and says when the target moves", () => {
    let result = servers([
        { ".name": "same", label: "Same", protocol: "vless", security: "reality", server_uuid: "u",
            tls_server_name: "www.microsoft.com", reality_handshake_server: "www.microsoft.com", reality_handshake_server_port: "443" },
        { ".name": "nosni", label: "No SNI", protocol: "vless", security: "reality", server_uuid: "u", reality_handshake_server: "www.apple.com" },
        { ".name": "moved", label: "Moved", protocol: "vless", security: "reality", server_uuid: "u",
            tls_server_name: "www.microsoft.com", reality_handshake_server: "www.bing.com", reality_handshake_server_port: "8443",
            reality_max_time_difference: "1m" }
    ]);
    t.eq([ result.server.nosni.tls_server_name, result.server.moved.tls_server_name ], [ "www.apple.com", "www.microsoft.com" ]);
    t.eq(result.warnings, [ "Server 'Moved' hands unknown clients to www.microsoft.com:443 instead of www.bing.com:8443" ]);
    for (let name, item in result.server)
        absent(item, [ "reality_handshake_server", "reality_handshake_server_port", "reality_max_time_difference" ]);
});

t.test("a certificate Forkop issued moves into the server, the user's own path stays a path", () => {
    let dir = stub.tmpdir() + "/server-certs/";
    fs.mkdir(dir);
    fs.writefile(dir + "hy2.crt", "-----BEGIN CERTIFICATE-----\nissued\n-----END CERTIFICATE-----\n");
    fs.writefile(dir + "hy2.key", "-----BEGIN PRIVATE KEY-----\nissued-key\n-----END PRIVATE KEY-----\n");
    let saved = v2.paths.certificates;
    v2.paths.certificates = dir;
    let paths = (name) => ({ tls_certificate_path: dir + name + ".crt", tls_key_path: dir + name + ".key" });
    let result = servers([
        { ".name": "hy2", protocol: "hysteria2", server_password: "p", ...paths("hy2") },
        { ".name": "lost", protocol: "trojan", security: "tls", server_password: "p", ...paths("lost") },
        { ".name": "acme", protocol: "vless", security: "tls", server_uuid: "u",
            tls_certificate_path: "/etc/ssl/acme/fullchain.crt", tls_key_path: "/etc/ssl/acme/key.pem" },
        { ".name": "reality", protocol: "vless", security: "reality", server_uuid: "u", ...paths("reality") },
        { ".name": "plain", protocol: "trojan", security: "none", server_password: "p", tls_certificate_path: "/etc/ssl/x.crt", tls_key_path: "/etc/ssl/x.key" }
    ]);
    v2.paths.certificates = saved;
    let server = result.server;
    t.eq([ server.hy2.tls_certificate_source, server.hy2.tls_self_signed_certificate, server.hy2.tls_self_signed_key ],
        [ null, "-----BEGIN CERTIFICATE-----\nissued\n-----END CERTIFICATE-----", "-----BEGIN PRIVATE KEY-----\nissued-key\n-----END PRIVATE KEY-----" ]);
    t.eq([ server.lost.tls_certificate_source, server.lost.tls_self_signed_certificate ], [ null, null ], "one that cannot be read is issued again");
    t.eq([ server.acme.tls_certificate_source, server.acme.tls_certificate, server.acme.tls_key ],
        [ "custom", "/etc/ssl/acme/fullchain.crt", "/etc/ssl/acme/key.pem" ]);
    t.eq([ server.reality.tls_certificate_source, server.reality.tls_self_signed_key ], [ null, null ]);
    t.eq([ server.plain.security, server.plain.tls_certificate_source ], [ "tls", null ], "a server without TLS had no certificate in use");
    t.eq(result.out.after_commit, [ dir ], "the issued files go once the configuration holding them is committed");
    for (let name, item in server)
        absent(item, [ "tls_certificate_path", "tls_key_path" ]);
});

t.test("a Trojan server without TLS serves TLS and says its clients need the new link", () => {
    let result = servers([
        { ".name": "plain", label: "Plain", protocol: "trojan", security: "none", server_password: "p" },
        { ".name": "wrapped", label: "Wrapped", protocol: "trojan", security: "tls", server_password: "p" },
        { ".name": "reality", label: "Reality", protocol: "trojan", security: "reality", server_password: "p" },
        { ".name": "vmess", label: "VMess", protocol: "vmess", security: "reality", server_uuid: "u" }
    ]);
    t.eq(map([ "plain", "wrapped", "reality", "vmess" ], (name) => result.server[name].security), [ "tls", "tls", "tls", "none" ]);
    t.eq(result.warnings, [ "Server 'Plain' serves Trojan over TLS now, which every Trojan client needs: hand its clients the new link" ]);
});

t.test("a released server whose links name an IPv6 address listens on both families", () => {
    let trojan = (name, public_host, listen) => ({ ".name": name, protocol: "trojan", security: "tls", server_password: "p", listen, public_host });
    let result = servers([ trojan("v6", "2001:db8::1", "0.0.0.0"), trojan("bracketed", "[2001:db8::2]", "0.0.0.0"),
        trojan("v4", "203.0.113.9", "0.0.0.0"), trojan("host", "vpn.example.com", "0.0.0.0"), trojan("chosen", "2001:db8::3", "192.168.1.1") ]);
    t.eq(map([ "v6", "bracketed", "v4", "host", "chosen" ], (name) => result.server[name].listen), [ "::", "::", "0.0.0.0", "0.0.0.0", "192.168.1.1" ]);
});

t.test("an HTTP transport takes the first host, and an inbound JSON loses the fields sing-box dropped", () => {
    let result = servers([
        { ".name": "http", protocol: "vless", security: "none", server_uuid: "u", transport: "http", transport_hosts: [ "a.example", "b.example" ] },
        { ".name": "ws", protocol: "vless", security: "none", server_uuid: "u", transport: "ws", transport_host: "ws.example", transport_hosts: [ "x" ] },
        { ".name": "json", label: "JSON", protocol: "json_inbound",
            inbound_json: "{\"type\":\"mixed\",\"listen_port\":1080,\"sniff\":true,\"sniff_override_destination\":true,\"domain_strategy\":\"ipv4_only\"}" },
        { ".name": "sniffing", label: "Sniffing", protocol: "json_inbound", inbound_json: "{\"type\":\"mixed\",\"listen_port\":1081,\"sniff\":true}" }
    ]);
    t.eq([ result.server.http.transport_host, result.server.ws.transport_host ], [ "a.example", "ws.example" ]);
    t.eq(json(result.server.json.inbound_json), { type: "mixed", listen_port: 1080 });
    t.eq(json(result.server.sniffing.inbound_json), { type: "mixed", listen_port: 1081 });
    t.eq(result.warnings, [ "Removed sniff_override_destination, domain_strategy from the inbound JSON of server 'JSON': sing-box no longer reads them there" ],
        "Forkop sniffs every server itself");
});

t.test("a released MTProto server leaves with a warning", () => {
    let result = servers([ { ".name": "mt", label: "MTProto", protocol: "mtproto", mtproto_secret: "ee00", mtproto_padding: "1" } ]);
    t.eq(result.server.mt, null);
    t.eq(result.warnings, [ "Removed the MTProto server 'MTProto': Forkop no longer serves MTProto" ]);
});

t.test("a section's own mixed proxy becomes a mixed server routed to it, its port closed in the firewall", () => {
    let out = migrated(released({
        section: [
            { ".name": "main", label: "Main", action: "connection", mixed_proxy_enabled: "1", mixed_proxy_port: "2080",
                mixed_proxy_auth_enabled: "1", mixed_proxy_username: "Ivan Petrov", mixed_proxy_password: "secret" },
            { ".name": "off", label: "Off", action: "connection", enabled: "0", mixed_proxy_enabled: "1", mixed_proxy_port: "2081" },
            { ".name": "broken", label: "Broken", action: "connection", mixed_proxy_enabled: "1", mixed_proxy_port: "70000" }
        ],
        server: [ { ".name": "server_main_mixed", label: "Main - Mixed proxy", protocol: "vless", server_uuid: "u" } ]
    }));
    let created = filter(out.config.server, (item) => item.protocol == "mixed");
    t.eq(map(created, (item) => [ item[".name"], item.label, item.enabled, item.listen, item.listen_port, item.open_firewall,
        item.routing_mode, item.routing_section, item.mixed_auth_enabled ]), [
        [ "server_main_mixed_2", "Main - Mixed proxy 2", "1", "::", "2080", "0", "section", "main", "1" ],
        [ "server_off_mixed", "Off - Mixed proxy", "0", "::", "2081", "0", "section", "off", "0" ]
    ], "only what 1.0.5 accepted reached a listener");
    let client = filter(out.config.server_client, (item) => item.server == "server_main_mixed_2")[0];
    t.eq([ client.name, client.password ], [ "Ivan-Petrov", "secret" ]);
    t.contains(out.warnings, "The mixed proxy of section 'Main' accepts the account 'Ivan-Petrov' instead of 'Ivan Petrov', since an account name holds only letters, digits, '.', '_' and '-': use it in its clients");
    for (let item in out.config.section)
        absent(item, [ "mixed_proxy_enabled", "mixed_proxy_port", "mixed_proxy_auth_enabled", "mixed_proxy_username", "mixed_proxy_password" ]);
});

/* ------------------------------------------------------------------- writing it back */

t.test("the writes replay the migration: added sections first, then edits, then removals", () => {
    let out = migrated(released({
        section: [ { ".name": "main", action: "connection", selector_proxy_links: [ "vless://u@a.example:443#A" ] },
            { ".name": "zap", action: "zapret" } ],
        priority_group: [ { ".name": "g", section: "main", name: "G" } ]
    }));
    let ops = out.operations;
    t.eq(ops[0], { op: "add", section: ".new-1", type: "connection_link" });
    t.contains(ops, { op: "retype", section: "g", type: "fallback_group" });
    t.contains(ops, { op: "set", section: ".new-1", option: "uri", value: "vless://u@a.example:443#A" });
    t.eq(ops[length(ops) - 1], { op: "remove", section: "zap" });
});

/* ------------------------------------------------------------- the dnsmasq takeover */

t.test("a takeover backup is restored exactly and its private keys removed", () => {
    let plan = v2.dnsmasq_plan({
        server: [ "127.0.0.42" ], noresolv: "1", cachesize: "0", rebind_protection: "0",
        forkop_server: [ "1.1.1.1", "tls://8.8.8.8" ], forkop_noresolv: "1",
        forkop_cachesize: "321", forkop_rebind_protection: "__unset__"
    }, false, "");
    t.ok(plan.changed);
    t.eq(plan.set_lists.server, [ "1.1.1.1", "tls://8.8.8.8" ]);
    t.eq([ plan.set.noresolv, plan.set.cachesize ], [ "1", "321" ]);
    for (let key in [ "forkop_server", "forkop_noresolv", "forkop_cachesize", "forkop_rebind_protection", "rebind_protection" ])
        t.contains(plan.delete_options, key);
});

t.test("a takeover without a backup falls back to the stock values, and an untouched dnsmasq is left alone", () => {
    let plan = v2.dnsmasq_plan({ server: [ "127.0.0.42", "9.9.9.9" ], notinterface: [ "br-lan", "wan" ] }, true, "br-lan");
    t.eq([ plan.set_lists.server, plan.set.noresolv, plan.set.cachesize, plan.set_lists.notinterface, plan.delete_legacy_instance ],
        [ [ "9.9.9.9" ], "0", "150", [ "wan" ], true ]);
    t.eq(v2.dnsmasq_plan({ server: [ "192.168.1.1" ], noresolv: "0", cachesize: "150" }, false, "").changed, false);
});

t.done();
