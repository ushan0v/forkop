// Every inbound key the generator emits must exist in tests/fixtures/singbox_inbound_options.json,
// a snapshot of the core's option structs that tests/fixtures/singbox_inbound_options.js rebuilds.

let t = require("t");
let fs = require("fs");
let repo = require("repo");
let fixture = require("fixture");
let generator = require("singbox.generator");

let schema = json(fs.readfile(repo.path("tests/fixtures/singbox_inbound_options.json")));

const PEM = {
    certificate: "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----",
    key: "-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----"
};
const SELF_SIGNED = { tls_self_signed_certificate: PEM.certificate, tls_self_signed_key: PEM.key };

const WG_KEY = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=";
const AWG_KEY = "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=";
const AMNEZIA_SERVER = {
    amnezia_jc: "5", amnezia_jmin: "10", amnezia_jmax: "50", amnezia_i1: "<r 2>",
    amnezia_s1: "12", amnezia_s2: "12", amnezia_s3: "12", amnezia_s4: "12",
    amnezia_h1: "1", amnezia_h2: "2", amnezia_h3: "3", amnezia_h4: "4",
    amnezia_header_protection_key: WG_KEY, amnezia_random_trailers: "1", amnezia_disable_cookies: "1",
    amnezia_rekey_after_time: "100-120", amnezia_rekey_timeout: "3-7", amnezia_reject_after_time: "150-180",
    amnezia_keepalive_timeout: "5-15", amnezia_max_handshake_attempts: "15-20"
};

