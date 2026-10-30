let t = require("t");
let fixture = require("fixture");
let q = require("sbconfig");
let generator = require("singbox.generator");
let nft_sections = require("nft.sections");

const GEOIP = "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geoip/geoip-ru.srs";
const DOMAINS = "https://example.com/domains.srs";
const MIXED = "https://example.com/mixed.srs";

function build(section) {
    fixture.seed({
        settings: fixture.settings(),
        section: [ section, { ".name": "proxy", action: "connection", destinations: "example.org",
            outbound_jsons: [ "{\"type\":\"direct\"}" ] } ]
    });
    return generator.build({ service_address: "127.0.0.1" });
}

t.test("bypass subnets match an evaluated response before a lower FakeIP section", () => {
    let section = { ".name": "RU_IP", action: "bypass", community_lists: [ "discord" ],
        rule_set: [ DOMAINS ], rule_set_with_subnets: [ GEOIP, MIXED ],
        source_ip_cidr: [ "@system", "192.168.1.10/32" ] };
    let config = build(section);
    let geoip = q.ruleset_url(config, GEOIP).tag;
    let domain = q.ruleset_url(config, DOMAINS).tag;
    let mixed = q.ruleset_url(config, MIXED).tag;
    t.ok(q.route_rule(config, (r) => r.outbound == "direct-out" && q.has(r.rule_set, geoip)) != null,
        "IP rules still participate in traffic routing");
    let expected_sets = nft_sections.matchers(section).subnet_tags;
    t.contains(expected_sets, geoip, "the same provider still supplies nftables");
    t.contains(expected_sets, mixed);
    t.excludes(expected_sets, domain, "domain-only lists do not acquire IP semantics");

    for (let device in [ (r) => q.has(r.inbound, "system-dns-in"),
        (r) => q.has(r.source_ip_cidr, "192.168.1.10/32") ]) {
        let domains_at = q.dns_rule_index(config, (r) => device(r) && q.has(r.rule_set, geoip) && r.rule_set_domain_only);
        t.ok(domains_at >= 0, "domains in a mixed set still match the query directly");
        let response_at = q.dns_rule_index(config, (r) => device(r) && q.has(r.rule_set, geoip) && r.match_response != null);
        t.ok(response_at > domains_at, "subnets must use explicit response matching");
        let response = config.dns.rules[response_at];
        t.eq(response.action, "respond", "return the evaluated answer instead of querying twice");
        t.eq(q.as_array(response.rule_set), expected_sets);
        t.eq(response.rule_set_domain_only, null, "IP matching remains enabled for the response");
        let evaluate_at = q.dns_rule_index(config, (r) => device(r) && r.action == "evaluate" && r.tag == response.match_response);
        t.ok(evaluate_at > domains_at && evaluate_at < response_at);
        let evaluate = config.dns.rules[evaluate_at];
        t.eq(evaluate.server, "dns-server");
        t.eq(evaluate.rewrite_ttl, 60);
        t.eq(evaluate.query_type, [ "A", "AAAA" ]);
        let proxy_at = q.dns_rule_index(config, (r) => r.server == "fakeip-server" && q.has(r.domain_suffix, "example.org"));
        t.ok(proxy_at > response_at, "a matching real IP keeps the bypass section's priority");
    }
});

t.test("domain-only and FakeIP sections do not evaluate real DNS responses", () => {
    for (let section in [
        { ".name": "domains", action: "bypass", rule_set: [ DOMAINS ] },
        { ".name": "ports", action: "bypass", ports: [ "443" ], rule_set_with_subnets: [ GEOIP ] },
        { ".name": "blocked", action: "block", rule_set_with_subnets: [ GEOIP ] },
        { ".name": "connected", action: "connection", rule_set_with_subnets: [ GEOIP ],
            outbound_jsons: [ "{\"type\":\"direct\"}" ] }
    ]) {
        let config = build(section);
        t.eq(filter(config.dns.rules, (r) => r.action == "evaluate"), [],
            "no speculative real lookup for " + section[".name"]);
        for (let rule in config.dns.rules)
            if (rule.rule_set != null)
                t.eq(rule.rule_set_domain_only, true, "request matchers cannot contain legacy address filters");
    }
});

t.done();
