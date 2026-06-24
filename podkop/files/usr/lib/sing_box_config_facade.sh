# shellcheck shell=dash
PODKOP_LIB="${PODKOP_LIB:-/usr/lib/podkop-plus}"
. "$PODKOP_LIB/helpers.sh"
. "$PODKOP_LIB/sing_box_config_manager.sh"

sing_box_cf_ucode() {
    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/sing_box_config_facade.uc" "$@"
}

sing_box_cf_ucode_input() {
    local operation="$1"
    local input="$2"
    shift 2

    printf '%s' "$input" |
        ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/sing_box_config_facade.uc" "$operation" "$@"
}

sing_box_cf_tags_json_count() {
    sing_box_cf_ucode_input stdin-collection-length "${1:-[]}" 2>/dev/null
}

sing_box_cf_tags_json_csv() {
    sing_box_cf_ucode_input stdin-string-array-csv "${1:-[]}" 2>/dev/null
}

sing_box_cf_outbounds_json_count() {
    sing_box_cf_ucode_input stdin-collection-length "${1:-[]}" 2>/dev/null
}

sing_box_cf_subscription_outbound_count() {
    local count="${SUBSCRIPTION_OUTBOUND_COUNT:-}"

    case "$count" in
    '' | *[!0-9]*)
        sing_box_cf_tags_json_count "$SUBSCRIPTION_OUTBOUND_TAGS_JSON"
        ;;
    *)
        printf '%s\n' "$count"
        ;;
    esac
}

sing_box_cf_add_dns_server() {
    local config="$1"
    local type="$2"
    local tag="$3"
    local server="$4"
    local domain_resolver="$5"
    local detour="$6"

    local server_address server_port
    server_address=$(url_get_host "$server")
    server_port=$(url_get_port "$server")

    case "$type" in
    udp)
        [ -z "$server_port" ] && server_port=53
        config=$(sing_box_cm_add_udp_dns_server "$config" "$tag" "$server_address" "$server_port" "$domain_resolver" \
            "$detour")
        ;;
    dot)
        [ -z "$server_port" ] && server_port=853
        config=$(sing_box_cm_add_tls_dns_server "$config" "$tag" "$server_address" "$server_port" "$domain_resolver" \
            "$detour")
        ;;
    doh)
        [ -z "$server_port" ] && server_port=443
        local path headers
        path=$(url_get_path "$server")
        headers="" # TODO(ampetelin): implement it if necessary
        config=$(sing_box_cm_add_https_dns_server "$config" "$tag" "$server_address" "$server_port" "$path" "$headers" \
            "$domain_resolver" "$detour")
        ;;
    *)
        log "Unsupported DNS server type: $type. Aborted." "fatal"
        exit 1
        ;;
    esac

    echo "$config"
}

sing_box_cf_add_mixed_inbound_and_route_rule() {
    local config="$1"
    local tag="$2"
    local listen_address="$3"
    local listen_port="$4"
    local outbound="$5"
    local username="$6"
    local password="$7"

    config=$(sing_box_cm_add_mixed_inbound "$config" "$tag" "$listen_address" "$listen_port" "$username" "$password")
    config=$(sing_box_cm_add_route_rule "$config" "" "$tag" "$outbound")

    echo "$config"
}

sing_box_cf_add_proxy_outbound() {
    local config="$1"
    local section="$2"
    local url="$3"
    local udp_over_tcp="$4"

    url=$(sing_box_cf_ucode url-decode "$url")
    url=$(url_strip_fragment "$url")

    local scheme
    scheme="$(url_get_scheme "$url")"
    case "$scheme" in
    http | https)
        local tag host port path userinfo username password tls_enabled

        tag=$(get_outbound_tag_by_section "$section")
        host=$(url_get_host "$url")
        port=$(url_get_port "$url")
        path=$(url_get_path "$url")
        if [ -z "$host" ] || [ -z "$port" ] || { [ -n "$path" ] && [ "$path" != "/" ]; } || [ "${url#*\?}" != "$url" ]; then
            log "Invalid HTTP proxy URL: host and explicit port are required; path and query are not supported. Aborted." "fatal"
            exit 1
        fi
        userinfo=$(url_get_userinfo "$url")
        if [ -n "$userinfo" ]; then
            case "$userinfo" in
            *:*)
                username="${userinfo%%:*}"
                password="${userinfo#*:}"
                ;;
            *)
                username="$userinfo"
                ;;
            esac
        fi
        [ "$scheme" = "https" ] && tls_enabled=1 || tls_enabled=0
        config=$(sing_box_cm_add_http_outbound "$config" "$tag" "$host" "$port" "$username" "$password" "$tls_enabled")
        ;;
    socks4 | socks4a | socks5)
        local tag host port version userinfo username password udp_over_tcp

        tag=$(get_outbound_tag_by_section "$section")
        host=$(url_get_host "$url")
        port=$(url_get_port "$url")
        version="${scheme#socks}"
        if [ "$scheme" = "socks5" ]; then
            userinfo=$(url_get_userinfo "$url")
            if [ -n "$userinfo" ]; then
                username="${userinfo%%:*}"
                password="${userinfo#*:}"
            fi
        fi
        config="$(sing_box_cm_add_socks_outbound \
            "$config" \
            "$tag" \
            "$host" \
            "$port" \
            "$version" \
            "$username" \
            "$password" \
            "" \
            "$([ "$udp_over_tcp" = "1" ] && echo 2)" # if udp_over_tcp is enabled, enable version 2
        )"
        ;;
    vless)
        local tag host port uuid flow packet_encoding
        tag=$(get_outbound_tag_by_section "$section")
        host=$(url_get_host "$url")
        port=$(url_get_port "$url")
        uuid=$(url_get_userinfo "$url")
        flow=$(url_get_query_param "$url" "flow")
        packet_encoding=$(url_get_query_param "$url" "packetEncoding")
        case "$packet_encoding" in
        xudp | packetaddr) ;;
        *) packet_encoding="" ;;
        esac

        config=$(sing_box_cm_add_vless_outbound "$config" "$tag" "$host" "$port" "$uuid" "$flow" "" "$packet_encoding")
        config=$(_add_outbound_security "$config" "$tag" "$url")
        config=$(_add_outbound_transport "$config" "$tag" "$url")
        ;;
    vmess)
        local tag outbound_json
        tag=$(get_outbound_tag_by_section "$section")
        outbound_json="$(ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/subscription_parser.uc" share-link-outbound "$url" "$tag")" || {
            log "Invalid VMess proxy URL. Aborted." "fatal"
            exit 1
        }
        config=$(sing_box_cm_add_raw_outbound "$config" "$tag" "$outbound_json")
        ;;
    ss)
        local userinfo tag host port method password udp_over_tcp

        userinfo=$(url_get_userinfo "$url")
        if ! sing_box_cf_ucode shadowsocks-userinfo-format-valid "$userinfo"; then
            userinfo=$(base64_decode "$userinfo")
            if [ $? -ne 0 ]; then
                log "Cannot decode shadowsocks userinfo or it does not match the expected format. Aborted." "fatal"
                exit 1
            fi
        fi

        tag=$(get_outbound_tag_by_section "$section")
        host=$(url_get_host "$url")
        port=$(url_get_port "$url")
        method="${userinfo%%:*}"
        password="${userinfo#*:}"

        config=$(
            sing_box_cm_add_shadowsocks_outbound \
                "$config" \
                "$tag" \
                "$host" \
                "$port" \
                "$method" \
                "$password" \
                "" \
                "$([ "$udp_over_tcp" = "1" ] && echo 2)" # if udp_over_tcp is enabled, enable version 2
        )
        ;;
    trojan)
        local tag host port password
        tag=$(get_outbound_tag_by_section "$section")
        host=$(url_get_host "$url")
        port=$(url_get_port "$url")
        password=$(url_get_userinfo "$url")

        config=$(sing_box_cm_add_trojan_outbound "$config" "$tag" "$host" "$port" "$password")
        config=$(_add_outbound_security "$config" "$tag" "$url")
        config=$(_add_outbound_transport "$config" "$tag" "$url")
        ;;
    hysteria2 | hy2)
        local tag host port mport password obfuscator_type obfuscator_password upload_mbps download_mbps
        tag=$(get_outbound_tag_by_section "$section")
        host=$(url_get_host "$url")
        port="$(url_get_port "$url")"
        mport="$(url_get_query_param "$url" "mport")"
        [ -n "$mport" ] && port="$mport"
        password=$(url_get_userinfo "$url")
        obfuscator_type=$(url_get_query_param "$url" "obfs")
        obfuscator_password=$(url_get_query_param "$url" "obfs-password")
        upload_mbps=$(url_get_query_param "$url" "upmbps")
        download_mbps=$(url_get_query_param "$url" "downmbps")

        config=$(sing_box_cm_add_hysteria2_outbound "$config" "$tag" "$host" "$port" "$password" "$obfuscator_type" \
            "$obfuscator_password" "$upload_mbps" "$download_mbps")
        config=$(_add_outbound_security "$config" "$tag" "$url")
        ;;
    *)
        log "Unsupported proxy $scheme type. Aborted." "fatal"
        exit 1
        ;;
    esac

    echo "$config"
}

