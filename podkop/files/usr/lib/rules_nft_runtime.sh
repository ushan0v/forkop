# shellcheck shell=ash

rules_nft_runtime_ucode() {
    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/rules_nft_runtime.uc" "$@"
}

rules_nft_cache_enabled() {
    case "${PODKOP_RULE_CONDITION_CACHE_ENABLED:-0}" in
    1 | true | yes)
        return 0
        ;;
    esac

    return 1
}

rules_nft_cache_init() {
    if [ -z "${PODKOP_RULE_CONDITION_CACHE_DIR:-}" ]; then
        if [ -z "${PODKOP_RULE_CONDITION_CACHE_CLEANED:-}" ]; then
            rm -rf /tmp/podkop-plus-rule-cache.* 2>/dev/null || true
            PODKOP_RULE_CONDITION_CACHE_CLEANED=1
        fi
        PODKOP_RULE_CONDITION_CACHE_DIR="/tmp/podkop-plus-rule-cache.$$"
        mkdir -p "$PODKOP_RULE_CONDITION_CACHE_DIR" 2>/dev/null || return 1
    fi
}

rules_nft_cache_dir() {
    rules_nft_cache_init || return 1

    printf '%s\n' "$PODKOP_RULE_CONDITION_CACHE_DIR"
}

rule_condition_cache_clear() {
    [ -z "${PODKOP_RULE_CONDITION_CACHE_DIR:-}" ] || rm -rf "$PODKOP_RULE_CONDITION_CACHE_DIR" 2>/dev/null || true
    rm -rf /tmp/podkop-plus-rule-cache.* 2>/dev/null || true
    PODKOP_RULE_CONDITION_CACHE_DIR=""
    PODKOP_RULE_CONDITION_CACHE_CLEANED=""
}

rules_nft_cache_key_is_safe() {
    case "$1" in
    "" | *[!A-Za-z0-9_]*)
        return 1
        ;;
    esac

    return 0
}

rules_nft_cache_path() {
    local namespace="$1"
    local section="$2"
    local key="$3"
    local kind="${4:-value}"
    local cache_dir

    rules_nft_cache_enabled || return 1
    rules_nft_cache_key_is_safe "$namespace" || return 1
    rules_nft_cache_key_is_safe "$section" || return 1
    rules_nft_cache_key_is_safe "$key" || return 1
    rules_nft_cache_key_is_safe "$kind" || return 1

    rules_nft_cache_init || return 1
    cache_dir="$PODKOP_RULE_CONDITION_CACHE_DIR"
    printf '%s/%s_%s_%s_%s\n' "$cache_dir" "$namespace" "$section" "$key" "$kind"
}

rules_nft_cache_get() {
    local path="$1"
    local value

    [ -f "$path" ] || return 1
    value=""
    IFS= read -r value < "$path" || true
    printf '%s\n' "$value"
}

rules_nft_cache_put() {
    local path="$1"
    local value="$2"

    printf '%s\n' "$value" > "$path" 2>/dev/null || return 1
}

normalize_port_condition_for_nft() {
    rules_nft_runtime_ucode normalize-port-condition-for-nft "$1"
}

is_port_condition() {
    normalize_port_condition_for_nft "$1" >/dev/null 2>&1
}

br_netfilter_disable() {
    if lsmod | rules_nft_runtime_ucode stdin-contains br_netfilter >/dev/null 2>&1 &&
        [ "$(sysctl -n net.bridge.bridge-nf-call-iptables 2> /dev/null)" = "1" ]; then
        log "br_netfilter enabled detected. Disabling"
        sysctl -w net.bridge.bridge-nf-call-iptables=0
        sysctl -w net.bridge.bridge-nf-call-ip6tables=0
    fi
}

parse_generic_string_to_commas_string() {
    local string="$1"

    [ -n "$string" ] || return 0
    rules_nft_runtime_ucode text-list-to-csv "$string" comma
}

parse_domain_or_subnet_string_to_commas_string() {
    local string="$1"
    local type="$2"

    [ -n "$string" ] || return 0
    rules_nft_runtime_ucode domain-subnet-text-csv "$string" "$type"
}

