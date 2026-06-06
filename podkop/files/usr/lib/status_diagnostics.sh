# shellcheck shell=ash

cleanup_check_proxy_dir() {
    local dir="$1"

    case "$dir" in
        "$TMP_SING_BOX_FOLDER"/check-proxy-*)
            rm -rf "$dir"
            ;;
    esac
}

get_wan_ipv4_address() {
    local interface ip

    for interface in wan wwan; do
        ip="$(
            ubus -S call "network.interface.$interface" status 2>/dev/null |
                helpers_ucode network-status-ipv4-address 2>/dev/null
        )"
        [ -n "$ip" ] && {
            printf '%s\n' "$ip"
            return 0
        }
    done

    if network_find_wan interface >/dev/null 2>&1; then
        network_get_ipaddr ip "$interface"
        [ -n "$ip" ] && printf '%s\n' "$ip"
    fi
}

firewall_port_open_for_proto() {
    local port="$1"
    local proto="$2"

    uci -q show firewall 2>/dev/null |
        status_diagnostics_ucode firewall-port-open "$port" "$proto" >/dev/null 2>&1
}

firewall_required_protocols_open() {
    local port="$1"
    local required_proto="$2"
    local proto

    for proto in $required_proto; do
        firewall_port_open_for_proto "$port" "$proto" || return 1
    done

    return 0
}

server_required_inbound_proto() {
    status_diagnostics_ucode server-required-inbound-proto "$1"
}

server_runtime_type_for_protocol() {
    status_diagnostics_ucode server-runtime-type-for-protocol "$1"
}

server_listen_requires_firewall() {
    local listen="$1"

    [ "$listen" = "0.0.0.0" ] && return 0
    [ -n "$INBOUNDS_CHECK_WAN_IP" ] && [ "$listen" = "$INBOUNDS_CHECK_WAN_IP" ] && return 0
    server_is_public_ipv4 "$listen"
}

server_port_is_listening_for_proto() {
    local listen="$1"
    local port="$2"
    local proto="$3"

    netstat -ln 2>/dev/null | status_diagnostics_ucode server-port-listening "$listen" "$port" "$proto" >/dev/null 2>&1
}

server_non_sing_box_port_listener_owners_for_proto() {
    local listen="$1"
    local port="$2"
    local proto="$3"

    netstat -lnp 2>/dev/null | status_diagnostics_ucode server-port-conflict-owners "$listen" "$port" "$proto"
}

server_required_port_conflict_owners() {
    local listen="$1"
    local port="$2"
    local required_proto="$3"
    local proto proto_owners owners

    for proto in $required_proto; do
        proto_owners="$(server_non_sing_box_port_listener_owners_for_proto "$listen" "$port" "$proto")"
        [ -n "$proto_owners" ] || continue
        owners="${owners}${owners:+ }${proto_owners}"
    done

    printf '%s\n' "$owners"
}

server_required_ports_listening() {
    local listen="$1"
    local port="$2"
    local required_proto="$3"
    local proto

    for proto in $required_proto; do
        server_port_is_listening_for_proto "$listen" "$port" "$proto" || return 1
    done

    return 0
}

resolve_public_host_ipv4s() {
    local host="$1"

    [ -n "$host" ] || return 0

    if is_ipv4 "$host"; then
        printf '%s\n' "$host"
        return 0
    fi

    dig +short A "$host" +timeout=2 +tries=1 2>/dev/null |
        while read -r ip; do
            is_ipv4 "$ip" && printf '%s\n' "$ip"
        done
}

check_inbounds_server_handler() {
    local section="$1"
    local label protocol listen listen_port public_host routing_mode inbound_tag expected_type required_proto
    local runtime_json listening routes_configured
    local firewall_required firewall_open port_conflict port_conflict_owners public_host_ips public_host_resolved public_host_public public_host_matches_wan
    local host_ip item_json separator

    server_is_enabled "$section" || return 0
    INBOUNDS_CHECK_ENABLED_COUNT=$((INBOUNDS_CHECK_ENABLED_COUNT + 1))

    config_get label "$section" "label" "$section"
    config_get protocol "$section" "protocol" "vless"
    config_get listen "$section" "listen" "0.0.0.0"
    config_get listen_port "$section" "listen_port"
    config_get public_host "$section" "public_host"
    config_get routing_mode "$section" "routing_mode" "rules"

    inbound_tag="$(get_server_inbound_tag_by_section "$section")"
    expected_type="$(server_runtime_type_for_protocol "$protocol")"
    required_proto="$(server_required_inbound_proto "$protocol")"

    if [ "$protocol" = "tailscale" ]; then
        runtime_json="$(provider_status_ucode endpoint-summary "$INBOUNDS_CHECK_CONFIG_PATH" "$inbound_tag" 2>/dev/null)"
    else
        runtime_json="$(provider_status_ucode inbound-summary "$INBOUNDS_CHECK_CONFIG_PATH" "$inbound_tag" 2>/dev/null)"
    fi

    listening=-1
    firewall_required=0
    firewall_open=-1
    port_conflict=0
    port_conflict_owners=""
    if [ "$protocol" != "tailscale" ]; then
        port_conflict_owners="$(server_required_port_conflict_owners "$listen" "$listen_port" "$required_proto")"
        [ -z "$port_conflict_owners" ] || port_conflict=1

        if server_required_ports_listening "$listen" "$listen_port" "$required_proto"; then
            listening=1
        else
            listening=0
        fi

        if server_listen_requires_firewall "$listen"; then
            firewall_required=1
            if firewall_required_protocols_open "$listen_port" "$required_proto"; then
                firewall_open=1
            else
                firewall_open=0
            fi
        fi
    fi

    if provider_status_ucode has-route-rule-for-inbound "$INBOUNDS_CHECK_CONFIG_PATH" "$inbound_tag" >/dev/null 2>&1; then
        routes_configured=1
    else
        routes_configured=0
    fi

    public_host_ips="$(resolve_public_host_ipv4s "$public_host" | status_diagnostics_ucode stdin-sorted-unique-space-list 2>/dev/null)"
    public_host_resolved=-1
    public_host_public=-1
    public_host_matches_wan=-1

    if [ -n "$public_host" ]; then
        if [ -n "$public_host_ips" ]; then
            public_host_resolved=1
            public_host_public=1
            for host_ip in $public_host_ips; do
                server_is_public_ipv4 "$host_ip" || public_host_public=0
            done

            if [ "$INBOUNDS_CHECK_WAN_PUBLIC" = "1" ]; then
                if list_has_item "$public_host_ips" "$INBOUNDS_CHECK_WAN_IP"; then
                    public_host_matches_wan=1
                else
                    public_host_matches_wan=0
                fi
            fi
        else
            public_host_resolved=0
        fi
    fi

    item_json="$(
        status_diagnostics_ucode inbound-item-json \
            "$runtime_json" \
            "$section" \
            "$label" \
            "$protocol" \
            "$routing_mode" \
            "$inbound_tag" \
            "$listen" \
            "$listen_port" \
            "$public_host" \
            "$public_host_ips" \
            "$expected_type" \
            "$required_proto" \
            "$listening" \
            "$firewall_required" \
            "$firewall_open" \
            "$port_conflict" \
            "$port_conflict_owners" \
            "$routes_configured" \
            "$public_host_resolved" \
            "$public_host_public" \
            "$public_host_matches_wan"
    )"

    [ -n "$INBOUNDS_CHECK_ITEMS_JSON" ] && separator=","
    INBOUNDS_CHECK_ITEMS_JSON="${INBOUNDS_CHECK_ITEMS_JSON}${separator}${item_json}"
}