const SERVERS = {
    settings: { dns_server: "77.88.8.8", bootstrap_dns_server: "77.88.8.8", service_listen_address: "127.0.0.1" },
    section: [
        {
            ".name": "proxy", ".type": "section", label: "proxy", enabled: "1", action: "connection",
            connection_url: "socks5://127.0.0.1:1080", user_domains: "example.com"
        }
    ],
    server: [
        {
            ".name": "mixed_srv", ".type": "server", enabled: "1", label: "mixed", protocol: "mixed",
            listen: "0.0.0.0", listen_port: "20001", mixed_auth_enabled: "1",
            routing_mode: "direct"
        },
        {
            ".name": "vless_srv", ".type": "server", enabled: "1", label: "vless", protocol: "vless",
            listen: "0.0.0.0", listen_port: "20002", security: "reality", tls_server_name: "www.microsoft.com",
            reality_private_key: "kP1C4vzQnlzyKRo3DORq6f_v3n9u7nGY8dl0AKbx11A",
            reality_public_key: "kP1C4vzQnlzyKRo3DORq6f_v3n9u7nGY8dl0AKbx11A", reality_short_id: "4aee2254",
            transport: "tcp", multiplex_enabled: "1", multiplex_padding: "1", routing_mode: "direct"
        },
        {
            ".name": "vmess_srv", ".type": "server", enabled: "1", label: "vmess", protocol: "vmess",
            listen: "0.0.0.0", listen_port: "20003", security: "tls", tls_server_name: "example.com",
            tls_alpn: [ "h2", "http/1.1" ], tls_certificate_source: "custom", tls_certificate: "/etc/ssl/vmess.crt",
            tls_key: "/etc/ssl/vmess.key", transport: "ws", transport_path: "/ws",
            transport_host: "example.com", routing_mode: "direct"
        },
        {
            ".name": "trojan_srv", ".type": "server", enabled: "1", label: "trojan", protocol: "trojan",
            listen: "0.0.0.0", listen_port: "20004", security: "tls",
            ...SELF_SIGNED, transport: "xhttp", transport_path: "/x",
            transport_xhttp_mode: "auto", routing_mode: "direct"
        },
        {
            ".name": "trojan_grpc", ".type": "server", enabled: "1", label: "trojan grpc", protocol: "trojan",
            listen: "0.0.0.0", listen_port: "20014", security: "tls",
            ...SELF_SIGNED, transport: "grpc",
            transport_service_name: "grpc", routing_mode: "direct"
        },
        {
            ".name": "vless_enc", ".type": "server", enabled: "1", label: "vless enc", protocol: "vless",
            listen: "0.0.0.0", listen_port: "20017", security: "none", transport: "xhttp", transport_path: "/x",
            vless_encryption: "xorpub", vless_encryption_private_key: "jzVX7WGd0p1WWCLo5zilIcA_cLTfouNEFqG6F1WUnCI",
            vless_encryption_public_key: "PUD2tXF0WUfi5DvDc5gKXGrvefeB7obg9_UG-SAM-xM", routing_mode: "direct"
        },
        {
            ".name": "vless_http", ".type": "server", enabled: "1", label: "vless http", protocol: "vless",
            listen: "0.0.0.0", listen_port: "20015", security: "none", transport: "http", transport_path: "/h",
            transport_host: "h.example.com", routing_mode: "direct"
        },
        {
            ".name": "vmess_upgrade", ".type": "server", enabled: "1", label: "vmess upgrade",
            protocol: "vmess", listen: "0.0.0.0", listen_port: "20016", security: "none",
            transport: "httpupgrade", transport_path: "/u", transport_host: "example.com",
            routing_mode: "direct"
        },
        {
            ".name": "ss_srv", ".type": "server", enabled: "1", label: "shadowsocks", protocol: "shadowsocks",
            listen: "0.0.0.0", listen_port: "20005", shadowsocks_method: "2022-blake3-aes-256-gcm",
            shadowsocks_psk: "ZGVmYXVsdC1rZXktZm9yLXRlc3RzLTMyLWJ5dGVzIQ==", multiplex_enabled: "1",
            routing_mode: "direct"
        },
        {
            ".name": "hy2_srv", ".type": "server", enabled: "1", label: "hysteria2", protocol: "hysteria2",
            listen: "0.0.0.0", listen_port: "20006", security: "tls",
            ...SELF_SIGNED, hysteria2_up_mbps: "100",
            hysteria2_down_mbps: "200", hysteria2_obfs_type: "salamander",
            hysteria2_obfs_password: "obfs-password",
            hysteria2_masquerade: "https://example.com", routing_mode: "direct"
        },
        {
            ".name": "tuic_srv", ".type": "server", enabled: "1", label: "tuic", protocol: "tuic",
            listen: "0.0.0.0", listen_port: "20007", security: "tls",
            ...SELF_SIGNED, tuic_congestion_control: "bbr",
            routing_mode: "direct"
        },
        {
            ".name": "anytls_srv", ".type": "server", enabled: "1", label: "anytls", protocol: "anytls",
            listen: "0.0.0.0", listen_port: "20008", security: "tls",
            ...SELF_SIGNED, routing_mode: "direct"
        },
        {
            ".name": "naive_srv", ".type": "server", enabled: "1", label: "naive", protocol: "naive",
            listen: "0.0.0.0", listen_port: "20009", security: "tls",
            tls_certificate: PEM.certificate, tls_key: PEM.key, naive_network: "tcp_udp",
            routing_mode: "direct"
        },
        {
            ".name": "tt_srv", ".type": "server", enabled: "1", label: "trusttunnel", protocol: "trusttunnel",
            listen: "::", listen_port: "20012", tls_server_name: "www.microsoft.com", ...SELF_SIGNED,
            trusttunnel_network: "tcp_udp", routing_mode: "direct"
        },
        {
            ".name": "tt_h2", ".type": "server", enabled: "1", label: "trusttunnel h2", protocol: "trusttunnel",
            listen: "::", listen_port: "20020", ...SELF_SIGNED, routing_mode: "direct"
        },
        {
            ".name": "mieru_srv", ".type": "server", enabled: "1", label: "mieru", protocol: "mieru",
            listen: "0.0.0.0", listen_port: "20011", mieru_transport: "UDP", routing_mode: "direct"
        },
        {
            ".name": "tailscale_srv", ".type": "server", enabled: "1", label: "tailscale",
            protocol: "tailscale", tailscale_auth_key: "tskey-auth-contract", tailscale_hostname: "forkop",
            tailscale_control_url: "https://controlplane.tailscale.com", tailscale_ephemeral: "1",
            tailscale_advertise_routes: [ "192.168.1.0/24" ], routing_mode: "direct"
        },
        {
            ".name": "openvpn_srv", ".type": "server", enabled: "1", label: "openvpn", protocol: "openvpn",
            listen: "::", listen_port: "20013", openvpn_network: "udp", tunnel_address: [ "10.8.0.1/24", "fd00:8::1/64" ],
            openvpn_certificate: "CERT", openvpn_key: "KEY", openvpn_tls_crypt_key: "TLSCRYPT", routing_mode: "direct"
        },
        {
            ".name": "openvpn_split", ".type": "server", enabled: "1", label: "openvpn split", protocol: "openvpn",
            listen: "::", listen_port: "20017", openvpn_network: "tcp", tunnel_address: [ "10.9.0.1/24" ],
            tunnel_all_traffic: "0", tunnel_routes: [ "192.168.1.0/24" ],
            openvpn_certificate: "CERT", openvpn_key: "KEY", openvpn_tls_crypt_key: "TLSCRYPT", routing_mode: "direct"
        },
        {
            ".name": "wg_srv", ".type": "server", enabled: "1", label: "wireguard", protocol: "wireguard",
            listen_port: "20018", tunnel_address: [ "10.10.0.1/24", "fd00:a::1/64" ],
            wireguard_private_key: WG_KEY, wireguard_public_key: WG_KEY, routing_mode: "direct"
        },
        {
            ".name": "awg_srv", ".type": "server", enabled: "1", label: "amneziawg", protocol: "amneziawg",
            listen_port: "20019", tunnel_address: [ "10.11.0.1/24" ],
            wireguard_private_key: AWG_KEY, wireguard_public_key: AWG_KEY, ...AMNEZIA_SERVER, routing_mode: "direct"
        }
    ],
    server_client: [
        { ".name": "c_mixed", ".type": "server_client", server: "mixed_srv", name: "user", password: "pass" },
        {
            ".name": "c_vless", ".type": "server_client", server: "vless_srv", name: "phone",
            uuid: "11111111-1111-4111-8111-111111111111"
        },
        {
            ".name": "c_vless_enc", ".type": "server_client", server: "vless_enc", name: "phone",
            uuid: "11111111-1111-4111-8111-111111111113", flow: "xtls-rprx-vision"
        },
        {
            ".name": "c_vless_http", ".type": "server_client", server: "vless_http", name: "phone",
            uuid: "11111111-1111-4111-8111-111111111112", flow: "xtls-rprx-vision"
        },
        {
            ".name": "c_vmess", ".type": "server_client", server: "vmess_srv", name: "phone",
            uuid: "22222222-2222-4222-8222-222222222222"
        },
        {
            ".name": "c_vmess_up", ".type": "server_client", server: "vmess_upgrade", name: "phone",
            uuid: "22222222-2222-4222-8222-222222222223"
        },
        {
            ".name": "c_trojan", ".type": "server_client", server: "trojan_srv", name: "phone",
            password: "trojan-pass"
        },
        {
            ".name": "c_trojan_g", ".type": "server_client", server: "trojan_grpc", name: "phone",
            password: "trojan-pass"
        },
        {
            ".name": "c_ss", ".type": "server_client", server: "ss_srv", name: "phone",
            password: "ZGVmYXVsdC1rZXktZm9yLXRlc3RzLTMyLWJ5dGVzIQ=="
        },
        { ".name": "c_hy2", ".type": "server_client", server: "hy2_srv", name: "phone", password: "hy2-pass" },
        {
            ".name": "c_tuic", ".type": "server_client", server: "tuic_srv", name: "phone",
            uuid: "33333333-3333-4333-8333-333333333333", password: "tuic-pass"
        },
        {
            ".name": "c_anytls", ".type": "server_client", server: "anytls_srv", name: "phone",
            password: "anytls-pass"
        },
        {
            ".name": "c_naive", ".type": "server_client", server: "naive_srv", name: "phone",
            password: "naive-pass"
        },
        {
            ".name": "c_tt", ".type": "server_client", server: "tt_srv", name: "phone", password: "tt-pass"
        },
        {
            ".name": "c_tt_h2", ".type": "server_client", server: "tt_h2", name: "phone", password: "tt-pass"
        },
        {
            ".name": "c_mieru", ".type": "server_client", server: "mieru_srv", name: "phone",
            password: "mieru-pass"
        },
        {
            ".name": "c_openvpn", ".type": "server_client", server: "openvpn_srv", name: "phone",
            openvpn_certificate: "C", openvpn_key: "K", openvpn_certificate_sha256: "ab"
        },
        {
            ".name": "c_openvpn_split", ".type": "server_client", server: "openvpn_split", name: "phone",
            openvpn_certificate: "C", openvpn_key: "K", openvpn_certificate_sha256: "cd"
        },
        {
            ".name": "c_wg", ".type": "server_client", server: "wg_srv", name: "phone",
            wireguard_private_key: WG_KEY, wireguard_public_key: WG_KEY, wireguard_pre_shared_key: WG_KEY,
            wireguard_address: [ "10.10.0.2/32", "fd00:a::2/128" ]
        },
        {
            ".name": "c_awg", ".type": "server_client", server: "awg_srv", name: "phone",
            wireguard_private_key: WG_KEY, wireguard_public_key: WG_KEY, wireguard_pre_shared_key: WG_KEY,
            wireguard_address: [ "10.11.0.2/32" ]
        }
    ]
};