parse_domain_or_subnet_file_to_comma_string() {
    local filepath="$1"
    local type="$2"

    rules_nft_runtime_ucode domain-subnet-file-csv "$filepath" "$type"
}

parse_combined_domain_string_to_commas_string() {
    local string="$1"
    local type="$2"

    [ -n "$string" ] || return 0
    rules_nft_runtime_ucode combined-domain-text-csv "$string" "$type"
}

parse_combined_domain_list_to_commas_string() {
    local list_value="$1"
    local type="$2"

    [ -n "$list_value" ] || return 0
    rules_nft_runtime_ucode combined-domain-csv "$(rule_list_value_to_commas_string "$list_value")" "$type"
}

split_domain_or_subnet_file() {
    local filepath="$1"
    local domains_output="$2"
    local subnets_output="$3"

    rules_nft_runtime_ucode split-domain-subnet-file "$filepath" "$domains_output" "$subnets_output"
}

rule_list_value_to_commas_string() {
    printf '%s\n' "$1" | tr ' ' ','
}

get_legacy_domain_condition_commas_string() {
    local section="$1"
    local key="$2"
    local kind="$3"

    local text_mode conditions_text_mode text_value list_value
    config_get_bool text_mode "$section" "${key}_text_mode" 0
    config_get_bool conditions_text_mode "$section" "conditions_text_mode" 0
    config_get text_value "$section" "${key}_text"
    config_get list_value "$section" "$key"

    if [ "$text_mode" -eq 1 ] || [ "$conditions_text_mode" -eq 1 ]; then
        case "$kind" in
        domains) parse_domain_or_subnet_string_to_commas_string "$text_value" "domains" ;;
        *)
            parse_generic_string_to_commas_string "$text_value"
            ;;
        esac
        return 0
    fi

    if [ -n "$list_value" ]; then
        rule_list_value_to_commas_string "$list_value"
        return 0
    fi

    if [ -n "$text_value" ]; then
        case "$kind" in
        domains) parse_domain_or_subnet_string_to_commas_string "$text_value" "domains" ;;
        *)
            parse_generic_string_to_commas_string "$text_value"
            ;;
        esac
        return 0
    fi

    rule_list_value_to_commas_string "$list_value"
}

get_combined_domain_condition_commas_string() {
    local section="$1"
    local requested_key="$2"
    local legacy_kind="$3"

    local combined_text_mode conditions_text_mode combined_text_value combined_list_value
    local combined_text_values combined_list_values combined_values legacy_values
    config_get_bool combined_text_mode "$section" "domain_suffix_text_mode" 0
    config_get_bool conditions_text_mode "$section" "conditions_text_mode" 0
    config_get combined_text_value "$section" "domain_suffix_text"
    config_get combined_list_value "$section" "domain_suffix"

    combined_text_values="$(parse_combined_domain_string_to_commas_string "$combined_text_value" "$requested_key")"
    combined_list_values="$(parse_combined_domain_list_to_commas_string "$combined_list_value" "$requested_key")"
    if [ -n "$combined_text_values" ] && [ -n "$combined_list_values" ]; then
        combined_values="${combined_text_values},${combined_list_values}"
    else
        combined_values="${combined_text_values}${combined_list_values}"
    fi

    if [ "$requested_key" = "domain_suffix" ]; then
        printf '%s\n' "$combined_values"
        return 0
    fi

    legacy_values="$(get_legacy_domain_condition_commas_string "$section" "$requested_key" "$legacy_kind")"
    if [ -n "$combined_values" ] && [ -n "$legacy_values" ]; then
        printf '%s,%s\n' "$combined_values" "$legacy_values"
    else
        printf '%s%s\n' "$combined_values" "$legacy_values"
    fi
}

