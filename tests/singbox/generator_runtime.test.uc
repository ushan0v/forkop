let t = require("t");
let fixture = require("fixture");
let q = require("sbconfig");
let generator = require("singbox.generator");

let has = q.has;

function build(data) {
    fixture.seed(data);
    return generator.build({ service_address: "127.0.0.1" });
}

function settings(extra) {
    return {
        config_path: "/tmp/sing-box/config.json",
        dns_server: "1.1.1.1",
        service_listen_address: "127.0.0.1",
        ...(extra ?? {})
    };
}

t.test("a lone connection section without sources leaves nothing usable", () => {
    let e = t.throws(() => build({
        settings: settings(),
        section: [ { ".name": "unfinished", enabled: "1", action: "connection", destinations: "unfinished.example" } ],
        server: []
    }));
    t.eq(e.message, "no usable sections or servers");
});

t.test("an empty connection section is omitted without suppressing its neighbours", () => {
    let config = build({
        settings: settings(),
        section: [
            { ".name": "empty", enabled: "1", action: "connection", destinations: "empty.example" },
            { ".name": "usable", enabled: "1", action: "connection" }
        ],
        subscription_url: [ { ".name": "sub_usable", section: "usable", url: "https://example.com/sub.json", tag: "sub1" } ]
    });
    t.excludes(sprintf("%J", config), "\"empty\"");
    t.ok(q.provider(config, "usable/sub1") != null, "subscription provider of the usable section");
});

t.test("a subscription-only section becomes a native provider", () => {
    let config = build({
        settings: settings(),
        section: [ { ".name": "subscription_only", enabled: "1", action: "connection" } ],
        subscription_url: [ { ".name": "sub_only", section: "subscription_only", url: "https://example.com/sub.json", tag: "sub1" } ]
    });
    t.ok(q.provider(config, "subscription_only/sub1") != null);
});

t.test("tunnels become native endpoints with the fields their kind allows", () => {
    let config = build({
        settings: settings({ cache_path: "/tmp/sing-box/cache.db" }),
        section: [
            { ".name": "tunnels", enabled: "1", action: "connection" },
            { ".name": "control", enabled: "1", action: "connection", outbound_jsons: [ "{\"type\":\"direct\"}" ] }
        ],
        tunnel: [
            {
                ".name": "tun_warp", section: "tunnels", order: "0",
                kind: "warp", name: "Cloudflare WARP", amnezia_jc: "7",
                warp_profile_id: "profile-id", warp_profile_auth_token: "auth-token",
                warp_profile_private_key: "private-key", warp_profile_license_key: "license-key",
                amnezia_i1: "<r 1>", amnezia_content_padding_addition: "8-16", amnezia_disable_cookies: "1",
                amnezia_s1: "40", amnezia_h1: "100-200",
                amnezia_header_protection_key: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
            },
            {
                ".name": "tun_amnezia", section: "tunnels", order: "1",
                kind: "amneziawg", name: "Amnezia", address: [ "10.0.0.2/32" ],
                private_key: "private-amnezia", amnezia_jc: "5", amnezia_h1: "100",
                amnezia_random_trailers: "1", amnezia_disable_cookies: "1"
            },
            {
                ".name": "tun_bare", section: "tunnels", order: "5",
                kind: "wireguard", name: "Bare", address: [ "10.0.0.4/32" ], private_key: "private-bare"
            },
            {
                ".name": "tun_plain", section: "tunnels", order: "4",
                kind: "wireguard", name: "Plain", address: [ "10.0.0.3/32" ],
                private_key: "private-plain", amnezia_jc: "3", amnezia_i1: "<r 2>", amnezia_disable_cookies: "1",
                amnezia_s1: "64", amnezia_h1: "100-200",
                amnezia_header_protection_key: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
            },
            {
                ".name": "tun_tailnet", section: "tunnels", order: "2",
                kind: "tailscale", name: "Tailnet", tailscale_auth_key: "tskey-auth-test",
                tailscale_hostname: "forkop-router", tailscale_exit_node: "100.64.0.1",
                tailscale_detour_section: "control"
            },
            {
                ".name": "tun_home", section: "tunnels", order: "6",
                kind: "tailscale", name: "Home", tailscale_auth_key: "tskey-auth-test",
                tailscale_hostname: "forkop-home"
            },
            {
                ".name": "tun_json", section: "tunnels", order: "3",
                kind: "json", endpoint_json: "{\"type\":\"vpn-client\",\"tag\":\"custom-endpoint\",\"server\":\"vpn.example.com\"}"
            }
        ],
        tunnel_peer: [
            { ".name": "peer_amnezia", tunnel: "tun_amnezia", order: "0", address: "vpn.example.com", port: "51820", public_key: "public", allowed_ips: [ "0.0.0.0/0" ] },
            { ".name": "peer_plain", tunnel: "tun_plain", order: "0", address: "wg.example.com", port: "51820", public_key: "public", allowed_ips: [ "0.0.0.0/0" ] },
            { ".name": "peer_bare", tunnel: "tun_bare", order: "0", address: "wg.example.com", port: "51820", public_key: "public", allowed_ips: [ "0.0.0.0/0" ] }
        ]
    });

    let warp = q.endpoint(config, "tunnels/Cloudflare WARP");
    t.eq(warp.type, "warp");
    t.eq(warp.profile.license_key, "license-key");
    t.eq(warp.profile.recreate, null, "the core keys its profile cache by the profile, so one it already fetched is not asked for again");
    t.eq(warp.amnezia, { jc: 7, i1: "<r 1>", content_padding_addition: "8-16" },
        "WARP carries only the obfuscation a plain peer ignores");

    let amnezia = q.endpoint(config, "tunnels/Amnezia");
    t.eq(amnezia.type, "amneziawg");
    t.eq(amnezia.amnezia, { jc: 5, h1: 100, random_trailers: true, disable_cookies: true });

    let plain = q.endpoint(config, "tunnels/Plain");
    t.eq(plain.type, "wireguard");
    t.eq(plain.amnezia, { jc: 3, i1: "<r 2>" },
        "a WireGuard endpoint carries only one-sided Amnezia fields");
    for (let endpoint in config.endpoints)
        t.ok(endpoint.amnezia == null || length(keys(endpoint.amnezia)) > 0, "empty Amnezia block on " + endpoint.tag);

    let tailscale = q.endpoint(config, "tunnels/Tailnet");
    t.eq(tailscale.type, "tailscale");
    t.eq(tailscale.state_directory, "/etc/forkop/tailscale/tunnels-tun_tailnet");
    t.eq(tailscale.detour, "control");
    t.eq(tailscale.exit_node, "100.64.0.1");
    t.eq(tailscale.exit_node_allow_lan_access, true);

    let home = q.endpoint(config, "tunnels/Home");
    t.eq(home.type, "tailscale");
    t.ok(!exists(home, "exit_node") && !exists(home, "exit_node_allow_lan_access"),
        "a Tailscale tunnel without an exit node must not ask for one");

    let custom = q.endpoint(config, "tunnels/custom-endpoint");
    t.eq(custom.type, "vpn-client");
    t.eq(custom.detour, null);

    let selector = q.outbound(config, "tunnels");
    for (let tag in [ warp.tag, amnezia.tag, tailscale.tag, custom.tag ])
        t.contains(selector.outbounds, tag, "tunnels are selectable connection outbounds");

    t.eq(config.experimental.cache_file.enabled, true);
    t.eq(config.experimental.cache_file.path, "/tmp/sing-box/cache.db");
    t.eq(config.experimental.cache_file.store_warp_config, true);
});

