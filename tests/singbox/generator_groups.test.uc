let t = require("t");
let fixture = require("fixture");
let q = require("sbconfig");
let generator = require("singbox.generator");

function build(data) {
    fixture.seed(data);
    return generator.build({ service_address: "127.0.0.1" });
}

t.test("one filter picks manual servers as the core picks provider nodes", () => {
    let config = build({
        settings: { dns_server: "1.1.1.1" },
        section: [ { ".name": "proxy", enabled: "1", action: "connection" } ],
        connection_link: fixture.links("proxy", [ "socks://127.0.0.1:1080#DE1", "socks://127.0.0.1:1081#DEd", "socks://127.0.0.1:1082#de 2" ]),
        subscription_url: [ { ".name": "sub_xray", section: "proxy", url: "https://xray.example/sub", tag: "sub1" } ],
        urltest: [
            { ".name": "digit", section: "proxy", name: "Digit", server_filter_mode: "include", include_regex: "^DE\\d$" },
            { ".name": "folded", section: "proxy", name: "Folded", server_filter_mode: "include", include_regex: "(?i)^de\\s?\\d" }
        ]
    });
    let digit = q.outbound(config, "proxy/Digit");
    t.eq(digit.outbounds, [ "proxy/DE1" ], "\\d is a digit here as it is in RE2");
    t.contains(digit.include, "^DE\\d$", "the core gets the pattern as written");
    t.eq(q.outbound(config, "proxy/Folded").outbounds, [ "proxy/DE1", "proxy/de 2" ]);
});

t.test("a subscription is a native provider that URLTest groups filter natively", () => {
    let config = build({
        settings: { dns_server: "1.1.1.1" },
        section: [ { ".name": "proxy", enabled: "1", action: "connection" } ],
        subscription_url: [ { ".name": "sub_xray", section: "proxy", url: "https://xray.example/sub", tag: "sub1" } ],
        urltest: [
            { ".name": "black", section: "proxy", name: "Blacklist", server_filter_mode: "exclude", expected_status: "204/200-299", exclude_regex: "Riga" },
            { ".name": "empty", section: "proxy", name: "Empty whitelist", server_filter_mode: "include" }
        ]
    });
    let provider = q.provider(config, "proxy/sub1");
    t.eq([ provider.type, provider.url, provider.exclude_types ], [ "remote", "https://xray.example/sub", null ]);
    let selector = q.outbound(config, "proxy");
    t.eq(selector.providers, [ provider.tag ]);
    t.eq([ selector.exclude_provider_group_members, selector.exclude_provider_dependencies ], [ null, null ]);
    let black = q.outbound(config, "proxy/Blacklist");
    t.eq([ black.providers, black.expected_status, black.include ], [ [ provider.tag ], "204/200-299", null ]);
    t.contains(black.exclude, "Riga");
    t.eq(black.outbounds, [], "provider nodes are not parsed into static membership");
    let empty = q.outbound(config, "proxy/Empty whitelist");
    t.eq([ empty.include, empty.expected_status ], [ "a^", "*" ], "an empty whitelist matches no provider node");
});

const LINKS = [
    "vless://00000000-0000-4000-8000-000000000001@example.com:443?encryption=none&security=tls&sni=example.com#first",
    "vless://00000000-0000-4000-8000-000000000002@example.org:443?encryption=none&security=tls&sni=example.org#second"
];

t.test("a URLTest keeps connections unless told otherwise, the selector interrupts them", () => {
    let config = build({
        settings: { log_level: "warn" },
        section: [ { ".name": "proxy", enabled: "1", action: "connection" } ],
        connection_link: fixture.links("proxy", LINKS),
        urltest: [ {
            ".name": "proxy_fastest", section: "proxy", name: "Fastest", check_interval: "3m", tolerance: "50",
            testing_url: "https://www.gstatic.com/generate_204", server_filter_mode: "all"
        } ]
    });
    t.eq(length(filter(config.outbounds, (o) => o.type == "urltest" && o.interrupt_exist_connections === false)), 1);
    t.eq(length(filter(config.outbounds, (o) => o.type == "selector" && o.interrupt_exist_connections === true)), 1);
    let fastest = q.outbound(config, "proxy/Fastest");
    t.eq([ fastest.url, fastest.interval, fastest.idle_timeout ], [ "https://www.gstatic.com/generate_204", "3m", null ]);
});