check_inbounds_config_server_handler() {
    local section="$1"

    server_is_enabled "$section" || return 0
    INBOUNDS_CONFIG_ENABLED_COUNT=$((INBOUNDS_CONFIG_ENABLED_COUNT + 1))
}

check_inbounds_config() {
    INBOUNDS_CONFIG_ENABLED_COUNT=0

    config_foreach check_inbounds_config_server_handler "server"

    status_diagnostics_ucode inbounds-config-json "$INBOUNDS_CONFIG_ENABLED_COUNT"
}

check_inbounds() {
    local sing_box_config_path wan_ip wan_public

    config_get sing_box_config_path "settings" "config_path"
    wan_ip="$(get_wan_ipv4_address)"
    wan_public=0
    if server_is_public_ipv4 "$wan_ip"; then
        wan_public=1
    fi

    INBOUNDS_CHECK_CONFIG_PATH="$sing_box_config_path"
    INBOUNDS_CHECK_WAN_IP="$wan_ip"
    INBOUNDS_CHECK_WAN_PUBLIC="$wan_public"
    INBOUNDS_CHECK_ENABLED_COUNT=0
    INBOUNDS_CHECK_ITEMS_JSON=""

    config_foreach check_inbounds_server_handler "server"

    status_diagnostics_ucode inbounds-check-json \
        "$INBOUNDS_CHECK_ENABLED_COUNT" \
        "$sing_box_config_path" \
        "$wan_ip" \
        "$wan_public" \
        "[$INBOUNDS_CHECK_ITEMS_JSON]"
}

check_proxy() {
    local sing_box_config_path
    config_get sing_box_config_path "settings" "config_path"

    if ! command -v sing-box > /dev/null 2>&1; then
        nolog "sing-box is not installed"
        return 1
    fi

    if [ ! -f "$sing_box_config_path" ]; then
        nolog "Configuration file not found"
        return 1
    fi

    nolog "Checking sing-box configuration..."

    if ! sing-box -c "$sing_box_config_path" check > /dev/null; then
        nolog "Invalid configuration"
        return 1
    fi

    status_diagnostics_ucode mask-sing-box-config "$sing_box_config_path"

    nolog "Checking proxy connection..."

    local check_proxy_dir check_proxy_config check_proxy_cache check_proxy_outbound_tag masked_response_ip
    check_proxy_dir="$TMP_SING_BOX_FOLDER/check-proxy-$$"
    check_proxy_config="$check_proxy_dir/config.json"
    check_proxy_cache="$check_proxy_dir/cache.db"

    cleanup_check_proxy_dir "$check_proxy_dir"
    mkdir -p "$check_proxy_dir"
    if ! status_diagnostics_ucode prepare-check-proxy-config "$sing_box_config_path" "$check_proxy_config" "$check_proxy_cache"; then
        nolog "Failed to prepare temporary configuration"
        cleanup_check_proxy_dir "$check_proxy_dir"
        return 1
    fi

    check_proxy_outbound_tag="$(status_diagnostics_ucode check-proxy-outbound-tag "$check_proxy_config" "$CHECK_PROXY_IP_DOMAIN" 2>/dev/null)"

    attempt=1
    while [ "$attempt" -le 5 ]; do
        if [ -n "$check_proxy_outbound_tag" ]; then
            response=$(sing-box tools fetch ifconfig.me -c "$check_proxy_config" -D "$check_proxy_dir" \
                --disable-color -o "$check_proxy_outbound_tag" 2> /dev/null)
        else
            response=$(sing-box tools fetch ifconfig.me -c "$check_proxy_config" -D "$check_proxy_dir" \
                --disable-color 2> /dev/null)
        fi
        if printf '%s\n' "$response" | status_diagnostics_ucode proxy-response-is-retryable-error >/dev/null 2>&1; then
            attempt=$((attempt + 1))
            continue
        fi
        masked_response_ip="$(printf '%s' "$response" | status_diagnostics_ucode proxy-response-ip-mask 2>/dev/null)"
        if [ -n "$masked_response_ip" ]; then
            nolog "$masked_response_ip - should match proxy IP"
            cleanup_check_proxy_dir "$check_proxy_dir"
            return 0
        fi
        if [ $attempt -eq 5 ]; then
            nolog "Failed to get valid IP address after 5 attempts"
            if [ -z "$response" ]; then
                nolog "Error: Empty response"
            else
                nolog "Error response: $response"
            fi
            cleanup_check_proxy_dir "$check_proxy_dir"
            return 1
        fi
        attempt=$((attempt + 1))
    done

    cleanup_check_proxy_dir "$check_proxy_dir"
}