t.test("list update settings reach remote rule sets, and ports constrain the whole rule-set matcher", () => {
    let disabled = build({
        settings: settings({ list_update_enabled: "0", update_interval: "5m" }),
        section: [ {
            ".name": "proxy", enabled: "1", action: "connection",
            outbound_jsons: [ "{\"type\":\"direct\"}" ], destinations: "example.org",
            rule_set: [ "https://example.com/rules.srs" ], ports: [ "8443" ]
        } ]
    });
    t.eq(q.first_remote_ruleset(disabled).update_interval, null, "disabled list updates omit the interval");
    t.eq(q.route_rule(disabled, (r) => r.action == "resolve"), null);
    let route = q.route_rule(disabled, (r) => r.type == "logical" && r.outbound == "proxy");
    t.ok(route != null && length(route.rules) == 2 &&
        has(route.rules[0].rule_set, q.first_remote_ruleset(disabled).tag) && has(route.rules[1].port, 8443),
        "section ports constrain the complete rule-set matcher");

    let defaults = build({
        settings: settings(),
        section: [ {
            ".name": "proxy", enabled: "1", action: "connection",
            outbound_jsons: [ "{\"type\":\"direct\"}" ], rule_set: [ "https://example.com/rules.srs" ]
        } ]
    });
    t.eq(q.first_remote_ruleset(defaults).update_interval, "1d");
    t.eq(defaults.experimental.unified_delay.enabled, true);
    t.eq(defaults.dns.strategy, "prefer_ipv4");
    t.ok(q.inbound(defaults, "source-dns-in") != null, "interface DNS inbound is always generated");
    t.ok(q.dns_server_tag(defaults, "dnsmasq-server") != null, "the local resolver is always a DNS server");
    t.ok(q.dns_rule(defaults, (r) => r.server == "dns-server" && has(r.inbound, "source-dns-in") &&
        r.source_ip_cidr == null && r.domain == null && r.domain_suffix == null && r.domain_regex == null &&
        r.rule_set == null && r.query_type == null) != null,
        "unmatched interface DNS resolves through the Forkop DNS by default");
    t.ok(q.dns_rule(defaults, (r) => r.server == "dnsmasq-server" && has(r.inbound, "source-dns-in") &&
        r.domain_regex == "^[^.]+$") != null, "the local resolver keeps the zone it is authoritative for");
});

t.test("server inbounds carry their protocol options and their clients", () => {
    let server = build({
        settings: settings(),
        section: [ {
            ".name": "proxy", enabled: "1", action: "connection",
            outbound_jsons: [ "{\"type\":\"direct\"}" ], destinations: "example.org"
        } ],
        server: [
            { ".name": "unfinished", protocol: "shadowsocks", shadowsocks_method: "2022-blake3-aes-128-gcm", listen: "0.0.0.0", routing_mode: "direct" },
            { ".name": "edge", enabled: "1", protocol: "mixed", mixed_auth_enabled: "1", listen: "0.0.0.0", listen_port: "18080", routing_mode: "direct" },
            {
                ".name": "tailnet", enabled: "1", protocol: "tailscale", tailscale_auth_key: "tskey-auth-server",
                tailscale_hostname: "forkop-server", tailscale_detour_enabled: "1", tailscale_detour_section: "proxy",
                routing_mode: "direct"
            },
            { ".name": "open", enabled: "1", protocol: "mixed", listen: "0.0.0.0", listen_port: "18081", mixed_auth_enabled: "0", routing_mode: "direct" },
            {
                ".name": "naive", enabled: "1", protocol: "naive", listen: "0.0.0.0", listen_port: "18443", security: "tls",
                tls_certificate: "/etc/ssl/acme/naive.crt", tls_key: "-----BEGIN PRIVATE KEY-----\nnaive-key\n-----END PRIVATE KEY-----",
                naive_network: "tcp_udp", routing_mode: "direct"
            },
            { ".name": "mieru", enabled: "1", protocol: "mieru", listen: "0.0.0.0", listen_port: "18444", mieru_transport: "UDP", routing_mode: "direct" },
            {
                ".name": "anytls", enabled: "1", protocol: "anytls", listen: "0.0.0.0", listen_port: "18445", label: "AnyTLS user",
                security: "tls", tls_self_signed_certificate: "-----BEGIN CERTIFICATE-----\r\nissued\r\n-----END CERTIFICATE-----",
                tls_self_signed_key: "-----BEGIN PRIVATE KEY-----\nissued-key\n-----END PRIVATE KEY-----",
                tls_certificate: "/etc/ssl/ignored.crt", tls_key: "/etc/ssl/ignored.key", routing_mode: "direct"
            },
            {
                ".name": "tuic", enabled: "1", protocol: "tuic", listen: "0.0.0.0", listen_port: "18446", label: "TUIC user",
                security: "tls", tls_certificate_source: "custom", tls_certificate: "/etc/ssl/tuic.crt", tls_key: "/etc/ssl/tuic.key",
                tuic_congestion_control: "bbr", routing_mode: "direct"
            },
            {
                ".name": "vlessmux", enabled: "1", protocol: "vless", listen: "0.0.0.0", listen_port: "18447", label: "VLESS mux",
                security: "reality", reality_private_key: "reality-private", reality_public_key: "reality-public",
                reality_short_id: [ "abcd" ], multiplex_enabled: "1", multiplex_padding: "1", routing_mode: "direct"
            },
            {
                ".name": "ss2022", enabled: "1", protocol: "shadowsocks", listen: "0.0.0.0", listen_port: "18448",
                label: "Shadowsocks 2022", shadowsocks_method: "2022-blake3-aes-128-gcm",
                shadowsocks_psk: "c2VydmVyLXByZXNoYXJlZC1rZXk=", routing_mode: "direct"
            }
        ],
        server_client: [
            { ".name": "edge_tester", server: "edge", name: "tester", password: "secret" },
            { ".name": "edge_ruled", server: "edge", name: "ruled", password: "ruled-secret", routing_override: "1", routing_mode: "rules" },
            { ".name": "open_ignored", server: "open", name: "ignored", password: "ignored" },
            { ".name": "naive_user", server: "naive", name: "naive-user", password: "naive-password" },
            { ".name": "mieru_user", server: "mieru", name: "mieru-user", password: "mieru-password" },
            { ".name": "anytls_user", server: "anytls", name: "anytls-client", password: "anytls-password" },
            { ".name": "tuic_user", server: "tuic", name: "tuic-client", uuid: "33333333-3333-4333-8333-333333333333", password: "tuic-password" },
            { ".name": "vlessmux_phone", server: "vlessmux", name: "phone", uuid: "44444444-4444-4444-8444-444444444444", flow: "xtls-rprx-vision" },
            { ".name": "vlessmux_laptop", server: "vlessmux", name: "laptop", uuid: "55555555-5555-4555-8555-555555555555", routing_override: "1", routing_mode: "direct" },
            { ".name": "ss2022_phone", server: "ss2022", name: "phone", password: "Y2xpZW50LXByZXNoYXJlZC1rZXk=" }
        ]
    });

    t.eq(q.inbound(server, "unfinished"), null, "a server without the enable switch is not generated");

    let mixed = q.inbound(server, "edge");
    t.eq([ mixed.type, mixed.listen_port ], [ "mixed", 18080 ]);
    t.eq([ mixed.users[0].username, mixed.users[0].password ], [ "tester", "secret" ]);

    let tailnet = q.endpoint(server, "tailnet");
    t.eq(tailnet.type, "tailscale");
    t.eq(tailnet.detour, "proxy");
    t.eq(tailnet.advertise_exit_node, true);
    t.ok(q.route_rule(server, (r) => r.action == "sniff" && r.inbound == "tailnet") != null,
        "the Tailscale endpoint is sniffed, so the shared rules see the domain of a peer's flow to an address");
    t.eq(q.dns_server(server, (s) => s.type == "tailscale"), null,
        "a peer using the router as its exit node resolves through the shared DNS rules, not the tailnet's resolvers");
    t.eq(q.dns_rule(server, (r) => has(r.inbound, "tailnet")), null);

    let open = q.inbound(server, "open");
    t.eq([ open.type, open.listen_port, open.users ], [ "mixed", 18081, null ], "disabled mixed authentication omits users");

    let naive = q.inbound(server, "naive");
    t.eq([ naive.type, naive.network ], [ "naive", [ "tcp", "udp" ] ]);
    t.eq(naive.users[0].username, "naive-user");
    t.eq(naive.quic_congestion_control, null);
    t.eq([ naive.tls.enabled, naive.tls.certificate_path, naive.tls.certificate, naive.tls.key ],
        [ true, "/etc/ssl/acme/naive.crt", null, [ "-----BEGIN PRIVATE KEY-----", "naive-key", "-----END PRIVATE KEY-----" ] ],
        "NaiveProxy always serves the user's certificate, a file by path and a pasted key inline");

    let mieru = q.inbound(server, "mieru");
    t.eq([ mieru.type, mieru.transport, mieru.users[0].password ], [ "mieru", "UDP", "mieru-password" ]);
    t.eq(mieru.user_hint_is_mandatory, null);

    let anytls = q.inbound(server, "AnyTLS user");
    t.eq([ anytls.type, anytls.users[0].password, anytls.tls.enabled ], [ "anytls", "anytls-password", true ]);
    t.eq([ anytls.tls.certificate, anytls.tls.key, anytls.tls.certificate_path ],
        [ [ "-----BEGIN CERTIFICATE-----", "issued", "-----END CERTIFICATE-----" ],
            [ "-----BEGIN PRIVATE KEY-----", "issued-key", "-----END PRIVATE KEY-----" ], null ],
        "a server without a certificate of the user's serves the one the router issued it");

    let tuic = q.inbound(server, "TUIC user");
    t.eq([ tuic.type, tuic.users[0].uuid ], [ "tuic", "33333333-3333-4333-8333-333333333333" ]);
    t.eq([ tuic.congestion_control, tuic.heartbeat, tuic.zero_rtt_handshake ], [ "bbr", null, null ],
        "the core keeps its own heartbeat and never offers 0-RTT, which replays can abuse");
    t.eq(tuic.auth_timeout, null);
    t.eq([ tuic.tls.enabled, tuic.tls.certificate_path, tuic.tls.key_path ], [ true, "/etc/ssl/tuic.crt", "/etc/ssl/tuic.key" ]);

    let vless_mux = q.inbound(server, "VLESS mux");
    t.eq(length(vless_mux.users), 2, "a server accepts every client");
    t.eq([ vless_mux.users[0].name, vless_mux.users[0].uuid, vless_mux.users[0].flow ],
        [ "phone", "44444444-4444-4444-8444-444444444444", "xtls-rprx-vision" ]);
    t.eq([ vless_mux.users[1].name, vless_mux.users[1].flow ], [ "laptop", null ], "VLESS flow is a per-client setting");
    t.eq([ vless_mux.multiplex.enabled, vless_mux.multiplex.padding, vless_mux.multiplex.brutal ], [ true, true, null ]);
    t.eq(vless_mux.tls.reality.enabled, true);

    let ss2022 = q.inbound(server, "Shadowsocks 2022");
    t.eq(ss2022.method, "2022-blake3-aes-128-gcm");
    t.eq(ss2022.password, "c2VydmVyLXByZXNoYXJlZC1rZXk=", "the server pre-shared key stays on the inbound");
    t.eq(ss2022.users[0].password, "Y2xpZW50LXByZXNoYXJlZC1rZXk=", "a 2022 account carries its own key alone");

    t.ok(q.route_rule(server, (r) => r.inbound == "edge" && r.outbound == "direct-out") != null, "server direct route");
    let ruled_at = q.route_rule_index(server, (r) => r.inbound == "edge" && r.auth_user == "ruled");
    let direct_at = q.route_rule_index(server, (r) => r.inbound == "edge" && r.auth_user == null && r.outbound == "direct-out");
    t.ok(ruled_at >= 0 && direct_at > ruled_at, "the cloned rules of a client come before the rule of its server");

    let client_at = q.route_rule_index(server, (r) => r.inbound == "VLESS mux" && r.auth_user == "laptop");
    let mux_server_at = q.route_rule_index(server, (r) => r.inbound == "VLESS mux" && r.auth_user == null && r.action == "route");
    t.ok(client_at >= 0, "a client that overrides the route gets its own rule");
    t.eq(server.route.rules[client_at].outbound, "direct-out");
    t.ok(mux_server_at < 0 || client_at < mux_server_at, "a client rule comes before the rule of its server");
    for (let rule in server.route.rules)
        t.eq(rule.user, null, "a route rule names an account with auth_user, never with user");
});