const USER_KEYS = {
    mixed: [ "username", "password" ],
    naive: [ "username", "password" ],
    trusttunnel: [ "username", "password" ],
    vless: [ "name", "uuid", "flow" ],
    vmess: [ "name", "uuid", "alterId" ],
    trojan: [ "name", "password" ],
    shadowsocks: [ "name", "password" ],
    hysteria2: [ "name", "password" ],
    tuic: [ "name", "uuid", "password" ],
    anytls: [ "name", "password" ],
    mieru: [ "name", "password" ]
};

fixture.seed(SERVERS);
let config = generator.build({ service_address: "127.0.0.1" });
let listeners = filter([ ...(config.inbounds ?? []), ...(config.endpoints ?? []) ], (item) => schema[item.type] != null);

function unknown_keys(node, allowed, trail) {
    let unknown = [];
    for (let key, value in node) {
        if (length(trail) == 0 && (key == "type" || key == "tag"))
            continue;
        let path = [ ...trail, key ];
        let permitted = type(allowed) == "object" ? allowed[key] : null;
        if (permitted == null) {
            push(unknown, join(".", path));
            continue;
        }
        if (permitted === true)
            continue;
        for (let item in (type(value) == "array" ? value : [ value ]))
            if (type(item) == "object")
                push(unknown, ...unknown_keys(item, permitted, path));
    }
    return unknown;
}

