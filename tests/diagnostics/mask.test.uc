let t = require("t");
let mask = require("diagnostics.mask");

t.test("the masked Forkop configuration keeps its shape and loses every secret", () => {
    let masked = mask.forkop_config(
        "config settings 'main'\n        option hwid 'device-secret'\n        option proxy_string 'vless://secret@example.com:443'\n" +
        "        option yacd_secret_key 'clash-api-secret'\n" +
        "config subscription_url 'sub1'\n        option url 'https://user:password@example.com/subscription?token=secret'\n" +
        "        list header 'Authorization: Bearer header-secret'\nconfig section 'tunnels'\nconfig tunnel 'tun_tailnet'\n" +
        "        option section 'tunnels'\n        option kind 'tailscale'\n        option tailscale_auth_key 'tskey-secret'\n" +
        "        option warp_profile_auth_token 'warp-token-secret'\n        option warp_profile_private_key 'warp-private-secret'\n" +
        "        option warp_profile_license_key 'warp-license-secret'\nconfig tunnel_peer 'peer_tailnet'\n" +
        "        option tunnel 'tun_tailnet'\n        option pre_shared_key 'peer-secret'\n" +
        "config connection_link 'link_1'\n        option uri 'trojan://link-secret@example.com:443#Node'\n        option name 'Node'\n");
    for (let secret in [ "device-secret", "vless://secret", "clash-api-secret", "token=secret", "user:password", "header-secret",
        "tskey-secret", "warp-token-secret", "warp-private-secret", "warp-license-secret", "peer-secret", "link-secret" ])
        t.excludes(masked, secret);
    for (let kept in [ "list header 'MASKED'", "option hwid 'MASKED'", "option url 'MASKED'", "option tailscale_auth_key 'MASKED'",
        "option warp_profile_auth_token 'MASKED'", "option pre_shared_key 'MASKED'", "option uri 'MASKED'", "option name 'Node'" ])
        t.contains(masked, kept);
});

t.test("hand-written outbounds are masked, however many lines they take", () => {
    let masked = mask.forkop_config("config section 'main'\n        list outbound_jsons '{\"type\":\"vless\",\"server\":\"secret.example\"}'\n" +
        "        list outbound_jsons '{\n            \"type\": \"trojan\",\n            \"password\": \"trojan-secret\"\n        }'\n        option label 'Main'\n");
    t.excludes(masked, "secret.example");
    t.excludes(masked, "trojan-secret");
    t.contains(masked, "list outbound_jsons 'MASKED'");
    t.contains(masked, "option label 'Main'", "the line after a masked JSON value is kept");
});

t.test("what a section routes is masked, however many lines it takes", () => {
    let masked = mask.forkop_config("config section 'main'\n\toption destinations 'keyword:private\nsite.example\n203.0.113.0/24'\n" +
        "\toption label 'Main'\n\tlist community_lists 'telegram'\n");
    for (let secret in [ "private", "site.example", "203.0.113.0/24" ])
        t.excludes(masked, secret);
    for (let kept in [ "option destinations 'MASKED'", "option label 'Main'", "list community_lists 'telegram'" ])
        t.contains(masked, kept);
});

t.test("the sing-box dump hides the subscription behind a provider and a private resolver's account", () => {
    let masked = mask.sing_box_config({
        providers: [ { tag: "Main/sub1", type: "remote", url: "https://panel.example/sub?token=sub-secret", headers: { "X-HWID": "hwid-secret" } } ],
        route: { rule_set: [ { tag: "list", type: "remote", url: "https://lists.example/russia.srs" } ] },
        dns: { servers: [ { tag: "a", type: "https", server: "d.adguard-dns.com", path: "/dns-query/adguard-secret" },
            { tag: "b", type: "https", server: "1.1.1.1", path: "/dns-query" } ] }
    });
    let text = sprintf("%J", masked);
    for (let secret in [ "sub-secret", "hwid-secret", "adguard-secret" ])
        t.excludes(text, secret);
    t.eq(masked.route.rule_set[0].url, "https://lists.example/russia.srs", "a public list keeps its URL");
    t.eq([ masked.dns.servers[0].path, masked.dns.servers[1].path ], [ "/dns-query/MASKED", "/dns-query" ]);
});

