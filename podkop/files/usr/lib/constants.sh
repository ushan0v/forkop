# shellcheck disable=SC2034

PODKOP_VERSION="__COMPILED_VERSION_VARIABLE__"
PODKOP_CONFIG_NAME="podkop-plus"
PODKOP_CONFIG="/etc/config/$PODKOP_CONFIG_NAME"
PODKOP_BIN="/usr/bin/podkop-plus"
PODKOP_SERVICE_NAME="podkop-plus"
PODKOP_SERVICE_INIT="/etc/init.d/podkop-plus"
PODKOP_RELEASE_REPO="ushan0v/podkop-plus"
PODKOP_LUCI_VIEW_NAMESPACE="podkop_plus"
PODKOP_LUCI_VIEW_DIR="/www/luci-static/resources/view/$PODKOP_LUCI_VIEW_NAMESPACE"
PODKOP_LUCI_I18N_DOMAIN="podkop_plus"
PODKOP_DNSMASQ_SECTION="podkop_plus"
## Common
RESOLV_CONF="/etc/resolv.conf"
CHECK_PROXY_IP_DOMAIN="ip.podkop.fyi"
FAKEIP_TEST_DOMAIN="fakeip.podkop.fyi"
TMP_SING_BOX_FOLDER="/tmp/sing-box"
TMP_RULESET_FOLDER="$TMP_SING_BOX_FOLDER/rulesets"
TMP_SUBSCRIPTION_FOLDER="$TMP_SING_BOX_FOLDER/subscriptions"
CLOUDFLARE_OCTETS="8.47 162.159 188.114" # Endpoints https://github.com/ampetelin/warp-endpoint-checker
COREUTILS_BASE64_REQUIRED_VERSION="9.7"
RT_TABLE_NAME="podkopplus"

## nft
NFT_TABLE_NAME="PodkopPlusTable"
NFT_LOCALV4_SET_NAME="localv4"
NFT_COMMON_SET_NAME="podkop_plus_subnets"
NFT_PORT_SET_NAME="podkop_plus_ports"
NFT_IP_PORT_SET_NAME="podkop_plus_ip_ports"
NFT_DISCORD_SET_NAME="podkop_plus_discord_subnets"
NFT_INTERFACE_SET_NAME="podkop_plus_interfaces"
NFT_FAKEIP_MARK="0x00100000"
NFT_OUTBOUND_MARK="0x00200000"

## sing-box
SB_REQUIRED_VERSION="1.12.0"
# DNS
SB_DNS_SERVER_TAG="dns-server"
SB_FAKEIP_DNS_SERVER_TAG="fakeip-server"
SB_FAKEIP_INET4_RANGE="198.18.0.0/15"
SB_BOOTSTRAP_SERVER_TAG="bootstrap-dns-server"
SB_FAKEIP_DNS_RULE_TAG="fakeip-dns-rule-tag"
SB_FAKEIP_RULESET_DNS_RULE_TAG="fakeip-ruleset-dns-rule-tag"
SB_SERVICE_FAKEIP_DNS_RULE_TAG="service-fakeip-dns-rule-tag"
# Inbounds
SB_TPROXY_INBOUND_TAG="tproxy-in"
SB_TPROXY_INBOUND_ADDRESS="127.0.0.1"
SB_TPROXY_INBOUND_PORT=1602
SB_DNS_INBOUND_TAG="dns-in"
SB_DNS_INBOUND_ADDRESS="127.0.0.42"
SB_DNS_INBOUND_PORT=53
SB_SERVICE_MIXED_INBOUND_TAG="service-mixed-in"
SB_SERVICE_MIXED_INBOUND_ADDRESS="127.0.0.1"
SB_SERVICE_MIXED_INBOUND_PORT=4534
# Outbounds
SB_DIRECT_OUTBOUND_TAG="direct-out"
# Experimental
SB_CLASH_API_CONTROLLER_PORT=9090