t.test("every protocol the tab serves produces a listener", () => {
    let types = uniq(map(listeners, (item) => item.type));
    for (let expected in [ "mixed", "vless", "vmess", "trojan", "shadowsocks", "hysteria2",
        "tuic", "anytls", "naive", "mieru", "trusttunnel", "tailscale", "openvpn-server", "wireguard", "amneziawg" ])
        t.contains(types, expected);
});

t.test("a listener carries only options the core has", () => {
    let unknown = [];
    for (let listener in listeners)
        for (let path in unknown_keys(listener, schema[listener.type], []))
            push(unknown, listener.type + ": " + path);
    t.eq(unknown, []);
});

t.test("every HTTP-like transport takes its host from the one field", () => {
    let http = filter(listeners, (item) => item.tag == "vless http")[0];
    t.eq([ http.transport.type, http.transport.host, http.transport.path ], [ "http", [ "h.example.com" ], "/h" ]);
});

t.test("an HTTP/2 and HTTP/3 listener serves the transports the firewall opens for it", () => {
    let served = (tag) => filter(listeners, (item) => item.tag == tag)[0];
    t.eq([ served("trusttunnel").network, served("trusttunnel h2").network, served("naive").network ],
        [ [ "tcp", "udp" ], "tcp", [ "tcp", "udp" ] ]);
    t.eq(served("trusttunnel").users, [ { username: "phone", password: "tt-pass" } ]);
    t.eq(served("trusttunnel").tls.server_name, "www.microsoft.com");
});

t.test("a VLESS server with VLESS Encryption takes its private key in Xray's form, and only it", () => {
    let served = (tag) => filter(listeners, (item) => item.tag == tag)[0];
    t.eq(served("vless enc").decryption, "mlkem768x25519plus.xorpub.600s.jzVX7WGd0p1WWCLo5zilIcA_cLTfouNEFqG6F1WUnCI");
    t.eq(served("vless enc").users, [ { name: "phone", uuid: "11111111-1111-4111-8111-111111111113", flow: "xtls-rprx-vision" } ]);
    t.eq(served("vless").decryption, null);
});

t.test("a user carries only the fields of its protocol's user struct", () => {
    for (let listener in listeners) {
        let allowed = USER_KEYS[listener.type];
        if (allowed == null)
            continue;
        for (let user in listener.users ?? [])
            for (let key in keys(user))
                t.contains(allowed, key, listener.type + " user");
    }
});

t.done();
