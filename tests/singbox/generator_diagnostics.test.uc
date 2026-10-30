let t = require("t");
let fixture = require("fixture");
let q = require("sbconfig");
let generator = require("singbox.generator");

function build(section) {
    fixture.seed({
        settings: fixture.settings(),
        section: [ { ".name": "Foreign", enabled: "1", action: "connection", ...section } ],
        connection_link: fixture.links("Foreign", [ "vless://u@proxy.example:443#Proxy" ])
    });
    return generator.build({ service_address: "127.0.0.1" });
}

t.test("the router's direct-IP probe precedes catch-all and forced section routes", () => {
    for (let section in [ { ports: "1-65535" }, { fully_routed_ips: [ "@system" ] } ]) {
        let config = build(section);
        let direct_at = q.route_rule_index(config, (r) => r.action == "route" &&
            r.domain == "fakeip.podkop.fyi" && r.outbound == "direct-out");
        let section_at = q.route_rule_index(config, (r) => r.action == "route" &&
            r.outbound == "Foreign" && r.domain == null);
        t.ok(direct_at >= 0, "the baseline must use a guaranteed direct route");
        t.ok(section_at > direct_at, "a section must not capture the direct-IP probe");
        t.eq(config.route.rules[direct_at].inbound, [ "system-in", "system6-in" ],
            "only the router's IPv4 and IPv6 probes bypass the section; clients keep their own routes");

        let port_at = q.route_rule_index(config, (r) => r.action == "route-options" &&
            r.domain == "fakeip.podkop.fyi" && r.override_port == 8443);
        t.ok(port_at >= 0 && port_at < direct_at, "the FakeIP check still uses the service's special port");
        t.eq(config.route.final, "direct-out");
    }
});

t.test("forcing the baseline direct preserves the proxied IP probe and FakeIP DNS", () => {
    let config = build({ ports: "1-65535" });
    let proxy_probe = q.route_rule(config, (r) => r.action == "route" && r.domain == "ip.podkop.fyi");
    t.ok(proxy_probe != null);
    t.eq(proxy_probe.outbound, "Foreign");
    t.eq(proxy_probe.inbound, [ "tproxy-in", "tproxy6-in", "system-in", "system6-in" ]);

    for (let domain in [ "fakeip.podkop.fyi", "ip.podkop.fyi" ]) {
        let dns_rule = q.dns_rule(config, (r) => q.has(r.domain, domain));
        t.ok(dns_rule != null);
        t.eq(dns_rule.server, "fakeip-server", "both probes still test Forkop's FakeIP path");
        t.eq(dns_rule.query_type, [ "A", "AAAA" ]);
    }
});

t.done();