check_nft() {
    if ! command -v nft > /dev/null 2>&1; then
        nolog "nft is not installed"
        return 1
    fi

    nolog "Checking $NFT_TABLE_NAME rules..."

    # Check if table exists
    if ! nft list table inet "$NFT_TABLE_NAME" > /dev/null 2>&1; then
        nolog "❌ $NFT_TABLE_NAME not found"
        return 1
    fi

    local found_hetzner=0
    local found_ovh=0

    check_domain_list_contains() {
        local section="$1"

        config_get_bool domain_list_enabled "$section" "domain_list_enabled" "0"
        if [ "$domain_list_enabled" -eq 1 ]; then
            config_list_foreach "$section" "domain_list" check_domain_value
        fi
    }

    check_domain_value() {
        local domain_value="$1"

        if [ "$domain_value" = "hetzner" ]; then
            found_hetzner=1
        elif [ "$domain_value" = "ovh" ]; then
            found_ovh=1
        fi
    }

    config_foreach check_domain_list_contains

    if [ "$found_hetzner" -eq 1 ] || [ "$found_ovh" -eq 1 ]; then

        local sets="$NFT_COMMON_SET_NAME $NFT_PORT_SET_NAME $NFT_IP_PORT_SET_NAME $NFT_INTERFACE_SET_NAME $NFT_DISCORD_SET_NAME $NFT_LOCALV4_SET_NAME"

        nolog "Sets statistics:"
        for set_name in $sets; do
            if nft list set inet "$NFT_TABLE_NAME" "$set_name" > /dev/null 2>&1; then
                local count
                count="$(nft -j list set inet "$NFT_TABLE_NAME" "$set_name" 2>/dev/null | status_diagnostics_ucode nft-set-element-count)"
                echo "- $set_name: $count elements"
            fi
        done

        nolog "Chain configurations:"
        nft list table inet "$NFT_TABLE_NAME" | status_diagnostics_ucode nft-chain-config-blocks mangle proxy
    else
        # Simple view as originally implemented
        nolog "Sets configuration:"
        nft list table inet "$NFT_TABLE_NAME"
    fi

    nolog "NFT check completed"
}

check_logs() {
    if ! command -v logread > /dev/null 2>&1; then
        nolog "Error: logread command not found"
        return 1
    fi

    if ! logread | status_diagnostics_ucode podkop-logs; then
        nolog "Logs not found"
        return 1
    fi
}

check_sing_box_logs() {
    if ! command -v logread > /dev/null 2>&1; then
        nolog "Error: logread command not found"
        return 1
    fi

    if ! logread | status_diagnostics_ucode matching-log-tail "sing-box" 100; then
        nolog "sing-box logs not found"
        return 1
    fi
}

show_sing_box_config() {
    local sing_box_config_path
    config_get sing_box_config_path "settings" "config_path"
    nolog "Current sing-box configuration:"

    if [ ! -f "$sing_box_config_path" ]; then
        nolog "Configuration file not found"
        return 1
    fi

    status_diagnostics_ucode mask-sing-box-config "$sing_box_config_path"
}

show_config() {
    if [ ! -f "$PODKOP_CONFIG" ]; then
        nolog "Configuration file not found"
        return 1
    fi

    status_diagnostics_ucode podkop-config-masked "$PODKOP_CONFIG"
}

show_version() {
    echo "$PODKOP_VERSION"
}

show_sing_box_version() {
    local version
    version="$(get_sing_box_version)"
    echo "$version"
}

fetch_latest_podkop_release_json() {
    local owner repo

    owner="${PODKOP_RELEASE_REPO%%/*}"
    repo="${PODKOP_RELEASE_REPO#*/}"
    [ -n "$owner" ] || return 1
    [ -n "$repo" ] || return 1
    [ "$owner" != "$repo" ] || return 1

    updates_fetch_github_release_json "$owner" "$repo"
}

fetch_latest_podkop_version() {
    local response tag

    response="$(fetch_latest_podkop_release_json)" || return 1
    tag="$(printf '%s' "$response" | updates_ucode object-get-default tag_name "" 2>/dev/null)"

    [ -n "$tag" ] || return 1
    echo "$tag"
}

is_podkop_release_version() {
    updates_ucode podkop-release-version-valid "$1" >/dev/null 2>&1
}

podkop_release_version_compare() {
    updates_ucode podkop-release-version-compare "$1" "$2"
}

write_podkop_latest_version_cache() {
    local value="$1"
    local timestamp="$2"
    local cache_file="/tmp/podkop-plus.latest-version.cache"

    [ -n "$value" ] || return 0

    {
        printf '%s\n' "$value"
        printf '%s\n' "$timestamp"
    } > "$cache_file"
}

get_cached_podkop_latest_version() {
    local cache_file="/tmp/podkop-plus.latest-version.cache"
    local cache_value

    cache_value="$(status_diagnostics_ucode file-first-line "$cache_file" "unknown" 2>/dev/null)"
    echo "$cache_value"
}

get_luci_app_version() {
    if [ -f "$PODKOP_LUCI_VIEW_DIR/main.js" ]; then
        status_diagnostics_ucode js-var-string-value "$PODKOP_LUCI_VIEW_DIR/main.js" "PODKOP_LUCI_APP_VERSION"
        return 0
    fi

    echo "not installed"
}

system_info_cache_is_valid() {
    local now luci_app_version

    [ -s "$PODKOP_SYSTEM_INFO_CACHE_FILE" ] || return 1

    now="$(date +%s 2>/dev/null)"
    case "$now" in
    '' | *[!0-9]*) now=0 ;;
    esac

    luci_app_version="$(get_luci_app_version)"
    status_diagnostics_ucode system-info-cache-valid "$PODKOP_SYSTEM_INFO_CACHE_FILE" "$PODKOP_VERSION" "$luci_app_version" "$PODKOP_SYSTEM_INFO_CACHE_TTL" "$now" >/dev/null 2>&1
}

write_system_info_cache() {
    local tmpfile

    ensure_runtime_dirs

    tmpfile="${PODKOP_SYSTEM_INFO_CACHE_FILE}.$$"
    cat > "$tmpfile" && mv "$tmpfile" "$PODKOP_SYSTEM_INFO_CACHE_FILE"
}