t.test("a private resolver's account is masked in its host or its path, a public one stays readable", () => {
    for (let pair in [
        [ "https://dns.nextdns.io/abc123", "https://dns.nextdns.io/******" ],
        [ "tls://abc123.dns.nextdns.io", "tls://******.dns.nextdns.io" ],
        [ "https://d.adguard-dns.com/dns-query/abcd1234", "https://d.adguard-dns.com/dns-query/MASKED" ],
        [ "quic://abcd1234.d.adguard-dns.com", "quic://********.d.adguard-dns.com" ],
        [ "https://dns.controld.com/abcd1234", "https://dns.controld.com/MASKED" ],
        [ "tls://abcd1234.dns.controld.com", "tls://********.dns.controld.com" ],
        [ "https://1.1.1.1/dns-query", "https://1.1.1.1/dns-query" ],
        [ "8.8.8.8", "8.8.8.8" ]
    ])
        t.eq(mask.dns_server(pair[0]), pair[1], pair[0]);
});

const TUNNELS_AND_SERVERS = join("\n", [
    "config tunnel 'tun_warp'",
    "\toption kind 'warp'",
    "\toption warp_profile_id 'e9f13cd5-37ec-442f-b288-5833ad86b9e5'",
    "\toption warp_profile_license_key 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'",
    "\toption amnezia_jc '4'",
    "",
    "config tunnel 'tun_awg'",
    "\toption kind 'amneziawg'",
    "\tlist address '10.8.1.9/32'",
    "\toption private_key 'zz5/p+jwYqPFlg9mWcOP5ad8xXa4XfOOlrzouVD6E1w='",
    "\toption mtu '1280'",
    "\toption amnezia_header_protection_key 'X41Gx29SDgyl6QjV7g7sg4nuJvGu4tKdDgtssPUEU4g='",
    "",
    "config tunnel_peer 'tp_awg'",
    "\toption address 'peer.example.com'",
    "\toption port '47132'",
    "\toption public_key 'AKR8dq2b9o7/cO8d5mAzxvuxRhhw4DXi1pfUC3IPGWo='",
    "\tlist allowed_ips '0.0.0.0/0'",
    "",
    "config tunnel 'tun_json'",
    "\toption endpoint_json '{",
    "\t\"type\": \"wireguard\",",
    "\t\"private_key\": \"leaked\"",
    "}'",
    "",
    "config server 'srv_token'",
    "\toption inbound_json '{\"type\":\"trusttunnel\",\"token\":\"raw-inbound-token\"}'",
    "",
    "config server 'srv_json'",
    "\toption inbound_json '{",
    "\t\"type\": \"shadowsocks\",",
    "\t\"password\": \"inbound-leaked\"",
    "}'",
    "\toption routing_mode 'direct'",
    "",
    "config server 'srv_openvpn'",
    "\toption protocol 'openvpn'",
    "\toption openvpn_key '-----BEGIN PRIVATE KEY-----",
    "server-private-key",
    "-----END PRIVATE KEY-----'",
    "\toption openvpn_tls_crypt_key '-----BEGIN OpenVPN Static key V1-----",
    "tls-crypt-secret",
    "-----END OpenVPN Static key V1-----'",
    "",
    "config server_client 'client_openvpn'",
    "\toption openvpn_certificate '-----BEGIN CERTIFICATE-----",
    "client-certificate",
    "-----END CERTIFICATE-----'",
    "\toption openvpn_key '-----BEGIN PRIVATE KEY-----",
    "client-private-key",
    "-----END PRIVATE KEY-----'",
    "\toption openvpn_certificate_sha256 'ab'",
    "",
    "config server 'srv_wireguard'",
    "\toption protocol 'amneziawg'",
    "\toption wireguard_private_key 'wg-server-private='",
    "\toption wireguard_public_key 'wg-server-public='",
    "\toption amnezia_header_protection_key 'wg-header-key='",
    "\toption amnezia_s1 '12'",
    "",
    "config server_client 'client_wireguard'",
    "\toption wireguard_private_key 'wg-client-private='",
    "\toption wireguard_public_key 'wg-client-public='",
    "\toption wireguard_pre_shared_key 'wg-client-psk='",
    "\tlist wireguard_address '10.8.0.2/32'",
    "",
    "config server 'srv_tls'",
    "\toption tls_certificate '-----BEGIN CERTIFICATE-----",
    "own-certificate",
    "-----END CERTIFICATE-----'",
    "\toption tls_key '/etc/ssl/acme/own-key-path.key'",
    "\toption tls_self_signed_key '-----BEGIN PRIVATE KEY-----",
    "self-signed-private-key",
    "-----END PRIVATE KEY-----'",
    ""
]);