get_rule_condition_commas_string_uncached() {
    local section="$1"
    local key="$2"
    local kind="$3"

    local text_mode conditions_text_mode text_value list_value

    case "$key" in
    domain)
        get_combined_domain_condition_commas_string "$section" "domain" "domains"
        return 0
        ;;
    domain_suffix)
        get_combined_domain_condition_commas_string "$section" "domain_suffix" "domains"
        return 0
        ;;
    domain_keyword)
        get_combined_domain_condition_commas_string "$section" "domain_keyword" "generic"
        return 0
        ;;
    domain_regex)
        get_combined_domain_condition_commas_string "$section" "domain_regex" "generic"
        return 0
        ;;
    esac

    config_get_bool text_mode "$section" "${key}_text_mode" 0
    config_get_bool conditions_text_mode "$section" "conditions_text_mode" 0
    config_get text_value "$section" "${key}_text"
    config_get list_value "$section" "$key"

    if [ "$text_mode" -eq 1 ] || [ "$conditions_text_mode" -eq 1 ]; then
        case "$kind" in
        domains) parse_domain_or_subnet_string_to_commas_string "$text_value" "domains" ;;
        subnets) parse_domain_or_subnet_string_to_commas_string "$text_value" "subnets" ;;
        *)
            parse_generic_string_to_commas_string "$text_value"
            ;;
        esac
        return 0
    fi

    if [ -n "$list_value" ]; then
        rule_list_value_to_commas_string "$list_value"
        return 0
    fi

    if [ -n "$text_value" ]; then
        case "$kind" in
        domains) parse_domain_or_subnet_string_to_commas_string "$text_value" "domains" ;;
        subnets) parse_domain_or_subnet_string_to_commas_string "$text_value" "subnets" ;;
        *)
            parse_generic_string_to_commas_string "$text_value"
            ;;
        esac
        return 0
    fi

    rule_list_value_to_commas_string "$list_value"
}

get_rule_condition_commas_string() {
    local section="$1"
    local key="$2"
    local kind="$3"
    local cache_path value

    cache_path="$(rules_nft_cache_path condition "$section" "$key" "$kind" 2>/dev/null || true)"
    if [ -n "$cache_path" ]; then
        if value="$(rules_nft_cache_get "$cache_path")"; then
            printf '%s\n' "$value"
            return 0
        fi
    fi

    value="$(get_rule_condition_commas_string_uncached "$section" "$key" "$kind")"
    [ -z "$cache_path" ] || rules_nft_cache_put "$cache_path" "$value" || true
    printf '%s\n' "$value"
}

get_rule_condition_json_array() {
    local section="$1"
    local key="$2"
    local kind="$3"
    local values cache_path value

    cache_path="$(rules_nft_cache_path condition_json "$section" "$key" "$kind" 2>/dev/null || true)"
    if [ -n "$cache_path" ]; then
        if value="$(rules_nft_cache_get "$cache_path")"; then
            printf '%s\n' "$value"
            return 0
        fi
    fi

    values="$(get_rule_condition_commas_string "$section" "$key" "$kind")"
    if [ -n "$values" ]; then
        value="$(rules_nft_runtime_ucode csv-to-json-array "$values")"
    else
        value="[]"
    fi
    [ -z "$cache_path" ] || rules_nft_cache_put "$cache_path" "$value" || true
    printf '%s\n' "$value"
}

get_rule_ports_commas_string_uncached() {
    local section="$1"
    local values text_value

    config_get values "$section" "ports"
    config_get text_value "$section" "ports_text"

    [ -n "$values$text_value" ] || return 0
    rules_nft_runtime_ucode rule-ports-csv "$values" "$text_value"
}

get_rule_ports_commas_string() {
    local section="$1"
    local cache_path value

    cache_path="$(rules_nft_cache_path ports "$section" ports value 2>/dev/null || true)"
    if [ -n "$cache_path" ]; then
        if value="$(rules_nft_cache_get "$cache_path")"; then
            printf '%s\n' "$value"
            return 0
        fi
    fi

    value="$(get_rule_ports_commas_string_uncached "$section")"
    [ -z "$cache_path" ] || rules_nft_cache_put "$cache_path" "$value" || true
    printf '%s\n' "$value"
}

