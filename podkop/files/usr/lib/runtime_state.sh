# shellcheck shell=ash

close_inherited_service_lock_fd() {
    # OpenWrt init scripts may keep their service lock on fd 1000.
    # shellcheck disable=SC3023
    exec 1000>&- 2>/dev/null || true
}

acquire_runtime_dir_lock() {
    local lock_dir="$1"
    local owner_pid

    if mkdir "$lock_dir" 2>/dev/null; then
        printf '%s\n' "$$" > "$lock_dir/pid"
        return 0
    fi

    owner_pid="$(runtime_state_ucode file-first-line "$lock_dir/pid" 2>/dev/null)"
    if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
        return 1
    fi

    rm -f "$lock_dir/pid" 2>/dev/null
    rmdir "$lock_dir" 2>/dev/null || return 1
    mkdir "$lock_dir" 2>/dev/null || return 1
    printf '%s\n' "$$" > "$lock_dir/pid"
}

acquire_runtime_dir_lock_wait() {
    local lock_dir="$1"
    local timeout="${2:-300}"
    local start now elapsed

    start="$(date +%s 2>/dev/null)"
    case "$start" in
    '' | *[!0-9]*) start=0 ;;
    esac

    while ! acquire_runtime_dir_lock "$lock_dir"; do
        now="$(date +%s 2>/dev/null)"
        case "$now" in
        '' | *[!0-9]*) now="$start" ;;
        esac
        elapsed=$((now - start))
        [ "$elapsed" -lt "$timeout" ] || return 1
        sleep 2
    done

    return 0
}

release_runtime_dir_lock() {
    local lock_dir="$1"

    rm -f "$lock_dir/pid" 2>/dev/null
    rmdir "$lock_dir" 2>/dev/null
}

runtime_state_ucode() {
    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/runtime_state.uc" "$@"
}

mark_pending_reload() {
    local reason="${1:-pending}"
    local now

    ensure_runtime_dirs
    now="$(date +%s 2>/dev/null)"
    case "$now" in
    '' | *[!0-9]*) now=0 ;;
    esac

    {
        printf 'reason=%s\n' "$reason"
        printf 'updated_at=%s\n' "$now"
    } > "$PODKOP_PENDING_RELOAD_FILE"
}

consume_pending_reload() {
    [ -f "$PODKOP_PENDING_RELOAD_FILE" ] || return 1
    rm -f "$PODKOP_PENDING_RELOAD_FILE" 2>/dev/null
}

run_pending_reload_if_requested() {
    consume_pending_reload || return 0
    echolog "Applying pending Podkop Plus reload"
    "$PODKOP_SERVICE_INIT" reload pending >/dev/null 2>&1 &
}

sync_time_if_needed() {
    local current_year

    current_year="$(date +%Y 2>/dev/null)"
    case "$current_year" in
    '' | *[!0-9]*)
        return 0
        ;;
    esac

    [ "$current_year" -lt 2024 ] || return 0

    /usr/sbin/ntpd -q -p 194.190.168.1 -p 216.239.35.0 -p 216.239.35.4 -p 162.159.200.1 -p 162.159.200.123 >/dev/null 2>&1 || true
}

process_age_seconds() {
    local pid="$1"
    local stat stat_rest start_ticks uptime_seconds

    [ -r "/proc/$pid/stat" ] || return 1

    stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
    stat_rest="${stat##*) }"

    set -- $stat_rest
    [ "$#" -ge 20 ] || return 1
    shift 19
    start_ticks="$1"

    case "$start_ticks" in
    '' | *[!0-9]*) return 1 ;;
    esac

    read -r uptime_seconds _ < /proc/uptime || return 1
    uptime_seconds="${uptime_seconds%%.*}"
    case "$uptime_seconds" in
    '' | *[!0-9]*) return 1 ;;
    esac

    echo $((uptime_seconds - (start_ticks / 100)))
}

sing_box_service_pid() {
    local service_json='{"name":"sing-box"}'

    ubus call service list "$service_json" 2>/dev/null |
        runtime_state_ucode sing-box-service-pid 2>/dev/null
}

pid_is_sing_box() {
    local pid="$1"
    local exe

    case "$pid" in
    '' | *[!0-9]*) return 1 ;;
    esac

    exe="$(readlink "/proc/$pid/exe" 2>/dev/null)" || return 1
    [ "${exe##*/}" = "sing-box" ]
}

sing_box_service_is_running() {
    local pid

    pid="$(sing_box_service_pid)"
    pid_is_sing_box "$pid"
}

sing_box_service_is_stable() {
    local min_age="${1:-$PODKOP_RUNTIME_STABLE_MIN_AGE}"
    local pid age

    pid="$(sing_box_service_pid)"
    pid_is_sing_box "$pid" || return 1

    age="$(process_age_seconds "$pid")" || return 1
    [ "$age" -ge "$min_age" ]
}

podkop_runtime_network_is_configured() {
    nft list table inet "$NFT_TABLE_NAME" >/dev/null 2>&1 &&
        has_tproxy_marking_rule &&
        has_tproxy_route
}

podkop_is_running() {
    sing_box_service_is_running &&
        podkop_runtime_network_is_configured
}

podkop_is_stably_running() {
    sing_box_service_is_stable &&
        podkop_runtime_network_is_configured
}

wait_for_podkop_stable_start() {
    local timeout="${1:-8}"

    while [ "$timeout" -gt 0 ]; do
        podkop_is_stably_running && return 0
        sleep 1
        timeout=$((timeout - 1))
    done

    return 1
}

clear_reload_state() {
    rm -f "$PODKOP_RELOAD_STATE_FILE"
}

read_reload_state_value() {
    local key="$1"

    [ -f "$PODKOP_RELOAD_STATE_FILE" ] || return 1

    runtime_state_ucode get "$PODKOP_RELOAD_STATE_FILE" "$key"
}

reload_state_has_key() {
    local key="$1"

    [ -f "$PODKOP_RELOAD_STATE_FILE" ] || return 1

    runtime_state_ucode has-key "$PODKOP_RELOAD_STATE_FILE" "$key"
}

reload_state_is_compatible() {
    [ "$(read_reload_state_value "format")" = "$PODKOP_RELOAD_STATE_FORMAT" ]
}