build_system_info() {
    local podkop_version podkop_latest_version luci_app_version sing_box_version sing_box_extended sing_box_tiny sing_box_compressed sing_box_tailscale zapret_version zapret_installed zapret2_version zapret2_installed byedpi_version byedpi_installed openwrt_version device_model
    local generated_at

    podkop_version="$PODKOP_VERSION"

    podkop_latest_version="$(get_cached_podkop_latest_version)"
    [ -n "$podkop_latest_version" ] || podkop_latest_version="unknown"

    luci_app_version="$(get_luci_app_version)"

    if command -v sing-box > /dev/null 2>&1; then
        sing_box_version="$(get_sing_box_version)"
        [ -z "$sing_box_version" ] && sing_box_version="unknown"
    else
        sing_box_version="not installed"
    fi
    sing_box_extended=0
    is_sing_box_extended "$sing_box_version" && sing_box_extended=1
    sing_box_tiny=0
    is_sing_box_tiny && sing_box_tiny=1
    sing_box_compressed=0
    if [ "$sing_box_extended" -eq 1 ] && is_sing_box_compressed_marker_set; then
        sing_box_compressed=1
    fi
    sing_box_tailscale=0
    sing_box_supports_tailscale && sing_box_tailscale=1

    zapret_installed=0
    if is_zapret_installed; then
        zapret_installed=1
        zapret_version="$(get_zapret_package_version)"
        [ -z "$zapret_version" ] && zapret_version="unknown"
    else
        zapret_version="not installed"
    fi

    zapret2_installed=0
    if is_zapret2_installed; then
        zapret2_installed=1
        zapret2_version="$(get_zapret2_package_version)"
        [ -z "$zapret2_version" ] && zapret2_version="unknown"
    else
        zapret2_version="not installed"
    fi

    byedpi_installed=0
    if is_byedpi_installed; then
        byedpi_installed=1
        byedpi_version="$(get_byedpi_package_version)"
        [ -z "$byedpi_version" ] && byedpi_version="unknown"
    else
        byedpi_version="not installed"
    fi

    if [ -f /etc/os-release ]; then
        openwrt_version="$(status_diagnostics_ucode key-value-file-value /etc/os-release OPENWRT_RELEASE 2>/dev/null)"
        [ -z "$openwrt_version" ] && openwrt_version="unknown"
    else
        openwrt_version="unknown"
    fi

    if [ -f /tmp/sysinfo/model ]; then
        device_model=$(cat /tmp/sysinfo/model)
        [ -z "$device_model" ] && device_model="unknown"
    else
        device_model="unknown"
    fi

    generated_at="$(date +%s 2>/dev/null)"
    case "$generated_at" in
    '' | *[!0-9]*) generated_at=0 ;;
    esac

    status_diagnostics_ucode system-info-json \
        "$podkop_version" "$podkop_latest_version" "$luci_app_version" \
        "$sing_box_version" "$sing_box_extended" "$sing_box_tiny" "$sing_box_compressed" "$sing_box_tailscale" \
        "$zapret_version" "$zapret_installed" \
        "$zapret2_version" "$zapret2_installed" \
        "$byedpi_version" "$byedpi_installed" \
        "$openwrt_version" "$device_model" "$generated_at"
}

refresh_system_info_cache() {
    local system_info

    system_info="$(build_system_info)" || return 1
    [ -n "$system_info" ] || return 1

    printf '%s\n' "$system_info" | write_system_info_cache
}

get_system_info() {
    local system_info

    if system_info_cache_is_valid; then
        cat "$PODKOP_SYSTEM_INFO_CACHE_FILE"
        return 0
    fi

    system_info="$(build_system_info)" || return 1
    [ -n "$system_info" ] || return 1

    printf '%s\n' "$system_info" | write_system_info_cache
    printf '%s\n' "$system_info"
}

get_server_capabilities() {
    local sing_box_version sing_box_extended=0 sing_box_tiny=0 sing_box_tailscale=0

    sing_box_version="$(get_sing_box_version)"
    is_sing_box_extended "$sing_box_version" && sing_box_extended=1
    is_sing_box_tiny && sing_box_tiny=1
    sing_box_supports_tailscale && sing_box_tailscale=1

    status_diagnostics_ucode server-capabilities-json "$sing_box_extended" "$sing_box_tiny" "$sing_box_tailscale"
}

get_ui_capabilities() {
    local sing_box_version sing_box_extended=0 sing_box_tiny=0 sing_box_tailscale=0 zapret_installed=0 zapret2_installed=0 byedpi_installed=0

    sing_box_version="$(get_sing_box_version)"
    is_sing_box_extended "$sing_box_version" && sing_box_extended=1
    is_sing_box_tiny && sing_box_tiny=1
    sing_box_supports_tailscale && sing_box_tailscale=1
    is_zapret_installed && zapret_installed=1
    is_zapret2_installed && zapret2_installed=1
    is_byedpi_installed && byedpi_installed=1

    INBOUNDS_CONFIG_ENABLED_COUNT=0
    config_foreach check_inbounds_config_server_handler "server"

    status_diagnostics_ucode ui-capabilities-json \
        "$sing_box_extended" \
        "$sing_box_tiny" \
        "$sing_box_tailscale" \
        "$zapret_installed" \
        "$zapret2_installed" \
        "$byedpi_installed" \
        "${INBOUNDS_CONFIG_ENABLED_COUNT:-0}"
}

get_zapret_status() {
    get_zapret_status_json
}

get_zapret2_status() {
    get_zapret2_status_json
}

neutralize_zapret_defaults() {
    log "Standalone zapret is not neutralized automatically; Podkop Plus uses /opt/zapret/nfq/nfqws as an external provider and manages only its own NFQUEUE range."
}

check_zapret_runtime() {
    check_zapret_runtime_json
}

check_zapret2_runtime() {
    check_zapret2_runtime_json
}

get_byedpi_status() {
    get_byedpi_status_json
}

check_byedpi_runtime() {
    check_byedpi_runtime_json
}

get_sing_box_status() {
    local running=0
    local enabled=0
    local status=""
    local dns_configured=0

    # Check if service is enabled
    if [ -x /etc/rc.d/S99sing-box ]; then
        enabled=1
    fi

    # Check if service is running
    if pgrep -f "sing-box" > /dev/null; then
        running=1
    fi

    # Check DNS configuration
    if dnsmasq_has_podkop_dns; then
        dns_configured=1
    fi

    # Format status message
    if [ $running -eq 1 ]; then
        if [ $enabled -eq 1 ]; then
            status="running & enabled"
        else
            status="running but disabled"
        fi
    else
        if [ $enabled -eq 1 ]; then
            status="stopped but enabled"
        else
            status="stopped & disabled"
        fi
    fi

    status_diagnostics_ucode service-status-json "$running" "$enabled" "$status" "$dns_configured"
}

get_status() {
    local running=0
    local enabled=0
    local status=""
    local dns_configured=0

    if podkop_is_running; then
        running=1
    fi

    # Check if service is enabled
    if [ -x "/etc/rc.d/S99$PODKOP_SERVICE_NAME" ]; then
        enabled=1
    fi

    if dnsmasq_has_podkop_dns; then
        dns_configured=1
    fi

    if [ "$running" -eq 1 ]; then
        if [ "$enabled" -eq 1 ]; then
            status="running & enabled"
        else
            status="running but disabled"
        fi
    else
        if [ "$enabled" -eq 1 ]; then
            status="stopped but enabled"
        else
            status="stopped & disabled"
        fi
    fi

    status_diagnostics_ucode service-status-json "$running" "$enabled" "$status" "$dns_configured"
}