function matcher_fixture() {
    return build({
        settings: settings({ dns_strategy: "prefer_ipv6" }),
        section: [
            { ".name": "detour", enabled: "1", action: "connection", outbound_jsons: [ "{\"type\":\"direct\"}" ], destinations: "detour.example" },
            { ".name": "bypass", enabled: "1", action: "bypass", destinations: "example.org", source_ip_cidr: [ "10.0.0.3/32" ], ports: [ "443" ] },
            { ".name": "bypass_ruleset", enabled: "1", action: "bypass", rule_set: [ "https://example.com/bypass-port.srs" ], source_ip_cidr: [ "10.0.0.4/32" ], ports: [ "8443" ] },
            {
                ".name": "proxy", enabled: "1", action: "connection",
                destinations: "commented.example # ignored.example\nfull:exact-comment.example // ignored-full.example\n" +
                    "full:source-priority.test\nkeyword:clip\nproxy.example.org сайт.рф, full:пример.испытание\n" +
                    "keyword:пример\nregex:^сайт[.]рф$\n77.111.247.0/24 #77.111.247.19\n198.51.100.0/24 //203.0.113.0/24",
                source_ip_cidr: [ "10.0.0.2/32", "2001:db8::2/128", "@system" ],
                ports: [ "80", "8080" ]
            },
            { ".name": "proxy_global", enabled: "1", action: "connection", outbound_jsons: [ "{\"type\":\"direct\"}" ], destinations: "example.org" },
            { ".name": "bypass_global", enabled: "1", action: "bypass", destinations: "full:source-priority.test" }
        ],
        connection_link: fixture.links("proxy", [ "socks5://127.0.0.1:1080" ], { detour_section: "detour" }),
        server: [ {
            ".name": "server_proxy_mixed", enabled: "1", label: "proxy - Mixed proxy", protocol: "mixed",
            mixed_auth_enabled: "1", listen: "0.0.0.0", listen_port: "19090", open_firewall: "0",
            routing_mode: "section", routing_section: "proxy"
        } ],
        server_client: [ { ".name": "client_proxy_mixed", server: "server_proxy_mixed", name: "user", password: "pass" } ]
    });
}

t.test("inbounds, DNS servers and base routing of a matcher-heavy configuration", () => {
    let m = matcher_fixture();
    t.eq(m.dns.strategy, "prefer_ipv6");
    t.ok(q.dns_server(m, (r) => r.tag == "fakeip-server" && r.inet6_range == "fc00::/112") != null);
    t.eq(q.inbound(m, "tproxy6-in").listen, "::1");
    t.eq([ q.inbound(m, "system-in").listen_port, q.inbound(m, "system6-in").listen_port ], [ 1604, 1604 ]);
    t.eq(q.route_rule(m, (r) => r.action == "reject" && r.ip_version == 6), null, "IPv6 traffic is not rejected globally");
    t.eq(q.outbound(m, "direct-out").type, "direct");
    t.eq(q.outbound(m, "proxy/Node #1").detour, "detour", "a manual link takes its cascade detour");

    let mixed = q.inbound(m, "proxy - Mixed proxy");
    t.eq([ mixed.listen_port, mixed.users[0].username ], [ 19090, "user" ]);
    t.ok(q.route_rule(m, (r) => r.inbound == "proxy - Mixed proxy" && r.outbound == "proxy") != null, "a section-routed server follows its section");

    let source_dns = q.inbound(m, "source-dns-in");
    t.eq([ source_dns.type, source_dns.listen, source_dns.listen_port ], [ "direct", "::", 1603 ]);
    t.ok(q.route_rule(m, (r) => r.action == "sniff" && has(r.inbound, "source-dns-in")) != null);
    t.ok(q.route_rule(m, (r) => r.action == "hijack-dns" && r.protocol == "dns") != null, "sniffed DNS is hijacked by protocol");
    t.eq(q.route_rule(m, (r) => r.action == "hijack-dns" && r.port == 53), null, "non-DNS traffic on port 53 is not hijacked");
    t.ok(q.route_rule(m, (r) => r.action == "reject" && r.inbound == "source-dns-in") != null);
    t.eq(q.inbound(m, "system-dns-in").listen_port, 1605);
    t.ok(q.route_rule(m, (r) => r.action == "reject" && r.inbound == "system-dns-in") != null);
    t.ok(q.dns_server(m, (r) => r.tag == "dnsmasq-server" && r.type == "udp" && r.server == "127.0.0.1" && r.server_port == 53) != null);

    t.eq(q.inbound(m, "service-mixed-in"), null, "nothing outside the core measures the first section");
});