get_rule_port_values_json_array() {
    local section="$1"
    local ports cache_path value

    cache_path="$(rules_nft_cache_path ports_json "$section" values value 2>/dev/null || true)"
    if [ -n "$cache_path" ]; then
        if value="$(rules_nft_cache_get "$cache_path")"; then
            printf '%s\n' "$value"
            return 0
        fi
    fi

    ports="$(get_rule_ports_commas_string "$section")"
    if [ -n "$ports" ]; then
        value="$(rules_nft_runtime_ucode rule-port-values-json "$ports")"
    else
        value="[]"
    fi
    [ -z "$cache_path" ] || rules_nft_cache_put "$cache_path" "$value" || true
    printf '%s\n' "$value"
}

get_rule_port_ranges_json_array() {
    local section="$1"
    local ports cache_path value

    cache_path="$(rules_nft_cache_path ports_json "$section" ranges value 2>/dev/null || true)"
    if [ -n "$cache_path" ]; then
        if value="$(rules_nft_cache_get "$cache_path")"; then
            printf '%s\n' "$value"
            return 0
        fi
    fi

    ports="$(get_rule_ports_commas_string "$section")"
    if [ -n "$ports" ]; then
        value="$(rules_nft_runtime_ucode rule-port-ranges-json "$ports")"
    else
        value="[]"
    fi
    [ -z "$cache_path" ] || rules_nft_cache_put "$cache_path" "$value" || true
    printf '%s\n' "$value"
}

section_has_destination_matchers() {
    local section="$1"
    local domain domain_suffix domain_keyword domain_regex ip_cidr community_lists rule_set rule_set_with_subnets domain_ip_lists

    domain="$(get_rule_condition_commas_string "$section" "domain" "domains")"
    domain_suffix="$(get_rule_condition_commas_string "$section" "domain_suffix" "domains")"
    domain_keyword="$(get_rule_condition_commas_string "$section" "domain_keyword" "generic")"
    domain_regex="$(get_rule_condition_commas_string "$section" "domain_regex" "generic")"
    ip_cidr="$(get_rule_condition_commas_string "$section" "ip_cidr" "subnets")"
    config_get community_lists "$section" "community_lists"
    config_get rule_set "$section" "rule_set"
    config_get rule_set_with_subnets "$section" "rule_set_with_subnets"
    config_get domain_ip_lists "$section" "domain_ip_lists"

    [ -n "$domain" ] ||
        [ -n "$domain_suffix" ] ||
        [ -n "$domain_keyword" ] ||
        [ -n "$domain_regex" ] ||
        [ -n "$ip_cidr" ] ||
        [ -n "$community_lists" ] ||
        [ -n "$rule_set" ] ||
        [ -n "$rule_set_with_subnets" ] ||
        [ -n "$domain_ip_lists" ]
}

add_section_ip_cidr_to_nft_sets() {
    local section="$1"
    local ip_values="$2"
    local ports

    [ -n "$ip_values" ] || return 0

    ports="$(get_rule_ports_commas_string "$section")"
    if [ -n "$ports" ]; then
        local tmpfile status
        tmpfile="$(mktemp)"
        rules_nft_runtime_ucode csv-to-lines-file "$ip_values" "$tmpfile"
        nft_add_ip_port_set_elements_from_ip_file_chunked "$tmpfile" "$NFT_TABLE_NAME" "$NFT_IP_PORT_SET_NAME" "$ports"
        status=$?
        rm -f "$tmpfile"
        return "$status"
    else
        nft_add_set_elements "$NFT_TABLE_NAME" "$NFT_COMMON_SET_NAME" "$ip_values"
    fi
}

add_section_ports_to_nft_set_if_needed() {
    local section="$1"
    local ports

    ports="$(get_rule_ports_commas_string "$section")"
    [ -n "$ports" ] || return 0

    if section_has_destination_matchers "$section"; then
        return 0
    fi

    nft_add_set_elements "$NFT_TABLE_NAME" "$NFT_PORT_SET_NAME" "$ports"
}

ruleset_registered() {
    local tag="$1"
    rules_nft_runtime_ucode csv-list-contains "$configured_rulesets" "$tag" >/dev/null 2>&1
}

register_ruleset_tag() {
    local tag="$1"
    if ! ruleset_registered "$tag"; then
        if [ -z "$configured_rulesets" ]; then
            configured_rulesets="$tag"
        else
            configured_rulesets="$configured_rulesets,$tag"
        fi
    fi
}