load_previous_reload_state() {
    local line key value

    PREVIOUS_RELOAD_STATE_FORMAT=""
    PREVIOUS_RELOAD_STATE_SERVICE_TRIGGER_SIGNATURE=""
    PREVIOUS_RELOAD_STATE_RESTART_SIGNATURE=""
    PREVIOUS_RELOAD_STATE_DNSMASQ_SIGNATURE=""
    PREVIOUS_RELOAD_STATE_SING_BOX_SIGNATURE=""
    PREVIOUS_RELOAD_STATE_NFT_SIGNATURE=""
    PREVIOUS_RELOAD_STATE_ZAPRET_QUEUE_SIGNATURE=""
    PREVIOUS_RELOAD_STATE_ZAPRET_RUNTIME_SIGNATURE=""
    PREVIOUS_RELOAD_STATE_ZAPRET2_QUEUE_SIGNATURE=""
    PREVIOUS_RELOAD_STATE_ZAPRET2_RUNTIME_SIGNATURE=""
    PREVIOUS_RELOAD_STATE_BYEDPI_RUNTIME_SIGNATURE=""
    PREVIOUS_RELOAD_STATE_LIST_SIGNATURE=""
    PREVIOUS_RELOAD_STATE_CRON_SIGNATURE=""
    PREVIOUS_RELOAD_STATE_URLTEST_ENABLED_SECTIONS=""
    PREVIOUS_RELOAD_STATE_URLTEST_ENABLED_SECTIONS_KNOWN=0

    [ -f "$PODKOP_RELOAD_STATE_FILE" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        key="${line%%=*}"
        [ "$line" != "$key" ] && value="${line#*=}" || value=""

        case "$key" in
        format) PREVIOUS_RELOAD_STATE_FORMAT="$value" ;;
        service_trigger_signature) PREVIOUS_RELOAD_STATE_SERVICE_TRIGGER_SIGNATURE="$value" ;;
        restart_signature) PREVIOUS_RELOAD_STATE_RESTART_SIGNATURE="$value" ;;
        dnsmasq_signature) PREVIOUS_RELOAD_STATE_DNSMASQ_SIGNATURE="$value" ;;
        sing_box_signature) PREVIOUS_RELOAD_STATE_SING_BOX_SIGNATURE="$value" ;;
        nft_signature) PREVIOUS_RELOAD_STATE_NFT_SIGNATURE="$value" ;;
        zapret_queue_signature) PREVIOUS_RELOAD_STATE_ZAPRET_QUEUE_SIGNATURE="$value" ;;
        zapret_runtime_signature) PREVIOUS_RELOAD_STATE_ZAPRET_RUNTIME_SIGNATURE="$value" ;;
        zapret2_queue_signature) PREVIOUS_RELOAD_STATE_ZAPRET2_QUEUE_SIGNATURE="$value" ;;
        zapret2_runtime_signature) PREVIOUS_RELOAD_STATE_ZAPRET2_RUNTIME_SIGNATURE="$value" ;;
        byedpi_runtime_signature) PREVIOUS_RELOAD_STATE_BYEDPI_RUNTIME_SIGNATURE="$value" ;;
        list_signature) PREVIOUS_RELOAD_STATE_LIST_SIGNATURE="$value" ;;
        cron_signature) PREVIOUS_RELOAD_STATE_CRON_SIGNATURE="$value" ;;
        urltest_enabled_sections)
            PREVIOUS_RELOAD_STATE_URLTEST_ENABLED_SECTIONS="$value"
            PREVIOUS_RELOAD_STATE_URLTEST_ENABLED_SECTIONS_KNOWN=1
            ;;
        esac
    done < "$PODKOP_RELOAD_STATE_FILE"

    [ "$PREVIOUS_RELOAD_STATE_FORMAT" = "$PODKOP_RELOAD_STATE_FORMAT" ]
}

signature_begin() {
    RELOAD_SIGNATURE_TMPFILE="$(mktemp)"
}

signature_add() {
    local key="$1"
    local value="$2"

    printf '[%s]\n%s\n' "$key" "$value" >> "$RELOAD_SIGNATURE_TMPFILE"
}

signature_finish() {
    local hash_line

    hash_line="$(md5sum "$RELOAD_SIGNATURE_TMPFILE")"
    rm -f "$RELOAD_SIGNATURE_TMPFILE"
    set -- $hash_line
    echo "$1"
}

build_service_trigger_signature() {
    # These settings are consumed by init.d/procd triggers, not by sing-box/nft
    # runtime. Track them separately so config reloads can refresh procd without
    # forcing an in-process runtime restart.
    local enable_badwan_interface_monitoring badwan_monitored_interfaces badwan_reload_delay

    signature_begin
    config_get_bool enable_badwan_interface_monitoring "settings" "enable_badwan_interface_monitoring" 0
    signature_add "settings.enable_badwan_interface_monitoring" "$enable_badwan_interface_monitoring"

    if [ "$enable_badwan_interface_monitoring" -eq 1 ]; then
        config_get badwan_monitored_interfaces "settings" "badwan_monitored_interfaces"
        config_get badwan_reload_delay "settings" "badwan_reload_delay" "2000"
        signature_add "settings.badwan_monitored_interfaces" "$badwan_monitored_interfaces"
        signature_add "settings.badwan_reload_delay" "$badwan_reload_delay"
    fi

    signature_finish
}

build_dnsmasq_signature() {
    local dont_touch_dhcp legacy_dnsmasq_present

    signature_begin
    config_get_bool dont_touch_dhcp "settings" "dont_touch_dhcp" 0
    signature_add "settings.dont_touch_dhcp" "$dont_touch_dhcp"
    signature_add "dhcp.@dnsmasq[0].server" "$(uci_get "dhcp" "@dnsmasq[0]" "server")"
    signature_add "dhcp.@dnsmasq[0].noresolv" "$(uci_get "dhcp" "@dnsmasq[0]" "noresolv")"
    signature_add "dhcp.@dnsmasq[0].cachesize" "$(uci_get "dhcp" "@dnsmasq[0]" "cachesize")"
    signature_add "dhcp.@dnsmasq[0].podkop_server" "$(uci_get "dhcp" "@dnsmasq[0]" "podkop_server")"
    signature_add "dhcp.@dnsmasq[0].podkop_noresolv" "$(uci_get "dhcp" "@dnsmasq[0]" "podkop_noresolv")"
    signature_add "dhcp.@dnsmasq[0].podkop_cachesize" "$(uci_get "dhcp" "@dnsmasq[0]" "podkop_cachesize")"
    legacy_dnsmasq_present=0
    uci -q show "dhcp.podkop_plus" >/dev/null 2>&1 && legacy_dnsmasq_present=1
    signature_add "dhcp.podkop_plus.present" "$legacy_dnsmasq_present"
    signature_finish
}