t.test("each URLTest group carries its own settings, in list order in the selector", () => {
    let config = build({
        settings: { log_level: "warn" },
        section: [ { ".name": "proxy", enabled: "1", action: "connection" } ],
        connection_link: fixture.links("proxy", LINKS),
        urltest: [
            {
                ".name": "cfg010001", section: "proxy", name: "Fast URLTest", check_interval: "30s", tolerance: "50",
                testing_url: "https://fast.example/204", idle_timeout: "45s", interrupt_exist_connections: "0"
            },
            {
                ".name": "cfg010002", section: "proxy", name: "Stable URLTest", check_interval: "5m", tolerance: "120",
                testing_url: "https://stable.example/204", interrupt_exist_connections: "1"
            }
        ]
    });
    let fast = q.outbound(config, "proxy/Fast URLTest");
    t.eq([ fast.url, fast.interval, fast.idle_timeout, fast.interrupt_exist_connections ], [ "https://fast.example/204", "30s", "45s", false ]);
    let stable = q.outbound(config, "proxy/Stable URLTest");
    t.eq([ stable.url, stable.interval, stable.tolerance, stable.interrupt_exist_connections ], [ "https://stable.example/204", "5m", 120, true ]);
    let selector = q.outbound(config, "proxy");
    t.eq(slice(selector.outbounds, 0, 2), [ "proxy/Fast URLTest", "proxy/Stable URLTest" ]);
});

t.test("a latency difference of 0 reaches the core as the smallest it honours", () => {
    let config = build({
        settings: { log_level: "warn" },
        section: [ { ".name": "proxy", enabled: "1", action: "connection" } ],
        connection_link: fixture.links("proxy", LINKS),
        urltest: [ { ".name": "fast", section: "proxy", name: "Fast", tolerance: "0" } ]
    });
    t.eq(q.outbound(config, "proxy/Fast").tolerance, 1);
});

function fallback_fixture() {
    return {
        settings: { dns_server: [ "77.88.8.8" ], bootstrap_dns_server: [ "77.88.8.8" ] },
        section: [ {
            ".name": "proxy", enabled: "1", action: "connection",
            outbound_jsons: [
                "{\"type\":\"socks\",\"tag\":\"Alpha\",\"server\":\"127.0.0.1\",\"server_port\":1001}",
                "{\"type\":\"socks\",\"tag\":\"Beta\",\"server\":\"127.0.0.1\",\"server_port\":1002}",
                "{\"type\":\"socks\",\"tag\":\"Gamma\",\"server\":\"127.0.0.1\",\"server_port\":1003}",
                "{\"type\":\"fallback\",\"tag\":\"Nested\",\"outbounds\":[\"Alpha\"]}"
            ]
        } ],
        subscription_url: [ { ".name": "sub_main", section: "proxy", url: "https://example.com/sub", tag: "sub1", subscription_update_enabled: "1" } ],
        fallback_group: [
            {
                ".name": "pg_main", section: "proxy", name: "Main fallback",
                health_check_url: "https://health.example/generate_204", health_check_interval: "12s",
                health_check_timeout: "4s", attempt_timeout: "9s", expected_status: "204/200-299",
                idle_timeout: "20m", interrupt_exist_connections: "1"
            },
            { ".name": "pg_default", section: "proxy", name: "Default fallback" }
        ],
        fallback_level: [
            { ".name": "pl_top", group: "pg_main", name: "Top", order: "0", server_filter_mode: "include", include_outbounds: [ "Beta" ] },
            { ".name": "pl_mixed", group: "pg_main", name: "Mixed", order: "1", server_filter_mode: "include", include_regex: "Alpha|Gamma", exclude_outbounds: [ "Gamma" ] },
            { ".name": "pl_provider", group: "pg_main", name: "Provider only", order: "2", server_filter_mode: "include", include_regex: "Provider only" },
            { ".name": "pl_direct", group: "pg_main", name: "Direct", order: "3", server_filter_mode: "direct" },
            { ".name": "pl_remaining", group: "pg_main", name: "Remaining", order: "4", server_filter_mode: "all" },
            { ".name": "pl_default", group: "pg_default", name: "Direct", order: "0", server_filter_mode: "direct" }
        ]
    };
}