t.test("device-scoped sections keep FakeIP and their priority in DNS rules", () => {
    let m = matcher_fixture();
    t.ok(q.dns_rule(m, (r) => r.server == "fakeip-server" && has(r.domain_suffix, "example.org") && has(r.source_ip_cidr, "10.0.0.3/32")) != null,
        "domain and port bypass keeps FakeIP so sing-box can match the destination port");
    let port_ruleset = q.ruleset_url(m, "https://example.com/bypass-port.srs");
    let ruleset_dns = q.dns_rule(m, (r) => r.server == "fakeip-server" && has(r.rule_set, port_ruleset.tag) && has(r.source_ip_cidr, "10.0.0.4/32"));
    t.ok(ruleset_dns != null, "rule-set and port bypass keeps FakeIP domain identity");
    t.eq(ruleset_dns.rule_set_domain_only, true, "a rule-set domain limited to a port of its own gets FakeIP as well");
    t.eq(q.dns_rule(m, (r) => r.server == "dns-server" && has(r.domain_suffix, "example.org") && r.source_ip_cidr == null), null,
        "a filtered bypass does not change DNS for every device");
    t.ok(q.dns_rule(m, (r) => r.server == "fakeip-server" && has(r.domain_suffix, "example.org") && r.source_ip_cidr == null) != null,
        "a lower global proxy still gives FakeIP to other devices");
    let scoped = q.dns_rule(m, (r) => r.server == "fakeip-server" && has(r.domain_suffix, "proxy.example.org"));
    t.ok(has(scoped.source_ip_cidr, "10.0.0.2/32") && has(scoped.inbound, "source-dns-in"), "a filtered proxy gives FakeIP only to its devices");
    t.ok(q.dns_rule(m, (r) => r.server == "fakeip-server" && has(r.domain_suffix, "proxy.example.org") && has(r.inbound, "system-dns-in") && r.source_ip_cidr == null) != null,
        "the System device keeps the same proxy DNS conditions");

    let fakeip_rules = filter(m.dns.rules, (r) => r.server == "fakeip-server");
    t.ok(length(fakeip_rules) > 0);
    for (let rule in fakeip_rules)
        t.eq(rule.query_type, [ "A", "AAAA" ], "FakeIP rules stay limited to address queries");

    let fallback = q.dns_rule(m, (r) => r.server == "dns-server" && r.type == null && r.domain == null && r.domain_suffix == null &&
        r.domain_regex == null && r.rule_set == null && r.query_type == null && has(r.inbound, "source-dns-in"));
    t.eq(fallback.source_ip_cidr, null);
    t.ok(q.dns_rule(m, (r) => r.server == "dnsmasq-server" && has(r.inbound, "system-dns-in") && r.domain_regex == "^[^.]+$") != null,
        "the router's local zone stays with its resolver");
    t.ok(q.dns_rule(m, (r) => r.server == "dns-server" && r.domain == null && r.domain_suffix == null && r.rule_set == null && has(r.inbound, "system-dns-in")) != null);

    let bypass_at = q.dns_rule_index(m, (r) => r.server == "fakeip-server" && has(r.domain_suffix, "example.org") && has(r.source_ip_cidr, "10.0.0.3/32"));
    let proxy_below = q.dns_rule_index(m, (r) => r.server == "fakeip-server" && has(r.domain_suffix, "example.org") && r.source_ip_cidr == null);
    t.ok(bypass_at >= 0 && proxy_below > bypass_at, "a source-scoped port bypass keeps its priority over a lower proxy");
    let scoped_at = q.dns_rule_index(m, (r) => r.server == "fakeip-server" && has(r.domain, "source-priority.test") && has(r.source_ip_cidr, "10.0.0.2/32"));
    let bypass_below = q.dns_rule_index(m, (r) => r.server == "dns-server" && has(r.domain, "source-priority.test") && r.source_ip_cidr == null);
    t.ok(scoped_at >= 0 && bypass_below > scoped_at, "a source-scoped proxy keeps its priority over a lower bypass");
    let scoped_route = q.route_rule_index(m, (r) => r.outbound == "proxy" && has(r.domain, "source-priority.test") && has(r.source_ip_cidr, "10.0.0.2/32"));
    let bypass_route = q.route_rule_index(m, (r) => r.outbound == "direct-out" && has(r.domain, "source-priority.test") && r.source_ip_cidr == null);
    t.ok(scoped_route >= 0 && bypass_route > scoped_route, "route and DNS priorities stay aligned");
});

t.test("domain conditions are converted to ASCII and their comments dropped", () => {
    let m = matcher_fixture();
    t.eq(q.dns_rule(m, (r) => has(r.domain_suffix, "xn--80aswg.xn--p1ai")).server, "fakeip-server");
    t.eq(q.dns_rule(m, (r) => has(r.domain, "xn--e1afmkfd.xn--80akhbyknj4f")).server, "fakeip-server");
    t.eq(q.dns_rule(m, (r) => has(r.domain_keyword, "xn--e1afmkfd")).server, "fakeip-server");
    t.eq(q.dns_rule(m, (r) => has(r.domain_regex, "^xn--80aswg[.]xn--p1ai$")).server, "fakeip-server");
    t.eq(q.dns_rule(m, (r) => has(r.domain_suffix, "commented.example")).server, "fakeip-server");
    t.eq(q.dns_rule(m, (r) => has(r.domain, "exact-comment.example")).server, "fakeip-server");
    t.eq(q.dns_rule(m, (r) => has(r.domain_keyword, "clip")).server, "fakeip-server");
    let text = sprintf("%J", m);
    t.excludes(text, "ignored.example");
    t.excludes(text, "ignored-full.example");
    for (let key in [ "domain_suffix", "domain", "domain_keyword", "domain_regex" ]) {
        let value = { domain_suffix: "xn--80aswg.xn--p1ai", domain: "xn--e1afmkfd.xn--80akhbyknj4f",
            domain_keyword: "xn--e1afmkfd", domain_regex: "^xn--80aswg[.]xn--p1ai$" }[key];
        t.ok(q.route_rule(m, (r) => r.outbound == "proxy" && has(r[key], value)) != null, "IDN " + key + " in the route rule");
    }
});

t.test("route rules carry devices, addresses and ports, and never the System sentinel", () => {
    let m = matcher_fixture();
    t.ok(q.route_rule(m, (r) => r.outbound == "direct-out" && has(r.domain_suffix, "example.org") && has(r.source_ip_cidr, "10.0.0.3/32") && has(r.port, 443)) != null,
        "a domain bypass keeps its port matcher");
    let port_ruleset = q.ruleset_url(m, "https://example.com/bypass-port.srs");
    let ruleset_route = q.route_rule(m, (r) => r.type == "logical" && r.mode == "and" && r.outbound == "direct-out");
    t.eq(length(ruleset_route.rules), 2);
    t.ok(has(ruleset_route.rules[0].rule_set, port_ruleset.tag) && has(ruleset_route.rules[0].inbound, "tproxy-in"));
    t.eq([ ruleset_route.rules[0].source_ip_cidr, ruleset_route.rules[0].port ], [ null, null ]);
    t.ok(has(ruleset_route.rules[1].source_ip_cidr, "10.0.0.4/32") && has(ruleset_route.rules[1].port, 8443),
        "a rule-set bypass applies the section device filter and port as AND conditions");
    t.ok(q.route_rule(m, (r) => has(r.inbound, "tproxy-in") && has(r.inbound, "tproxy6-in") && r.outbound == "proxy") != null);
    t.ok(q.route_rule(m, (r) => r.outbound == "proxy" && has(r.source_ip_cidr, "10.0.0.2/32") && has(r.source_ip_cidr, "2001:db8::2/128")) != null);
    t.ok(q.route_rule(m, (r) => r.outbound == "proxy" && has(r.inbound, "system-in") && has(r.inbound, "system6-in") &&
        r.source_ip_cidr == null && has(r.domain_suffix, "proxy.example.org")) != null, "the System device keeps the same route conditions");
    t.excludes(sprintf("%J", m), "@system");

    let commented = q.route_rule(m, (r) => r.outbound == "proxy" && has(r.ip_cidr, "77.111.247.0/24") && has(r.ip_cidr, "198.51.100.0/24"));
    t.eq(commented.port, [ 80, 8080 ]);
    t.ok(has(commented.domain_suffix, "proxy.example.org"), "the addresses share the rule with the domains next to them");
    t.eq(filter(m.dns.rules, (r) => index(sprintf("%J", r), "77.111.247.0/24") >= 0), [], "an address never reaches a DNS rule");
    let text = sprintf("%J", commented);
    for (let dropped in [ "#77.111.247.19", "203.0.113.0/24" ])
        t.excludes(text, dropped, "comments are left out of the rule");
});