append_sing_box_rule_signature() {
    local section="$1"
    local action domain domain_suffix domain_keyword domain_regex ip_cidr source_ip_cidr fully_routed_ips \
        ports community_lists rule_set rule_set_with_subnets domain_ip_lists mixed_proxy_enabled mixed_proxy_port \
        mixed_proxy_auth_enabled mixed_proxy_username mixed_proxy_password resolve_real_ip_for_routing

    rule_is_enabled "$section" || return 0

    action="$(get_rule_action "$section")"
    [ -n "$action" ] || return 0

    signature_add "rule.$section.action" "$action"

    case "$action" in
    proxy)
        local selector_proxy_links subscription_urls udp_over_tcp urltest_enabled \
            urltest_check_interval urltest_tolerance urltest_testing_url subscription_update_enabled \
            subscription_update_interval detect_server_country urltest_filter_mode urltest_exclude_countries urltest_include_countries \
            urltest_exclude_outbounds urltest_exclude_regex urltest_include_outbounds urltest_include_regex \
            outbound_detour_enabled outbound_detour_section
        config_get selector_proxy_links "$section" "selector_proxy_links"
        config_get subscription_urls "$section" "subscription_urls"
        config_get_bool udp_over_tcp "$section" "enable_udp_over_tcp" 0
        config_get_bool urltest_enabled "$section" "urltest_enabled" 0
        config_get detect_server_country "$section" "detect_server_country" "$SERVER_COUNTRY_METHOD_FLAG_EMOJI"
        detect_server_country="$(normalize_detect_server_country_method "$detect_server_country")"
        urltest_check_interval="$(get_urltest_check_interval_for_rule "$section")"
        config_get urltest_tolerance "$section" "urltest_tolerance" 50
        config_get urltest_testing_url "$section" "urltest_testing_url" "https://www.gstatic.com/generate_204"
        config_get_bool subscription_update_enabled "$section" "subscription_update_enabled" 1
        subscription_update_interval="$(get_subscription_update_interval_for_rule "$section")"
        config_get urltest_filter_mode "$section" "urltest_filter_mode" "disabled"
        config_get urltest_exclude_countries "$section" "urltest_exclude_countries"
        config_get urltest_include_countries "$section" "urltest_include_countries"
        config_get urltest_exclude_outbounds "$section" "urltest_exclude_outbounds"
        config_get urltest_exclude_regex "$section" "urltest_exclude_regex"
        config_get urltest_include_outbounds "$section" "urltest_include_outbounds"
        config_get urltest_include_regex "$section" "urltest_include_regex"

        signature_add "rule.$section.selector_proxy_links" "$selector_proxy_links"
        signature_add "rule.$section.subscription_urls" "$subscription_urls"
        signature_add "rule.$section.enable_udp_over_tcp" "$udp_over_tcp"
        signature_add "rule.$section.urltest_enabled" "$urltest_enabled"
        signature_add "rule.$section.detect_server_country" "$detect_server_country"
        signature_add "rule.$section.urltest_check_interval" "$urltest_check_interval"
        signature_add "rule.$section.urltest_tolerance" "$urltest_tolerance"
        signature_add "rule.$section.urltest_testing_url" "$urltest_testing_url"
        signature_add "rule.$section.urltest_filter_mode" "$urltest_filter_mode"
        signature_add "rule.$section.urltest_exclude_countries" "$urltest_exclude_countries"
        signature_add "rule.$section.urltest_include_countries" "$urltest_include_countries"
        signature_add "rule.$section.urltest_exclude_outbounds" "$urltest_exclude_outbounds"
        signature_add "rule.$section.urltest_exclude_regex" "$urltest_exclude_regex"
        signature_add "rule.$section.urltest_include_outbounds" "$urltest_include_outbounds"
        signature_add "rule.$section.urltest_include_regex" "$urltest_include_regex"
        signature_add "rule.$section.subscription_update_enabled" "$subscription_update_enabled"
        signature_add "rule.$section.subscription_update_interval" "$subscription_update_interval"

        config_get_bool outbound_detour_enabled "$section" "outbound_detour_enabled" 0
        signature_add "rule.$section.outbound_detour_enabled" "$outbound_detour_enabled"
        if [ "$outbound_detour_enabled" -eq 1 ]; then
            config_get outbound_detour_section "$section" "outbound_detour_section"
            signature_add "rule.$section.outbound_detour_section" "$outbound_detour_section"
        fi

        config_get_bool mixed_proxy_enabled "$section" "mixed_proxy_enabled" 0
        signature_add "rule.$section.mixed_proxy_enabled" "$mixed_proxy_enabled"
        if [ "$mixed_proxy_enabled" -eq 1 ]; then
            config_get mixed_proxy_port "$section" "mixed_proxy_port"
            signature_add "rule.$section.mixed_proxy_port" "$mixed_proxy_port"
            config_get_bool mixed_proxy_auth_enabled "$section" "mixed_proxy_auth_enabled" 0
            signature_add "rule.$section.mixed_proxy_auth_enabled" "$mixed_proxy_auth_enabled"
            if [ "$mixed_proxy_auth_enabled" -eq 1 ]; then
                config_get mixed_proxy_username "$section" "mixed_proxy_username"
                config_get mixed_proxy_password "$section" "mixed_proxy_password"
                signature_add "rule.$section.mixed_proxy_username" "$mixed_proxy_username"
                signature_add "rule.$section.mixed_proxy_password" "$mixed_proxy_password"
            fi
        fi

        config_get_bool resolve_real_ip_for_routing "$section" "resolve_real_ip_for_routing" 0
        signature_add "rule.$section.resolve_real_ip_for_routing" "$resolve_real_ip_for_routing"
        ;;
    outbound)
        local outbound_json outbound_detour_enabled outbound_detour_section
        config_get outbound_json "$section" "outbound_json"
        signature_add "rule.$section.outbound_json" "$outbound_json"

        config_get_bool outbound_detour_enabled "$section" "outbound_detour_enabled" 0
        signature_add "rule.$section.outbound_detour_enabled" "$outbound_detour_enabled"
        if [ "$outbound_detour_enabled" -eq 1 ]; then
            config_get outbound_detour_section "$section" "outbound_detour_section"
            signature_add "rule.$section.outbound_detour_section" "$outbound_detour_section"
        fi

        config_get_bool mixed_proxy_enabled "$section" "mixed_proxy_enabled" 0
        signature_add "rule.$section.mixed_proxy_enabled" "$mixed_proxy_enabled"
        if [ "$mixed_proxy_enabled" -eq 1 ]; then
            config_get mixed_proxy_port "$section" "mixed_proxy_port"
            signature_add "rule.$section.mixed_proxy_port" "$mixed_proxy_port"
            config_get_bool mixed_proxy_auth_enabled "$section" "mixed_proxy_auth_enabled" 0
            signature_add "rule.$section.mixed_proxy_auth_enabled" "$mixed_proxy_auth_enabled"
            if [ "$mixed_proxy_auth_enabled" -eq 1 ]; then
                config_get mixed_proxy_username "$section" "mixed_proxy_username"
                config_get mixed_proxy_password "$section" "mixed_proxy_password"
                signature_add "rule.$section.mixed_proxy_username" "$mixed_proxy_username"
                signature_add "rule.$section.mixed_proxy_password" "$mixed_proxy_password"
            fi
        fi

        config_get_bool resolve_real_ip_for_routing "$section" "resolve_real_ip_for_routing" 0
        signature_add "rule.$section.resolve_real_ip_for_routing" "$resolve_real_ip_for_routing"
        ;;
    byedpi)
        local byedpi_index
        byedpi_index="$(get_byedpi_rule_index "$section")"
        signature_add "rule.$section.byedpi_index" "$byedpi_index"

        config_get_bool mixed_proxy_enabled "$section" "mixed_proxy_enabled" 0
        signature_add "rule.$section.mixed_proxy_enabled" "$mixed_proxy_enabled"
        if [ "$mixed_proxy_enabled" -eq 1 ]; then
            config_get mixed_proxy_port "$section" "mixed_proxy_port"
            signature_add "rule.$section.mixed_proxy_port" "$mixed_proxy_port"
            config_get_bool mixed_proxy_auth_enabled "$section" "mixed_proxy_auth_enabled" 0
            signature_add "rule.$section.mixed_proxy_auth_enabled" "$mixed_proxy_auth_enabled"
            if [ "$mixed_proxy_auth_enabled" -eq 1 ]; then
                config_get mixed_proxy_username "$section" "mixed_proxy_username"
                config_get mixed_proxy_password "$section" "mixed_proxy_password"
                signature_add "rule.$section.mixed_proxy_username" "$mixed_proxy_username"
                signature_add "rule.$section.mixed_proxy_password" "$mixed_proxy_password"
            fi
        fi

        signature_add "rule.$section.resolve_real_ip_for_routing" "1"
        ;;
    zapret | zapret2)
        config_get_bool mixed_proxy_enabled "$section" "mixed_proxy_enabled" 0
        signature_add "rule.$section.mixed_proxy_enabled" "$mixed_proxy_enabled"
        if [ "$mixed_proxy_enabled" -eq 1 ]; then
            config_get mixed_proxy_port "$section" "mixed_proxy_port"
            signature_add "rule.$section.mixed_proxy_port" "$mixed_proxy_port"
            config_get_bool mixed_proxy_auth_enabled "$section" "mixed_proxy_auth_enabled" 0
            signature_add "rule.$section.mixed_proxy_auth_enabled" "$mixed_proxy_auth_enabled"
            if [ "$mixed_proxy_auth_enabled" -eq 1 ]; then
                config_get mixed_proxy_username "$section" "mixed_proxy_username"
                config_get mixed_proxy_password "$section" "mixed_proxy_password"
                signature_add "rule.$section.mixed_proxy_username" "$mixed_proxy_username"
                signature_add "rule.$section.mixed_proxy_password" "$mixed_proxy_password"
            fi
        fi
        ;;
    vpn)
        local interface_name domain_resolver_enabled domain_resolver_dns_type domain_resolver_dns_server
        config_get interface_name "$section" "interface"
        config_get_bool domain_resolver_enabled "$section" "domain_resolver_enabled" 0
        signature_add "rule.$section.interface" "$interface_name"
        signature_add "rule.$section.domain_resolver_enabled" "$domain_resolver_enabled"
        if [ "$domain_resolver_enabled" -eq 1 ]; then
            config_get domain_resolver_dns_type "$section" "domain_resolver_dns_type"
            config_get domain_resolver_dns_server "$section" "domain_resolver_dns_server"
            signature_add "rule.$section.domain_resolver_dns_type" "$domain_resolver_dns_type"
            signature_add "rule.$section.domain_resolver_dns_server" "$domain_resolver_dns_server"
        fi

        config_get_bool mixed_proxy_enabled "$section" "mixed_proxy_enabled" 0
        signature_add "rule.$section.mixed_proxy_enabled" "$mixed_proxy_enabled"
        if [ "$mixed_proxy_enabled" -eq 1 ]; then
            config_get mixed_proxy_port "$section" "mixed_proxy_port"
            signature_add "rule.$section.mixed_proxy_port" "$mixed_proxy_port"
            config_get_bool mixed_proxy_auth_enabled "$section" "mixed_proxy_auth_enabled" 0
            signature_add "rule.$section.mixed_proxy_auth_enabled" "$mixed_proxy_auth_enabled"
            if [ "$mixed_proxy_auth_enabled" -eq 1 ]; then
                config_get mixed_proxy_username "$section" "mixed_proxy_username"
                config_get mixed_proxy_password "$section" "mixed_proxy_password"
                signature_add "rule.$section.mixed_proxy_username" "$mixed_proxy_username"
                signature_add "rule.$section.mixed_proxy_password" "$mixed_proxy_password"
            fi
        fi

        config_get_bool resolve_real_ip_for_routing "$section" "resolve_real_ip_for_routing" 0
        signature_add "rule.$section.resolve_real_ip_for_routing" "$resolve_real_ip_for_routing"
        ;;
    esac

    domain="$(get_rule_condition_commas_string "$section" "domain" "domains")"
    domain_suffix="$(get_rule_condition_commas_string "$section" "domain_suffix" "domains")"
    domain_keyword="$(get_rule_condition_commas_string "$section" "domain_keyword" "generic")"
    domain_regex="$(get_rule_condition_commas_string "$section" "domain_regex" "generic")"
    ip_cidr="$(get_rule_condition_commas_string "$section" "ip_cidr" "subnets")"
    source_ip_cidr="$(get_rule_condition_commas_string "$section" "source_ip_cidr" "subnets")"
    ports="$(get_rule_ports_commas_string "$section")"
    config_get fully_routed_ips "$section" "fully_routed_ips"
    config_get community_lists "$section" "community_lists"
    config_get rule_set "$section" "rule_set"
    config_get rule_set_with_subnets "$section" "rule_set_with_subnets"
    config_get domain_ip_lists "$section" "domain_ip_lists"

    signature_add "rule.$section.domain" "$domain"
    signature_add "rule.$section.domain_suffix" "$domain_suffix"
    signature_add "rule.$section.domain_keyword" "$domain_keyword"
    signature_add "rule.$section.domain_regex" "$domain_regex"
    signature_add "rule.$section.ip_cidr" "$ip_cidr"
    signature_add "rule.$section.source_ip_cidr" "$source_ip_cidr"
    signature_add "rule.$section.ports" "$ports"
    signature_add "rule.$section.fully_routed_ips" "$fully_routed_ips"
    signature_add "rule.$section.community_lists" "$community_lists"
    signature_add "rule.$section.rule_set" "$rule_set"
    signature_add "rule.$section.rule_set_with_subnets" "$rule_set_with_subnets"
    signature_add "rule.$section.domain_ip_lists" "$domain_ip_lists"
}