get_outbound_link() {
    local section="$1"
    local outbound_tag="$2"

    ensure_runtime_dirs
    case "$section" in
    "" | */* | *..*)
        subscription_cache_ucode empty-link
        return 0
        ;;
    esac

    subscription_cache_ucode get-link \
        "$PODKOP_SECTION_CACHE_DIR" "$TMP_SUBSCRIPTION_FOLDER" "$section" "$outbound_tag" "$PODKOP_SUBSCRIPTION_LINKS_DIR" ||
        subscription_cache_ucode empty-link
}

get_outbound_link_states() {
    local section="$1"

    ensure_runtime_dirs
    case "$section" in
    "" | */* | *..*)
        printf '{}\n'
        return 0
        ;;
    esac

    subscription_cache_ucode get-link-states "$PODKOP_SECTION_CACHE_DIR" "$section" "$PODKOP_SUBSCRIPTION_LINKS_DIR" ||
        printf '{}\n'
}

get_outbound_metadata() {
    local section="$1"
    local metadata_path

    ensure_runtime_dirs
    case "$section" in
    "" | */* | *..*)
        subscription_cache_ucode empty-outbound-metadata
        return 0
        ;;
    esac

    metadata_path="$(get_outbound_metadata_path "$section")"
    subscription_cache_ucode get-outbound-metadata "$PODKOP_SECTION_CACHE_DIR" "$section" "$metadata_path" ||
        subscription_cache_ucode empty-outbound-metadata
}

get_subscription_metadata() {
    local section="$1"
    local metadata_path

    ensure_runtime_dirs

    case "$section" in
    "" | */* | *..*)
        printf '{}\n'
        return 0
        ;;
    esac

    metadata_path="$(get_subscription_metadata_path "$section")"
    subscription_cache_ucode get-subscription-metadata "$PODKOP_SECTION_CACHE_DIR" "$section" "$metadata_path" ||
        printf '{}\n'
}

validate_nfqws_strategy_json() {
    local raw_opt="${1:-}"

    if check_nfqws_strategy "$raw_opt"; then
        status_diagnostics_ucode nfqws-strategy-validation true "" "" ""
        return 0
    fi

    status_diagnostics_ucode nfqws-strategy-validation false "$NFQWS_VALIDATE_ERROR" "$NFQWS_VALIDATE_NEEDLE" "$NFQWS_VALIDATE_NEEDLES"
}

validate_nfqws2_strategy_json() {
    local raw_opt="${1:-}"

    if check_nfqws2_strategy "$raw_opt"; then
        status_diagnostics_ucode nfqws-strategy-validation true "" "" ""
        return 0
    fi

    status_diagnostics_ucode nfqws-strategy-validation false "$NFQWS2_VALIDATE_ERROR" "$NFQWS2_VALIDATE_NEEDLE" "$NFQWS2_VALIDATE_NEEDLES"
}

dns_check_resolve_host() {
    local host="$1"
    local resolver="$2"
    local resolved

    [ -n "$host" ] || return 1

    if is_ipv4 "$host"; then
        printf '%s\n' "$host"
        return 0
    fi

    [ -n "$resolver" ] || return 1

    resolved="$(
        dig @"$resolver" "$host" A +short +timeout=2 +tries=1 2> /dev/null |
            status_diagnostics_ucode stdin-first-ipv4-line 2>/dev/null
    )"
    [ -n "$resolved" ] || return 1

    printf '%s\n' "$resolved"
}

dns_check_dig_server_available() {
    local dns_type="$1"
    local dns_server="$2"
    local bootstrap_dns_server="$3"
    local domain="$4"
    local dns_host server_port probe_server tls_hostname

    dns_host="$(url_get_host "$dns_server")"
    [ -n "$dns_host" ] || dns_host="$dns_server"
    server_port="$(url_get_port "$dns_server")"
    tls_hostname=""

    if is_ipv4 "$dns_host"; then
        probe_server="$dns_host"
    else
        probe_server="$(dns_check_resolve_host "$dns_host" "$bootstrap_dns_server")"
        [ -n "$probe_server" ] || return 1
        tls_hostname="$dns_host"
    fi

    case "$dns_type" in
    dot)
        if [ -n "$tls_hostname" ]; then
            if [ -n "$server_port" ]; then
                dig -p "$server_port" @"$probe_server" "$domain" +tls +tls-hostname="$tls_hostname" +timeout=2 +tries=1 > /dev/null 2>&1
            else
                dig @"$probe_server" "$domain" +tls +tls-hostname="$tls_hostname" +timeout=2 +tries=1 > /dev/null 2>&1
            fi
        else
            if [ -n "$server_port" ]; then
                dig -p "$server_port" @"$probe_server" "$domain" +tls +timeout=2 +tries=1 > /dev/null 2>&1
            else
                dig @"$probe_server" "$domain" +tls +timeout=2 +tries=1 > /dev/null 2>&1
            fi
        fi
        ;;
    udp)
        if [ -n "$server_port" ]; then
            dig -p "$server_port" @"$probe_server" "$domain" +timeout=2 +tries=1 > /dev/null 2>&1
        else
            dig @"$probe_server" "$domain" +timeout=2 +tries=1 > /dev/null 2>&1
        fi
        ;;
    *)
        return 1
        ;;
    esac
}

dns_check_doh_server_available() {
    local dns_server="$1"
    local bootstrap_dns_server="$2"
    local dns_host server_port doh_path doh_query url http_code resolved_ip

    dns_host="$(url_get_host "$dns_server")"
    [ -n "$dns_host" ] || dns_host="$dns_server"
    [ -n "$dns_host" ] || return 1

    server_port="$(url_get_port "$dns_server")"
    [ -n "$server_port" ] || server_port=443

    doh_path="$(url_get_path "$dns_server")"
    [ -n "$doh_path" ] && [ "$doh_path" != "/" ] || doh_path="/dns-query"

    doh_query="AAABAAABAAAAAAAABmdvb2dsZQNjb20AAAEAAQ"
    url="https://$dns_host:$server_port$doh_path?dns=$doh_query"

    if is_ipv4 "$dns_host"; then
        http_code="$(curl -sS --max-time 3 -o /dev/null -w "%{http_code}" \
            -H "accept: application/dns-message" "$url" 2> /dev/null)"
    else
        resolved_ip="$(dns_check_resolve_host "$dns_host" "$bootstrap_dns_server")"
        [ -n "$resolved_ip" ] || return 1

        http_code="$(curl -sS --max-time 3 -o /dev/null -w "%{http_code}" \
            --resolve "$dns_host:$server_port:$resolved_ip" \
            -H "accept: application/dns-message" "$url" 2> /dev/null)"
    fi

    [ "$http_code" = "200" ]
}