_add_outbound_security() {
    local config="$1"
    local outbound_tag="$2"
    local url="$3"

    local security scheme
    scheme="$(url_get_scheme "$url")"
    security=$(url_get_query_param "$url" "security")
    if [ -z "$security" ]; then
        if [ "$scheme" = "hysteria2" ] || [ "$scheme" = "hy2" ]; then
            security="tls"
        fi
    fi

    case "$security" in
    tls | reality)
        local sni insecure alpn fingerprint public_key short_id
        sni=$(url_get_query_param "$url" "sni")
        insecure=$(_get_insecure_query_param_from_url "$url")
        alpn=$(sing_box_cf_ucode tls-alpn-json-array "$(url_get_query_param "$url" "alpn")" "$(url_get_query_param "$url" "type")")
        fingerprint=$(url_get_query_param "$url" "fp")
        if [ "$scheme" = "hysteria2" ] || [ "$scheme" = "hy2" ]; then
            fingerprint=""
        fi
        public_key=$(url_get_query_param "$url" "pbk")
        short_id=$(url_get_query_param "$url" "sid")

        config=$(
            sing_box_cm_set_tls_for_outbound \
                "$config" \
                "$outbound_tag" \
                "$sni" \
                "$([ "$insecure" = "1" ] && echo true)" \
                "$([ "$alpn" = "[]" ] && echo null || echo "$alpn")" \
                "$fingerprint" \
                "$public_key" \
                "$short_id"
        )
        ;;
    none) ;;
    *)
        log "Unknown security '$security' detected." "error"
        ;;
    esac

    echo "$config"
}

_get_insecure_query_param_from_url() {
    local url="$1"

    local insecure
    insecure=$(url_get_query_param "$url" "allowInsecure")
    if [ -z "$insecure" ]; then
        insecure=$(url_get_query_param "$url" "insecure")
    fi

    echo "$insecure"
}