append_sing_box_server_signature() {
    local section="$1"
    local enabled label protocol listen listen_port public_host routing_mode routing_section security \
        inbound_json \
        users tls_server_name tls_alpn tls_certificate_path tls_key_path reality_handshake_server \
        reality_handshake_server_port reality_private_key reality_public_key reality_short_id \
        reality_max_time_difference transport transport_path transport_host transport_service_name transport_hosts transport_xhttp_mode \
        client_fingerprint server_uuid server_username server_password vless_flow vmess_alter_id \
        shadowsocks_method hysteria2_up_mbps hysteria2_down_mbps hysteria2_obfs_type hysteria2_obfs_password \
        mtproto_secret mtproto_faketls mtproto_padding mtproto_concurrency mtproto_domain_fronting_port \
        mtproto_domain_fronting_ip mtproto_domain_fronting_proxy_protocol mtproto_prefer_ip mtproto_auto_update \
        mtproto_allow_fallback_on_unknown_dc mtproto_tolerate_time_skewness mtproto_idle_timeout \
        mtproto_handshake_timeout \
        tailscale_auth_key tailscale_control_url tailscale_hostname \
        tailscale_accept_routes tailscale_advertise_routes \
        tailscale_advertise_exit_node

    config_get_bool enabled "$section" "enabled" 0
    signature_add "server.$section.enabled" "$enabled"
    [ "$enabled" -eq 1 ] || return 0

    config_get label "$section" "label" "$section"
    config_get protocol "$section" "protocol" "vless"
    config_get listen "$section" "listen" "0.0.0.0"
    config_get listen_port "$section" "listen_port"
    config_get public_host "$section" "public_host"
    config_get inbound_json "$section" "inbound_json"
    config_get routing_mode "$section" "routing_mode" "rules"
    config_get routing_section "$section" "routing_section"
    config_get security "$section" "security" "reality"
    config_get users "$section" "server_users"
    config_get tls_server_name "$section" "tls_server_name"
    config_get tls_alpn "$section" "tls_alpn"
    config_get tls_certificate_path "$section" "tls_certificate_path"
    config_get tls_key_path "$section" "tls_key_path"
    config_get reality_handshake_server "$section" "reality_handshake_server"
    config_get reality_handshake_server_port "$section" "reality_handshake_server_port"
    config_get reality_private_key "$section" "reality_private_key"
    config_get reality_public_key "$section" "reality_public_key"
    config_get reality_short_id "$section" "reality_short_id"
    config_get reality_max_time_difference "$section" "reality_max_time_difference"
    config_get transport "$section" "transport" "tcp"
    config_get transport_path "$section" "transport_path"
    config_get transport_host "$section" "transport_host"
    config_get transport_service_name "$section" "transport_service_name"
    config_get transport_hosts "$section" "transport_hosts"
    config_get transport_xhttp_mode "$section" "transport_xhttp_mode"
    config_get client_fingerprint "$section" "client_fingerprint"
    config_get server_uuid "$section" "server_uuid"
    config_get server_username "$section" "server_username"
    config_get server_password "$section" "server_password"
    config_get vless_flow "$section" "vless_flow"
    config_get vmess_alter_id "$section" "vmess_alter_id"
    config_get shadowsocks_method "$section" "shadowsocks_method"
    config_get hysteria2_up_mbps "$section" "hysteria2_up_mbps"
    config_get hysteria2_down_mbps "$section" "hysteria2_down_mbps"
    config_get hysteria2_obfs_type "$section" "hysteria2_obfs_type"
    config_get hysteria2_obfs_password "$section" "hysteria2_obfs_password"
    config_get mtproto_secret "$section" "mtproto_secret"
    config_get mtproto_faketls "$section" "mtproto_faketls"
    config_get mtproto_padding "$section" "mtproto_padding"
    config_get mtproto_concurrency "$section" "mtproto_concurrency"
    config_get mtproto_domain_fronting_port "$section" "mtproto_domain_fronting_port"
    config_get mtproto_domain_fronting_ip "$section" "mtproto_domain_fronting_ip"
    config_get mtproto_domain_fronting_proxy_protocol "$section" "mtproto_domain_fronting_proxy_protocol"
    config_get mtproto_prefer_ip "$section" "mtproto_prefer_ip"
    config_get mtproto_auto_update "$section" "mtproto_auto_update"
    config_get mtproto_allow_fallback_on_unknown_dc "$section" "mtproto_allow_fallback_on_unknown_dc"
    config_get mtproto_tolerate_time_skewness "$section" "mtproto_tolerate_time_skewness"
    config_get mtproto_idle_timeout "$section" "mtproto_idle_timeout"
    config_get mtproto_handshake_timeout "$section" "mtproto_handshake_timeout"
    config_get tailscale_auth_key "$section" "tailscale_auth_key"
    config_get tailscale_control_url "$section" "tailscale_control_url"
    config_get tailscale_hostname "$section" "tailscale_hostname"
    config_get tailscale_accept_routes "$section" "tailscale_accept_routes"
    config_get tailscale_advertise_routes "$section" "tailscale_advertise_routes"
    config_get tailscale_advertise_exit_node "$section" "tailscale_advertise_exit_node"

    signature_add "server.$section.label" "$label"
    signature_add "server.$section.protocol" "$protocol"
    signature_add "server.$section.listen" "$listen"
    signature_add "server.$section.listen_port" "$listen_port"
    signature_add "server.$section.public_host" "$public_host"
    signature_add "server.$section.inbound_json" "$inbound_json"
    signature_add "server.$section.routing_mode" "$routing_mode"
    signature_add "server.$section.routing_section" "$routing_section"
    signature_add "server.$section.security" "$security"
    signature_add "server.$section.server_users" "$users"
    signature_add "server.$section.tls_server_name" "$tls_server_name"
    signature_add "server.$section.tls_alpn" "$tls_alpn"
    signature_add "server.$section.tls_certificate_path" "$tls_certificate_path"
    signature_add "server.$section.tls_key_path" "$tls_key_path"
    signature_add "server.$section.reality_handshake_server" "$reality_handshake_server"
    signature_add "server.$section.reality_handshake_server_port" "$reality_handshake_server_port"
    signature_add "server.$section.reality_private_key" "$reality_private_key"
    signature_add "server.$section.reality_public_key" "$reality_public_key"
    signature_add "server.$section.reality_short_id" "$reality_short_id"
    signature_add "server.$section.reality_max_time_difference" "$reality_max_time_difference"
    signature_add "server.$section.transport" "$transport"
    signature_add "server.$section.transport_path" "$transport_path"
    signature_add "server.$section.transport_host" "$transport_host"
    signature_add "server.$section.transport_service_name" "$transport_service_name"
    signature_add "server.$section.transport_hosts" "$transport_hosts"
    signature_add "server.$section.transport_xhttp_mode" "$transport_xhttp_mode"
    signature_add "server.$section.client_fingerprint" "$client_fingerprint"
    signature_add "server.$section.server_uuid" "$server_uuid"
    signature_add "server.$section.server_username" "$server_username"
    signature_add "server.$section.server_password" "$server_password"
    signature_add "server.$section.vless_flow" "$vless_flow"
    signature_add "server.$section.vmess_alter_id" "$vmess_alter_id"
    signature_add "server.$section.shadowsocks_method" "$shadowsocks_method"
    signature_add "server.$section.hysteria2_up_mbps" "$hysteria2_up_mbps"
    signature_add "server.$section.hysteria2_down_mbps" "$hysteria2_down_mbps"
    signature_add "server.$section.hysteria2_obfs_type" "$hysteria2_obfs_type"
    signature_add "server.$section.hysteria2_obfs_password" "$hysteria2_obfs_password"
    signature_add "server.$section.mtproto_secret" "$mtproto_secret"
    signature_add "server.$section.mtproto_faketls" "$mtproto_faketls"
    signature_add "server.$section.mtproto_padding" "$mtproto_padding"
    signature_add "server.$section.mtproto_concurrency" "$mtproto_concurrency"
    signature_add "server.$section.mtproto_domain_fronting_port" "$mtproto_domain_fronting_port"
    signature_add "server.$section.mtproto_domain_fronting_ip" "$mtproto_domain_fronting_ip"
    signature_add "server.$section.mtproto_domain_fronting_proxy_protocol" "$mtproto_domain_fronting_proxy_protocol"
    signature_add "server.$section.mtproto_prefer_ip" "$mtproto_prefer_ip"
    signature_add "server.$section.mtproto_auto_update" "$mtproto_auto_update"
    signature_add "server.$section.mtproto_allow_fallback_on_unknown_dc" "$mtproto_allow_fallback_on_unknown_dc"
    signature_add "server.$section.mtproto_tolerate_time_skewness" "$mtproto_tolerate_time_skewness"
    signature_add "server.$section.mtproto_idle_timeout" "$mtproto_idle_timeout"
    signature_add "server.$section.mtproto_handshake_timeout" "$mtproto_handshake_timeout"
    signature_add "server.$section.tailscale_auth_key" "$tailscale_auth_key"
    signature_add "server.$section.tailscale_control_url" "$tailscale_control_url"
    signature_add "server.$section.tailscale_hostname" "$tailscale_hostname"
    signature_add "server.$section.tailscale_accept_routes" "$tailscale_accept_routes"
    signature_add "server.$section.tailscale_advertise_routes" "$tailscale_advertise_routes"
    signature_add "server.$section.tailscale_advertise_exit_node" "$tailscale_advertise_exit_node"
}