dns_check_router_resolver_available() {
    local domain="$1"
    local address interface source_network_interfaces

    for address in 127.0.0.1 "$SB_DNS_INBOUND_ADDRESS"; do
        [ -n "$address" ] || continue
        if dig @"$address" "$domain" +timeout=2 +tries=1 > /dev/null 2>&1; then
            return 0
        fi
    done

    address="$(get_service_listen_address 2> /dev/null | status_diagnostics_ucode stdin-first-line 2>/dev/null)"
    if [ -n "$address" ] &&
        dig @"$address" "$domain" +timeout=2 +tries=1 > /dev/null 2>&1; then
        return 0
    fi

    source_network_interfaces="$(uci_get "$PODKOP_CONFIG_NAME" "settings" "source_network_interfaces")"
    [ -n "$source_network_interfaces" ] || source_network_interfaces="br-lan"

    for interface in $source_network_interfaces; do
        network_get_ipaddr address "$interface"
        if [ -n "$address" ] &&
            dig @"$address" "$domain" +timeout=2 +tries=1 > /dev/null 2>&1; then
            return 0
        fi

        address="$(get_device_ipv4_address "$interface")"
        if [ -n "$address" ] &&
            dig @"$address" "$domain" +timeout=2 +tries=1 > /dev/null 2>&1; then
            return 0
        fi
    done

    return 1
}

check_dns_available() {
    local dns_type dns_server bootstrap_dns_server dns_server_host bootstrap_check_domain display_dns_server
    config_get dns_type "settings" "dns_type"
    config_get dns_server "settings" "dns_server"
    config_get bootstrap_dns_server "settings" "bootstrap_dns_server"

    local dns_status=0
    local dns_on_router=0
    local bootstrap_dns_status=0
    local dhcp_config_status=1
    local domain="google.com"

    display_dns_server="$(status_diagnostics_ucode mask-dns-server "$dns_server")"

    dns_server_host="$(url_get_host "$dns_server")"
    [ -n "$dns_server_host" ] || dns_server_host="$dns_server"

    case "$dns_type" in
    doh)
        if dns_check_doh_server_available "$dns_server" "$bootstrap_dns_server"; then
            dns_status=1
        fi
        ;;
    dot | udp)
        if dns_check_dig_server_available "$dns_type" "$dns_server" "$bootstrap_dns_server" "$domain"; then
            dns_status=1
        fi
        ;;
    esac

    # Check if local DNS resolver is working
    if dns_check_router_resolver_available "$domain"; then
        dns_on_router=1
    fi

    # Check bootstrap DNS server
    if [ -n "$bootstrap_dns_server" ]; then
        bootstrap_check_domain="$domain"
        if [ -n "$dns_server_host" ] && ! is_ipv4 "$dns_server_host"; then
            bootstrap_check_domain="$dns_server_host"
        fi

        if dns_check_resolve_host "$bootstrap_check_domain" "$bootstrap_dns_server" > /dev/null; then
            bootstrap_dns_status=1
        fi
    fi

    # Check if dnsmasq sends DNS requests through Podkop DNS.
    config_load dhcp
    check_dhcp_has_podkop_dns
    config_load "$PODKOP_CONFIG_NAME"

    status_diagnostics_ucode dns-check-json \
        "$dns_type" \
        "$display_dns_server" \
        "$dns_status" \
        "$dns_on_router" \
        "$bootstrap_dns_server" \
        "$bootstrap_dns_status" \
        "$dhcp_config_status"
}

check_dhcp_has_podkop_dns() {
    if ! dnsmasq_default_config_is_complete; then
        dhcp_config_status=0
    fi
}

nft_chain_counter_status() {
    nft list chain inet "$NFT_TABLE_NAME" "$1" 2>/dev/null | status_diagnostics_ucode nft-chain-counter-status
}

check_nft_rules() {
    local table_exist=0
    local rules_mangle_exist=0
    local rules_mangle_counters=0
    local rules_mangle_output_exist=0
    local rules_mangle_output_counters=0
    local rules_proxy_exist=0
    local rules_proxy_counters=0
    local rules_other_mark_exist=0

    # Generate traffic through PodkopTable
    curl -m 3 -s "https://$CHECK_PROXY_IP_DOMAIN/check" > /dev/null 2>&1 &
    local pid1=$!
    curl -m 3 -s "https://$FAKEIP_TEST_DOMAIN/check" > /dev/null 2>&1 &
    local pid2=$!

    wait $pid1 2> /dev/null
    wait $pid2 2> /dev/null
    sleep 1

    # Check if PodkopPlusTable exists
    if nft list table inet "$NFT_TABLE_NAME" > /dev/null 2>&1; then
        table_exist=1

        # Check mangle chain rules
        if nft list chain inet "$NFT_TABLE_NAME" mangle > /dev/null 2>&1; then
            read -r rules_mangle_exist rules_mangle_counters <<EOF
$(nft_chain_counter_status mangle)
EOF
        fi

        # Check mangle_output chain rules
        if nft list chain inet "$NFT_TABLE_NAME" mangle_output > /dev/null 2>&1; then
            read -r rules_mangle_output_exist rules_mangle_output_counters <<EOF
$(nft_chain_counter_status mangle_output)
EOF
        fi

        # Check proxy chain rules
        if nft list chain inet "$NFT_TABLE_NAME" proxy > /dev/null 2>&1; then
            read -r rules_proxy_exist rules_proxy_counters <<EOF
$(nft_chain_counter_status proxy)
EOF
        fi
    fi

    # Check for other mark rules outside PodkopPlusTable
    nft list tables 2> /dev/null | while read -r _ family table_name; do
        [ -z "$table_name" ] && continue

        [ "$table_name" = "$NFT_TABLE_NAME" ] && continue

        if nft list table "$family" "$table_name" 2> /dev/null |
            status_diagnostics_ucode stdin-contains "meta mark set" >/dev/null 2>&1; then
            touch /tmp/podkop_mark_check.$$
            break
        fi
    done

    if [ -f /tmp/podkop_mark_check.$$ ]; then
        rules_other_mark_exist=1
        rm -f /tmp/podkop_mark_check.$$
    fi

    status_diagnostics_ucode nft-check-json \
        "$table_exist" \
        "$rules_mangle_exist" \
        "$rules_mangle_counters" \
        "$rules_mangle_output_exist" \
        "$rules_mangle_output_counters" \
        "$rules_proxy_exist" \
        "$rules_proxy_counters" \
        "$rules_other_mark_exist"
}