_add_outbound_transport() {
    local config="$1"
    local outbound_tag="$2"
    local url="$3"

    local transport
    transport=$(url_get_query_param "$url" "type")
    case "$transport" in
    "" | tcp | raw) ;;
    http | h2)
        local http_path http_hosts
        http_path=$(url_get_query_param "$url" "path")
        http_hosts=$(sing_box_cf_ucode csv-to-json-array "$(url_get_query_param "$url" "host")")

        config=$(
            sing_box_cm_set_http_transport_for_outbound "$config" "$outbound_tag" "$http_path" "$http_hosts"
        )
        ;;
    ws)
        local ws_path ws_host ws_early_data
        ws_path=$(url_get_query_param "$url" "path")
        ws_host=$(url_get_query_param "$url" "host")
        ws_early_data=$(url_get_query_param "$url" "ed")

        config=$(
            sing_box_cm_set_ws_transport_for_outbound "$config" "$outbound_tag" "$ws_path" "$ws_host" "$ws_early_data"
        )
        ;;
    grpc)
        # TODO(ampetelin): Add handling of optional gRPC parameters; example links are needed.
        local grpc_service_name
        grpc_service_name=$(url_get_query_param "$url" "serviceName")

        config=$(
            sing_box_cm_set_grpc_transport_for_outbound "$config" "$outbound_tag" "$grpc_service_name"
        )
        ;;
    httpupgrade)
        local httpupgrade_path httpupgrade_host
        httpupgrade_path=$(url_get_query_param "$url" "path")
        httpupgrade_host=$(url_get_query_param "$url" "host")

        config=$(
            sing_box_cm_set_httpupgrade_transport_for_outbound "$config" "$outbound_tag" "$httpupgrade_path" "$httpupgrade_host"
        )
        ;;
    xhttp)
        local xhttp_path xhttp_host xhttp_mode xhttp_sni xhttp_extra_args xhttp_old_ifs
        local xhttp_x_padding_bytes xhttp_no_grpc_header xhttp_sc_max_each_post_bytes xhttp_sc_min_posts_interval_ms \
            xhttp_sc_stream_up_server_secs xhttp_xmux
        if ! is_sing_box_extended; then
            log "XHTTP transport requires sing-box-extended. Install sing-box-extended and retry." "error"
            echo "$config"
            return 0
        fi

        xhttp_path=$(url_get_query_param "$url" "path")
        xhttp_host=$(url_get_query_param "$url" "host")
        xhttp_sni=$(url_get_query_param "$url" "sni")
        [ -n "$xhttp_host" ] || xhttp_host="$xhttp_sni"
        xhttp_mode=$(url_get_query_param "$url" "mode")
        xhttp_extra_args="$(sing_box_cf_ucode xhttp-transport-extra "$url")"
        xhttp_old_ifs="$IFS"
        IFS="$(printf '\t')" read -r \
            xhttp_x_padding_bytes \
            xhttp_no_grpc_header \
            xhttp_sc_max_each_post_bytes \
            xhttp_sc_min_posts_interval_ms \
            xhttp_sc_stream_up_server_secs \
            xhttp_xmux <<EOF
$xhttp_extra_args
EOF
        IFS="$xhttp_old_ifs"

        config=$(
            sing_box_cm_set_xhttp_transport_for_outbound \
                "$config" \
                "$outbound_tag" \
                "$xhttp_path" \
                "$xhttp_host" \
                "$xhttp_mode" \
                "$xhttp_x_padding_bytes" \
                "$xhttp_no_grpc_header" \
                "$xhttp_sc_max_each_post_bytes" \
                "$xhttp_sc_min_posts_interval_ms" \
                "$xhttp_sc_stream_up_server_secs" \
                "$xhttp_xmux"
        )
        ;;
    *)
        log "Unknown transport '$transport' detected." "error"
        ;;
    esac

    echo "$config"
}

sing_box_cf_add_json_outbound() {
    local config="$1"
    local section="$2"
    local json_outbound="$3"

    local tag
    tag=$(get_outbound_tag_by_section "$section")

    config=$(sing_box_cm_add_raw_outbound "$config" "$tag" "$json_outbound")

    echo "$config"
}

sing_box_cf_proxy_domain() {
    local config="$1"
    local inbound="$2"
    local domain="$3"
    local outbound="$4"

    tag="$(gen_id)"
    config=$(sing_box_cm_add_route_rule "$config" "$tag" "$inbound" "$outbound")
    config=$(sing_box_cm_patch_route_rule "$config" "$tag" "domain" "$domain")

    echo "$config"
}

sing_box_cf_override_domain_port() {
    local config="$1"
    local domain="$2"
    local port="$3"

    tag="$(gen_id)"
    config=$(sing_box_cm_add_options_route_rule "$config" "$tag")
    config=$(sing_box_cm_patch_route_rule "$config" "$tag" "domain" "$domain")
    config=$(sing_box_cm_patch_route_rule "$config" "$tag" "override_port" "$port")

    echo "$config"
}

sing_box_cf_add_single_key_reject_rule() {
    local config="$1"
    local inbound="$2"
    local key="$3"
    local value="$4"

    tag="$(gen_id)"
    config=$(sing_box_cm_add_reject_route_rule "$config" "$tag" "$inbound")
    config=$(sing_box_cm_patch_route_rule "$config" "$tag" "$key" "$value")

    echo "$config"
}

sing_box_cf_subscription_candidate_outbounds() {
    local subscription_json_path="$1"

    sing_box_cf_ucode candidate-outbounds "$subscription_json_path" 2>/dev/null
}

sing_box_cf_log_subscription_skips() {
    local prepared_json="$1"
    local context="$2"
    local skipped_count reason_summary

    skipped_count="$(sing_box_cf_ucode_input skip-count "$prepared_json" 2>/dev/null)"
    case "$skipped_count" in
    '' | *[!0-9]*) return 0 ;;
    esac
    [ "$skipped_count" -gt 0 ] || return 0

    reason_summary="$(sing_box_cf_ucode_input skip-summary "$prepared_json" 2>/dev/null)"

    if [ -n "$reason_summary" ]; then
        log "Skipped $skipped_count subscription outbounds $context: $reason_summary" "warn"
    else
        log "Skipped $skipped_count subscription outbounds $context" "warn"
    fi
}