build_sing_box_signature() {
    local dns_type dns_server bootstrap_dns_server rewrite_ttl output_network_interface disable_quic routing_excluded_ips \
        update_interval cache_path config_path log_level enable_yacd enable_yacd_wan_access yacd_secret_key \
        download_lists_via_proxy download_subscriptions_via_proxy download_components_via_proxy \
        download_lists_via_proxy_section service_listen_address mwan3_active

    signature_begin

    config_get dns_type "settings" "dns_type" "doh"
    config_get dns_server "settings" "dns_server" "1.1.1.1"
    config_get bootstrap_dns_server "settings" "bootstrap_dns_server" "77.88.8.8"
    config_get rewrite_ttl "settings" "dns_rewrite_ttl" "60"
    config_get output_network_interface "settings" "output_network_interface"
    config_get_bool disable_quic "settings" "disable_quic" 0
    config_get routing_excluded_ips "settings" "routing_excluded_ips"
    update_interval="$(get_settings_update_interval)"
    config_get cache_path "settings" "cache_path" "/tmp/sing-box/cache.db"
    config_get config_path "settings" "config_path"
    config_get log_level "settings" "log_level" "warn"
    config_get service_listen_address "settings" "service_listen_address"
    config_get_bool enable_yacd "settings" "enable_yacd" 0
    config_get_bool enable_yacd_wan_access "settings" "enable_yacd_wan_access" 0
    config_get_bool download_lists_via_proxy "settings" "download_lists_via_proxy" 0
    config_get_bool download_subscriptions_via_proxy "settings" "download_subscriptions_via_proxy" 0
    config_get_bool download_components_via_proxy "settings" "download_components_via_proxy" 0
    mwan3_active=0
    mwan3_is_active && mwan3_active=1

    signature_add "settings.dns_type" "$dns_type"
    signature_add "settings.dns_server" "$dns_server"
    signature_add "settings.bootstrap_dns_server" "$bootstrap_dns_server"
    signature_add "settings.dns_rewrite_ttl" "$rewrite_ttl"
    signature_add "settings.output_network_interface" "$output_network_interface"
    signature_add "settings.disable_quic" "$disable_quic"
    signature_add "settings.routing_excluded_ips" "$routing_excluded_ips"
    if has_remote_sing_box_ruleset_sources; then
        signature_add "settings.update_interval" "$update_interval"
    fi
    signature_add "settings.cache_path" "$cache_path"
    signature_add "settings.config_path" "$config_path"
    signature_add "settings.log_level" "$log_level"
    signature_add "settings.service_listen_address" "$service_listen_address"
    signature_add "runtime.mwan3_active" "$mwan3_active"
    signature_add "settings.enable_yacd" "$enable_yacd"
    if [ "$enable_yacd" -eq 1 ]; then
        signature_add "settings.enable_yacd_wan_access" "$enable_yacd_wan_access"
        config_get yacd_secret_key "settings" "yacd_secret_key"
        signature_add "settings.yacd_secret_key" "$yacd_secret_key"
    fi

    signature_add "settings.download_lists_via_proxy" "$download_lists_via_proxy"
    signature_add "settings.download_subscriptions_via_proxy" "$download_subscriptions_via_proxy"
    signature_add "settings.download_components_via_proxy" "$download_components_via_proxy"
    if download_via_proxy_any_enabled; then
        config_get download_lists_via_proxy_section "settings" "download_lists_via_proxy_section"
        signature_add "settings.download_lists_via_proxy_section" "$download_lists_via_proxy_section"
    fi

    config_foreach append_sing_box_rule_signature "section"
    config_foreach append_sing_box_server_signature "server"
    signature_finish
}

