# shellcheck shell=ash

config_validation_ucode() {
    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/config_validation.uc" "$@"
}

_validate_download_lists_via_proxy_section_handler() {
    local section="$1"
    local action

    [ "$section" = "$PODKOP_VALIDATE_DOWNLOAD_SECTION" ] || return 0

    PODKOP_VALIDATE_DOWNLOAD_SECTION_FOUND=1
    if ! rule_is_enabled "$section"; then
        return 0
    fi

    PODKOP_VALIDATE_DOWNLOAD_SECTION_ENABLED=1
    action="$(get_rule_action "$section")"
    if [ "$action" = "proxy" ] || [ "$action" = "vpn" ] || [ "$action" = "outbound" ]; then
        PODKOP_VALIDATE_DOWNLOAD_SECTION_OUTBOUND=1
    fi
}

validate_download_lists_via_proxy_section() {
    local download_lists_via_proxy download_lists_via_proxy_section

    config_get_bool download_lists_via_proxy "settings" "download_lists_via_proxy" 0
    [ "$download_lists_via_proxy" -eq 1 ] || return 0

    config_get download_lists_via_proxy_section "settings" "download_lists_via_proxy_section"
    if [ -z "$download_lists_via_proxy_section" ]; then
        log "Download lists/updates/subscriptions via Proxy/VPN is enabled, but no proxy/VPN/JSON outbound rule is selected. Aborted." "fatal"
        exit 1
    fi

    PODKOP_VALIDATE_DOWNLOAD_SECTION="$download_lists_via_proxy_section"
    PODKOP_VALIDATE_DOWNLOAD_SECTION_FOUND=0
    PODKOP_VALIDATE_DOWNLOAD_SECTION_ENABLED=0
    PODKOP_VALIDATE_DOWNLOAD_SECTION_OUTBOUND=0
    config_foreach _validate_download_lists_via_proxy_section_handler "section"

    if [ "$PODKOP_VALIDATE_DOWNLOAD_SECTION_FOUND" -eq 0 ]; then
        log "Download lists/updates/subscriptions via Proxy/VPN references missing rule '$download_lists_via_proxy_section'. Select an enabled proxy/VPN/JSON outbound rule or disable the option. Aborted." "fatal"
        exit 1
    fi

    if [ "$PODKOP_VALIDATE_DOWNLOAD_SECTION_ENABLED" -eq 0 ]; then
        log "Download lists/updates/subscriptions via Proxy/VPN references disabled rule '$download_lists_via_proxy_section'. Select an enabled proxy/VPN/JSON outbound rule or disable the option. Aborted." "fatal"
        exit 1
    fi

    if [ "$PODKOP_VALIDATE_DOWNLOAD_SECTION_OUTBOUND" -eq 0 ]; then
        log "Download lists/updates/subscriptions via Proxy/VPN references rule '$download_lists_via_proxy_section', but it is not a proxy/VPN/JSON outbound rule. Select an enabled proxy/VPN/JSON outbound rule or disable the option. Aborted." "fatal"
        exit 1
    fi
}

validate_list_update_settings() {
    local enabled update_interval

    config_get_bool enabled "settings" "list_update_enabled" 1
    [ "$enabled" -eq 1 ] || return 0

    config_get update_interval "settings" "update_interval" "1d"
    [ -n "$update_interval" ] || update_interval="1d"
    validate_required_sing_box_duration_option "$update_interval" "settings.update_interval"
}

validate_runtime_settings() {
    validate_list_update_settings
    validate_download_lists_via_proxy_section
}

commit_podkop_config() {
    # Podkop updates a small runtime flag in its own UCI config while starting
    # and stopping. Mark these commits so the init trigger can ignore the
    # self-induced config.change event instead of scheduling another reload.
    date +%s > "$PODKOP_INTERNAL_CONFIG_TRIGGER_GUARD" 2>/dev/null || echo 0 > "$PODKOP_INTERNAL_CONFIG_TRIGGER_GUARD"
    uci commit "$PODKOP_CONFIG_NAME" && config_load "$PODKOP_CONFIG_NAME"
}

podkop_uci_option_exists() {
    local section="$1"
    local option="$2"

    uci -q get "$PODKOP_CONFIG_NAME.$section.$option" >/dev/null 2>&1
}

podkop_uci_set_option() {
    local section="$1"
    local option="$2"
    local value="$3"
    local current

    current="$(uci -q get "$PODKOP_CONFIG_NAME.$section.$option" 2>/dev/null)"
    [ "$current" = "$value" ] && return 0

    uci set "$PODKOP_CONFIG_NAME.$section.$option=$value"
    podkop_config_migration_changed=1
}

