#!/usr/bin/env ucode

function as_string(value) {
    return value == null ? "" : "" + value;
}

function env(name, fallback) {
    let value = getenv(name);
    return value == null ? as_string(fallback) : as_string(value);
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function constants_map() {
    let c = {};

    c.PODKOP_VERSION = env("PODKOP_VERSION", "__COMPILED_VERSION_VARIABLE__");
    c.PODKOP_CONFIG_NAME = env("PODKOP_CONFIG_NAME", "podkop-plus");
    c.PODKOP_CONFIG = env("PODKOP_CONFIG", "/etc/config/" + c.PODKOP_CONFIG_NAME);
    c.PODKOP_BIN = env("PODKOP_BIN", "/usr/bin/podkop-plus");
    c.PODKOP_SERVICE_NAME = env("PODKOP_SERVICE_NAME", "podkop-plus");
    c.PODKOP_SERVICE_INIT = env("PODKOP_SERVICE_INIT", "/etc/init.d/podkop-plus");
    c.PODKOP_RELEASE_REPO = env("PODKOP_RELEASE_REPO", "ushan0v/podkop-plus");
    c.PODKOP_LUCI_VIEW_NAMESPACE = env("PODKOP_LUCI_VIEW_NAMESPACE", "podkop_plus");
    c.PODKOP_LUCI_VIEW_DIR = env("PODKOP_LUCI_VIEW_DIR", "/www/luci-static/resources/view/" + c.PODKOP_LUCI_VIEW_NAMESPACE);
    c.PODKOP_LUCI_I18N_DOMAIN = env("PODKOP_LUCI_I18N_DOMAIN", "podkop_plus");

    c.RESOLV_CONF = env("RESOLV_CONF", "/etc/resolv.conf");
    c.CHECK_PROXY_IP_DOMAIN = env("CHECK_PROXY_IP_DOMAIN", "ip.podkop.fyi");
    c.FAKEIP_TEST_DOMAIN = env("FAKEIP_TEST_DOMAIN", "fakeip.podkop.fyi");
    c.TMP_SING_BOX_FOLDER = env("TMP_SING_BOX_FOLDER", "/tmp/sing-box");
    c.TMP_RULESET_FOLDER = env("TMP_RULESET_FOLDER", c.TMP_SING_BOX_FOLDER + "/rulesets");
    c.TMP_SUBSCRIPTION_FOLDER = env("TMP_SUBSCRIPTION_FOLDER", c.TMP_SING_BOX_FOLDER + "/subscriptions");
    c.CLOUDFLARE_OCTETS = env("CLOUDFLARE_OCTETS", "8.47 162.159 188.114");
    c.COREUTILS_BASE64_REQUIRED_VERSION = env("COREUTILS_BASE64_REQUIRED_VERSION", "9.7");
    c.RT_TABLE_NAME = env("RT_TABLE_NAME", "podkop");

    c.NFT_TABLE_NAME = env("NFT_TABLE_NAME", "PodkopPlusTable");
    c.NFT_LOCALV4_SET_NAME = env("NFT_LOCALV4_SET_NAME", "localv4");
    c.NFT_LOCALV6_SET_NAME = env("NFT_LOCALV6_SET_NAME", "localv6");
    c.NFT_COMMON_SET_NAME = env("NFT_COMMON_SET_NAME", "podkop_plus_subnets");
    c.NFT_COMMON6_SET_NAME = env("NFT_COMMON6_SET_NAME", "podkop_plus_subnets6");
    c.NFT_PORT_SET_NAME = env("NFT_PORT_SET_NAME", "podkop_plus_ports");
    c.NFT_IP_PORT_SET_NAME = env("NFT_IP_PORT_SET_NAME", "podkop_plus_ip_ports");
    c.NFT_IP_PORT6_SET_NAME = env("NFT_IP_PORT6_SET_NAME", "podkop_plus_ip6_ports");
    c.NFT_DISCORD_SET_NAME = env("NFT_DISCORD_SET_NAME", "podkop_plus_discord_subnets");
    c.NFT_DISCORD6_SET_NAME = env("NFT_DISCORD6_SET_NAME", "podkop_plus_discord_subnets6");
    c.NFT_INTERFACE_SET_NAME = env("NFT_INTERFACE_SET_NAME", "podkop_plus_interfaces");
    c.NFT_FAKEIP_MARK = env("NFT_FAKEIP_MARK", "0x00100000");
    c.NFT_OUTBOUND_MARK = env("NFT_OUTBOUND_MARK", "0x00200000");

    c.SB_REQUIRED_VERSION = env("SB_REQUIRED_VERSION", "1.12.0");
    c.SB_MANAGED_SERVICE_MARKER = env("SB_MANAGED_SERVICE_MARKER", "Podkop Plus managed sing-box service for binary variants");
    c.SB_DNS_SERVER_TAG = env("SB_DNS_SERVER_TAG", "dns-server");
    c.SB_FAKEIP_DNS_SERVER_TAG = env("SB_FAKEIP_DNS_SERVER_TAG", "fakeip-server");
    c.SB_FAKEIP_INET4_RANGE = env("SB_FAKEIP_INET4_RANGE", "198.18.0.0/15");
    c.SB_FAKEIP_INET6_RANGE = env("SB_FAKEIP_INET6_RANGE", "fc00::/18");
    c.SB_BOOTSTRAP_SERVER_TAG = env("SB_BOOTSTRAP_SERVER_TAG", "bootstrap-dns-server");
    c.SB_FAKEIP_DNS_RULE_TAG = env("SB_FAKEIP_DNS_RULE_TAG", "fakeip-dns-rule-tag");
    c.SB_FAKEIP_RULESET_DNS_RULE_TAG = env("SB_FAKEIP_RULESET_DNS_RULE_TAG", "fakeip-ruleset-dns-rule-tag");
    c.SB_SERVICE_FAKEIP_DNS_RULE_TAG = env("SB_SERVICE_FAKEIP_DNS_RULE_TAG", "service-fakeip-dns-rule-tag");
    c.SB_TPROXY_INBOUND_TAG = env("SB_TPROXY_INBOUND_TAG", "tproxy-in");
    c.SB_TPROXY_INBOUND_ADDRESS = env("SB_TPROXY_INBOUND_ADDRESS", "0.0.0.0");
    c.SB_TPROXY_INBOUND6_TAG = env("SB_TPROXY_INBOUND6_TAG", "tproxy6-in");
    c.SB_TPROXY_INBOUND6_ADDRESS = env("SB_TPROXY_INBOUND6_ADDRESS", "::1");
    c.SB_TPROXY_INBOUND_PORT = env("SB_TPROXY_INBOUND_PORT", "1602");
    c.SB_DNS_INBOUND_TAG = env("SB_DNS_INBOUND_TAG", "dns-in");
    c.SB_DNS_INBOUND_ADDRESS = env("SB_DNS_INBOUND_ADDRESS", "127.0.0.42");
    c.SB_DNS_INBOUND_PORT = env("SB_DNS_INBOUND_PORT", "53");
    c.SB_SERVICE_MIXED_INBOUND_TAG = env("SB_SERVICE_MIXED_INBOUND_TAG", "service-mixed-in");
    c.SB_SERVICE_MIXED_INBOUND_ADDRESS = env("SB_SERVICE_MIXED_INBOUND_ADDRESS", "127.0.0.1");
    c.SB_SERVICE_MIXED_INBOUND_PORT = env("SB_SERVICE_MIXED_INBOUND_PORT", "4534");
    c.SB_DIRECT_OUTBOUND_TAG = env("SB_DIRECT_OUTBOUND_TAG", "direct-out");
    c.SB_BYPASS_OUTBOUND_TAG = env("SB_BYPASS_OUTBOUND_TAG", "bypass-out");
    c.SB_CLASH_API_CONTROLLER_PORT = env("SB_CLASH_API_CONTROLLER_PORT", "9090");
    c.SB_VARIANT_STATE_FILE = env("SB_VARIANT_STATE_FILE", "/etc/podkop-plus/sing-box-variant");
    c.SB_VERSION_STATE_FILE = env("SB_VERSION_STATE_FILE", "/etc/podkop-plus/sing-box-version");

    c.GITHUB_RAW_URL = env("GITHUB_RAW_URL", "https://raw.githubusercontent.com/itdoginfo/allow-domains/main");
    c.SRS_MAIN_URL = env("SRS_MAIN_URL", "https://github.com/itdoginfo/allow-domains/releases/latest/download");
    c.SRS_ADS_HAGEZI_PRO_URL = env("SRS_ADS_HAGEZI_PRO_URL", "https://github.com/zxc-rv/ad-filter/releases/latest/download/adlist.srs");
    c.SRS_SUPERCELL_URL = env("SRS_SUPERCELL_URL", "https://raw.githubusercontent.com/ushan0v/sing-box-supercell-ruleset/main/supercell.srs");
    c.SUBNETS_TWITTER = env("SUBNETS_TWITTER", c.GITHUB_RAW_URL + "/Subnets/IPv4/twitter.lst");
    c.SUBNETS_META = env("SUBNETS_META", c.GITHUB_RAW_URL + "/Subnets/IPv4/meta.lst");
    c.SUBNETS_DISCORD = env("SUBNETS_DISCORD", c.GITHUB_RAW_URL + "/Subnets/IPv4/discord.lst");
    c.SUBNETS_ROBLOX = env("SUBNETS_ROBLOX", c.GITHUB_RAW_URL + "/Subnets/IPv4/roblox.lst");
    c.SUBNETS_TELERAM = env("SUBNETS_TELERAM", c.GITHUB_RAW_URL + "/Subnets/IPv4/telegram.lst");
    c.SUBNETS_CLOUDFLARE = env("SUBNETS_CLOUDFLARE", c.GITHUB_RAW_URL + "/Subnets/IPv4/cloudflare.lst");
    c.SUBNETS_HETZNER = env("SUBNETS_HETZNER", c.GITHUB_RAW_URL + "/Subnets/IPv4/hetzner.lst");
    c.SUBNETS_OVH = env("SUBNETS_OVH", c.GITHUB_RAW_URL + "/Subnets/IPv4/ovh.lst");
    c.SUBNETS_DIGITALOCEAN = env("SUBNETS_DIGITALOCEAN", c.GITHUB_RAW_URL + "/Subnets/IPv4/digitalocean.lst");
    c.SUBNETS_CLOUDFRONT = env("SUBNETS_CLOUDFRONT", c.GITHUB_RAW_URL + "/Subnets/IPv4/cloudfront.lst");
    c.COMMUNITY_SERVICES = env("COMMUNITY_SERVICES", "russia_inside russia_outside ukraine_inside geoblock block porn news anime youtube hdrezka tiktok google_ai google_play hodca discord meta twitter cloudflare cloudfront digitalocean hetzner ovh telegram roblox ads_hagezi_pro supercell");

    c.ZAPRET_PROVIDER_BASE_DIR = env("ZAPRET_PROVIDER_BASE_DIR", "/opt/zapret");
    c.ZAPRET_PROVIDER_NFQWS_BIN = env("ZAPRET_PROVIDER_NFQWS_BIN", c.ZAPRET_PROVIDER_BASE_DIR + "/nfq/nfqws");
    c.ZAPRET_PROVIDER_FILES_DIR = env("ZAPRET_PROVIDER_FILES_DIR", c.ZAPRET_PROVIDER_BASE_DIR + "/files");
    c.ZAPRET_PROVIDER_IPSET_DIR = env("ZAPRET_PROVIDER_IPSET_DIR", c.ZAPRET_PROVIDER_BASE_DIR + "/ipset");
    c.ZAPRET_LEGACY_RUNTIME_BASE_DIR = env("ZAPRET_LEGACY_RUNTIME_BASE_DIR", "/var/run/podkop-plus/zapret-runtime");
    c.ZAPRET_NFQWS_BIN = env("ZAPRET_NFQWS_BIN", c.ZAPRET_PROVIDER_NFQWS_BIN);
    c.ZAPRET_STATE_DIR = env("ZAPRET_STATE_DIR", "/var/run/podkop-plus/zapret");
    c.ZAPRET_PID_DIR = env("ZAPRET_PID_DIR", c.ZAPRET_STATE_DIR + "/pid");
    c.ZAPRET_CHILD_PID_DIR = env("ZAPRET_CHILD_PID_DIR", c.ZAPRET_STATE_DIR + "/child-pid");
    c.ZAPRET_LOG_DIR = env("ZAPRET_LOG_DIR", c.ZAPRET_STATE_DIR + "/log");
    c.ZAPRET_HOSTLIST_DIR = env("ZAPRET_HOSTLIST_DIR", c.ZAPRET_STATE_DIR + "/hostlist");
    c.ZAPRET_ROUTE_MARK_BASE = env("ZAPRET_ROUTE_MARK_BASE", "0x01000000");
    c.ZAPRET_QUEUE_BASE = env("ZAPRET_QUEUE_BASE", "4000");
    c.ZAPRET_QUEUE_RANGE_SIZE = env("ZAPRET_QUEUE_RANGE_SIZE", "256");
    c.ZAPRET_NFQWS_RESPAWN_DELAY = env("ZAPRET_NFQWS_RESPAWN_DELAY", "5");
    c.ZAPRET_DESYNC_MARK = env("ZAPRET_DESYNC_MARK", "0x40000000");
    c.ZAPRET_DESYNC_MARK_POSTNAT = env("ZAPRET_DESYNC_MARK_POSTNAT", "0x20000000");
    c.ZAPRET_LEGACY_DEFAULT_NFQWS_OPT = env("ZAPRET_LEGACY_DEFAULT_NFQWS_OPT", "--filter-tcp=80 <HOSTLIST> --dpi-desync=fake,fakedsplit --dpi-desync-autottl=2 --dpi-desync-fooling=badsum --new --filter-tcp=443 --hostlist=/opt/zapret/ipset/zapret-hosts-google.txt --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=11 --dpi-desync-fooling=badsum --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com --new --filter-udp=443 --hostlist=/opt/zapret/ipset/zapret-hosts-google.txt --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-fake-quic=/opt/zapret/files/fake/quic_initial_www_google_com.bin --new --filter-udp=443 <HOSTLIST_NOAUTO> --dpi-desync=fake --dpi-desync-repeats=11 --new --filter-tcp=443 <HOSTLIST> --dpi-desync=multidisorder --dpi-desync-split-pos=1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1");
    c.ZAPRET_DEFAULT_NFQWS_OPT = env("ZAPRET_DEFAULT_NFQWS_OPT", "--filter-tcp=80 --dpi-desync=fake,fakedsplit --dpi-desync-autottl=2 --dpi-desync-fooling=badsum --new --filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=11 --dpi-desync-fooling=badsum --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-fake-quic=/opt/zapret/files/fake/quic_initial_www_google_com.bin");

    c.ZAPRET2_PROVIDER_BASE_DIR = env("ZAPRET2_PROVIDER_BASE_DIR", "/opt/zapret2");
    c.ZAPRET2_PROVIDER_NFQWS2_BIN = env("ZAPRET2_PROVIDER_NFQWS2_BIN", c.ZAPRET2_PROVIDER_BASE_DIR + "/nfq2/nfqws2");
    c.ZAPRET2_PROVIDER_FILES_DIR = env("ZAPRET2_PROVIDER_FILES_DIR", c.ZAPRET2_PROVIDER_BASE_DIR + "/files");
    c.ZAPRET2_PROVIDER_IPSET_DIR = env("ZAPRET2_PROVIDER_IPSET_DIR", c.ZAPRET2_PROVIDER_BASE_DIR + "/ipset");
    c.ZAPRET2_PROVIDER_LUA_DIR = env("ZAPRET2_PROVIDER_LUA_DIR", c.ZAPRET2_PROVIDER_BASE_DIR + "/lua");
    c.ZAPRET2_NFQWS2_BIN = env("ZAPRET2_NFQWS2_BIN", c.ZAPRET2_PROVIDER_NFQWS2_BIN);
    c.ZAPRET2_STATE_DIR = env("ZAPRET2_STATE_DIR", "/var/run/podkop-plus/zapret2");
    c.ZAPRET2_PID_DIR = env("ZAPRET2_PID_DIR", c.ZAPRET2_STATE_DIR + "/pid");
    c.ZAPRET2_CHILD_PID_DIR = env("ZAPRET2_CHILD_PID_DIR", c.ZAPRET2_STATE_DIR + "/child-pid");
    c.ZAPRET2_LOG_DIR = env("ZAPRET2_LOG_DIR", c.ZAPRET2_STATE_DIR + "/log");
    c.ZAPRET2_ROUTE_MARK_BASE = env("ZAPRET2_ROUTE_MARK_BASE", "0x01010000");
    c.ZAPRET2_QUEUE_BASE = env("ZAPRET2_QUEUE_BASE", "4300");
    c.ZAPRET2_QUEUE_RANGE_SIZE = env("ZAPRET2_QUEUE_RANGE_SIZE", "256");
    c.ZAPRET2_NFQWS2_RESPAWN_DELAY = env("ZAPRET2_NFQWS2_RESPAWN_DELAY", "5");
    c.ZAPRET2_DESYNC_MARK = env("ZAPRET2_DESYNC_MARK", "0x40000000");
    c.ZAPRET2_DESYNC_MARK_POSTNAT = env("ZAPRET2_DESYNC_MARK_POSTNAT", "0x20000000");
    c.ZAPRET2_DEFAULT_NFQWS2_OPT = env("ZAPRET2_DEFAULT_NFQWS2_OPT", "--filter-tcp=80 --filter-l7=http --payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_md5 --lua-desync=multisplit:pos=method+2 --new --filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 --lua-desync=multidisorder:pos=1,midsld --new --filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6");

    c.BYEDPI_BIN = env("BYEDPI_BIN", "/usr/bin/ciadpi");
    c.BYEDPI_SERVICE_INIT = env("BYEDPI_SERVICE_INIT", "/etc/init.d/byedpi");
    c.BYEDPI_STATE_DIR = env("BYEDPI_STATE_DIR", "/var/run/podkop-plus/byedpi");
    c.BYEDPI_PID_DIR = env("BYEDPI_PID_DIR", c.BYEDPI_STATE_DIR + "/pid");
    c.BYEDPI_CHILD_PID_DIR = env("BYEDPI_CHILD_PID_DIR", c.BYEDPI_STATE_DIR + "/child-pid");
    c.BYEDPI_LOG_DIR = env("BYEDPI_LOG_DIR", c.BYEDPI_STATE_DIR + "/log");
    c.BYEDPI_LISTEN_ADDRESS = env("BYEDPI_LISTEN_ADDRESS", "127.0.0.1");
    c.BYEDPI_PORT_BASE = env("BYEDPI_PORT_BASE", "1080");
    c.BYEDPI_RESPAWN_DELAY = env("BYEDPI_RESPAWN_DELAY", "5");
    c.BYEDPI_OPEN_FILES_LIMIT = env("BYEDPI_OPEN_FILES_LIMIT", "4096");
    c.BYEDPI_DEFAULT_CMD_OPTS = env("BYEDPI_DEFAULT_CMD_OPTS", "-o 2 --auto=t,r,a,s -d 2");

    return c;
}

function print_shell_env(constants) {
    for (let name in sort(keys(constants)))
        print(name, "=", shell_quote(constants[name]), "\n");
}

function module_exports() {
    return constants_map();
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return module_exports();

let mode = ARGV[0] || "";
let constants = constants_map();

if (mode == "shell-env")
    print_shell_env(constants);
else if (mode == "json")
    print(sprintf("%J", constants), "\n");
else if (mode == "get")
    print(as_string(constants[ARGV[1]]), "\n");
else {
    warn("Usage: core/constants.uc <shell-env|json|get> ...\n");
    exit(1);
}