t.test("a server following the rules also follows a rule set narrowed to ports", () => {
    let d = build({
        settings: settings(),
        section: [
            { ".name": "main", enabled: "1", action: "connection", outbound_jsons: [ "{\"type\":\"direct\"}" ],
                rule_set: [ "https://example.com/main.srs" ], ports: [ "8000-9000" ] },
            { ".name": "plain", enabled: "1", action: "connection", outbound_jsons: [ "{\"type\":\"direct\"}" ], destinations: "plain.example" }
        ],
        server: [
            { ".name": "srv", enabled: "1", protocol: "mixed", listen: "0.0.0.0", listen_port: "18090", mixed_auth_enabled: "0", routing_mode: "rules" },
            { ".name": "own", enabled: "1", protocol: "mixed", listen: "0.0.0.0", listen_port: "18091", mixed_auth_enabled: "1", routing_mode: "direct" }
        ],
        server_client: [ { ".name": "own_one", server: "own", name: "one", password: "one-secret", routing_override: "1", routing_mode: "rules" } ]
    });
    let server_tag = q.find(d.inbounds, (inbound) => inbound.listen_port == 18090).tag;
    let narrowed = filter(d.route.rules, (r) => r.type == "logical" && r.outbound == "main");
    let own_tag = q.find(d.inbounds, (inbound) => inbound.listen_port == 18091).tag;
    t.eq(length(narrowed), 3, "the section's own rule, the server's copy and the account's");
    t.ok(has(narrowed[0].rules[0].inbound, "tproxy-in"));
    let copy = q.find(narrowed, (r) => r.rules[0].inbound == server_tag);
    t.eq(copy.rules[1].port_range, [ "8000:9000" ], "the copy keeps the ports that narrow it");
    let account = q.find(narrowed, (r) => r.rules[0].inbound == own_tag);
    t.eq([ account.rules[0].auth_user, account.auth_user ], [ "one", null ], "the account is matched where the inbound is");
    t.ok(q.route_rule(d, (r) => r.inbound == server_tag && has(r.domain_suffix, "plain.example")) != null);
});

t.test("a Mixed server written without the authentication switch asks for its accounts", () => {
    let d = build({
        settings: settings(),
        section: [ { ".name": "main", enabled: "1", action: "connection", outbound_jsons: [ "{\"type\":\"direct\"}" ], destinations: "example.org" } ],
        server: [ { ".name": "srv", enabled: "1", protocol: "mixed", listen: "0.0.0.0", listen_port: "18092", routing_mode: "direct" } ],
        server_client: [ { ".name": "srv_one", server: "srv", name: "one", password: "one-secret" } ]
    });
    t.eq(q.find(d.inbounds, (inbound) => inbound.listen_port == 18092).users, [ { username: "one", password: "one-secret" } ]);
});

t.test("a Tailscale server advertises a single address as its own prefix", () => {
    let d = build({
        settings: settings(),
        section: [ { ".name": "main", enabled: "1", action: "connection", outbound_jsons: [ "{\"type\":\"direct\"}" ], destinations: "example.org" } ],
        server: [ { ".name": "tail", enabled: "1", protocol: "tailscale", tailscale_auth_key: "tskey-auth-test", routing_mode: "direct",
            tailscale_advertise_routes: [ "192.168.1.10", "192.168.2.0/24", "fd00::10" ] } ]
    });
    t.eq(q.find(d.endpoints, (e) => e.type == "tailscale").advertise_routes, [ "192.168.1.10/32", "192.168.2.0/24", "fd00::10/128" ]);
});

// sing-box merges only a rule set of one plain rule into the rule naming it, and discord has three.
t.test("a section's own destinations and its rule sets each select traffic on their own", () => {
    let d = build({ settings: settings(), section: [ { ".name": "proxy", enabled: "1", action: "connection",
        outbound_jsons: [ "{\"type\":\"direct\"}" ], destinations: "own.example\n203.0.113.0/24",
        community_lists: [ "discord" ], ports: [ "443" ] } ] });
    let rules = filter(d.route.rules, (r) => r.outbound == "proxy" && r.domain == null);
    t.eq(length(rules), 2);
    let own = q.find(rules, (r) => has(r.domain_suffix, "own.example"));
    t.ok(own != null && has(own.ip_cidr, "203.0.113.0/24") && has(own.port, 443) && has(own.inbound, "tproxy-in"));
    t.eq(own.rule_set, null, "the own destinations do not have to be in the rule set as well");
    let listed = q.find(rules, (r) => r.type == "logical");
    t.ok(has(listed.rules[0].rule_set, "proxy-discord-community-ruleset") && has(listed.rules[0].inbound, "tproxy-in"));
    t.eq([ listed.rules[0].domain_suffix, listed.rules[0].ip_cidr ], [ null, null ], "a listed domain does not have to be an own one as well");
    t.ok(has(listed.rules[1].port, 443), "the section's ports still narrow the rule set");
});

// The core refuses a set of subnets alone in a DNS rule reading the whole set once it loads the set.
t.test("a section's DNS rule reads only the domains of its rule sets, its route rule the whole sets", () => {
    let d = build({ settings: settings(), section: [
        { ".name": "proxy", enabled: "1", action: "connection", outbound_jsons: [ "{\"type\":\"direct\"}" ], rule_set: [ "https://example.com/ports.srs" ] },
        { ".name": "deny", enabled: "1", action: "block", community_lists: [ "discord" ] },
        { ".name": "direct", enabled: "1", action: "bypass", rule_set: [ "https://example.com/direct.srs" ] },
        { ".name": "ru_ip", enabled: "1", action: "bypass", community_lists: [ "telegram" ], rule_set_with_subnets: [ "https://example.com/geoip-ru.srs" ] } ] });
    let proxied = q.dns_rule(d, (r) => has(r.rule_set, q.ruleset_url(d, "https://example.com/ports.srs").tag));
    t.eq([ proxied.server, proxied.rule_set_domain_only ], [ "fakeip-server", true ]);
    let denied = q.dns_rule(d, (r) => has(r.rule_set, "deny-discord-community-ruleset"));
    t.eq([ denied.server, denied.rule_set_domain_only ], [ "fakeip-server", true ]);
    let direct = q.dns_rule(d, (r) => has(r.rule_set, q.ruleset_url(d, "https://example.com/direct.srs").tag));
    t.eq([ direct.server, direct.rule_set_domain_only ], [ "dns-server", true ]);
    let geoip = q.ruleset_url(d, "https://example.com/geoip-ru.srs").tag;
    let subnets = q.dns_rule(d, (r) => has(r.rule_set, geoip));
    t.eq([ subnets.server, subnets.rule_set_domain_only ], [ "dns-server", true ]);
    for (let rule in d.dns.rules)
        if (rule.rule_set != null)
            t.eq(rule.rule_set_domain_only, true, sprintf("%J", rule));
    let route = q.route_rule(d, (r) => has(r.rule_set, geoip));
    t.eq([ route.outbound, route.rule_set_domain_only ], [ "direct-out", null ], "the subnets still select traffic");
});

t.test("the FakeIP check goes direct ahead of every section, so its address is the direct one", () => {
    for (let section in [ { ports: [ "1-65535" ] }, { fully_routed_ips: [ "@system" ] } ]) {
        let d = build({ settings: settings(), section: [ { ".name": "proxy", enabled: "1", action: "connection",
            outbound_jsons: [ "{\"type\":\"direct\"}" ], ...section } ] });
        let check_at = q.route_rule_index(d, (r) => r.domain == "fakeip.podkop.fyi");
        let check = d.route.rules[check_at];
        t.eq([ check.action, check.outbound, check.override_port, check.inbound ], [ "route", "direct-out", 8443, null ]);
        t.ok(check_at < q.route_rule_index(d, (r) => r.outbound == "proxy" && r.domain == null), sprintf("%J", section));
        t.eq(q.route_rule(d, (r) => r.domain == "ip.podkop.fyi").outbound, "proxy", "the exit check still takes the section");
    }
});

t.test("ports on their own select traffic in one rule", () => {
    let d = build({ settings: settings(), section: [
        { ".name": "proxy", enabled: "1", action: "connection", outbound_jsons: [ "{\"type\":\"direct\"}" ], ports: [ "22", "6000-7000" ] },
        { ".name": "deny", enabled: "1", action: "block", ports: [ "25" ] } ] });
    let proxied = filter(d.route.rules, (r) => r.outbound == "proxy" && r.domain == null);
    t.eq(length(proxied), 1);
    t.eq([ proxied[0].port, proxied[0].port_range, proxied[0].rule_set ], [ [ 22 ], [ "6000:7000" ], null ]);
    t.ok(has(proxied[0].inbound, "system-in"), "the router's own traffic is matched as well");
    t.ok(q.route_rule(d, (r) => r.action == "reject" && has(r.port, 25) && has(r.inbound, "tproxy-in")) != null);
});