## Lists
GITHUB_RAW_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main"
SRS_MAIN_URL="https://github.com/itdoginfo/allow-domains/releases/latest/download"
SRS_ADS_HAGEZI_PRO_URL="https://github.com/zxc-rv/ad-filter/releases/latest/download/adlist.srs"
SRS_SUPERCELL_URL="https://raw.githubusercontent.com/ushan0v/sing-box-supercell-ruleset/main/supercell.srs"
SUBNETS_TWITTER="${GITHUB_RAW_URL}/Subnets/IPv4/twitter.lst"
SUBNETS_META="${GITHUB_RAW_URL}/Subnets/IPv4/meta.lst"
SUBNETS_DISCORD="${GITHUB_RAW_URL}/Subnets/IPv4/discord.lst"
SUBNETS_ROBLOX="${GITHUB_RAW_URL}/Subnets/IPv4/roblox.lst"
SUBNETS_TELERAM="${GITHUB_RAW_URL}/Subnets/IPv4/telegram.lst"
SUBNETS_CLOUDFLARE="${GITHUB_RAW_URL}/Subnets/IPv4/cloudflare.lst"
SUBNETS_HETZNER="${GITHUB_RAW_URL}/Subnets/IPv4/hetzner.lst"
SUBNETS_OVH="${GITHUB_RAW_URL}/Subnets/IPv4/ovh.lst"
SUBNETS_DIGITALOCEAN="${GITHUB_RAW_URL}/Subnets/IPv4/digitalocean.lst"
SUBNETS_CLOUDFRONT="${GITHUB_RAW_URL}/Subnets/IPv4/cloudfront.lst"
COMMUNITY_SERVICES="russia_inside russia_outside ukraine_inside geoblock block porn news anime youtube hdrezka tiktok google_ai google_play hodca discord meta twitter cloudflare cloudfront digitalocean hetzner ovh telegram roblox ads_hagezi_pro supercell"

## Zapret
ZAPRET_PROVIDER_BASE_DIR="/opt/zapret"
ZAPRET_PROVIDER_NFQWS_BIN="$ZAPRET_PROVIDER_BASE_DIR/nfq/nfqws"
ZAPRET_PROVIDER_FILES_DIR="$ZAPRET_PROVIDER_BASE_DIR/files"
ZAPRET_PROVIDER_IPSET_DIR="$ZAPRET_PROVIDER_BASE_DIR/ipset"
ZAPRET_LEGACY_RUNTIME_BASE_DIR="/var/run/podkop-plus/zapret-runtime"
ZAPRET_NFQWS_BIN="$ZAPRET_PROVIDER_NFQWS_BIN"
ZAPRET_STATE_DIR="/var/run/podkop-plus/zapret"
ZAPRET_PID_DIR="$ZAPRET_STATE_DIR/pid"
ZAPRET_CHILD_PID_DIR="$ZAPRET_STATE_DIR/child-pid"
ZAPRET_LOG_DIR="$ZAPRET_STATE_DIR/log"
ZAPRET_HOSTLIST_DIR="$ZAPRET_STATE_DIR/hostlist"
ZAPRET_ROUTE_MARK_BASE="0x01000000"
# Podkop Plus uses a dedicated NFQUEUE range so its managed nfqws processes can
# coexist with standalone zapret/luci-app-zapret instances on the same router.
ZAPRET_QUEUE_BASE=4000
ZAPRET_QUEUE_RANGE_SIZE=256
ZAPRET_NFQWS_RESPAWN_DELAY=5
ZAPRET_DESYNC_MARK="0x40000000"
ZAPRET_DESYNC_MARK_POSTNAT="0x20000000"
ZAPRET_LEGACY_DEFAULT_NFQWS_OPT="--filter-tcp=80 <HOSTLIST> --dpi-desync=fake,fakedsplit --dpi-desync-autottl=2 --dpi-desync-fooling=badsum --new --filter-tcp=443 --hostlist=/opt/zapret/ipset/zapret-hosts-google.txt --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=11 --dpi-desync-fooling=badsum --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com --new --filter-udp=443 --hostlist=/opt/zapret/ipset/zapret-hosts-google.txt --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-fake-quic=/opt/zapret/files/fake/quic_initial_www_google_com.bin --new --filter-udp=443 <HOSTLIST_NOAUTO> --dpi-desync=fake --dpi-desync-repeats=11 --new --filter-tcp=443 <HOSTLIST> --dpi-desync=multidisorder --dpi-desync-split-pos=1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1"
ZAPRET_DEFAULT_NFQWS_OPT="--filter-tcp=80 --dpi-desync=fake,fakedsplit --dpi-desync-autottl=2 --dpi-desync-fooling=badsum --new --filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=11 --dpi-desync-fooling=badsum --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-fake-quic=/opt/zapret/files/fake/quic_initial_www_google_com.bin"

## ByeDPI
BYEDPI_BIN="/usr/bin/ciadpi"
BYEDPI_SERVICE_INIT="/etc/init.d/byedpi"
BYEDPI_STATE_DIR="/var/run/podkop-plus/byedpi"
BYEDPI_PID_DIR="$BYEDPI_STATE_DIR/pid"
BYEDPI_CHILD_PID_DIR="$BYEDPI_STATE_DIR/child-pid"
BYEDPI_LOG_DIR="$BYEDPI_STATE_DIR/log"
BYEDPI_LISTEN_ADDRESS="127.0.0.1"
BYEDPI_PORT_BASE=1080
BYEDPI_RESPAWN_DELAY=5
BYEDPI_OPEN_FILES_LIMIT=4096
BYEDPI_DEFAULT_CMD_OPTS="-o 2 --auto=t,r,a,s -d 2"