sing_box_cf_prepared_file_skip_count() {
    local prepared_path="$1"
    local skipped_count

    skipped_count="$(sing_box_cf_ucode skip-count-file "$prepared_path" 2>/dev/null)"
    case "$skipped_count" in
    '' | *[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$skipped_count" ;;
    esac
}

sing_box_cf_log_subscription_skips_file() {
    local prepared_path="$1"
    local context="$2"
    local skipped_count reason_summary

    skipped_count="$(sing_box_cf_prepared_file_skip_count "$prepared_path")"
    [ "$skipped_count" -gt 0 ] || return 0

    reason_summary="$(sing_box_cf_ucode skip-summary-file "$prepared_path" 2>/dev/null)"

    if [ -n "$reason_summary" ]; then
        log "Skipped $skipped_count subscription outbounds $context: $reason_summary" "warn"
    else
        log "Skipped $skipped_count subscription outbounds $context" "warn"
    fi
}

sing_box_cf_subscription_plugin_supports() {
    local outbounds_json="$1"
    local records_tmp plugin_name plugin_supports_json supported

    records_tmp="$(mktemp)" || return 1

    : > "$records_tmp"
    sing_box_cf_ucode_input plugin-names "$outbounds_json" 2>/dev/null |
    while IFS= read -r plugin_name || [ -n "$plugin_name" ]; do
        [ -n "$plugin_name" ] || continue
        command -v "$plugin_name" >/dev/null 2>&1 && supported=true || supported=false
        printf '%s\t%s\n' "$plugin_name" "$supported" >> "$records_tmp"
    done

    plugin_supports_json="$(sing_box_cf_ucode plugin-supports-from-records "$records_tmp" 2>/dev/null)"

    rm -f "$records_tmp"
    [ -n "$plugin_supports_json" ] || plugin_supports_json="{}"
    printf '%s\n' "$plugin_supports_json"
}

sing_box_cf_subscription_plugin_supports_file() {
    local subscription_json_path="$1"
    local records_tmp plugin_name plugin_supports_json supported

    records_tmp="$(mktemp)" || return 1

    : > "$records_tmp"
    sing_box_cf_ucode subscription-plugin-names "$subscription_json_path" 2>/dev/null |
    while IFS= read -r plugin_name || [ -n "$plugin_name" ]; do
        [ -n "$plugin_name" ] || continue
        command -v "$plugin_name" >/dev/null 2>&1 && supported=true || supported=false
        printf '%s\t%s\n' "$plugin_name" "$supported" >> "$records_tmp"
    done

    plugin_supports_json="$(sing_box_cf_ucode plugin-supports-from-records "$records_tmp" 2>/dev/null)"

    rm -f "$records_tmp"
    [ -n "$plugin_supports_json" ] || plugin_supports_json="{}"
    printf '%s\n' "$plugin_supports_json"
}

sing_box_cf_prepare_subscription_batch() {
    local config="$1"
    local outbounds_json="$2"
    local outbounds_tmp prepared_json supports_xhttp plugin_supports_json config_tmp plugin_supports_tmp prepared_tmp

    supports_xhttp=false
    if is_sing_box_extended; then
        supports_xhttp=true
    fi
    plugin_supports_json="$(sing_box_cf_subscription_plugin_supports "$outbounds_json")"
    [ -n "$plugin_supports_json" ] || plugin_supports_json="{}"

    outbounds_tmp="$(mktemp)" || return 1
    printf '%s' "$outbounds_json" > "$outbounds_tmp" || {
        rm -f "$outbounds_tmp"
        return 1
    }

    command -v ucode >/dev/null 2>&1 || {
        rm -f "$outbounds_tmp"
        return 1
    }

    config_tmp="$(mktemp)" || {
        rm -f "$outbounds_tmp"
        return 1
    }
    plugin_supports_tmp="$(mktemp)" || {
        rm -f "$outbounds_tmp" "$config_tmp"
        return 1
    }
    prepared_tmp="$(mktemp)" || {
        rm -f "$outbounds_tmp" "$config_tmp" "$plugin_supports_tmp"
        return 1
    }

    if printf '%s' "$config" > "$config_tmp" &&
        printf '%s' "$plugin_supports_json" > "$plugin_supports_tmp" &&
        sing_box_cf_ucode prepare-subscription "$config_tmp" "$outbounds_tmp" "$prepared_tmp" "$supports_xhttp" "$plugin_supports_tmp" &&
        prepared_json="$(cat "$prepared_tmp" 2>/dev/null)" &&
        [ -n "$prepared_json" ]; then
        rm -f "$outbounds_tmp" "$config_tmp" "$plugin_supports_tmp" "$prepared_tmp"
        printf '%s\n' "$prepared_json"
        return 0
    fi

    rm -f "$outbounds_tmp" "$config_tmp" "$plugin_supports_tmp" "$prepared_tmp"
    return 1
}

sing_box_cf_prepare_subscription_batch_file() {
    local config="$1"
    local subscription_json_path="$2"
    local prepared_path="$3"
    local outbounds_count_path="$4"
    local supports_xhttp plugin_supports_json config_tmp plugin_supports_tmp

    supports_xhttp=false
    if is_sing_box_extended; then
        supports_xhttp=true
    fi
    plugin_supports_json="$(sing_box_cf_subscription_plugin_supports_file "$subscription_json_path")"
    [ -n "$plugin_supports_json" ] || plugin_supports_json="{}"

    command -v ucode >/dev/null 2>&1 || return 1

    config_tmp="$(mktemp)" || return 1
    plugin_supports_tmp="$(mktemp)" || {
        rm -f "$config_tmp"
        return 1
    }

    if printf '%s' "$config" > "$config_tmp" &&
        printf '%s' "$plugin_supports_json" > "$plugin_supports_tmp" &&
        sing_box_cf_ucode prepare-subscription-file \
            "$config_tmp" \
            "$subscription_json_path" \
            "$prepared_path" \
            "$outbounds_count_path" \
            "$supports_xhttp" \
            "$plugin_supports_tmp"; then
        rm -f "$config_tmp" "$plugin_supports_tmp"
        return 0
    fi

    rm -f "$config_tmp" "$plugin_supports_tmp"
    return 1
}

sing_box_cf_validation_error_summary() {
    local output="$1"
    local summary

    summary="$(sing_box_cf_ucode_input validation-error-summary "$output" 2>/dev/null)"
    [ -n "$summary" ] || summary="sing-box check failed"
    printf '%s\n' "$summary"
}

sing_box_cf_try_subscription_outbounds_batch_file() {
    local config="$1"
    local new_outbounds_tmp="$2"
    local updated_tmp validation_tmp check_tmp validation_config check_output

    SING_BOX_CF_VALIDATED_CONFIG=""
    SING_BOX_CF_VALIDATION_ERROR=""

    updated_tmp="$(mktemp)" || {
        return 1
    }
    validation_tmp="$(mktemp)" || {
        rm -f "$updated_tmp"
        return 1
    }
    check_tmp="$(mktemp)" || {
        rm -f "$updated_tmp" "$validation_tmp"
        return 1
    }

    if ! sing_box_cf_ucode_input prepare-validation "$config" "$new_outbounds_tmp" "$updated_tmp" "$validation_tmp"; then
        rm -f "$updated_tmp" "$validation_tmp" "$check_tmp"
        return 1
    fi

    validation_config="$(cat "$validation_tmp" 2>/dev/null)" || validation_config=""
    [ -n "$validation_config" ] || {
        rm -f "$updated_tmp" "$validation_tmp" "$check_tmp"
        return 1
    }

    sing_box_cm_save_config_to_file "$validation_config" "$check_tmp"
    if ! check_output="$(sing-box -c "$check_tmp" check 2>&1)"; then
        SING_BOX_CF_VALIDATION_ERROR="$(sing_box_cf_validation_error_summary "$check_output")"
        rm -f "$updated_tmp" "$validation_tmp" "$check_tmp"
        return 1
    fi

    SING_BOX_CF_VALIDATED_CONFIG="$(cat "$updated_tmp" 2>/dev/null)"
    rm -f "$updated_tmp" "$validation_tmp" "$check_tmp"
    [ -n "$SING_BOX_CF_VALIDATED_CONFIG" ] || return 1
    return 0
}

sing_box_cf_try_subscription_outbounds_batch() {
    local config="$1"
    local new_outbounds="$2"
    local new_outbounds_tmp status

    new_outbounds_tmp="$(mktemp)" || return 1
    if ! printf '%s' "$new_outbounds" > "$new_outbounds_tmp"; then
        rm -f "$new_outbounds_tmp"
        return 1
    fi

    sing_box_cf_try_subscription_outbounds_batch_file "$config" "$new_outbounds_tmp"
    status=$?
    rm -f "$new_outbounds_tmp"
    return "$status"
}

sing_box_cf_subscription_prepared_slice() {
    local prepared_json="$1"
    local start="$2"
    local end="$3"

    sing_box_cf_ucode_input prepared-slice "$prepared_json" "$start" "$end" 2>/dev/null
}

sing_box_cf_prepared_visible_count() {
    local prepared_json="$1"
    local count

    count="$(sing_box_cf_ucode_input prepared-visible-count "$prepared_json" 2>/dev/null)"
    case "$count" in
    '' | *[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$count" ;;
    esac
}

sing_box_cf_prepared_field_to_file() {
    local prepared_json="$1"
    local field="$2"
    local output_path="$3"
    local count_path="${4:-}"

    printf '%s' "$prepared_json" |
        ucode "$PODKOP_LIB/sing_box_config_facade.uc" prepared-field-to-file "$field" "$output_path" "$count_path"
}

sing_box_cf_load_prepared_state() {
    local prepared_json="$1"
    local source_section="${2:-$SING_BOX_CF_SOURCE_SECTION}"
    local tags_tmp tags_csv_tmp names_lines_tmp link_refs_tmp names_tmp servers_tmp status

    tags_tmp="$(mktemp)" || return 1
    tags_csv_tmp="$(mktemp)" || {
        rm -f "$tags_tmp"
        return 1
    }
    names_lines_tmp="$(mktemp)" || {
        rm -f "$tags_tmp" "$tags_csv_tmp"
        return 1
    }
    link_refs_tmp="$(mktemp)" || {
        rm -f "$tags_tmp" "$tags_csv_tmp" "$names_lines_tmp"
        return 1
    }
    names_tmp="$(mktemp)" || {
        rm -f "$tags_tmp" "$tags_csv_tmp" "$names_lines_tmp" "$link_refs_tmp"
        return 1
    }
    servers_tmp="$(mktemp)" || {
        rm -f "$tags_tmp" "$tags_csv_tmp" "$names_lines_tmp" "$link_refs_tmp" "$names_tmp"
        return 1
    }

    status=1
    if printf '%s' "$prepared_json" |
        ucode "$PODKOP_LIB/sing_box_config_facade.uc" prepared-state-to-files "$source_section" \
            "$tags_tmp" "$tags_csv_tmp" "$names_lines_tmp" "$link_refs_tmp" "$names_tmp" "$servers_tmp"; then
        IFS= read -r SUBSCRIPTION_OUTBOUND_TAGS_JSON < "$tags_tmp" || SUBSCRIPTION_OUTBOUND_TAGS_JSON=""
        [ -n "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" ] || SUBSCRIPTION_OUTBOUND_TAGS_JSON="[]"
        IFS= read -r SUBSCRIPTION_OUTBOUND_TAGS < "$tags_csv_tmp" || SUBSCRIPTION_OUTBOUND_TAGS=""
        SUBSCRIPTION_OUTBOUND_NAMES="$(cat "$names_lines_tmp" 2>/dev/null)"
        IFS= read -r SUBSCRIPTION_OUTBOUND_LINK_REFS_JSON < "$link_refs_tmp" || SUBSCRIPTION_OUTBOUND_LINK_REFS_JSON=""
        [ -n "$SUBSCRIPTION_OUTBOUND_LINK_REFS_JSON" ] || SUBSCRIPTION_OUTBOUND_LINK_REFS_JSON="{}"
        IFS= read -r SUBSCRIPTION_OUTBOUND_NAMES_JSON < "$names_tmp" || SUBSCRIPTION_OUTBOUND_NAMES_JSON=""
        [ -n "$SUBSCRIPTION_OUTBOUND_NAMES_JSON" ] || SUBSCRIPTION_OUTBOUND_NAMES_JSON="{}"
        IFS= read -r SUBSCRIPTION_OUTBOUND_SERVERS_JSON < "$servers_tmp" || SUBSCRIPTION_OUTBOUND_SERVERS_JSON=""
        [ -n "$SUBSCRIPTION_OUTBOUND_SERVERS_JSON" ] || SUBSCRIPTION_OUTBOUND_SERVERS_JSON="{}"
        status=0
    fi

    rm -f "$tags_tmp" "$tags_csv_tmp" "$names_lines_tmp" "$link_refs_tmp" "$names_tmp" "$servers_tmp"
    return "$status"
}

sing_box_cf_read_prepared_state_files() {
    local tags_tmp="$1"
    local tags_csv_tmp="$2"
    local names_lines_tmp="$3"
    local link_refs_tmp="$4"
    local names_tmp="$5"
    local servers_tmp="$6"

    IFS= read -r SUBSCRIPTION_OUTBOUND_TAGS_JSON < "$tags_tmp" || SUBSCRIPTION_OUTBOUND_TAGS_JSON=""
    [ -n "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" ] || SUBSCRIPTION_OUTBOUND_TAGS_JSON="[]"
    IFS= read -r SUBSCRIPTION_OUTBOUND_TAGS < "$tags_csv_tmp" || SUBSCRIPTION_OUTBOUND_TAGS=""
    SUBSCRIPTION_OUTBOUND_NAMES="$(cat "$names_lines_tmp" 2>/dev/null)"
    IFS= read -r SUBSCRIPTION_OUTBOUND_LINK_REFS_JSON < "$link_refs_tmp" || SUBSCRIPTION_OUTBOUND_LINK_REFS_JSON=""
    [ -n "$SUBSCRIPTION_OUTBOUND_LINK_REFS_JSON" ] || SUBSCRIPTION_OUTBOUND_LINK_REFS_JSON="{}"
    IFS= read -r SUBSCRIPTION_OUTBOUND_NAMES_JSON < "$names_tmp" || SUBSCRIPTION_OUTBOUND_NAMES_JSON=""
    [ -n "$SUBSCRIPTION_OUTBOUND_NAMES_JSON" ] || SUBSCRIPTION_OUTBOUND_NAMES_JSON="{}"
    IFS= read -r SUBSCRIPTION_OUTBOUND_SERVERS_JSON < "$servers_tmp" || SUBSCRIPTION_OUTBOUND_SERVERS_JSON=""
    [ -n "$SUBSCRIPTION_OUTBOUND_SERVERS_JSON" ] || SUBSCRIPTION_OUTBOUND_SERVERS_JSON="{}"
}

sing_box_cf_append_subscription_prepared_metadata() {
    local prepared_json="$1"
    local tags_tmp names_lines_tmp link_refs_tmp names_tmp servers_tmp status

    tags_tmp="$(mktemp)" || return 1
    names_lines_tmp="$(mktemp)" || {
        rm -f "$tags_tmp"
        return 1
    }
    link_refs_tmp="$(mktemp)" || {
        rm -f "$tags_tmp" "$names_lines_tmp"
        return 1
    }
    names_tmp="$(mktemp)" || {
        rm -f "$tags_tmp" "$names_lines_tmp" "$link_refs_tmp"
        return 1
    }
    servers_tmp="$(mktemp)" || {
        rm -f "$tags_tmp" "$names_lines_tmp" "$link_refs_tmp" "$names_tmp"
        return 1
    }

    status=1
    [ -n "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" ] || SUBSCRIPTION_OUTBOUND_TAGS_JSON="[]"
    [ -n "$SUBSCRIPTION_OUTBOUND_LINK_REFS_JSON" ] || SUBSCRIPTION_OUTBOUND_LINK_REFS_JSON="{}"
    [ -n "$SUBSCRIPTION_OUTBOUND_NAMES_JSON" ] || SUBSCRIPTION_OUTBOUND_NAMES_JSON="{}"
    [ -n "$SUBSCRIPTION_OUTBOUND_SERVERS_JSON" ] || SUBSCRIPTION_OUTBOUND_SERVERS_JSON="{}"

    if printf '%s' "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" > "$tags_tmp" &&
        printf '%s' "$SUBSCRIPTION_OUTBOUND_NAMES" > "$names_lines_tmp" &&
        printf '%s' "$SUBSCRIPTION_OUTBOUND_LINK_REFS_JSON" > "$link_refs_tmp" &&
        printf '%s' "$SUBSCRIPTION_OUTBOUND_NAMES_JSON" > "$names_tmp" &&
        printf '%s' "$SUBSCRIPTION_OUTBOUND_SERVERS_JSON" > "$servers_tmp" &&
        printf '%s' "$prepared_json" |
            ucode "$PODKOP_LIB/sing_box_config_facade.uc" append-prepared-state-to-files "$SING_BOX_CF_SOURCE_SECTION" \
                "$tags_tmp" "$names_lines_tmp" "$link_refs_tmp" "$names_tmp" "$servers_tmp"; then
        IFS= read -r SUBSCRIPTION_OUTBOUND_TAGS_JSON < "$tags_tmp" || SUBSCRIPTION_OUTBOUND_TAGS_JSON=""
        [ -n "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" ] || SUBSCRIPTION_OUTBOUND_TAGS_JSON="[]"
        SUBSCRIPTION_OUTBOUND_NAMES="$(cat "$names_lines_tmp" 2>/dev/null)"
        IFS= read -r SUBSCRIPTION_OUTBOUND_LINK_REFS_JSON < "$link_refs_tmp" || SUBSCRIPTION_OUTBOUND_LINK_REFS_JSON=""
        [ -n "$SUBSCRIPTION_OUTBOUND_LINK_REFS_JSON" ] || SUBSCRIPTION_OUTBOUND_LINK_REFS_JSON="{}"
        IFS= read -r SUBSCRIPTION_OUTBOUND_NAMES_JSON < "$names_tmp" || SUBSCRIPTION_OUTBOUND_NAMES_JSON=""
        [ -n "$SUBSCRIPTION_OUTBOUND_NAMES_JSON" ] || SUBSCRIPTION_OUTBOUND_NAMES_JSON="{}"
        IFS= read -r SUBSCRIPTION_OUTBOUND_SERVERS_JSON < "$servers_tmp" || SUBSCRIPTION_OUTBOUND_SERVERS_JSON=""
        [ -n "$SUBSCRIPTION_OUTBOUND_SERVERS_JSON" ] || SUBSCRIPTION_OUTBOUND_SERVERS_JSON="{}"
        status=0
    fi

    rm -f "$tags_tmp" "$names_lines_tmp" "$link_refs_tmp" "$names_tmp" "$servers_tmp"
    return "$status"
}

sing_box_cf_apply_subscription_batch() {
    local config="$1"
    local prepared_json="$2"
    local tmpdir new_outbounds_tmp new_outbounds_count_tmp new_outbounds_count \
        tags_tmp tags_csv_tmp names_lines_tmp link_refs_tmp names_tmp servers_tmp

    tmpdir="$(mktemp -d)" || return 1
    new_outbounds_tmp="$tmpdir/outbounds.json"
    new_outbounds_count_tmp="$tmpdir/outbounds.count"
    tags_tmp="$tmpdir/tags.json"
    tags_csv_tmp="$tmpdir/tags.csv"
    names_lines_tmp="$tmpdir/names.lines"
    link_refs_tmp="$tmpdir/link-refs.json"
    names_tmp="$tmpdir/names.json"
    servers_tmp="$tmpdir/servers.json"

    if ! printf '%s' "$prepared_json" |
        ucode "$PODKOP_LIB/sing_box_config_facade.uc" prepared-outbounds-state-to-files "$SING_BOX_CF_SOURCE_SECTION" \
            "$new_outbounds_tmp" "$new_outbounds_count_tmp" \
            "$tags_tmp" "$tags_csv_tmp" "$names_lines_tmp" "$link_refs_tmp" "$names_tmp" "$servers_tmp"; then
        rm -rf "$tmpdir"
        return 1
    fi

    new_outbounds_count="$(cat "$new_outbounds_count_tmp" 2>/dev/null)"
    case "$new_outbounds_count" in
    '' | *[!0-9]*)
        rm -rf "$tmpdir"
        return 1
        ;;
    esac
    if [ "$new_outbounds_count" -eq 0 ]; then
        rm -rf "$tmpdir"
        return 1
    fi

    if ! sing_box_cf_try_subscription_outbounds_batch_file "$config" "$new_outbounds_tmp"; then
        rm -rf "$tmpdir"
        return 1
    fi

    sing_box_cf_read_prepared_state_files "$tags_tmp" "$tags_csv_tmp" "$names_lines_tmp" "$link_refs_tmp" "$names_tmp" "$servers_tmp"
    SUBSCRIPTION_OUTBOUND_COUNT="$(sing_box_cf_tags_json_count "$SUBSCRIPTION_OUTBOUND_TAGS_JSON")"
    if [ "${SUBSCRIPTION_OUTBOUND_COUNT:-0}" -le 0 ]; then
        rm -rf "$tmpdir"
        return 1
    fi
    SING_BOX_CF_LAST_CONFIG="$SING_BOX_CF_VALIDATED_CONFIG"
    rm -rf "$tmpdir"

    return 0
}

sing_box_cf_apply_subscription_batch_file() {
    local config="$1"
    local prepared_path="$2"
    local tmpdir new_outbounds_tmp new_outbounds_count_tmp new_outbounds_count \
        tags_tmp tags_csv_tmp names_lines_tmp link_refs_tmp names_tmp servers_tmp

    tmpdir="$(mktemp -d)" || return 1
    new_outbounds_tmp="$tmpdir/outbounds.json"
    new_outbounds_count_tmp="$tmpdir/outbounds.count"
    tags_tmp="$tmpdir/tags.json"
    tags_csv_tmp="$tmpdir/tags.csv"
    names_lines_tmp="$tmpdir/names.lines"
    link_refs_tmp="$tmpdir/link-refs.json"
    names_tmp="$tmpdir/names.json"
    servers_tmp="$tmpdir/servers.json"

    if ! ucode "$PODKOP_LIB/sing_box_config_facade.uc" prepared-outbounds-state-file-to-files \
        "$prepared_path" "$SING_BOX_CF_SOURCE_SECTION" \
        "$new_outbounds_tmp" "$new_outbounds_count_tmp" \
        "$tags_tmp" "$tags_csv_tmp" "$names_lines_tmp" "$link_refs_tmp" "$names_tmp" "$servers_tmp"; then
        rm -rf "$tmpdir"
        return 1
    fi

    new_outbounds_count="$(cat "$new_outbounds_count_tmp" 2>/dev/null)"
    case "$new_outbounds_count" in
    '' | *[!0-9]*)
        rm -rf "$tmpdir"
        return 1
        ;;
    esac
    if [ "$new_outbounds_count" -eq 0 ]; then
        rm -rf "$tmpdir"
        return 1
    fi

    if ! sing_box_cf_try_subscription_outbounds_batch_file "$config" "$new_outbounds_tmp"; then
        rm -rf "$tmpdir"
        return 1
    fi

    sing_box_cf_read_prepared_state_files "$tags_tmp" "$tags_csv_tmp" "$names_lines_tmp" "$link_refs_tmp" "$names_tmp" "$servers_tmp"
    SUBSCRIPTION_OUTBOUND_COUNT="$(sing_box_cf_tags_json_count "$SUBSCRIPTION_OUTBOUND_TAGS_JSON")"
    if [ "${SUBSCRIPTION_OUTBOUND_COUNT:-0}" -le 0 ]; then
        rm -rf "$tmpdir"
        return 1
    fi
    SING_BOX_CF_LAST_CONFIG="$SING_BOX_CF_VALIDATED_CONFIG"
    rm -rf "$tmpdir"

    return 0
}