append_nft_rule_signature() {
    local section="$1"
    local ip_cidr ports fully_routed_ips community_lists community_subnet_lists remote_subnet_lists rule_set_with_subnets domain_ip_lists

    rule_is_enabled "$section" || return 0

    ip_cidr="$(get_rule_condition_commas_string "$section" "ip_cidr" "subnets")"
    ports="$(get_rule_ports_commas_string "$section")"
    config_get fully_routed_ips "$section" "fully_routed_ips"
    config_get community_lists "$section" "community_lists"
    community_subnet_lists="$(filter_community_subnet_lists "$community_lists")"
    config_get remote_subnet_lists "$section" "remote_subnet_lists"
    config_get rule_set_with_subnets "$section" "rule_set_with_subnets"
    config_get domain_ip_lists "$section" "domain_ip_lists"

    signature_add "rule.$section.ip_cidr" "$ip_cidr"
    signature_add "rule.$section.ports" "$ports"
    signature_add "rule.$section.fully_routed_ips" "$fully_routed_ips"
    signature_add "rule.$section.community_subnet_lists" "$community_subnet_lists"
    signature_add "rule.$section.remote_subnet_lists" "$remote_subnet_lists"
    signature_add "rule.$section.rule_set_with_subnets" "$rule_set_with_subnets"
    signature_add "rule.$section.domain_ip_lists" "$domain_ip_lists"
}

build_nft_signature() {
    local source_network_interfaces exclude_ntp

    signature_begin
    config_get source_network_interfaces "settings" "source_network_interfaces" "br-lan"
    config_get_bool exclude_ntp "settings" "exclude_ntp" 0
    signature_add "settings.source_network_interfaces" "$source_network_interfaces"
    signature_add "settings.exclude_ntp" "$exclude_ntp"
    config_foreach append_nft_rule_signature "section"
    signature_finish
}

append_zapret_queue_signature() {
    local section="$1"

    rule_is_enabled "$section" || return 0
    [ "$(get_rule_action "$section")" = "zapret" ] || return 0

    signature_add "zapret_queue.section" "$section"
}

build_zapret_queue_signature() {
    signature_begin
    config_foreach append_zapret_queue_signature "section"
    signature_finish
}

append_zapret_runtime_signature() {
    local section="$1"
    local domain domain_suffix community_lists rule_set rule_set_with_subnets domain_ip_lists user_domain_list_type items

    rule_is_enabled "$section" || return 0
    [ "$(get_rule_action "$section")" = "zapret" ] || return 0

    domain="$(get_rule_condition_commas_string "$section" "domain" "domains")"
    domain_suffix="$(get_rule_condition_commas_string "$section" "domain_suffix" "domains")"
    config_get community_lists "$section" "community_lists"
    config_get rule_set "$section" "rule_set"
    config_get rule_set_with_subnets "$section" "rule_set_with_subnets"
    config_get domain_ip_lists "$section" "domain_ip_lists"
    config_get user_domain_list_type "$section" "user_domain_list_type" "disabled"

    signature_add "zapret.$section.nfqws_opt" "$(get_rule_nfqws_opt "$section")"
    signature_add "zapret.$section.domain" "$domain"
    signature_add "zapret.$section.domain_suffix" "$domain_suffix"
    signature_add "zapret.$section.community_lists" "$community_lists"
    signature_add "zapret.$section.rule_set" "$rule_set"
    signature_add "zapret.$section.rule_set_with_subnets" "$rule_set_with_subnets"
    signature_add "zapret.$section.domain_ip_lists" "$domain_ip_lists"
    signature_add "zapret.$section.user_domain_list_type" "$user_domain_list_type"
    config_get items "$section" "local_domain_lists"
    signature_add "zapret.$section.local_domain_lists" "$items"
    config_get items "$section" "remote_domain_lists"
    signature_add "zapret.$section.remote_domain_lists" "$items"

    case "$user_domain_list_type" in
    dynamic) config_get items "$section" "user_domains" ;;
    text) config_get items "$section" "user_domains_text" ;;
    *) items="" ;;
    esac
    signature_add "zapret.$section.user_domains" "$items"
}

build_zapret_runtime_signature() {
    signature_begin
    config_foreach append_zapret_runtime_signature "section"
    signature_finish
}

append_zapret2_queue_signature() {
    local section="$1"

    rule_is_enabled "$section" || return 0
    [ "$(get_rule_action "$section")" = "zapret2" ] || return 0

    signature_add "zapret2_queue.section" "$section"
}

build_zapret2_queue_signature() {
    signature_begin
    config_foreach append_zapret2_queue_signature "section"
    signature_finish
}

append_zapret2_runtime_signature() {
    local section="$1"
    local domain domain_suffix community_lists rule_set rule_set_with_subnets domain_ip_lists user_domain_list_type items

    rule_is_enabled "$section" || return 0
    [ "$(get_rule_action "$section")" = "zapret2" ] || return 0

    domain="$(get_rule_condition_commas_string "$section" "domain" "domains")"
    domain_suffix="$(get_rule_condition_commas_string "$section" "domain_suffix" "domains")"
    config_get community_lists "$section" "community_lists"
    config_get rule_set "$section" "rule_set"
    config_get rule_set_with_subnets "$section" "rule_set_with_subnets"
    config_get domain_ip_lists "$section" "domain_ip_lists"
    config_get user_domain_list_type "$section" "user_domain_list_type" "disabled"

    signature_add "zapret2.$section.nfqws2_opt" "$(get_rule_nfqws2_opt "$section")"
    signature_add "zapret2.$section.domain" "$domain"
    signature_add "zapret2.$section.domain_suffix" "$domain_suffix"
    signature_add "zapret2.$section.community_lists" "$community_lists"
    signature_add "zapret2.$section.rule_set" "$rule_set"
    signature_add "zapret2.$section.rule_set_with_subnets" "$rule_set_with_subnets"
    signature_add "zapret2.$section.domain_ip_lists" "$domain_ip_lists"
    signature_add "zapret2.$section.user_domain_list_type" "$user_domain_list_type"
    config_get items "$section" "local_domain_lists"
    signature_add "zapret2.$section.local_domain_lists" "$items"
    config_get items "$section" "remote_domain_lists"
    signature_add "zapret2.$section.remote_domain_lists" "$items"

    case "$user_domain_list_type" in
    dynamic) config_get items "$section" "user_domains" ;;
    text) config_get items "$section" "user_domains_text" ;;
    *) items="" ;;
    esac
    signature_add "zapret2.$section.user_domains" "$items"
}

build_zapret2_runtime_signature() {
    signature_begin
    config_foreach append_zapret2_runtime_signature "section"
    signature_finish
}

append_byedpi_runtime_signature() {
    local section="$1"
    local byedpi_index

    rule_is_enabled "$section" || return 0
    [ "$(get_rule_action "$section")" = "byedpi" ] || return 0

    byedpi_index="$(get_byedpi_rule_index "$section")"
    signature_add "byedpi.$section.index" "$byedpi_index"
    signature_add "byedpi.$section.byedpi_cmd_opts" "$(get_rule_byedpi_cmd_opts "$section")"
}

build_byedpi_runtime_signature() {
    signature_begin
    config_foreach append_byedpi_runtime_signature "section"
    signature_finish
}

append_list_update_signature() {
    local section="$1"
    local ports community_lists community_subnet_lists remote_domain_lists remote_subnet_lists rule_set_with_subnets domain_ip_lists

    rule_is_enabled "$section" || return 0

    ports="$(get_rule_ports_commas_string "$section")"
    config_get community_lists "$section" "community_lists"
    community_subnet_lists="$(filter_community_subnet_lists "$community_lists")"
    config_get remote_domain_lists "$section" "remote_domain_lists"
    config_get remote_subnet_lists "$section" "remote_subnet_lists"
    config_get rule_set_with_subnets "$section" "rule_set_with_subnets"
    config_get domain_ip_lists "$section" "domain_ip_lists"

    signature_add "lists.$section.ports" "$ports"
    signature_add "lists.$section.community_subnet_lists" "$community_subnet_lists"
    signature_add "lists.$section.remote_domain_lists" "$remote_domain_lists"
    signature_add "lists.$section.remote_subnet_lists" "$remote_subnet_lists"
    signature_add "lists.$section.rule_set_with_subnets" "$rule_set_with_subnets"
    signature_add "lists.$section.domain_ip_lists" "$domain_ip_lists"
}

build_list_update_signature() {
    signature_begin
    config_foreach append_list_update_signature "section"
    signature_finish
}