podkop_uci_set_option_if_missing() {
    local section="$1"
    local option="$2"
    local value="$3"

    podkop_uci_option_exists "$section" "$option" && return 0
    podkop_uci_set_option "$section" "$option" "$value"
}

podkop_uci_migrate_urltest_filter_mode() {
    local section="$1"

    podkop_uci_option_exists "$section" "urltest_filter_mode" && return 0

    if podkop_uci_option_exists "$section" "urltest_exclude_countries" ||
        podkop_uci_option_exists "$section" "urltest_include_countries" ||
        podkop_uci_option_exists "$section" "urltest_exclude_outbounds" ||
        podkop_uci_option_exists "$section" "urltest_exclude_regex"; then
        podkop_uci_set_option "$section" "urltest_filter_mode" "exclude"
    fi
}

urltest_filter_mode_filters_enabled() {
    case "$1" in
    exclude | include | mixed)
        return 0
        ;;
    esac

    return 1
}

normalize_detect_server_country_method() {
    local value="${1:-}"

    case "$value" in
    "$SERVER_COUNTRY_METHOD_COUNTRY_IS")
        printf '%s\n' "$SERVER_COUNTRY_METHOD_COUNTRY_IS"
        ;;
    0 | 1 | "" | "$SERVER_COUNTRY_METHOD_FLAG_EMOJI")
        printf '%s\n' "$SERVER_COUNTRY_METHOD_FLAG_EMOJI"
        ;;
    *)
        printf '%s\n' "$SERVER_COUNTRY_METHOD_FLAG_EMOJI"
        ;;
    esac
}

podkop_uci_migrate_detect_server_country() {
    local section="$1"
    local value urltest_enabled urltest_filter_mode

    podkop_uci_option_exists "$section" "detect_server_country" || return 0

    config_get value "$section" "detect_server_country"
    config_get_bool urltest_enabled "$section" "urltest_enabled" 0
    config_get urltest_filter_mode "$section" "urltest_filter_mode" "disabled"

    case "$value" in
    0 | 1)
        if [ "$urltest_enabled" -eq 1 ] && urltest_filter_mode_filters_enabled "$urltest_filter_mode"; then
            podkop_uci_set_option "$section" "detect_server_country" "$SERVER_COUNTRY_METHOD_FLAG_EMOJI"
        else
            podkop_uci_delete_option "$section" "detect_server_country"
        fi
        ;;
    esac
}

podkop_uci_delete_option() {
    local section="$1"
    local option="$2"

    podkop_uci_option_exists "$section" "$option" || return 0

    uci -q delete "$PODKOP_CONFIG_NAME.$section.$option" || true
    podkop_config_migration_changed=1
}

podkop_uci_list_contains_handler() {
    local item="$1"
    local expected="$2"

    [ "$item" = "$expected" ] && UCI_LIST_CONTAINS=1
}

podkop_uci_add_list_unique() {
    local section="$1"
    local option="$2"
    local value="$3"
    local quoted_value list_key

    [ -n "$value" ] || return 0
    list_key="$section.$option=$value"

    UCI_LIST_CONTAINS=0
    config_list_foreach "$section" "$option" podkop_uci_list_contains_handler "$value"
    [ "$UCI_LIST_CONTAINS" -eq 1 ] && return 0
    case "
$podkop_config_migration_added_lists
" in
    *"
$list_key
"*)
        return 0
        ;;
    esac

    quoted_value="$(config_validation_ucode shell-single-quote "$value")"
    printf 'add_list %s.%s.%s=%s\n' "$PODKOP_CONFIG_NAME" "$section" "$option" "$quoted_value" | uci -q batch
    podkop_config_migration_added_lists="${podkop_config_migration_added_lists}
${list_key}"
    podkop_config_migration_changed=1
}

migrate_0_7_17_8_urltest_link() {
    local link="$1"
    local section="$2"

    podkop_uci_add_list_unique "$section" "selector_proxy_links" "$link"
}

migrate_0_7_17_8_proxy_string() {
    local section="$1"
    local proxy_string link migrated

    config_get proxy_string "$section" "proxy_string"
    [ -n "$proxy_string" ] || return 0

    migrated=0
    while IFS= read -r link || [ -n "$link" ]; do
        link="$(printf '%s' "$link" | trim_string)"
        [ -n "$link" ] || continue
        case "$link" in
        '//'*) continue ;;
        esac

        podkop_uci_add_list_unique "$section" "selector_proxy_links" "$link"
        migrated=1
    done <<EOF
$proxy_string
EOF

    [ "$migrated" -eq 1 ] && podkop_uci_delete_option "$section" "proxy_string"
}