sing_box_cf_apply_subscription_outbounds_range() {
    local start="$1"
    local count="$2"
    local end chunk outbounds_json display_name half rest index visible_count

    [ "$count" -gt 0 ] || return 0

    end=$((start + count))
    chunk="$(sing_box_cf_subscription_prepared_slice "$SING_BOX_CF_FALLBACK_PREPARED_JSON" "$start" "$end")" || {
        SING_BOX_CF_FALLBACK_SKIPPED_COUNT=$((SING_BOX_CF_FALLBACK_SKIPPED_COUNT + count))
        return 0
    }

    outbounds_json="$(sing_box_cf_ucode_input prepared-field "$chunk" outbounds 2>/dev/null)"
    [ -n "$outbounds_json" ] || {
        SING_BOX_CF_FALLBACK_SKIPPED_COUNT=$((SING_BOX_CF_FALLBACK_SKIPPED_COUNT + count))
        return 0
    }

    if sing_box_cf_try_subscription_outbounds_batch "$SING_BOX_CF_FALLBACK_WORKING_CONFIG" "$outbounds_json"; then
        SING_BOX_CF_FALLBACK_WORKING_CONFIG="$SING_BOX_CF_VALIDATED_CONFIG"
        if ! sing_box_cf_append_subscription_prepared_metadata "$chunk"; then
            log "Failed to append subscription metadata for rule '$SING_BOX_CF_SOURCE_SECTION'. Aborted." "fatal"
            exit 1
        fi
        visible_count="$(sing_box_cf_prepared_visible_count "$chunk")"
        SING_BOX_CF_FALLBACK_ADDED_COUNT=$((SING_BOX_CF_FALLBACK_ADDED_COUNT + visible_count))
        return 0
    fi

    if [ "$count" -eq 1 ]; then
        display_name="$(sing_box_cf_ucode_input prepared-display-name "$chunk" 2>/dev/null)"
        [ -n "$display_name" ] || display_name="unknown"
        [ -n "$SING_BOX_CF_VALIDATION_ERROR" ] || SING_BOX_CF_VALIDATION_ERROR="sing-box check failed"
        log "Skipped unsupported subscription outbound '$display_name': $SING_BOX_CF_VALIDATION_ERROR" "warn"
        SING_BOX_CF_FALLBACK_SKIPPED_COUNT=$((SING_BOX_CF_FALLBACK_SKIPPED_COUNT + 1))
        return 0
    fi

    if [ "$count" -le 8 ]; then
        index=0
        while [ "$index" -lt "$count" ]; do
            sing_box_cf_apply_subscription_outbounds_range $((start + index)) 1
            index=$((index + 1))
        done
        return 0
    fi

    half=$((count / 2))
    [ "$half" -gt 0 ] || half=1
    rest=$((count - half))

    sing_box_cf_apply_subscription_outbounds_range "$start" "$half"
    sing_box_cf_apply_subscription_outbounds_range $((start + half)) "$rest"
}