t.test("a range of one port is a port, since the core refuses a range without a colon", () => {
    let d = build({ settings: settings(), section: [ { ".name": "proxy", enabled: "1", action: "connection",
        outbound_jsons: [ "{\"type\":\"direct\"}" ], destinations: "example.org", ports: [ "443-443", "443", "1000-2000", "x", "80", "1000-2000" ] } ] });
    let rule = q.route_rule(d, (r) => r.outbound == "proxy" && has(r.domain_suffix, "example.org"));
    t.eq([ rule.port, rule.port_range ], [ [ 443, 80 ], [ "1000:2000" ] ]);
});

t.test("DNS action sections build their servers and rules at their priority", () => {
    let d = build({
        settings: settings(),
        section: [
            {
                ".name": "dns_first", enabled: "1", action: "dns",
                dns_server: [ "tls://9.9.9.9:5353", "https://1.1.1.1/dns-query", "quic://9.9.9.9", "h3://1.1.1.1/dns-query", "tcp://8.8.8.8", "8.8.4.4" ],
                dns_fallback_strategy: "sequential", dns_detour_enabled: "1", dns_detour_section: "detour",
                destinations: "dns-first.example", community_lists: [ "youtube" ],
                rule_set: [ "https://example.com/domain-only.srs", "/tmp/dns-action.lst" ],
                source_ip_cidr: [ "192.0.2.1/32" ], fully_routed_ips: [ "192.0.2.2/32" ], ports: [ "443" ]
            },
            { ".name": "proxy", enabled: "1", action: "connection", outbound_jsons: [ "{\"type\":\"direct\"}" ], destinations: "dns-first.example\nproxy-first.example" },
            { ".name": "dns_second", enabled: "1", action: "dns", dns_server: [ "8.8.8.8" ], destinations: "proxy-first.example", fully_routed_ips: [ "192.0.2.3/32" ] },
            { ".name": "detour", enabled: "1", action: "connection", outbound_jsons: [ "{\"type\":\"direct\"}" ], destinations: "detour.example" }
        ]
    });

    let group = q.dns_server_tag(d, "dns_first-dns-server");
    t.eq([ group.type, group.strategy, length(group.servers) ], [ "fallback", "sequential", 6 ]);
    t.ok(q.dns_server(d, (r) => r.tag == "dns_first-dns-server-1" && r.type == "tls" && r.server == "9.9.9.9" && r.server_port == 5353 && r.detour == "detour") != null);
    t.ok(q.dns_server(d, (r) => r.tag == "dns_first-dns-server-2" && r.type == "https" && r.path == "/dns-query") != null);
    t.ok(q.dns_server(d, (r) => r.tag == "dns_first-dns-server-3" && r.type == "quic" && r.server_port == 853) != null);
    t.ok(q.dns_server(d, (r) => r.tag == "dns_first-dns-server-4" && r.type == "h3" && r.server_port == 443) != null);
    t.ok(q.dns_server(d, (r) => r.tag == "dns_first-dns-server-5" && r.type == "tcp" && r.server_port == 53) != null);
    t.ok(q.dns_server(d, (r) => r.tag == "dns_first-dns-server-6" && r.type == "udp" && r.server_port == 53) != null);
    t.ok(q.dns_server(d, (r) => r.tag == "dns_second-dns-server" && r.server == "8.8.8.8") != null);
    t.eq([ q.outbound(d, "dns_first-out"), q.outbound(d, "dns_second-out") ], [ null, null ], "DNS actions create no outbound");
    t.ok(q.route_rule(d, (r) => has(r.domain_suffix, "dns-first.example") && r.outbound != null) != null);
    t.eq(q.route_rule(d, (r) => has(r.domain_suffix, "list-dns.example")), null, "a DNS action creates no route rule");

    let dns_first_at = q.dns_rule_index(d, (r) => has(r.domain_suffix, "dns-first.example") && r.server == "dns_first-dns-server");
    let proxy_after = q.dns_rule_index(d, (r) => has(r.domain_suffix, "dns-first.example") && r.server == "fakeip-server");
    t.ok(dns_first_at >= 0 && proxy_after > dns_first_at, "a higher DNS action wins over a lower proxy");
    let dns_first_rule = d.dns.rules[dns_first_at];
    t.ok(has(dns_first_rule.inbound, "source-dns-in") && has(dns_first_rule.source_ip_cidr, "192.0.2.1/32"));
    let forced_at = q.dns_rule_index(d, (r) => r.server == "dns_first-dns-server" && r.domain == null && r.domain_suffix == null && has(r.source_ip_cidr, "192.0.2.2/32"));
    t.ok(forced_at >= 0 && forced_at < proxy_after);
    let proxy_first = q.dns_rule_index(d, (r) => has(r.domain_suffix, "proxy-first.example") && r.server == "fakeip-server");
    let dns_after = q.dns_rule_index(d, (r) => has(r.domain_suffix, "proxy-first.example") && r.server == "dns_second-dns-server");
    t.ok(proxy_first >= 0 && dns_after > proxy_first, "a higher proxy wins over a lower DNS action");
    let second_forced = q.dns_rule_index(d, (r) => r.server == "dns_second-dns-server" && r.domain == null && r.domain_suffix == null && has(r.source_ip_cidr, "192.0.2.3/32"));
    t.ok(second_forced > proxy_first);

    let community = q.dns_rule(d, (r) => has(r.rule_set, "dns_first-youtube-community-ruleset") && r.server == "dns_first-dns-server" && has(r.source_ip_cidr, "192.0.2.1/32"));
    t.eq(community.rule_set_domain_only, true, "a DNS action reads only the domain half of a rule set");
    t.eq(dns_first_rule.rule_set_domain_only, null);
    let custom = q.ruleset_url(d, "https://example.com/domain-only.srs");
    t.ok(q.dns_rule(d, (r) => has(r.rule_set, custom.tag) && r.server == "dns_first-dns-server" && has(r.source_ip_cidr, "192.0.2.1/32")) != null);
    let local = q.ruleset_path(d, "/tmp/dns-action.lst");
    t.eq([ local.type, local.format ], [ "local", "auto" ]);
    t.ok(q.dns_rule(d, (r) => has(r.rule_set, local.tag) && r.server == "dns_first-dns-server") != null);
    t.ok(q.dns_rule(d, (r) => r.server == "dnsmasq-server" && r.domain == null && r.domain_suffix == null && r.rule_set == null &&
        has(r.inbound, "source-dns-in") && r.source_ip_cidr == null) != null);
    let forced_local = q.dns_rule_index(d, (r) => r.server == "dnsmasq-server" && r.domain_regex == "^[^.]+$" && has(r.source_ip_cidr, "192.0.2.2/32"));
    t.ok(forced_local >= 0 && forced_local < forced_at, "a forced device's local names stay with the local resolver");
    t.eq(q.route_rule(d, (r) => has(r.source_ip_cidr, "192.0.2.2/32")), null, "a forced DNS action does not route device traffic");
});

t.test("a URLTest group filters its members and becomes the selector default", () => {
    let u = build({
        settings: settings(),
        section: [ {
            ".name": "proxy", enabled: "1", action: "connection",
            outbound_jsons: [
                "{\"type\":\"http\",\"tag\":\"Keep\",\"server\":\"127.0.0.1\",\"server_port\":18081}",
                "{\"type\":\"http\",\"tag\":\"Drop\",\"server\":\"127.0.0.1\",\"server_port\":18082}"
            ],
            destinations: "example.org"
        } ],
        urltest: [ { ".name": "proxy_fastest", section: "proxy", name: "Fastest", server_filter_mode: "include", include_outbounds: [ "Keep" ] } ]
    });
    t.eq(q.outbound(u, "proxy/Fastest").outbounds, [ "proxy/Keep" ]);
    t.eq(q.outbound(u, "proxy/Keep").type, "http");
    t.eq(q.outbound(u, "proxy").default, "proxy/Fastest");
});