t.test("tunnels, their peers and JSON servers lose their keys and addresses and keep their settings", () => {
    let masked = mask.forkop_config(TUNNELS_AND_SERVERS);
    for (let secret in [
        "e9f13cd5-37ec-442f-b288-5833ad86b9e5", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "10.8.1.9/32",
        "zz5/p+jwYqPFlg9mWcOP5ad8xXa4XfOOlrzouVD6E1w=", "peer.example.com", "47132",
        "AKR8dq2b9o7/cO8d5mAzxvuxRhhw4DXi1pfUC3IPGWo=", "0.0.0.0/0", "leaked", "raw-inbound-token", "inbound-leaked",
        "server-private-key", "tls-crypt-secret", "client-certificate", "client-private-key", "END PRIVATE KEY",
        "own-certificate", "own-key-path", "self-signed-private-key", "X41Gx29SDgyl6QjV7g7sg4nuJvGu4tKdDgtssPUEU4g=",
        "wg-server-private", "wg-server-public", "wg-header-key", "wg-client-private", "wg-client-public", "wg-client-psk"
    ])
        t.excludes(masked, secret);
    for (let kept in [ "option kind 'warp'", "option amnezia_jc '4'", "option mtu '1280'", "option routing_mode 'direct'",
        "option protocol 'openvpn'", "option openvpn_certificate_sha256 'ab'", "option amnezia_s1 '12'",
        "list wireguard_address '10.8.0.2/32'" ])
        t.contains(masked, kept);
});

t.test("the credentials of a native endpoint are masked in the sing-box dump without touching the input", () => {
    for (let key in [ "psk", "userkey", "static_key", "key", "client_key", "certificate", "client_certificate",
        "peer_fingerprint", "cookie", "token", "auth_token", "license_key",
        "client_key_password", "mca_certificate", "mca_key", "mca_key_password", "form_entries", "local_hostname",
        "device_unique_id" ]) {
        let config = { endpoints: [ { tls: { [key]: [ "sensitive" ] } } ] };
        t.eq(mask.sing_box_config(config).endpoints[0].tls[key], "MASKED", key);
        t.eq(config.endpoints[0].tls[key], [ "sensitive" ], key + " in the input");
    }
});

t.test("an AmneziaWG server keeps its obfuscation settings and loses its header protection key", () => {
    let masked = mask.sing_box_config({ endpoints: [ { type: "amneziawg", tag: "Server", private_key: "server-private=",
        amnezia: { jc: 6, h1: 335028323, header_protection_key: "header-secret=" } } ] });
    t.excludes(sprintf("%J", masked), "header-secret");
    t.eq([ masked.endpoints[0].amnezia.jc, masked.endpoints[0].amnezia.h1 ], [ 6, 335028323 ]);
});