sing_box_cf_apply_subscription_outbounds_chunked() {
    local config="$1"
    local prepared_json="$2"
    local outbounds_count half rest

    outbounds_count="$(sing_box_cf_ucode_input prepared-length "$prepared_json" outbounds 2>/dev/null)"
    [ -n "$outbounds_count" ] || return 1
    [ "$outbounds_count" -gt 0 ] || return 1

    SING_BOX_CF_FALLBACK_WORKING_CONFIG="$config"
    SING_BOX_CF_FALLBACK_PREPARED_JSON="$prepared_json"
    SING_BOX_CF_FALLBACK_ADDED_COUNT=0
    SING_BOX_CF_FALLBACK_SKIPPED_COUNT=0
    SUBSCRIPTION_OUTBOUND_TAGS_JSON="[]"
    SUBSCRIPTION_OUTBOUND_LINK_REFS_JSON="{}"
    SUBSCRIPTION_OUTBOUND_NAMES_JSON="{}"
    SUBSCRIPTION_OUTBOUND_SERVERS_JSON="{}"
    SUBSCRIPTION_OUTBOUND_NAMES=""
    SUBSCRIPTION_OUTBOUND_COUNT=0

    if [ "$outbounds_count" -le 8 ]; then
        sing_box_cf_apply_subscription_outbounds_range 0 "$outbounds_count"
    else
        half=$((outbounds_count / 2))
        [ "$half" -gt 0 ] || half=1
        rest=$((outbounds_count - half))
        sing_box_cf_apply_subscription_outbounds_range 0 "$half"
        sing_box_cf_apply_subscription_outbounds_range "$half" "$rest"
    fi

    if [ "$SING_BOX_CF_FALLBACK_ADDED_COUNT" -eq 0 ]; then
        return 1
    fi

    if [ "$SING_BOX_CF_FALLBACK_SKIPPED_COUNT" -gt 0 ]; then
        log "Skipped $SING_BOX_CF_FALLBACK_SKIPPED_COUNT unsupported subscription outbounds during chunked fallback validation" "warn"
    fi

    SUBSCRIPTION_OUTBOUND_TAGS="$(sing_box_cf_tags_json_csv "$SUBSCRIPTION_OUTBOUND_TAGS_JSON")"
    SUBSCRIPTION_OUTBOUND_COUNT="$SING_BOX_CF_FALLBACK_ADDED_COUNT"
    SING_BOX_CF_LAST_CONFIG="$SING_BOX_CF_FALLBACK_WORKING_CONFIG"

    return 0
}