t.test("manual links stay verbatim in parser outbounds, JSON outbounds keep their transport", () => {
    let socks = build({ settings: { dns_server: "1.1.1.1" }, section: [ { ".name": "proxy", enabled: "1", action: "connection" } ], connection_link: fixture.links("proxy", [ "socks5://127.0.0.1:8080" ]) });
    t.eq(q.outbound(socks, "proxy/Node #1").type, "parser");

    let link = "vless://11111111-1111-4111-8111-111111111111@127.0.0.1:443?security=tls&type=ws&path=%2Fws&host=example.com&sni=example.com&alpn=h2%2Chttp%2F1.1&encryption=mlkem768x25519plus.native.test#WS";
    let manual = build({
        settings: settings(),
        section: [ {
            ".name": "proxy", enabled: "1", action: "connection",
            destinations: "example.org"
        } ],
        connection_link: fixture.links("proxy", [
            link,
            "vmess://eyJ2IjoiMiIsInBzIjoiVk1lc3MgV1MiLCJhZGQiOiIxMjcuMC4wLjEiLCJwb3J0IjoiNDQzIiwiaWQiOiIyMjIyMjIyMi0yMjIyLTQyMjItODIyMi0yMjIyMjIyMjIyMjIiLCJhaWQiOiI0Iiwic2N5IjoiYXV0byIsIm5ldCI6IndzIiwidHlwZSI6Im5vbmUiLCJob3N0Ijoidm1lc3MuZXhhbXBsZSIsInBhdGgiOiIvdm1lc3MiLCJ0bHMiOiJ0bHMiLCJzbmkiOiJ2bWVzcy5leGFtcGxlIiwiYWxwbiI6ImgyLGh0dHAvMS4xIiwiZnAiOiJjaHJvbWUifQ==#VMess",
            "ss://YWVzLTEyOC1nY206cGFzcw@127.0.0.1:8388#SS"
        ])
    });
    t.eq(q.outbound(manual, "proxy/WS").link, link);

    let xhttp = build({ settings: { dns_server: "1.1.1.1" }, section: [ {
        ".name": "manual_xhttp", enabled: "1", action: "connection"
    } ], connection_link: fixture.links("manual_xhttp", [ "vless://00000000-0000-4000-8000-000000000001@xhttp.example:443?encryption=none&security=tls&sni=xhttp.example&type=xhttp#Manual XHTTP" ]) });
    t.contains(q.outbound(xhttp, "manual_xhttp/Manual XHTTP").link, "type=xhttp");

    let json_xhttp = build({ settings: { dns_server: "1.1.1.1" }, section: [ {
        ".name": "json_xhttp", enabled: "1", action: "connection",
        outbound_jsons: [ "{\"type\":\"vless\",\"tag\":\"JSON XHTTP\",\"server\":\"xhttp.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000002\",\"transport\":{\"type\":\"xhttp\"}}" ]
    } ] });
    t.eq(q.outbound(json_xhttp, "json_xhttp/JSON XHTTP").transport.type, "xhttp");
});

t.test("interface outbounds resolve through their own resolver group", () => {
    let v = build({
        settings: settings(),
        section: [
            { ".name": "renamed_awg", enabled: "1", action: "connection", destinations: "vpn.example" },
            { ".name": "detoured_awg", enabled: "1", action: "connection", label: "Detoured", destinations: "detour.example" },
            {
                ".name": "resolver_detour", enabled: "1", action: "connection", label: "Resolver detour"
            }
        ],
        connection_link: fixture.links("resolver_detour", [ "vless://00000000-0000-4000-8000-000000000003@127.0.0.1:8443?security=none&type=tcp#Detour" ]),
        section_interface: [
            {
                ".name": "vpn-interface", section: "renamed_awg", name: "tun0", domain_resolver_enabled: "1",
                domain_resolver_dns_server: [ "https://dns.example/dns-query", "tls://1.1.1.1" ],
                domain_resolver_dns_fallback_strategy: "sequential"
            },
            {
                ".name": "detour-interface", section: "detoured_awg", name: "tun1", domain_resolver_enabled: "1",
                domain_resolver_dns_server: [ "9.9.9.9" ], domain_resolver_dns_detour_enabled: "1",
                domain_resolver_dns_detour_section: "resolver_detour"
            }
        ]
    });
    let tun0 = q.outbound(v, "renamed_awg/tun0");
    t.eq([ tun0.bind_interface, tun0.domain_resolver, tun0.detour ], [ "tun0", "renamed_awg-interface-1-domain-resolver", null ]);
    let resolver = q.dns_server_tag(v, "renamed_awg-interface-1-domain-resolver");
    t.eq([ resolver.type, resolver.strategy, resolver.servers ],
        [ "fallback", "sequential", [ "renamed_awg-interface-1-domain-resolver-1", "renamed_awg-interface-1-domain-resolver-2" ] ]);
    let first = q.dns_server_tag(v, "renamed_awg-interface-1-domain-resolver-1");
    t.eq([ first.type, first.server, first.path, first.detour ], [ "https", "dns.example", "/dns-query", "renamed_awg/tun0" ],
        "a resolver without a DNS detour queries through its own interface");
    let second = q.dns_server_tag(v, "renamed_awg-interface-1-domain-resolver-2");
    t.eq([ second.type, second.server, second.server_port ], [ "tls", "1.1.1.1", 853 ]);
    let detoured = q.dns_server_tag(v, "detoured_awg-interface-1-domain-resolver");
    t.eq([ detoured.type, detoured.server, detoured.detour ], [ "udp", "9.9.9.9", "Resolver detour" ],
        "a DNS detour replaces the interface with the selected section");
    t.ok(q.route_rule(v, (r) => r.outbound == "renamed_awg" && has(r.domain_suffix, "vpn.example")) != null);
    t.ok(q.dns_rule(v, (r) => has(r.domain_suffix, "vpn.example")) != null);
});

t.test("downloads through a section get service inbounds and rule-set detours", () => {
    let d = build({
        settings: settings({ download_lists_via_proxy: "1", download_lists_via_proxy_section: "proxy" }),
        section: [
            {
                ".name": "proxy", enabled: "1", action: "connection",
                outbound_jsons: [ "{\"type\":\"socks\",\"server\":\"127.0.0.1\",\"server_port\":1080}" ],
                destinations: "example.org", community_lists: [ "discord" ],
                rule_set: [ "https://example.com/rules.srs" ], rule_set_with_subnets: [ "https://example.com/mixed.txt" ]
            }
        ]
    });
    t.eq(filter(d.inbounds, (inbound) => index(inbound.tag, "service-subscription") == 0), [], "a subscription downloads through its detour, not a port");
    t.eq(q.ruleset(d, "proxy-discord-community-ruleset").http_client.detour, "proxy");
    t.eq(q.ruleset_url(d, "https://example.com/rules.srs").http_client.detour, "proxy");
    let text_ruleset = q.ruleset_url(d, "https://example.com/mixed.txt");
    t.eq([ text_ruleset.format, text_ruleset.update_interval, text_ruleset.http_client.detour ], [ "auto", "1d", "proxy" ]);

    let sections = [ {
        ".name": "proxy", enabled: "1", action: "connection",
        outbound_jsons: [ "{\"type\":\"socks\",\"server\":\"127.0.0.1\",\"server_port\":1080}" ],
        community_lists: [ "discord" ], rule_set: [ "https://example.com/rules.srs" ]
    } ];
    let direct = build({ settings: settings(), section: sections });
    t.eq([ q.ruleset(direct, "proxy-discord-community-ruleset").http_client.detour,
        q.ruleset_url(direct, "https://example.com/rules.srs").http_client.detour ], [ "direct-out", "direct-out" ],
        "without a section a list downloads direct, whatever the route's final outbound");
    let through_section = build({
        settings: settings({ download_lists_via_proxy: "1", download_lists_via_proxy_section: "proxy" }),
        section: sections
    });
    t.eq(map(through_section.inbounds, (inbound) => inbound.tag), map(direct.inbounds, (inbound) => inbound.tag),
        "lists download through a section as a rule-set detour and open no port for it");
});

t.test("WARP profile requests go through the chosen section: the tunnel names it, the page's generator gets an inbound", () => {
    let data = (extra) => ({
        settings: settings(extra),
        section: [
            { ".name": "proxy", enabled: "1", action: "connection", outbound_jsons: [ "{\"type\":\"direct\"}" ], destinations: "example.org" },
            { ".name": "tunnels", enabled: "1", action: "connection" }
        ],
        tunnel: [ {
            ".name": "tun_warp", section: "tunnels", order: "0", kind: "warp", name: "WARP",
            warp_profile_id: "profile-id", warp_profile_auth_token: "auth-token", warp_profile_private_key: "private-key"
        } ]
    });

    let through = build(data({ warp_profiles_via_proxy: "1", warp_profiles_via_proxy_section: "proxy" }));
    let warp = q.endpoint(through, "tunnels/WARP");
    t.eq([ warp.profile.id, warp.profile.detour ], [ "profile-id", "proxy" ]);
    t.eq(q.inbound(through, "service-warp-in").listen_port, 4536);
    t.ok(q.route_rule(through, (r) => r.inbound == "service-warp-in" && r.outbound == "proxy") != null);

    let direct = build(data());
    t.eq([ q.endpoint(direct, "tunnels/WARP").profile.detour, q.inbound(direct, "service-warp-in") ], [ null, null ],
        "without a section the profile goes the way the router's own traffic goes");
});