append_subscription_update_cron_signature() {
    local section="$1"
    local subscription_update_interval subscription_urls subscription_update_enabled

    rule_is_subscription_proxy "$section" || return 0

    config_get subscription_urls "$section" "subscription_urls"
    config_get_bool subscription_update_enabled "$section" "subscription_update_enabled" 1
    subscription_update_interval="$(get_subscription_update_interval_for_rule "$section")"

    signature_add "subscription.$section.subscription_urls" "$subscription_urls"
    signature_add "subscription.$section.subscription_update_enabled" "$subscription_update_enabled"
    signature_add "subscription.$section.subscription_update_interval" "$subscription_update_interval"
}

build_cron_signature() {
    local update_interval

    signature_begin
    update_interval="$(get_settings_update_interval)"
    signature_add "settings.update_interval" "$update_interval"
    config_foreach append_list_update_signature "section"
    config_foreach append_subscription_update_cron_signature "section"
    signature_finish
}

list_has_remote_references() {
    local items="$1"
    local item

    for item in $items; do
        case "$item" in
        http://* | https://*)
            return 0
            ;;
        esac
    done

    return 1
}

community_service_has_subnet_list() {
    case "$1" in
    twitter | meta | telegram | cloudflare | hetzner | ovh | digitalocean | cloudfront | discord | roblox)
        return 0
        ;;
    esac

    return 1
}

filter_community_subnet_lists() {
    local items="$1"
    local item result

    for item in $items; do
        community_service_has_subnet_list "$item" || continue

        if [ -z "$result" ]; then
            result="$item"
        else
            result="$result $item"
        fi
    done

    printf '%s\n' "$result"
}

reference_is_remote_sing_box_ruleset() {
    case "$1" in
    http://* | https://*)
        return 0
        ;;
    esac

    return 1
}

list_has_remote_sing_box_rulesets() {
    local items="$1"
    local item

    for item in $items; do
        reference_is_remote_sing_box_ruleset "$item" && return 0
    done

    return 1
}

enabled_rule_has_remote_sing_box_ruleset_source() {
    local section="$1"
    local community_lists rule_set rule_set_with_subnets

    rule_is_enabled "$section" || return 0

    config_get community_lists "$section" "community_lists"
    if [ -n "$community_lists" ]; then
        RELOAD_REMOTE_SING_BOX_RULESET_SOURCES_PRESENT=1
        return 0
    fi

    config_get rule_set "$section" "rule_set"
    if list_has_remote_sing_box_rulesets "$rule_set"; then
        RELOAD_REMOTE_SING_BOX_RULESET_SOURCES_PRESENT=1
        return 0
    fi

    config_get rule_set_with_subnets "$section" "rule_set_with_subnets"
    if list_has_remote_sing_box_rulesets "$rule_set_with_subnets"; then
        RELOAD_REMOTE_SING_BOX_RULESET_SOURCES_PRESENT=1
    fi
}

has_remote_sing_box_ruleset_sources() {
    RELOAD_REMOTE_SING_BOX_RULESET_SOURCES_PRESENT=0
    config_foreach enabled_rule_has_remote_sing_box_ruleset_source "section"
    [ "$RELOAD_REMOTE_SING_BOX_RULESET_SOURCES_PRESENT" -eq 1 ]
}

get_settings_update_interval() {
    local enabled update_interval

    config_get_bool enabled "settings" "list_update_enabled" 1
    if [ "$enabled" -eq 0 ]; then
        printf '\n'
        return 0
    fi

    config_get update_interval "settings" "update_interval" "1d"
    if [ -n "$update_interval" ]; then
        printf '%s\n' "$update_interval"
    else
        printf '1d\n'
    fi
}

get_subscription_update_interval_for_rule() {
    local section="$1"
    local enabled value

    rule_has_subscription_urls "$section" || {
        printf '\n'
        return 0
    }

    config_get_bool enabled "$section" "subscription_update_enabled" 1
    if [ "$enabled" -eq 0 ]; then
        printf '\n'
        return 0
    fi

    config_get value "$section" "subscription_update_interval"
    if [ -n "$value" ]; then
        printf '%s\n' "$value"
    else
        printf '1h\n'
    fi
}

get_urltest_check_interval_for_rule() {
    local section="$1"
    local enabled value

    config_get_bool enabled "$section" "urltest_enabled" 0
    if [ "$enabled" -eq 0 ]; then
        printf '\n'
        return 0
    fi

    config_get value "$section" "urltest_check_interval"
    if [ -n "$value" ]; then
        printf '%s\n' "$value"
    else
        printf '3m\n'
    fi
}

get_remote_ruleset_update_interval() {
    local update_interval

    update_interval="$(get_settings_update_interval)"
    if [ -n "$update_interval" ]; then
        printf '%s\n' "$update_interval"
    else
        printf '%s\n' "$SING_BOX_DISABLED_UPDATE_INTERVAL"
    fi

}

append_urltest_enabled_section() {
    local section="$1"
    local action enabled

    rule_is_enabled "$section" || return 0

    action="$(get_rule_action "$section")"
    [ "$action" = "proxy" ] || return 0

    config_get_bool enabled "$section" "urltest_enabled" 0
    [ "$enabled" -eq 1 ] || return 0

    RELOAD_STATE_URLTEST_ENABLED_SECTIONS="${RELOAD_STATE_URLTEST_ENABLED_SECTIONS}${RELOAD_STATE_URLTEST_ENABLED_SECTIONS:+ }$section"
}

build_urltest_enabled_sections() {
    RELOAD_STATE_URLTEST_ENABLED_SECTIONS=""
    config_foreach append_urltest_enabled_section "section"
    printf '%s\n' "$RELOAD_STATE_URLTEST_ENABLED_SECTIONS"
}

build_new_urltest_enabled_sections() {
    local previous_sections="$1"
    local current_sections="$2"
    local section new_sections

    new_sections=""
    for section in $current_sections; do
        list_has_item "$previous_sections" "$section" && continue
        new_sections="${new_sections}${new_sections:+ }$section"
    done

    printf '%s\n' "$new_sections"
}

capture_reload_state() {
    config_load "$PODKOP_CONFIG_NAME"
    RELOAD_STATE_SERVICE_TRIGGER_SIGNATURE="$(build_service_trigger_signature)"
    RELOAD_STATE_DNSMASQ_SIGNATURE="$(build_dnsmasq_signature)"
    RELOAD_STATE_SING_BOX_SIGNATURE="$(build_sing_box_signature)"
    RELOAD_STATE_NFT_SIGNATURE="$(build_nft_signature)"
    RELOAD_STATE_ZAPRET_QUEUE_SIGNATURE="$(build_zapret_queue_signature)"
    RELOAD_STATE_ZAPRET_RUNTIME_SIGNATURE="$(build_zapret_runtime_signature)"
    RELOAD_STATE_ZAPRET2_QUEUE_SIGNATURE="$(build_zapret2_queue_signature)"
    RELOAD_STATE_ZAPRET2_RUNTIME_SIGNATURE="$(build_zapret2_runtime_signature)"
    RELOAD_STATE_BYEDPI_RUNTIME_SIGNATURE="$(build_byedpi_runtime_signature)"
    RELOAD_STATE_LIST_SIGNATURE="$(build_list_update_signature)"
    RELOAD_STATE_CRON_SIGNATURE="$(build_cron_signature)"
    RELOAD_STATE_URLTEST_ENABLED_SECTIONS="$(build_urltest_enabled_sections)"
    config_get_bool RELOAD_STATE_DONT_TOUCH_DHCP "settings" "dont_touch_dhcp" 0
}