ENSURED_RULESET_TAG=""
ENSURED_RULESET_KIND="unknown"

get_community_ruleset_url() {
    local name="$1"

    case "$name" in
    ads_hagezi_pro)
        printf '%s\n' "$SRS_ADS_HAGEZI_PRO_URL"
        ;;
    supercell)
        printf '%s\n' "$SRS_SUPERCELL_URL"
        ;;
    *)
        printf '%s\n' "$SRS_MAIN_URL/$name.srs"
        ;;
    esac
}

ensure_builtin_ruleset() {
    local name="$1"
    local tag="builtin-$name-ruleset"

    ENSURED_RULESET_TAG="$tag"
    ENSURED_RULESET_KIND="domains"

    if ! ruleset_registered "$tag"; then
        local detour update_interval url
        detour="$(get_download_detour_tag)"
        update_interval="$(get_remote_ruleset_update_interval)"
        url="$(get_community_ruleset_url "$name")"
        config=$(sing_box_cm_add_remote_ruleset "$config" "$tag" "binary" "$url" "$detour" "$update_interval")
        register_ruleset_tag "$tag"
    fi
}

ensure_inline_custom_ruleset() {
    local reference="$1"
    local tag hash detour update_interval extension format

    hash="$(printf '%s' "$reference" | md5sum | helpers_ucode md5sum-hex-prefix 12)"
    tag="inline-custom-$hash-ruleset"
    ENSURED_RULESET_TAG="$tag"
    ENSURED_RULESET_KIND="$(detect_inline_ruleset_reference_kind "$reference")"

    if ! ruleset_registered "$tag"; then
        update_interval="$(get_remote_ruleset_update_interval)"

        case "$reference" in
        /*.srs)
            config=$(sing_box_cm_add_local_ruleset "$config" "$tag" "binary" "$reference")
            ;;
        /*.json)
            config=$(sing_box_cm_add_local_ruleset "$config" "$tag" "source" "$reference")
            ;;
        http://* | https://*)
            extension="$(url_get_file_extension "$reference")"
            detour="$(get_download_detour_tag)"
            case "$extension" in
            srs)
                config=$(sing_box_cm_add_remote_ruleset "$config" "$tag" "binary" "$reference" "$detour" "$update_interval")
                ;;
            json)
                config=$(sing_box_cm_add_remote_ruleset "$config" "$tag" "source" "$reference" "$detour" "$update_interval")
                ;;
            *)
                format="$(get_inline_remote_ruleset_format "$reference")"
                config=$(sing_box_cm_add_remote_ruleset "$config" "$tag" "$format" "$reference" "$detour" "$update_interval")
                ;;
            esac
            ;;
        *)
            return 1
            ;;
        esac

        register_ruleset_tag "$tag"
    fi
}

resolve_ruleset_reference() {
    local reference="$1"
    ENSURED_RULESET_TAG=""
    ENSURED_RULESET_KIND="unknown"

    if list_has_item "$COMMUNITY_SERVICES" "$reference"; then
        ensure_builtin_ruleset "$reference"
        return 0
    fi

    ensure_inline_custom_ruleset "$reference"
}

# Main funcs

route_table_rule_mark() {
    rules_nft_runtime_ucode file-regex-matches /etc/iproute2/rt_tables "105 $RT_TABLE_NAME" >/dev/null 2>&1 ||
        echo "105 $RT_TABLE_NAME" >> /etc/iproute2/rt_tables

    if ! has_tproxy_route; then
        log "Added route for tproxy" "debug"
        ip route add local 0.0.0.0/0 dev lo table "$RT_TABLE_NAME" 2> /dev/null || {
            if has_tproxy_route; then
                log "Route for tproxy exists" "debug"
            else
                log "Failed to add route for tproxy. Aborted." "fatal"
                exit 1
            fi
        }
    else
        log "Route for tproxy exists" "debug"
    fi

    if ! has_tproxy_marking_rule; then
        log "Create marking rule" "debug"
        ip -4 rule add fwmark "$NFT_FAKEIP_MARK"/"$NFT_FAKEIP_MARK" table "$RT_TABLE_NAME" priority 105 2> /dev/null || {
            if has_tproxy_marking_rule; then
                log "Marking rule exist" "debug"
            else
                log "Failed to create marking rule. Aborted." "fatal"
                exit 1
            fi
        }
    else
        log "Marking rule exist" "debug"
    fi
}

has_tproxy_route() {
    ip route list table "$RT_TABLE_NAME" 2>/dev/null |
        rules_nft_runtime_ucode has-local-default-route >/dev/null 2>&1
}

has_tproxy_marking_rule() {
    ip -4 rule list 2>/dev/null |
        rules_nft_runtime_ucode has-tproxy-marking-rule "$RT_TABLE_NAME" "$NFT_FAKEIP_MARK" >/dev/null 2>&1
}

nft_init_interfaces_set() {
    nft_create_ifname_set "$NFT_TABLE_NAME" "$NFT_INTERFACE_SET_NAME"

    local source_network_interfaces
    config_get source_network_interfaces "settings" "source_network_interfaces" "br-lan"

    for interface in $source_network_interfaces; do
        nft add element inet "$NFT_TABLE_NAME" "$NFT_INTERFACE_SET_NAME" "{ $interface }"
    done
}

create_nft_rules() {
    log "Create nft table"
    nft_create_table "$NFT_TABLE_NAME"

    log "Create localv4 set"
    nft_create_ipv4_set "$NFT_TABLE_NAME" "$NFT_LOCALV4_SET_NAME"
    nft add element inet "$NFT_TABLE_NAME" localv4 '{
        0.0.0.0/8,
        10.0.0.0/8,
        127.0.0.0/8,
        169.254.0.0/16,
        172.16.0.0/12,
        192.0.0.0/24,
        192.0.2.0/24,
        192.88.99.0/24,
        192.168.0.0/16,
        198.51.100.0/24,
        203.0.113.0/24,
        224.0.0.0/4,
        240.0.0.0-255.255.255.255
    }'

    log "Create common set"
    nft_create_ipv4_set "$NFT_TABLE_NAME" "$NFT_COMMON_SET_NAME"

    log "Create port set"
    nft_create_inet_service_set "$NFT_TABLE_NAME" "$NFT_PORT_SET_NAME"

    log "Create IP and port set"
    nft_create_ipv4_port_set "$NFT_TABLE_NAME" "$NFT_IP_PORT_SET_NAME"

    log "Create interface set"
    nft_init_interfaces_set

    log "Create nft rules"
    nft add chain inet "$NFT_TABLE_NAME" mangle '{ type filter hook prerouting priority -150; policy accept; }'
    nft add chain inet "$NFT_TABLE_NAME" mangle_output '{ type route hook output priority -150; policy accept; }'
    nft add chain inet "$NFT_TABLE_NAME" proxy '{ type filter hook prerouting priority -100; policy accept; }'

    nft add rule inet "$NFT_TABLE_NAME" mangle ct status dnat return
    nft add rule inet "$NFT_TABLE_NAME" mangle iifname "@$NFT_INTERFACE_SET_NAME" ip daddr "@$NFT_LOCALV4_SET_NAME" return
    nft add rule inet "$NFT_TABLE_NAME" mangle iifname "@$NFT_INTERFACE_SET_NAME" ip daddr "@$NFT_COMMON_SET_NAME" meta l4proto tcp meta mark set "$NFT_FAKEIP_MARK" counter
    nft add rule inet "$NFT_TABLE_NAME" mangle iifname "@$NFT_INTERFACE_SET_NAME" ip daddr "@$NFT_COMMON_SET_NAME" meta l4proto udp meta mark set "$NFT_FAKEIP_MARK" counter
    nft add rule inet "$NFT_TABLE_NAME" mangle iifname "@$NFT_INTERFACE_SET_NAME" ip daddr . tcp dport "@$NFT_IP_PORT_SET_NAME" meta mark set "$NFT_FAKEIP_MARK" counter
    nft add rule inet "$NFT_TABLE_NAME" mangle iifname "@$NFT_INTERFACE_SET_NAME" ip daddr . udp dport "@$NFT_IP_PORT_SET_NAME" meta mark set "$NFT_FAKEIP_MARK" counter
    nft add rule inet "$NFT_TABLE_NAME" mangle iifname "@$NFT_INTERFACE_SET_NAME" ip daddr != "@$NFT_LOCALV4_SET_NAME" tcp dport "@$NFT_PORT_SET_NAME" meta mark set "$NFT_FAKEIP_MARK" counter
    nft add rule inet "$NFT_TABLE_NAME" mangle iifname "@$NFT_INTERFACE_SET_NAME" ip daddr != "@$NFT_LOCALV4_SET_NAME" udp dport "@$NFT_PORT_SET_NAME" meta mark set "$NFT_FAKEIP_MARK" counter
    nft add rule inet "$NFT_TABLE_NAME" mangle iifname "@$NFT_INTERFACE_SET_NAME" ip daddr "$SB_FAKEIP_INET4_RANGE" meta l4proto tcp meta mark set "$NFT_FAKEIP_MARK" counter
    nft add rule inet "$NFT_TABLE_NAME" mangle iifname "@$NFT_INTERFACE_SET_NAME" ip daddr "$SB_FAKEIP_INET4_RANGE" meta l4proto udp meta mark set "$NFT_FAKEIP_MARK" counter

    nft add rule inet "$NFT_TABLE_NAME" proxy meta mark \& "$NFT_FAKEIP_MARK" == "$NFT_FAKEIP_MARK" meta l4proto tcp tproxy ip to :"$SB_TPROXY_INBOUND_PORT" counter
    nft add rule inet "$NFT_TABLE_NAME" proxy meta mark \& "$NFT_FAKEIP_MARK" == "$NFT_FAKEIP_MARK" meta l4proto udp tproxy ip to :"$SB_TPROXY_INBOUND_PORT" counter

    nft add rule inet "$NFT_TABLE_NAME" mangle_output ip daddr "@$NFT_LOCALV4_SET_NAME" return
    nft add rule inet "$NFT_TABLE_NAME" mangle_output meta mark "$NFT_OUTBOUND_MARK" counter return
    create_zapret_nft_rules
    create_zapret2_nft_rules
    nft add rule inet "$NFT_TABLE_NAME" mangle_output ip daddr "@$NFT_COMMON_SET_NAME" meta l4proto tcp meta mark set "$NFT_FAKEIP_MARK" counter
    nft add rule inet "$NFT_TABLE_NAME" mangle_output ip daddr "@$NFT_COMMON_SET_NAME" meta l4proto udp meta mark set "$NFT_FAKEIP_MARK" counter
    nft add rule inet "$NFT_TABLE_NAME" mangle_output ip daddr . tcp dport "@$NFT_IP_PORT_SET_NAME" meta mark set "$NFT_FAKEIP_MARK" counter
    nft add rule inet "$NFT_TABLE_NAME" mangle_output ip daddr . udp dport "@$NFT_IP_PORT_SET_NAME" meta mark set "$NFT_FAKEIP_MARK" counter
    nft add rule inet "$NFT_TABLE_NAME" mangle_output tcp dport "@$NFT_PORT_SET_NAME" meta mark set "$NFT_FAKEIP_MARK" counter
    nft add rule inet "$NFT_TABLE_NAME" mangle_output udp dport "@$NFT_PORT_SET_NAME" meta mark set "$NFT_FAKEIP_MARK" counter
    nft add rule inet "$NFT_TABLE_NAME" mangle_output ip daddr "$SB_FAKEIP_INET4_RANGE" meta l4proto tcp meta mark set "$NFT_FAKEIP_MARK" counter
    nft add rule inet "$NFT_TABLE_NAME" mangle_output ip daddr "$SB_FAKEIP_INET4_RANGE" meta l4proto udp meta mark set "$NFT_FAKEIP_MARK" counter

    local exclude_ntp
    config_get_bool exclude_ntp "settings" "exclude_ntp" "0"
    if [ "$exclude_ntp" -eq 1 ]; then
        log "NTP traffic exclude for proxy"
        nft insert rule inet "$NFT_TABLE_NAME" mangle udp dport 123 return
    fi
}

. "$PODKOP_LIB/dnsmasq_runtime.sh"