check_sing_box() {
    local sing_box_installed=0
    local sing_box_version_ok=0
    local sing_box_extended=0
    local sing_box_service_exist=0
    local sing_box_autostart_disabled=0
    local sing_box_process_running=0
    local sing_box_ports_listening=0

    # Check if sing-box is installed
    if command -v sing-box > /dev/null 2>&1; then
        sing_box_installed=1

        # Check version (must be >= 1.12.4)
        local version
        version="$(get_sing_box_version)"
        if [ -n "$version" ]; then
            version="$(status_diagnostics_ucode strip-leading-v "$version")"
            is_sing_box_extended "$version" && sing_box_extended=1

            if is_min_package_version "$version" "1.12.4"; then
                sing_box_version_ok=1
            fi
        fi
    fi

    # Check if service exists
    if [ -f /etc/init.d/sing-box ]; then
        sing_box_service_exist=1

        if ! /etc/init.d/sing-box enabled 2> /dev/null; then
            sing_box_autostart_disabled=1
        fi
    fi

    # Check if process is running
    if pgrep "sing-box" > /dev/null 2>&1; then
        sing_box_process_running=1
    fi

    # Check if sing-box is listening on required ports
    local port_53_ok=0
    local port_1602_ok=0

    if netstat -ln 2> /dev/null | status_diagnostics_ucode stdin-contains "127.0.0.42:53"; then
        port_53_ok=1
    fi

    if netstat -ln 2> /dev/null | status_diagnostics_ucode stdin-contains "127.0.0.1:1602"; then
        port_1602_ok=1
    fi

    # Both ports must be listening
    if [ "$port_53_ok" = "1" ] && [ "$port_1602_ok" = "1" ]; then
        sing_box_ports_listening=1
    fi

    status_diagnostics_ucode sing-box-check-json \
        "$sing_box_installed" \
        "$sing_box_version_ok" \
        "$sing_box_extended" \
        "$sing_box_service_exist" \
        "$sing_box_autostart_disabled" \
        "$sing_box_process_running" \
        "$sing_box_ports_listening"
}

check_fakeip() {
    local fakeip_address fakeip_status

    fakeip_address="$(
        dig +short @"$SB_DNS_INBOUND_ADDRESS" "$FAKEIP_TEST_DOMAIN" A +timeout=2 +tries=1 2> /dev/null |
            status_diagnostics_ucode stdin-first-ipv4-line 2>/dev/null
    )"

    fakeip_status="$(status_diagnostics_ucode fakeip-address-status "$fakeip_address" 2>/dev/null)"
    [ -n "$fakeip_status" ] || fakeip_status=false

    status_diagnostics_ucode fakeip-check-json "$fakeip_status" "$fakeip_address"
}

#######################################
# Clash API interface for managing proxies and groups
# Arguments:
#   $1 - Action: get_proxies, get_connections, get_proxy_latency, get_group_latency, set_group_proxy,
#        close_connection, close_all_connections
#   $2 - Proxy/Group tag (required for latency and set operations) or connection id
#   $3 - Timeout in ms (optional, defaults: 2000 for proxy, 5000 for group) or target proxy tag for set_group_proxy
# Outputs:
#   JSON formatted response
# Usage:
#   clash_api get_proxies
#   clash_api get_connections
#   clash_api get_proxy_latency <proxy_tag> [timeout]
#   clash_api get_group_latency <group_tag> [timeout]
#   clash_api set_group_proxy <group_tag> <proxy_tag>
#   clash_api close_connection <connection_id>
#   clash_api close_all_connections
#######################################

clash_api_urlencode_path_segment() {
    status_diagnostics_ucode url-encode "$1"
}

clash_api() {
    local action="$1"
    local clash_api_controller_address CLASH_URL TEST_URL
    clash_api_controller_address="$(get_service_listen_address)"
    if [ -z "$clash_api_controller_address" ]; then
        clash_api_controller_address="127.0.0.1"
    fi
    CLASH_URL="$clash_api_controller_address:$SB_CLASH_API_CONTROLLER_PORT"
    TEST_URL="https://www.gstatic.com/generate_204"

    local enable_yacd_wan_access yacd_secret_key auth_header
    config_get_bool enable_yacd_wan_access "settings" "enable_yacd_wan_access" 0
    config_get yacd_secret_key "settings" "yacd_secret_key"

    if [ "$enable_yacd_wan_access" -eq 1 ]; then
        auth_header="Authorization: Bearer $yacd_secret_key"
    else
        auth_header=""
    fi

    case "$action" in
    get_proxies)
        curl -s --header "$auth_header" "$CLASH_URL/proxies" | status_diagnostics_ucode stdin-json
        ;;

    get_connections)
        curl -s --header "$auth_header" "$CLASH_URL/connections" | status_diagnostics_ucode stdin-json
        ;;

    get_proxy_latency)
        local proxy_tag="$2"
        local timeout="${3:-2000}"

        if [ -z "$proxy_tag" ]; then
            status_diagnostics_ucode json-error "proxy_tag required"
            return 1
        fi

        curl -G -s "$CLASH_URL/proxies/$proxy_tag/delay" \
            --header "$auth_header" \
            --data-urlencode "url=$TEST_URL" \
            --data-urlencode "timeout=$timeout" | status_diagnostics_ucode stdin-json
        ;;

    get_group_latency)
        local group_tag="$2"
        local timeout="${3:-5000}"

        if [ -z "$group_tag" ]; then
            status_diagnostics_ucode json-error "group_tag required"
            return 1
        fi

        curl -G -s "$CLASH_URL/group/$group_tag/delay" \
            --header "$auth_header" \
            --data-urlencode "url=$TEST_URL" \
            --data-urlencode "timeout=$timeout" | status_diagnostics_ucode stdin-json
        ;;

    set_group_proxy)
        local group_tag="$2"
        local proxy_tag="$3"

        if [ -z "$group_tag" ] || [ -z "$proxy_tag" ]; then
            status_diagnostics_ucode json-error "group_tag and proxy_tag required"
            return 1
        fi

        local response
        response=$(
            curl -X PUT -s -w "\n%{http_code}" "$CLASH_URL/proxies/$group_tag" \
                --header "$auth_header" \
                --data-raw "$(status_diagnostics_ucode clash-set-group-proxy-payload "$proxy_tag")"
        )

        printf '%s' "$response" | status_diagnostics_ucode clash-set-group-proxy-result "$group_tag" "$proxy_tag"
        ;;

    close_connection)
        local connection_id="$2"

        if [ -z "$connection_id" ]; then
            status_diagnostics_ucode json-error "connection_id required"
            return 1
        fi

        local encoded_connection_id response
        encoded_connection_id="$(clash_api_urlencode_path_segment "$connection_id")" || return 1
        response=$(
            curl -X DELETE -s -w "\n%{http_code}" "$CLASH_URL/connections/$encoded_connection_id" \
                --header "$auth_header"
        )
        printf '%s' "$response" | status_diagnostics_ucode clash-close-connection-result "$connection_id"
        ;;

    close_all_connections)
        local response
        response=$(
            curl -X DELETE -s -w "\n%{http_code}" "$CLASH_URL/connections" \
                --header "$auth_header"
        )
        printf '%s' "$response" | status_diagnostics_ucode clash-close-all-connections-result
        ;;

    *)
        status_diagnostics_ucode clash-unknown-action
        return 1
        ;;
    esac
}