migrate_0_7_17_8_delete_subscription_cache() {
    local section="$1"

    case "$section" in
    "" | */* | *..*) return 0 ;;
    esac

    rm -f \
        "$(get_subscription_json_path "$section")" \
        "$(get_subscription_url_cache_path "$section")" \
        "$(get_subscription_user_agent_cache_path "$section")" \
        "$(get_subscription_metadata_path "$section")" \
        "$(get_subscription_links_path "$section")" \
        "$(get_outbound_metadata_path "$section")" \
        "$(get_section_cache_path "$section")" \
        "$TMP_SUBSCRIPTION_FOLDER/${section}-subscription-"*.json \
        "$TMP_SUBSCRIPTION_FOLDER/${section}-subscription-"*.url \
        "$TMP_SUBSCRIPTION_FOLDER/${section}-subscription-"*.user_agent
}

migrate_0_7_17_8_subscription_url() {
    local section="$1"
    local subscription_url subscription_user_agent subscription_entry

    config_get subscription_url "$section" "subscription_url"
    [ -n "$subscription_url" ] || return 0

    config_get subscription_user_agent "$section" "subscription_user_agent" ""
    if [ -n "$subscription_user_agent" ]; then
        subscription_entry="$subscription_url | $subscription_user_agent"
    else
        subscription_entry="$subscription_url"
    fi

    podkop_uci_add_list_unique "$section" "subscription_urls" "$subscription_entry"
    podkop_uci_delete_option "$section" "subscription_url"
    podkop_uci_delete_option "$section" "subscription_user_agent"
    migrate_0_7_17_8_delete_subscription_cache "$section"
}

migrate_0_7_17_8_interval_flags() {
    local section="$1"
    local proxy_config_type="$2"
    local urltest_interval_disabled subscription_update_interval_disabled

    if [ "$proxy_config_type" = "urltest" ] || [ "$proxy_config_type" = "subscription" ]; then
        config_get urltest_interval_disabled "$section" "urltest_check_interval_disabled"
        if [ "$urltest_interval_disabled" = "1" ]; then
            podkop_uci_set_option "$section" "urltest_enabled" "0"
        else
            podkop_uci_set_option_if_missing "$section" "urltest_enabled" "1"
        fi
    elif [ "$proxy_config_type" = "url" ] || [ "$proxy_config_type" = "selector" ]; then
        podkop_uci_set_option_if_missing "$section" "urltest_enabled" "0"
    fi

    if [ "$proxy_config_type" = "subscription" ]; then
        config_get subscription_update_interval_disabled "$section" "subscription_update_interval_disabled"
        if [ "$subscription_update_interval_disabled" = "1" ]; then
            podkop_uci_set_option "$section" "subscription_update_enabled" "0"
        else
            podkop_uci_set_option_if_missing "$section" "subscription_update_enabled" "1"
        fi
    fi

    podkop_uci_delete_option "$section" "urltest_check_interval_disabled"
    podkop_uci_delete_option "$section" "subscription_update_interval_disabled"
}

migrate_0_7_17_8_proxy_rule() {
    local section="$1"
    local proxy_config_type="$2"

    case "$proxy_config_type" in
    url)
        migrate_0_7_17_8_proxy_string "$section"
        ;;
    urltest)
        config_list_foreach "$section" "urltest_proxy_links" migrate_0_7_17_8_urltest_link "$section"
        podkop_uci_delete_option "$section" "urltest_proxy_links"
        ;;
    subscription)
        migrate_0_7_17_8_subscription_url "$section"
        migrate_0_7_17_8_delete_subscription_cache "$section"
        ;;
    esac

    migrate_0_7_17_8_interval_flags "$section" "$proxy_config_type"
    podkop_uci_delete_option "$section" "proxy_config_type"
}

migrate_0_7_17_8_rule_action() {
    local section="$1"
    local action proxy_config_type connection_type interface outbound_json selector_proxy_links subscription_urls

    config_get action "$section" "action"
    config_get proxy_config_type "$section" "proxy_config_type"
    config_get connection_type "$section" "connection_type"
    config_get interface "$section" "interface"
    config_get outbound_json "$section" "outbound_json"
    config_get selector_proxy_links "$section" "selector_proxy_links"
    config_get subscription_urls "$section" "subscription_urls"

    if [ "$action" = "proxy" ]; then
        case "$proxy_config_type" in
        interface)
            echo "vpn"
            return 0
            ;;
        outbound)
            echo "outbound"
            return 0
            ;;
        esac
    fi

    if [ -n "$action" ]; then
        echo "$action"
        return 0
    fi

    case "$connection_type" in
    proxy)
        case "$proxy_config_type" in
        interface)
            echo "vpn"
            ;;
        outbound)
            echo "outbound"
            ;;
        *)
            echo "proxy"
            ;;
        esac
        return 0
        ;;
    vpn)
        echo "vpn"
        return 0
        ;;
    block)
        echo "block"
        return 0
        ;;
    exclusion)
        echo "direct"
        return 0
        ;;
    esac

    case "$proxy_config_type" in
    interface)
        echo "vpn"
        ;;
    outbound)
        echo "outbound"
        ;;
    url | selector | urltest | subscription)
        echo "proxy"
        ;;
    *)
        if [ -n "$outbound_json" ]; then
            echo "outbound"
        elif [ -n "$interface" ]; then
            echo "vpn"
        elif [ -n "$selector_proxy_links" ] || [ -n "$subscription_urls" ]; then
            echo "proxy"
        else
            echo ""
        fi
        ;;
    esac
}

migrate_0_7_17_8_byedpi_cmd_opts() {
    local section="$1"
    local cmd_opts byedpi_cmd_opts

    config_get cmd_opts "$section" "cmd_opts"
    [ -n "$cmd_opts" ] || return 0

    config_get byedpi_cmd_opts "$section" "byedpi_cmd_opts"
    [ -z "$byedpi_cmd_opts" ] && podkop_uci_set_option "$section" "byedpi_cmd_opts" "$cmd_opts"
    podkop_uci_delete_option "$section" "cmd_opts"
}

migrate_0_7_17_8_zapret_nfqws_default() {
    local section="$1"
    local action nfqws_opt

    action="$(get_rule_action "$section")"
    [ "$action" = "zapret" ] || return 0

    config_get nfqws_opt "$section" "nfqws_opt"
    [ -n "$nfqws_opt" ] || return 0
    [ "$nfqws_opt" = "$ZAPRET_LEGACY_DEFAULT_NFQWS_OPT" ] || return 0

    podkop_uci_set_option "$section" "nfqws_opt" "$ZAPRET_DEFAULT_NFQWS_OPT"
}

migrate_0_7_17_8_rule() {
    local section="$1"
    local converted_from_rule="${2:-0}"
    local action proxy_config_type subscription_urls

    action="$(migrate_0_7_17_8_rule_action "$section")"
    config_get proxy_config_type "$section" "proxy_config_type"
    config_get subscription_urls "$section" "subscription_urls"

    [ -n "$action" ] && podkop_uci_set_option "$section" "action" "$action"

    podkop_uci_delete_option "$section" "connection_type"
    podkop_uci_delete_option "$section" "subscription_group_by_countries"
    podkop_uci_delete_option "$section" "group_by_countries"
    podkop_uci_delete_option "$section" "subscription_detect_server_countries"

    case "$action" in
    proxy)
        podkop_uci_migrate_urltest_filter_mode "$section"
        podkop_uci_migrate_detect_server_country "$section"
        migrate_0_7_17_8_proxy_rule "$section" "$proxy_config_type"
        if [ "$converted_from_rule" -eq 1 ] && [ -n "$subscription_urls" ]; then
            migrate_0_7_17_8_delete_subscription_cache "$section"
        fi
        ;;
    vpn | outbound | block | direct | zapret | zapret2 | byedpi)
        podkop_uci_delete_option "$section" "proxy_config_type"
        podkop_uci_delete_option "$section" "proxy_string"
        podkop_uci_delete_option "$section" "urltest_proxy_links"
        podkop_uci_delete_option "$section" "subscription_url"
        podkop_uci_delete_option "$section" "subscription_user_agent"
        podkop_uci_delete_option "$section" "urltest_check_interval_disabled"
        podkop_uci_delete_option "$section" "subscription_update_interval_disabled"
        ;;
    esac

    migrate_0_7_17_8_byedpi_cmd_opts "$section"
    migrate_0_7_17_8_zapret_nfqws_default "$section"
}

migrate_0_7_17_8_rule_section() {
    local section="$1"

    uci set "$PODKOP_CONFIG_NAME.$section=section"
    podkop_config_migration_changed=1
    migrate_0_7_17_8_rule "$section" 1
}

migrate_list_update_enabled() {
    local list_update_enabled update_interval

    if podkop_uci_option_exists "settings" "list_update_enabled"; then
        config_get_bool list_update_enabled "settings" "list_update_enabled" 1
        if [ "$list_update_enabled" -eq 1 ]; then
            config_get update_interval "settings" "update_interval"
            [ -n "$update_interval" ] || podkop_uci_set_option "settings" "update_interval" "1d"
        fi
        return 0
    fi

    config_get update_interval "settings" "update_interval"
    if [ -n "$update_interval" ]; then
        podkop_uci_set_option "settings" "list_update_enabled" "1"
    else
        podkop_uci_set_option "settings" "list_update_enabled" "0"
        podkop_uci_set_option "settings" "update_interval" "1d"
    fi
}

validate_extended_server_features_handler() {
    local section="$1"
    local protocol transport

    server_is_enabled "$section" || return 0

    config_get protocol "$section" "protocol" "vless"
    case "$protocol" in
    mtproto)
        log "Server '$section' uses MTProto proxy, but sing-box-extended is not installed. Install sing-box-extended or disable this server. Aborted." "fatal"
        exit 1
        ;;
    tailscale)
        if ! sing_box_supports_tailscale; then
            log "Server '$section' uses Tailscale, but the installed sing-box binary was built without Tailscale support. Install full sing-box or sing-box-extended, or disable this server. Aborted." "fatal"
            exit 1
        fi
        ;;
    esac

    config_get transport "$section" "transport" "tcp"
    case "$transport" in
    xhttp)
        log "Server '$section' uses XHTTP transport, but sing-box-extended is not installed. Install sing-box-extended or change the transport. Aborted." "fatal"
        exit 1
        ;;
    esac
}

validate_extended_server_features() {
    local sing_box_version="$1"

    is_sing_box_extended "$sing_box_version" && return 0

    config_foreach validate_extended_server_features_handler "server"
}

check_requirements() {
    log "Check Requirements"

    local sing_box_version coreutils_base64_version
    sing_box_version="$(get_sing_box_version)"
    coreutils_base64_version="$(base64 --version 2>/dev/null | config_validation_ucode stdin-first-line-field 4)"

    if [ -z "$sing_box_version" ]; then
        log "Package 'sing-box' is not installed. Aborted." "error"
        exit 1
    else
        if ! is_min_package_version "$sing_box_version" "$SB_REQUIRED_VERSION"; then
            log "Package 'sing-box' version ($sing_box_version) is lower than the required minimum ($SB_REQUIRED_VERSION). Update sing-box: opkg update && opkg remove sing-box && opkg install sing-box. Aborted." "error"
            exit 1
        fi

        if ! service_exists "sing-box"; then
            log "Service 'sing-box' is missing. Please install the official package to ensure the service is available. Aborted." "error"
            exit 1
        fi

        validate_extended_server_features "$sing_box_version"
    fi

    if [ -z "$coreutils_base64_version" ]; then
        log "Package 'coreutils-base64' is not installed. Aborted." "error"
        exit 1
    elif ! is_min_package_version "$coreutils_base64_version" "$COREUTILS_BASE64_REQUIRED_VERSION"; then
        log "Package 'coreutils-base64' version ($coreutils_base64_version) is lower than the required minimum ($COREUTILS_BASE64_REQUIRED_VERSION). This may cause issues when decoding base64 streams with missing padding, as automatic padding support is not available in older versions." "warn"
    fi

    if config_validation_ucode dhcp-has-https-dns-proxy-options /etc/config/dhcp >/dev/null 2>&1; then
        log "Detected https-dns-proxy in DHCP config. Edit /etc/config/dhcp" "error"
    fi

    if has_outbound_section; then
        log "Outbound proxy section found" "debug"
    else
        log "No proxy outbound sections found. Podkop Plus will use direct and/or provider-only routing." "warn"
    fi

    check_zapret_requirements
    check_zapret2_requirements
    check_byedpi_requirements
}

_check_outbound_node() {
    local section="$1"
    local action interface outbound_json selector_proxy_links subscription_urls

    rule_is_enabled "$section" || return 0

    action="$(get_rule_action "$section")"
    config_get selector_proxy_links "$section" "selector_proxy_links"
    config_get subscription_urls "$section" "subscription_urls"
    config_get outbound_json "$section" "outbound_json"
    config_get interface "$section" "interface"

    if [ "$action" = "byedpi" ] && is_byedpi_installed; then
        section_exists=0
        return 0
    fi

    if [ "$action" = "zapret" ] && is_zapret_installed; then
        section_exists=0
        return 0
    fi

    if [ "$action" = "zapret2" ] && is_zapret2_installed; then
        section_exists=0
        return 0
    fi

    if [ -n "$selector_proxy_links" ] || [ -n "$subscription_urls" ] ||
        [ -n "$outbound_json" ] || [ -n "$interface" ]; then
        section_exists=0
    fi
}

has_outbound_section() {
    local section_exists=1

    config_foreach _check_outbound_node "section"

    return $section_exists
}

mwan3_has_enabled_interface() {
    [ -s /etc/config/mwan3 ] || return 1

    uci -q show mwan3 2>/dev/null |
        config_validation_ucode mwan3-has-enabled-interface >/dev/null 2>&1
}

mwan3_is_active() {
    [ -x /etc/init.d/mwan3 ] || return 1
    mwan3_has_enabled_interface || return 1

    /etc/init.d/mwan3 status >/dev/null 2>&1 ||
        /etc/init.d/mwan3 enabled >/dev/null 2>&1
}

# Migrations and validation funcs
migration() {
    podkop_config_migration_changed=0
    podkop_config_migration_added_lists=""

    ensure_runtime_cache_format
    remove_legacy_server_country_cache
    migrate_list_update_enabled

    config_foreach migrate_0_7_17_8_rule_section "rule"
    config_foreach migrate_0_7_17_8_rule "section"

    if [ "$podkop_config_migration_changed" -eq 1 ]; then
        log "Migrated Podkop Plus UCI config"
        commit_podkop_config
    fi
}

validate_service() {
    local service="$1"

    helpers_ucode whitespace-list-contains "$COMMUNITY_SERVICES" "$service" >/dev/null 2>&1 && return 0

    log "Invalid service in community lists: $service. Check config and LuCI cache. Aborted." "fatal"
    exit 1
}

validate_ruleset_reference() {
    local reference="$1"

    if [ -z "$reference" ]; then
        return 0
    fi

    if helpers_ucode whitespace-list-contains "$COMMUNITY_SERVICES" "$reference" >/dev/null 2>&1; then
        return 0
    fi

    case "$reference" in
    http://* | https://*)
        return 0
        ;;
    /*.srs | /*.json)
        return 0
        ;;
    esac

    log "Unknown rule set reference '$reference'. Aborted." "fatal"
    exit 1
}

validate_plain_domain_ip_list_reference() {
    local reference="$1"

    if [ -z "$reference" ]; then
        return 0
    fi

    case "$reference" in
    http://* | https://*)
        return 0
        ;;
    /*.lst)
        return 0
        ;;
    esac

    log "Unknown plain list reference '$reference'. Aborted." "fatal"
    exit 1
}

validate_sing_box_duration_option() {
    local value="$1"
    local label="$2"

    [ -z "$value" ] && return 0

    if duration_to_seconds "$value" >/dev/null 2>&1; then
        return 0
    fi

    log "Invalid duration value for $label: $value. Use sing-box duration format like 1d, 12h or 30m. Aborted." "fatal"
    exit 1
}

validate_required_sing_box_duration_option() {
    local value="$1"
    local label="$2"

    if [ -z "$value" ]; then
        log "Missing duration value for $label. Use sing-box duration format like 1d, 12h or 30m. Aborted." "fatal"
        exit 1
    fi

    validate_sing_box_duration_option "$value" "$label"
}

validate_subscription_source_entry() {
    local entry="$1"
    local section="$2"

    if ! parse_subscription_source_entry "$entry"; then
        log "Invalid subscription URL in rule '$section': $SUBSCRIPTION_SOURCE_PARSE_ERROR. Aborted." "fatal"
        exit 1
    fi
}

validate_country_code_option() {
    local value="$1"
    local section="$2"

    [ -n "$value" ] || return 0
    if config_validation_ucode country-code-valid "$value" >/dev/null 2>&1; then
        return 0
    fi

    log "Invalid country code '$value' in rule '$section'. Aborted." "fatal"
    exit 1
}

validate_urltest_filter_mode_option() {
    local value="$1"
    local section="$2"

    [ -n "$value" ] || return 0
    if config_validation_ucode enum-valid "$value" disabled exclude include mixed >/dev/null 2>&1; then
        return 0
    fi

    log "Invalid URLTest filter mode '$value' in rule '$section'. Aborted." "fatal"
    exit 1
}

validate_detect_server_country_option() {
    local value="$1"
    local section="$2"

    [ -n "$value" ] || return 0
    if config_validation_ucode enum-valid "$value" "$SERVER_COUNTRY_METHOD_FLAG_EMOJI" "$SERVER_COUNTRY_METHOD_COUNTRY_IS" >/dev/null 2>&1; then
        return 0
    fi

    log "Invalid server country detection mode '$value' in rule '$section'. Aborted." "fatal"
    exit 1
}

validate_urltest_regex_option() {
    local value="$1"
    local section="$2"

    [ -n "$value" ] || return 0
    if config_validation_ucode regex-valid "$value" >/dev/null 2>&1; then
        return 0
    fi

    log "Invalid URLTest regular expression '$value' in rule '$section'. Aborted." "fatal"
    exit 1
}

ruleset_kind_from_reference_hint() {
    local reference="$1"

    case "$reference" in
    *geosite*|*domain*|*domains*|*adguard*|*filter*)
        echo "domains"
        ;;
    *geoip*|*subnet*|*subnets*|*cidr*)
        echo "subnets"
        ;;
    *)
        echo "unknown"
        ;;
    esac
}

json_ruleset_has_domain_matchers() {
    local filepath="$1"

    ucode "$PODKOP_LIB/rulesets.uc" has-domain-matchers "$filepath" >/dev/null 2>&1
}

detect_local_binary_ruleset_kind() {
    local filepath="$1"
    local json_tmpfile kind

    kind="$(ruleset_kind_from_reference_hint "$filepath")"
    if [ "$kind" != "unknown" ]; then
        echo "$kind"
        return 0
    fi

    if ! file_exists "$filepath"; then
        echo "unknown"
        return 0
    fi

    json_tmpfile="$(mktemp)"
    if ! decompile_binary_ruleset "$filepath" "$json_tmpfile"; then
        rm -f "$json_tmpfile"
        echo "unknown"
        return 0
    fi

    if json_ruleset_has_domain_matchers "$json_tmpfile"; then
        kind="domains"
    else
        kind="subnets"
    fi

    rm -f "$json_tmpfile"
    echo "$kind"
}

detect_local_source_ruleset_kind() {
    local filepath="$1"
    local kind

    kind="$(ruleset_kind_from_reference_hint "$filepath")"
    if [ "$kind" != "unknown" ]; then
        echo "$kind"
        return 0
    fi

    if ! file_exists "$filepath"; then
        echo "unknown"
        return 0
    fi

    if json_ruleset_has_domain_matchers "$filepath"; then
        echo "domains"
    else
        echo "subnets"
    fi
}

detect_inline_ruleset_reference_kind() {
    local reference="$1"
    local kind
    local extension

    kind="$(ruleset_kind_from_reference_hint "$reference")"
    if [ "$kind" != "unknown" ]; then
        echo "$kind"
        return 0
    fi

    case "$reference" in
    /*.srs)
        detect_local_binary_ruleset_kind "$reference"
        ;;
    /*.json)
        detect_local_source_ruleset_kind "$reference"
        ;;
    http://* | https://*)
        extension="$(url_get_file_extension "$reference")"
        [ "$extension" = "srs" ] || [ "$extension" = "json" ] || [ -z "$extension" ] || log "Unknown rule set URL extension '$extension' for '$reference'; assuming binary format" "debug"
        [ "$kind" = "unknown" ] && kind="domains"
        echo "$kind"
        ;;
    *)
        echo "unknown"
        ;;
    esac
}

get_inline_remote_ruleset_format() {
    local reference="$1"
    local extension

    extension="$(url_get_file_extension "$reference")"
    case "$extension" in
    json)
        echo "source"
        ;;
    srs | "")
        echo "binary"
        ;;
    *)
        log "Unknown rule set URL extension '$extension' for '$reference'; assuming binary format" "debug"
        echo "binary"
        ;;
    esac
}

validate_outbound_json_rule() {
    local section="$1"
    local outbound_json

    config_get outbound_json "$section" "outbound_json"
    if [ -z "$outbound_json" ]; then
        log "JSON outbound rule '$section' has empty outbound_json. Aborted." "fatal"
        exit 1
    fi

    if ! printf '%s' "$outbound_json" | config_validation_ucode valid-outbound >/dev/null 2>&1; then
        log "JSON outbound rule '$section' must contain a valid sing-box outbound JSON object with a type field. Aborted." "fatal"
        exit 1
    fi
}

validate_port_condition() {
    local value="$1"
    local section="$2"

    if ! is_port_condition "$value"; then
        log "Invalid port condition '$value' in rule '$section'. Use a single port or range like 80 or 1000-2000. Aborted." "fatal"
        exit 1
    fi
}

process_validate_rule() {
    local section="$1"
    local action urltest_check_interval subscription_update_interval

    rule_is_enabled "$section" || return 0

    action="$(get_rule_action "$section")"
    if [ -z "$action" ]; then
        log "Enabled rule '$section' has no action. Aborted." "fatal"
        exit 1
    fi

    config_list_foreach "$section" "ports" validate_port_condition "$section"

    if [ "$action" = "zapret" ]; then
        if ! is_zapret_installed; then
            if [ "$PODKOP_ZAPRET_MISSING_WARNING_EMITTED" -eq 0 ]; then
                log "There are enabled rules with action 'zapret', but the zapret package is not installed. These rules will be skipped." "error"
                PODKOP_ZAPRET_MISSING_WARNING_EMITTED=1
            fi
            config_list_foreach "$section" "community_lists" validate_service
            config_list_foreach "$section" "rule_set" validate_ruleset_reference
            config_list_foreach "$section" "rule_set_with_subnets" validate_ruleset_reference
            config_list_foreach "$section" "domain_ip_lists" validate_plain_domain_ip_list_reference
            return 0
        fi

        validate_rule_nfqws_opt "$section"
    fi

    if [ "$action" = "zapret2" ]; then
        if ! is_zapret2_installed; then
            if [ "$PODKOP_ZAPRET2_MISSING_WARNING_EMITTED" -eq 0 ]; then
                log "There are enabled rules with action 'zapret2', but the zapret2 package is not installed. These rules will be skipped." "error"
                PODKOP_ZAPRET2_MISSING_WARNING_EMITTED=1
            fi
            config_list_foreach "$section" "community_lists" validate_service
            config_list_foreach "$section" "rule_set" validate_ruleset_reference
            config_list_foreach "$section" "rule_set_with_subnets" validate_ruleset_reference
            config_list_foreach "$section" "domain_ip_lists" validate_plain_domain_ip_list_reference
            return 0
        fi

        validate_rule_nfqws2_opt "$section"
    fi

    if [ "$action" = "byedpi" ]; then
        if ! is_byedpi_installed; then
            if [ "$PODKOP_BYEDPI_MISSING_WARNING_EMITTED" -eq 0 ]; then
                log "There are enabled rules with action 'byedpi', but the byedpi package is not installed. These rules will be skipped." "error"
                PODKOP_BYEDPI_MISSING_WARNING_EMITTED=1
            fi
            config_list_foreach "$section" "community_lists" validate_service
            config_list_foreach "$section" "rule_set" validate_ruleset_reference
            config_list_foreach "$section" "rule_set_with_subnets" validate_ruleset_reference
            config_list_foreach "$section" "domain_ip_lists" validate_plain_domain_ip_list_reference
            return 0
        fi

        validate_byedpi_strategy "$(get_rule_byedpi_cmd_opts "$section")" "Invalid ByeDPI strategy for rule '$section'"
    fi

    if [ "$action" = "proxy" ]; then
        local urltest_enabled detect_server_country urltest_filter_mode
        config_get_bool urltest_enabled "$section" "urltest_enabled" 0
        if [ "$urltest_enabled" -eq 1 ]; then
            config_get urltest_filter_mode "$section" "urltest_filter_mode" "disabled"
            validate_urltest_filter_mode_option "$urltest_filter_mode" "$section"
            if urltest_filter_mode_filters_enabled "$urltest_filter_mode"; then
                config_get detect_server_country "$section" "detect_server_country" "$SERVER_COUNTRY_METHOD_FLAG_EMOJI"
                validate_detect_server_country_option "$detect_server_country" "$section"
            fi
            urltest_check_interval="$(get_urltest_check_interval_for_rule "$section")"
            validate_required_sing_box_duration_option "$urltest_check_interval" "rule.$section.urltest_check_interval"
            case "$urltest_filter_mode" in
            include | mixed)
                config_list_foreach "$section" "urltest_include_regex" validate_urltest_regex_option "$section"
                config_list_foreach "$section" "urltest_include_countries" validate_country_code_option "$section"
                ;;
            esac
            case "$urltest_filter_mode" in
            exclude | mixed)
                config_list_foreach "$section" "urltest_exclude_countries" validate_country_code_option "$section"
                config_list_foreach "$section" "urltest_exclude_regex" validate_urltest_regex_option "$section"
                ;;
            esac
        fi

        if rule_has_subscription_urls "$section"; then
            config_list_foreach "$section" "subscription_urls" validate_subscription_source_entry "$section"
            subscription_update_interval="$(get_subscription_update_interval_for_rule "$section")"
            if [ -n "$subscription_update_interval" ]; then
                validate_required_sing_box_duration_option "$subscription_update_interval" "rule.$section.subscription_update_interval"
            fi
        fi
    fi

    if [ "$action" = "outbound" ]; then
        validate_outbound_json_rule "$section"
    fi

    config_list_foreach "$section" "community_lists" validate_service
    config_list_foreach "$section" "rule_set" validate_ruleset_reference
    config_list_foreach "$section" "rule_set_with_subnets" validate_ruleset_reference
    config_list_foreach "$section" "domain_ip_lists" validate_plain_domain_ip_list_reference
}