sing_box_cf_add_subscription_outbounds() {
    local config="$1"
    local section="$2"
    local subscription_json_path="$3"
    local source_section="${4:-}"
    local tmpdir prepared_tmp outbounds_count_tmp outbounds_count prepared_json skipped_count

    SUBSCRIPTION_OUTBOUND_TAGS=""
    SUBSCRIPTION_OUTBOUND_TAGS_JSON="[]"
    SUBSCRIPTION_OUTBOUND_LINK_REFS_JSON="{}"
    SUBSCRIPTION_OUTBOUND_NAMES_JSON="{}"
    SUBSCRIPTION_OUTBOUND_SERVERS_JSON="{}"
    SUBSCRIPTION_OUTBOUND_NAMES=""
    SUBSCRIPTION_OUTBOUND_COUNT=0
    SING_BOX_CF_SOURCE_SECTION="$source_section"
    SING_BOX_CF_LAST_CONFIG="$config"

    if [ ! -f "$subscription_json_path" ]; then
        log "Subscription JSON file not found: $subscription_json_path" "error"
        echo "$config"
        return 1
    fi

    tmpdir="$(mktemp -d)" || {
        echo "$config"
        return 1
    }
    prepared_tmp="$tmpdir/prepared.json"
    outbounds_count_tmp="$tmpdir/outbounds.count"

    if ! sing_box_cf_prepare_subscription_batch_file "$config" "$subscription_json_path" "$prepared_tmp" "$outbounds_count_tmp"; then
        rm -rf "$tmpdir"
        echo "$config"
        return 1
    fi

    outbounds_count="$(cat "$outbounds_count_tmp" 2>/dev/null)"
    case "$outbounds_count" in
    '' | *[!0-9]*)
        rm -rf "$tmpdir"
        echo "$config"
        return 1
        ;;
    esac
    if [ "$outbounds_count" -eq 0 ]; then
        log "No proxy outbounds found in subscription JSON" "error"
        rm -rf "$tmpdir"
        echo "$config"
        return 1
    fi

    log "Found $outbounds_count proxy outbounds in subscription" "info"

    skipped_count="$(sing_box_cf_prepared_file_skip_count "$prepared_tmp")"
    if [ "${skipped_count:-0}" -gt 0 ]; then
        sing_box_cf_log_subscription_skips_file "$prepared_tmp" "before validation"
    fi

    if sing_box_cf_apply_subscription_batch_file "$config" "$prepared_tmp"; then
        log "Added $(sing_box_cf_subscription_outbound_count) subscription outbounds for rule '$section'" "info"
        rm -rf "$tmpdir"
        echo "$SING_BOX_CF_LAST_CONFIG"
        return 0
    fi

    log "Batch subscription validation failed for rule '$section', trying chunked fallback validation" "warn"
    prepared_json="$(cat "$prepared_tmp" 2>/dev/null)" || prepared_json=""
    rm -rf "$tmpdir"
    if [ -n "$prepared_json" ] && sing_box_cf_apply_subscription_outbounds_chunked "$config" "$prepared_json"; then
        log "Added $(sing_box_cf_subscription_outbound_count) subscription outbounds for rule '$section'" "info"
        echo "$SING_BOX_CF_LAST_CONFIG"
        return 0
    fi

    log "No valid subscription outbounds remained after validation for rule '$section'" "error"

    echo "$config"
    return 1
}