t.test("a Fallback group is one native outbound whose levels claim each node once", () => {
    let config = build(fallback_fixture());
    let group = q.outbound(config, "proxy/Main fallback");
    t.eq([ group.type, length(group.groups), group.levels, group.outbounds, group.exclude_group_members ], [ "fallback", 5, null, null, null ]);
    let levels = group.groups;
    t.eq(levels[0].outbounds, [ "proxy/Beta" ]);
    t.eq(levels[1].outbounds, [ "proxy/Alpha" ]);
    t.eq(levels[2].outbounds, []);
    t.eq(levels[3].outbounds, [ "direct-out" ]);
    t.eq(levels[4].outbounds, [ "proxy/Gamma" ], "a later level takes only what earlier ones left");
    for (let level in levels)
        t.eq(level.tag, null);
    for (let i in [ 0, 1, 2, 4 ]) {
        t.eq(levels[i].providers, [ "proxy/sub1" ]);
        t.eq(levels[i].exclude_types, null);
    }
    t.eq(levels[3].providers, null, "a direct level takes no provider");
    t.ok(levels[0].include != null && levels[1].include != null && levels[1].exclude != null);
    t.eq([ group.url, group.interval, group.timeout, group.attempt_timeout, group.expected_status, group.idle_timeout, group.interrupt_exist_connections ],
        [ "https://health.example/generate_204", "12s", "4s", "9s", "204/200-299", "20m", true ]);
    t.eq(group.max_failed_times, null, "the failure counter is a core constant");

    let defaults = q.outbound(config, "proxy/Default fallback");
    t.eq([ defaults.interval, defaults.timeout, defaults.attempt_timeout, defaults.expected_status, defaults.idle_timeout, defaults.interrupt_exist_connections ],
        [ "5m", "5s", "5s", "*", "5m", false ]);

    for (let outbound in config.outbounds)
        t.ok(index(outbound.tag, "proxy-fallback-pg_main-level-") != 0, "no nested level outbounds");
    t.eq(q.outbound(config, "proxy").default, group.tag, "the selector defaults to its first Fallback group");
});

t.test("the selector defaults to the Fallback that holds a URLTest, not to the URLTest alone", () => {
    let data = {
        settings: { log_level: "warn" },
        section: [ { ".name": "proxy", enabled: "1", action: "connection" } ],
        connection_link: fixture.links("proxy", LINKS),
        urltest: [ { ".name": "fast", section: "proxy", name: "Fast", server_filter_mode: "all" } ],
        fallback_group: [ { ".name": "backup", section: "proxy", name: "Backup" } ],
        fallback_level: [ { ".name": "level", group: "backup", name: "Primary", server_filter_mode: "include", include_groups: [ "Fast" ] } ]
    };
    let selector = q.outbound(build(data), "proxy");
    t.eq(selector.default, "proxy/Backup");
    t.eq(selector.outbounds[0], "proxy/Fast", "the order of the groups stays");

    data.fallback_level[0].include_outbounds = [ "first" ];
    t.eq(q.outbound(build(data), "proxy/Backup").groups[0].outbounds, [ "proxy/Fast", "proxy/first" ],
        "a level puts its URLTest before its own servers");

    data.fallback_level[0].include_groups = null;
    t.eq(q.outbound(build(data), "proxy").default, "proxy/Fast", "a URLTest no Fallback holds stays the default");
});

t.done();