t.test("the Clash API dashboard downloads its interface direct, wherever the lists download", () => {
    let sections = [
        { ".name": "proxy", enabled: "1", action: "connection", outbound_jsons: [ "{\"type\":\"direct\"}" ], destinations: "example.org" },
        { ".name": "lists_proxy", enabled: "1", action: "connection", outbound_jsons: [ "{\"type\":\"direct\"}" ], destinations: "lists.example" }
    ];
    let through_section = build({
        settings: settings({ enable_yacd: "1", download_lists_via_proxy: "1", download_lists_via_proxy_section: "lists_proxy" }),
        section: sections
    });
    t.eq([ through_section.experimental.clash_api.external_ui, through_section.experimental.clash_api.external_ui_download_detour ],
        [ "ui", "direct-out" ]);
    let without_ui = build({
        settings: settings({ download_lists_via_proxy: "1", download_lists_via_proxy_section: "lists_proxy" }),
        section: sections
    });
    t.eq(without_ui.experimental.clash_api.external_ui_download_detour, null, "no interface, nothing to download");
});

t.test("the Clash API asks for the key with YACD and without it", () => {
    let section = [ { ".name": "proxy", enabled: "1", action: "connection", outbound_jsons: [ "{\"type\":\"direct\"}" ], destinations: "example.org" } ];
    for (let yacd in [ "0", "1" ]) {
        let api = build({ settings: settings({ enable_yacd: yacd, yacd_secret_key: "0123abcd" }), section }).experimental.clash_api;
        t.eq([ api.external_controller, api.secret ], [ "127.0.0.1:9090", "0123abcd" ], "YACD " + yacd);
    }
});

t.test("with access from the WAN the Clash API listens on both address families", () => {
    let section = [ { ".name": "proxy", enabled: "1", action: "connection", outbound_jsons: [ "{\"type\":\"direct\"}" ], destinations: "example.org" } ];
    let controller = (extra, address) => {
        fixture.seed({ settings: settings(extra), section });
        return generator.build({ service_address: address }).experimental.clash_api.external_controller;
    };
    t.eq(controller({ enable_yacd: "1", enable_yacd_wan_access: "1" }, "192.168.1.1"), "[::]:9090");
    t.eq(controller({ enable_yacd: "0", enable_yacd_wan_access: "1" }, "192.168.1.1"), "192.168.1.1:9090", "no WAN access without YACD");
    t.eq(controller({ enable_yacd: "1" }, "fd00::1"), "[fd00::1]:9090", "an IPv6 LAN address");
});

t.test("fully routed devices follow their section at its priority", () => {
    let f = build({
        settings: settings(),
        section: [
            { ".name": "proxy_high", enabled: "1", action: "connection", outbound_jsons: [ "{\"type\":\"direct\"}" ], destinations: "forced-higher.test" },
            {
                ".name": "bypass", enabled: "1", action: "bypass",
                fully_routed_ips: [ "192.168.1.20/32", "192.168.1.30/32", "2001:db8::20/128", "@system" ],
                destinations: "example.org"
            },
            {
                ".name": "proxy", enabled: "1", action: "connection", outbound_jsons: [ "{\"type\":\"direct\"}" ],
                fully_routed_ips: [ "192.168.1.40/32" ], destinations: "proxy.example.org\nforced-lower.test"
            }
        ]
    });
    t.ok(q.route_rule(f, (r) => r.outbound == "direct-out" && has(r.inbound, "tproxy-in") && has(r.inbound, "tproxy6-in") &&
        has(r.source_ip_cidr, "192.168.1.20/32") && has(r.source_ip_cidr, "192.168.1.30/32") && has(r.source_ip_cidr, "2001:db8::20/128")) != null);
    t.ok(q.route_rule(f, (r) => r.outbound == "direct-out" && has(r.inbound, "system-in") && has(r.inbound, "system6-in") &&
        r.source_ip_cidr == null && r.domain == null) != null, "fully routed System bypass route");
    t.ok(q.route_rule(f, (r) => r.outbound == "proxy" && has(r.source_ip_cidr, "192.168.1.40/32")) != null);
    let every_query = (r) => r.domain == null && r.domain_suffix == null && r.domain_regex == null && r.rule_set == null && r.query_type == null;
    t.ok(q.dns_rule(f, (r) => r.server == "dns-server" && has(r.source_ip_cidr, "192.168.1.20/32") && every_query(r)) != null,
        "a fully routed bypass takes real addresses for every domain");
    t.ok(q.dns_rule(f, (r) => r.server == "dns-server" && has(r.inbound, "system-dns-in") && r.source_ip_cidr == null && every_query(r)) != null,
        "the System bypass takes real addresses from the server unmatched queries use");
    t.eq(q.dns_rule(f, (r) => has(r.source_ip_cidr, "192.168.1.40/32")), null, "a fully routed proxy keeps the normal FakeIP policy");

    let higher = q.dns_rule_index(f, (r) => r.server == "fakeip-server" && has(r.domain_suffix, "forced-higher.test"));
    let forced = q.dns_rule_index(f, (r) => r.server == "dns-server" && has(r.source_ip_cidr, "192.168.1.20/32") && every_query(r));
    let lower = q.dns_rule_index(f, (r) => r.server == "fakeip-server" && has(r.domain_suffix, "forced-lower.test"));
    t.ok(higher >= 0 && forced > higher && lower > forced, "the forced bypass keeps its section priority in DNS rules");
    let higher_route = q.route_rule_index(f, (r) => r.outbound == "proxy_high" && has(r.domain_suffix, "forced-higher.test"));
    let forced_route = q.route_rule_index(f, (r) => r.outbound == "direct-out" && has(r.source_ip_cidr, "192.168.1.20/32") && r.domain == null && r.domain_suffix == null);
    let lower_route = q.route_rule_index(f, (r) => r.outbound == "proxy" && has(r.domain_suffix, "forced-lower.test"));
    t.ok(higher_route >= 0 && forced_route > higher_route && lower_route > forced_route, "and in route rules");
    t.excludes(sprintf("%J", f), "@system");
});

t.test("sing-box's own connections follow the routes unless an output interface is pinned", () => {
    let base = {
        settings: settings(),
        section: [ { ".name": "proxy", enabled: "1", action: "connection", outbound_jsons: [ "{\"type\":\"direct\"}" ], destinations: "example.org" } ]
    };
    let routed = build(base);
    t.eq([ routed.route.auto_detect_interface, routed.route.default_interface, routed.route.default_mark ], [ null, null, 0x08000000 ]);
    base.settings.output_network_interface = "wan2";
    let pinned = build(base);
    t.eq([ pinned.route.auto_detect_interface, pinned.route.default_interface ], [ null, "wan2" ]);
});

t.test("universal rule sets are native, independently tagged and shared by route and DNS", () => {
    let l = build({
        settings: settings(),
        section: [ {
            ".name": "proxy", enabled: "1", action: "connection", outbound_jsons: [ "{\"type\":\"direct\"}" ],
            destinations: "example.org",
            rule_set_with_subnets: [ "/tmp/with-subnets.json", "/tmp/domain-ip.lst", "https://example.com/domain-ip.txt" ]
        } ]
    });
    t.ok(q.no_internal_fields(l), "internal fields are stripped");
    let local = q.ruleset_path(l, "/tmp/domain-ip.lst");
    let remote = q.ruleset_url(l, "https://example.com/domain-ip.txt");
    t.eq([ local.type, local.format ], [ "local", "auto" ]);
    t.eq([ remote.type, remote.format, remote.update_interval ], [ "remote", "auto", "1d" ]);
    t.ok(local.tag != remote.tag);
    t.ok(q.route_rule(l, (r) => has(r.rule_set, local.tag) && has(r.rule_set, remote.tag) && length(q.as_array(r.rule_set)) >= 3) != null);
    t.ok(q.dns_rule(l, (r) => has(r.rule_set, local.tag) && has(r.rule_set, remote.tag)) != null);
});

t.done();