write_reload_state() {
    local status

    mkdir -p "$PODKOP_RUNTIME_STATE_DIR"
    runtime_state_ucode write-reload-state \
        "$PODKOP_RELOAD_STATE_FILE" \
        "$PODKOP_RELOAD_STATE_FORMAT" \
        "$RELOAD_STATE_SERVICE_TRIGGER_SIGNATURE" \
        "$RELOAD_STATE_DNSMASQ_SIGNATURE" \
        "$RELOAD_STATE_SING_BOX_SIGNATURE" \
        "$RELOAD_STATE_NFT_SIGNATURE" \
        "$RELOAD_STATE_ZAPRET_QUEUE_SIGNATURE" \
        "$RELOAD_STATE_ZAPRET_RUNTIME_SIGNATURE" \
        "$RELOAD_STATE_ZAPRET2_QUEUE_SIGNATURE" \
        "$RELOAD_STATE_ZAPRET2_RUNTIME_SIGNATURE" \
        "$RELOAD_STATE_BYEDPI_RUNTIME_SIGNATURE" \
        "$RELOAD_STATE_LIST_SIGNATURE" \
        "$RELOAD_STATE_CRON_SIGNATURE" \
        "$RELOAD_STATE_URLTEST_ENABLED_SECTIONS" \
        "$RELOAD_STATE_DONT_TOUCH_DHCP"
    status="$?"
    if [ -n "${PODKOP_RULE_CONDITION_CACHE_DIR:-}" ]; then
        rm -rf "$PODKOP_RULE_CONDITION_CACHE_DIR" 2>/dev/null || true
        PODKOP_RULE_CONDITION_CACHE_DIR=""
    fi
    rm -rf /tmp/podkop-plus-rule-cache.* 2>/dev/null || true
    return "$status"
}

enabled_rule_has_list_sources() {
    local section="$1"
    local community_lists community_subnet_lists remote_domain_lists remote_subnet_lists rule_set_with_subnets domain_ip_lists

    rule_is_enabled "$section" || return 0
    config_get community_lists "$section" "community_lists"
    community_subnet_lists="$(filter_community_subnet_lists "$community_lists")"
    config_get remote_domain_lists "$section" "remote_domain_lists"
    config_get remote_subnet_lists "$section" "remote_subnet_lists"
    config_get rule_set_with_subnets "$section" "rule_set_with_subnets"
    config_get domain_ip_lists "$section" "domain_ip_lists"

    if [ -n "$community_subnet_lists" ] ||
        [ -n "$remote_domain_lists" ] ||
        [ -n "$remote_subnet_lists" ] ||
        [ -n "$rule_set_with_subnets" ] ||
        list_has_remote_references "$domain_ip_lists"; then
        RELOAD_LIST_SOURCES_PRESENT=1
    fi
}

has_list_update_sources() {
    RELOAD_LIST_SOURCES_PRESENT=0
    config_foreach enabled_rule_has_list_sources "section"
    [ "$RELOAD_LIST_SOURCES_PRESENT" -eq 1 ]
}

enabled_rule_has_subscription_update_source() {
    local section="$1"
    local subscription_update_interval

    rule_is_subscription_proxy "$section" || return 0

    subscription_update_interval="$(get_subscription_update_interval_for_rule "$section")"
    [ -n "$subscription_update_interval" ] || return 0

    RELOAD_SUBSCRIPTION_SOURCES_PRESENT=1
}

has_subscription_update_sources() {
    RELOAD_SUBSCRIPTION_SOURCES_PRESENT=0
    config_foreach enabled_rule_has_subscription_update_source "section"
    [ "$RELOAD_SUBSCRIPTION_SOURCES_PRESENT" -eq 1 ]
}

enabled_rule_has_nft_list_sources() {
    local section="$1"
    local community_lists community_subnet_lists remote_subnet_lists rule_set_with_subnets domain_ip_lists

    rule_is_enabled "$section" || return 0
    config_get community_lists "$section" "community_lists"
    community_subnet_lists="$(filter_community_subnet_lists "$community_lists")"
    config_get remote_subnet_lists "$section" "remote_subnet_lists"
    config_get rule_set_with_subnets "$section" "rule_set_with_subnets"
    config_get domain_ip_lists "$section" "domain_ip_lists"

    if [ -n "$community_subnet_lists" ] ||
        [ -n "$remote_subnet_lists" ] ||
        [ -n "$rule_set_with_subnets" ] ||
        list_has_remote_references "$domain_ip_lists"; then
        RELOAD_NFT_LIST_SOURCES_PRESENT=1
    fi
}

has_nft_list_update_sources() {
    RELOAD_NFT_LIST_SOURCES_PRESENT=0
    config_foreach enabled_rule_has_nft_list_sources "section"
    [ "$RELOAD_NFT_LIST_SOURCES_PRESENT" -eq 1 ]
}

populate_nft_runtime_sets_from_rule() {
    local section="$1"
    local ip_values

    rule_is_enabled "$section" || return 0
    subscription_section_is_deferred "$section" && return 0

    ip_values="$(get_rule_condition_commas_string "$section" "ip_cidr" "subnets")"
    add_section_ip_cidr_to_nft_sets "$section" "$ip_values"
    add_section_ports_to_nft_set_if_needed "$section"
    populate_fully_routed_ips_nft_from_rule "$section"
}

populate_fully_routed_ips_nft_from_rule() {
    local section="$1"

    rule_is_enabled "$section" || return 0
    subscription_section_is_deferred "$section" && return 0

    config_list_foreach "$section" "fully_routed_ips" populate_fully_routed_ip_nft
}

populate_fully_routed_ip_nft() {
    local source_ip="$1"

    [ "$PODKOP_NFT_POPULATE_ENABLED" = "1" ] || return 0

    nft_list_all_traffic_from_ip "$source_ip"
}

populate_nft_runtime_sets() {
    config_foreach populate_nft_runtime_sets_from_rule "section"
}

rebuild_nft_runtime() {
    log "Rebuilding nft runtime"

    if nft list table inet "$NFT_TABLE_NAME" > /dev/null 2>&1; then
        nft delete table inet "$NFT_TABLE_NAME"
    fi

    route_table_rule_mark
    create_nft_rules
}

refresh_list_update_cron() {
    local cron_job update_interval

    remove_cron_job

    if has_list_update_sources; then
        update_interval="$(get_settings_update_interval)"
        if [ -z "$update_interval" ]; then
            log "Remote list auto-update is disabled"
        else
            cron_job="$(build_list_update_cron_job)" || return 1
            crontab -l 2> /dev/null | {
                cat
                echo "$cron_job"
            } | crontab -
            log "The cron job has been created: $cron_job"
        fi
    fi

    if has_subscription_update_sources; then
        cron_job="$(build_subscription_update_cron_job)" || return 1
        crontab -l 2> /dev/null | {
            cat
            echo "$cron_job"
        } | crontab -
        log "The subscription cron job has been created: $cron_job"
    fi
}

reload_sing_box_runtime() {
    log "Reloading sing-box runtime"

    if ! /etc/init.d/sing-box reload; then
        log "Failed to reload sing-box. Aborted." "fatal"
        exit 1
    fi
}

schedule_urltest_selector_switch() {
    local selector_tag="$1"
    local urltest_tag="$2"

    PODKOP_URLTEST_SELECTOR_SWITCHES="${PODKOP_URLTEST_SELECTOR_SWITCHES}${selector_tag} ${urltest_tag}
"
}

apply_urltest_selector_switch() {
    local selector_tag="$1"
    local urltest_tag="$2"
    local attempt response

    attempt=1
    while [ "$attempt" -le 10 ]; do
        response="$(clash_api set_group_proxy "$selector_tag" "$urltest_tag" 2>/dev/null || true)"
        if printf '%s' "$response" | runtime_state_ucode response-success >/dev/null 2>&1; then
            log "Selected URLTest outbound '$urltest_tag' for selector '$selector_tag'"
            return 0
        fi

        sleep 1
        attempt=$((attempt + 1))
    done

    log "Failed to select URLTest outbound '$urltest_tag' for selector '$selector_tag'" "warn"
}

apply_pending_urltest_selector_switches() {
    local selector_tag urltest_tag

    [ -n "$PODKOP_URLTEST_SELECTOR_SWITCHES" ] || return 0

    printf '%s' "$PODKOP_URLTEST_SELECTOR_SWITCHES" | while read -r selector_tag urltest_tag; do
        [ -n "$selector_tag" ] || continue
        [ -n "$urltest_tag" ] || continue
        apply_urltest_selector_switch "$selector_tag" "$urltest_tag"
    done
}
