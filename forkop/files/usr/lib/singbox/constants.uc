const DNS_SERVER_TAG = "dns-server";
const FAKEIP_DNS_SERVER_TAG = "fakeip-server";
const BOOTSTRAP_DNS_SERVER_TAG = "bootstrap-dns-server";
const DNSMASQ_DNS_SERVER_TAG = "dnsmasq-server";
const HOSTS_DNS_SERVER_TAG = "hosts-server";
const FAKEIP_DNS_RULE_TAG = "fakeip-dns-rule-tag";
const FAKEIP_RULESET_DNS_RULE_TAG = "fakeip-ruleset-dns-rule-tag";
const SERVICE_FAKEIP_DNS_RULE_TAG = "service-fakeip-dns-rule-tag";

const TPROXY_INBOUND_TAG = "tproxy-in";
const TPROXY_INBOUND_ADDRESS = "0.0.0.0";
const TPROXY_INBOUND6_TAG = "tproxy6-in";
const TPROXY_INBOUND6_ADDRESS = "::1";
const TPROXY_INBOUND_PORT = 1602;
const DNS_INBOUND_TAG = "dns-in";
const DNS_INBOUND_ADDRESS = "127.0.0.42";
const DNS_INBOUND_PORT = 53;
const SOURCE_DNS_INBOUND_TAG = "source-dns-in";
const SOURCE_DNS_INBOUND_ADDRESS = "::";
const SOURCE_DNS_INBOUND_PORT = 1603;
const SYSTEM_TPROXY_INBOUND_TAG = "system-in";
const SYSTEM_TPROXY_INBOUND6_TAG = "system6-in";
const SYSTEM_TPROXY_INBOUND_PORT = 1604;
const SYSTEM_DNS_INBOUND_TAG = "system-dns-in";
const SYSTEM_DNS_INBOUND_ADDRESS = "::";
const SYSTEM_DNS_INBOUND_PORT = 1605;

const SERVICE_MIXED_INBOUND_ADDRESS = "127.0.0.1";
const WARP_PROFILES_MIXED_INBOUND_TAG = "service-warp-in";
const WARP_PROFILES_MIXED_INBOUND_PORT = 4536;
const DIRECT_OUTBOUND_TAG = "direct-out";
const CLASH_API_CONTROLLER_PORT = 9090;
// The mark sing-box puts on its own traffic is the one the nft table lets pass.
const OUTBOUND_MARK = hex(require("core.constants").NFT_OUTBOUND_MARK);
// The cache file keeps a name for every address until the range wraps, about 170 bytes each in
// tmpfs, hence 65536 addresses a family.
const FAKEIP_INET4_RANGE = "198.18.0.0/16";
const FAKEIP_INET6_RANGE = "2001:2::/48";

const URLTEST_DEFAULT_IDLE_TIMEOUT = "30m";
const CHECK_PROXY_IP_DOMAIN = "ip.podkop.fyi";
const FAKEIP_TEST_DOMAIN = "fakeip.podkop.fyi";
const TMP_SING_BOX_FOLDER = "/tmp/sing-box";
// Marks the Servers tab's nft rules, an nftables.d include that never appears in
// `uci show firewall`; the inbound check looks for it in the loaded chain.
const SERVER_FIREWALL_COMMENT = "forkop: server ports";

// Providers build nodes from outbounds only, so endpoint protocols and refused types are absent.
const FILTERABLE_PROVIDER_TYPES = [
    "vless", "vmess", "trojan", "shadowsocks",
    "hysteria2", "hysteria", "tuic", "anytls",
    "naive", "mieru", "snell", "shadowtls", "trusttunnel",
    "ssh", "tor", "socks", "http"
];

// Groups also hold a section's own servers, the only way tunnels and interfaces become members.
const FILTERABLE_GROUP_TYPES = [
    ...FILTERABLE_PROVIDER_TYPES,
    "wireguard", "amneziawg", "warp", "tailscale", "openvpn-client", "openconnect", "direct"
];

// A manual link is parsed at runtime, so its outbound is typed by the link's scheme. These are
// the schemes ParseSubscriptionLink accepts; a missing one leaves the node without a protocol.
const LINK_SCHEME_OUTBOUND_TYPES = {
    "ss": "shadowsocks",
    "vmess": "vmess",
    "vless": "vless",
    "trojan": "trojan",
    "tuic": "tuic",
    "anytls": "anytls",
    "hy": "hysteria",
    "hysteria": "hysteria",
    "hy2": "hysteria2",
    "hysteria2": "hysteria2",
    "mieru": "mieru",
    "mierus": "mieru",
    "naive+https": "naive",
    "naive+quic": "naive",
    "http2": "naive",
    "http3": "naive",
    "http": "http",
    "https": "http",
    "socks": "socks",
    "socks4": "socks",
    "socks4a": "socks",
    "socks5": "socks",
    "socks5h": "socks",
    "tt": "trusttunnel"
};