t.test("a public address keeps what tells it apart, and a local one stays as it is", () => {
    t.eq(map([ "194.76.146.236", "2a02:6b8:c0e:500:1:2:3:4", "2a00:1450::1", "192.168.1.1", "127.0.0.42", "198.18.0.7", "2001:2::7", "fc00::7", "::1" ], mask.address),
        [ "X.X.X.236", "2a02:6b8:c0e:XXXX:XXXX:XXXX:XXXX:XXXX", "2a00:1450:0:XXXX:XXXX:XXXX:XXXX:XXXX", "192.168.1.1", "127.0.0.42", "198.18.0.7", "2001:2::7", "fc00::7", "::1" ]);
});

t.test("the server addresses come from every place the generated configuration dials", () => {
    let hosts = mask.hosts({
        outbounds: [ { type: "parser", tag: "a", link: "vless://uuid@link.example:443?sni=front.example#name" },
            { type: "vless", tag: "b", server: "plain.example", tls: { server_name: "sni.example" } }, { type: "direct", tag: "direct-out" } ],
        endpoints: [ { type: "wireguard", peers: [ { address: "peer.example", allowed_ips: [ "0.0.0.0/0" ] } ], address: [ "10.0.0.2/32" ] } ],
        providers: [ { tag: "sub", url: "https://panel.example/sub?token=1" } ],
        dns: { servers: [ { type: "https", server: "dns.example" }, { type: "udp", server: "77.88.8.8" } ] },
        route: { rule_set: [ { url: "https://github.com/lists/list.srs" } ] }
    });
    t.eq(sort(hosts), [ "dns.example", "link.example", "panel.example", "peer.example", "plain.example", "sni.example" ]);
    t.eq(mask.hosts(null), []);
});

t.test("a host name is masked as a name, with its subdomains, never inside another word", () => {
    t.eq(mask.names("t.me and api.t.me, but.message, t.mesh, t.me.", [ "t.me" ]), "MASKED and api.MASKED, but.message, t.mesh, MASKED.");
    t.eq(mask.names("Main/Vless node.example #2", [ "node.example" ]), "Main/Vless MASKED #2");
});

t.test("free text loses URL paths and credentials, the given hosts and public addresses, and keeps the rest readable", () => {
    let log = join("\n", [
        "Mon Oct 19 17:05:01 2026 user.err forkop: [error] Failed to download https://user:pw@panel.example/sub?token=secret for 'Main'",
        "Mon Oct 19 17:05:02 2026 daemon.err sing-box[42]: ERROR[0330] outbound/vless[Main/node.example]: dial tcp 185.199.108.9:443: i/o timeout",
        "Mon Oct 19 17:05:03 2026 daemon.err sing-box[42]: ERROR[0331] dial [2a00:1450::1]:443 from 192.168.1.140 via 127.0.0.42:53",
        "Mon Oct 19 17:05:04 2026 user.info forkop: [info] Loaded 1.14.1 rule sets from https://github.com/",
        "Mon Oct 19 17:05:05 2026 user.err forkop: [error] Failed to download https://lists.example?key=query-secret#part"
    ]);
    let masked = mask.text(log, [ "panel.example", "node.example" ]);
    for (let secret in [ "secret", "user:pw", "panel.example", "node.example", "185.199.108.9", "2a00:1450::1", "query-secret", "#part" ])
        t.excludes(masked, secret);
    for (let kept in [ "https://MASKED@MASKED/MASKED for 'Main'", "Main/MASKED", "X.X.X.9:443", "[2a00:1450:0:XXXX:XXXX:XXXX:XXXX:XXXX]:443",
        "192.168.1.140", "127.0.0.42:53", "17:05:04", "1.14.1", "https://github.com/\nMon Oct 19 17:05:05", "https://lists.example/MASKED" ])
        t.contains(masked, kept);
});

t.done();