print_global() {
    local message="$1"
    echo "$message"
}

status_diagnostics_ucode() {
    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/status_diagnostics.uc" "$@"
}

global_check() {
    local PODKOP_LUCI_VERSION="Unknown"
    [ -n "$1" ] && PODKOP_LUCI_VERSION="$1"

    print_global "📡 Global check run!"
    print_global "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_global "🛠️ System info"

    local system_info_json
    system_info_json=$(get_system_info)

    if [ -n "$system_info_json" ]; then
        printf '%s' "$system_info_json" | status_diagnostics_ucode global-system-info ||
            print_global "❌ Failed to parse system info"
    else
        print_global "❌ Failed to get system info"
    fi

    print_global "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_global "➡️ DNS status"

    local dns_check_json
    dns_check_json=$(check_dns_available)

    if [ -n "$dns_check_json" ]; then
        local dont_touch_dhcp dns_render_rc
        config_get dont_touch_dhcp "settings" "dont_touch_dhcp"

        printf '%s' "$dns_check_json" | status_diagnostics_ucode global-dns-check "$dont_touch_dhcp"
        dns_render_rc=$?
        if [ "$dns_render_rc" -eq 10 ]; then
            status_diagnostics_ucode dhcp-dnsmasq-config /etc/config/dhcp
        elif [ "$dns_render_rc" -ne 0 ]; then
            print_global "❌ Failed to parse DNS info"
        fi
    else
        print_global "❌ Failed to get DNS info"
    fi

    print_global "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_global "📦 Sing-box status"

    local singbox_check_json
    singbox_check_json=$(check_sing_box)

    if [ -n "$singbox_check_json" ]; then
        printf '%s' "$singbox_check_json" | status_diagnostics_ucode global-sing-box-check ||
            print_global "❌ Failed to parse sing-box info"
    else
        print_global "❌ Failed to get sing-box info"
    fi

    print_global "---------------------------"
    print_global "Inbounds checks"

    local inbounds_check_json
    inbounds_check_json=$(check_inbounds)

    if [ -n "$inbounds_check_json" ]; then
        printf '%s' "$inbounds_check_json" | status_diagnostics_ucode global-inbounds-check ||
            print_global "[FAIL] Failed to parse inbounds check details"
    else
        print_global "[FAIL] Failed to get inbounds info"
    fi

    print_global "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_global "🧱 NFT rules status"

    local nft_check_json
    nft_check_json=$(check_nft_rules)

    if [ -n "$nft_check_json" ]; then
        if printf '%s' "$nft_check_json" | status_diagnostics_ucode global-nft-check; then
            if printf '%s' "$nft_check_json" | status_diagnostics_ucode global-nft-other-mark-exists >/dev/null 2>&1; then
                nft list ruleset | status_diagnostics_ucode nft-ruleset-other-mark-lines "$NFT_TABLE_NAME"
            fi
        else
            print_global "❌ Failed to parse NFT rules info"
        fi
    else
        print_global "❌ Failed to get NFT rules info"
    fi

    print_global "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_global "📄 Podkop Plus config"
    show_config

    print_global "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_global "📄 WAN config"
    if uci show network.wan > /dev/null 2>&1; then
        status_diagnostics_ucode wan-config-masked /etc/config/network
    else
        print_global "❌ WAN configuration not found"
    fi

    uci show network 2>/dev/null |
        status_diagnostics_ucode network-endpoint-host-warnings "$CLOUDFLARE_OCTETS" 2>/dev/null |
        while IFS="$(printf '\t')" read -r warning_kind host || [ -n "$warning_kind" ]; do
            [ -n "$host" ] || continue
            if [ "$warning_kind" = "engage" ]; then
                print_global "⚠️ WARP detected: $host"
                continue
            fi

            if [ "$warning_kind" = "prefix" ]; then
                print_global "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                print_global "⚠️ WARP detected: $host"
            fi
        done

    uci show network 2>/dev/null |
        status_diagnostics_ucode network-wireguard-route-allowed-peers 2>/dev/null |
        while read -r peer_section || [ -n "$peer_section" ]; do
            [ -n "$peer_section" ] || continue
            local allowed_ips
            allowed_ips=$(uci get "${peer_section}.allowed_ips" 2> /dev/null)

            if [ "$allowed_ips" = "0.0.0.0/0" ]; then
                print_global "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                print_global "⚠️ WG Route allowed IP enabled with 0.0.0.0/0"
            fi
        done

    if [ -x /etc/init.d/zapret ] && /etc/init.d/zapret status >/dev/null 2>&1; then
        print_global "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        print_global "⚠️ Standalone zapret service is active. Podkop Plus uses separate queues, but packet-level policy overlap is possible."
    elif [ -x /etc/init.d/zapret ] && /etc/init.d/zapret enabled >/dev/null 2>&1; then
        print_global "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        print_global "⚠️ Standalone zapret autostart is enabled. Podkop Plus will not modify /etc/config/zapret."
    fi

    if [ -x /etc/init.d/zapret2 ] && /etc/init.d/zapret2 status >/dev/null 2>&1; then
        print_global "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        print_global "⚠️ Standalone zapret2 service is active. Podkop Plus uses separate queues, but packet-level policy overlap is possible."
    elif [ -x /etc/init.d/zapret2 ] && /etc/init.d/zapret2 enabled >/dev/null 2>&1; then
        print_global "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        print_global "⚠️ Standalone zapret2 autostart is enabled. Podkop Plus will not modify /etc/config/zapret2."
    fi

    print_global "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_global "🥸 FakeIP status"

    local fakeip_check_json
    fakeip_check_json=$(check_fakeip)

    if [ -n "$fakeip_check_json" ]; then
        printf '%s' "$fakeip_check_json" | status_diagnostics_ucode global-fakeip-check ||
            print_global "❌ Failed to parse FakeIP info"
    else
        print_global "❌ Failed to get FakeIP info"
    fi
}