// A subscription sets every imported server's detour from its cascade, so a patch may not.
const RESERVED_OVERRIDE_PATCH_PATHS = [ "detour" ];

const RESERVED_TAGS = {
    [DNS_SERVER_TAG]: true,
    [FAKEIP_DNS_SERVER_TAG]: true,
    [BOOTSTRAP_DNS_SERVER_TAG]: true,
    [DNSMASQ_DNS_SERVER_TAG]: true,
    [HOSTS_DNS_SERVER_TAG]: true,
    [FAKEIP_DNS_RULE_TAG]: true,
    [FAKEIP_RULESET_DNS_RULE_TAG]: true,
    [SERVICE_FAKEIP_DNS_RULE_TAG]: true,
    [TPROXY_INBOUND_TAG]: true,
    [TPROXY_INBOUND6_TAG]: true,
    [DNS_INBOUND_TAG]: true,
    [SOURCE_DNS_INBOUND_TAG]: true,
    [SYSTEM_TPROXY_INBOUND_TAG]: true,
    [SYSTEM_TPROXY_INBOUND6_TAG]: true,
    [SYSTEM_DNS_INBOUND_TAG]: true,
    [WARP_PROFILES_MIXED_INBOUND_TAG]: true,
    [DIRECT_OUTBOUND_TAG]: true
};

function as_string(value) {
    return value == null ? "" : "" + value;
}

function tag(base, postfix) {
    let candidate = as_string(base) + "-" + as_string(postfix);
    return RESERVED_TAGS[candidate] ? candidate + "-1" : candidate;
}

function outbound_tag(section_name) {
    return as_string(section_name);
}

function child_tag(section_name, display_name) {
    return as_string(section_name) + "/" + as_string(display_name);
}

function domain_resolver_tag(section_name) {
    return tag(section_name, "domain-resolver");
}

// Verbatim: the tab shows it and the Clash API reports it; the runtime check refuses a name
// already in use.
function server_inbound_tag(display_name) {
    return as_string(display_name);
}

return {
    DNS_SERVER_TAG,
    FAKEIP_DNS_SERVER_TAG,
    BOOTSTRAP_DNS_SERVER_TAG,
    DNSMASQ_DNS_SERVER_TAG,
    HOSTS_DNS_SERVER_TAG,
    TPROXY_INBOUND_TAG,
    TPROXY_INBOUND_ADDRESS,
    TPROXY_INBOUND6_TAG,
    TPROXY_INBOUND6_ADDRESS,
    TPROXY_INBOUND_PORT,
    DNS_INBOUND_TAG,
    DNS_INBOUND_ADDRESS,
    DNS_INBOUND_PORT,
    SOURCE_DNS_INBOUND_TAG,
    SOURCE_DNS_INBOUND_ADDRESS,
    SOURCE_DNS_INBOUND_PORT,
    SYSTEM_TPROXY_INBOUND_TAG,
    SYSTEM_TPROXY_INBOUND6_TAG,
    SYSTEM_TPROXY_INBOUND_PORT,
    SYSTEM_DNS_INBOUND_TAG,
    SYSTEM_DNS_INBOUND_ADDRESS,
    SYSTEM_DNS_INBOUND_PORT,
    SERVICE_MIXED_INBOUND_ADDRESS,
    WARP_PROFILES_MIXED_INBOUND_TAG,
    WARP_PROFILES_MIXED_INBOUND_PORT,
    DIRECT_OUTBOUND_TAG,
    CLASH_API_CONTROLLER_PORT,
    OUTBOUND_MARK,
    FAKEIP_INET4_RANGE,
    FAKEIP_INET6_RANGE,
    URLTEST_DEFAULT_IDLE_TIMEOUT,
    CHECK_PROXY_IP_DOMAIN,
    FAKEIP_TEST_DOMAIN,
    TMP_SING_BOX_FOLDER,
    SERVER_FIREWALL_COMMENT,
    FILTERABLE_PROVIDER_TYPES,
    FILTERABLE_GROUP_TYPES,
    RESERVED_OVERRIDE_PATCH_PATHS,
    LINK_SCHEME_OUTBOUND_TYPES,
    RESERVED_TAGS,
    tag,
    outbound_tag,
    child_tag,
    domain_resolver_tag,
    server_inbound_tag
};
