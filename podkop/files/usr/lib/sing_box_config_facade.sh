PODKOP_LIB="/usr/lib/podkop-plus"
. "$PODKOP_LIB/helpers.sh"
. "$PODKOP_LIB/sing_box_config_manager.sh"

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

    config=$(sing_box_cm_add_mixed_inbound "$config" "$tag" "$listen_address" "$listen_port")
    config=$(sing_box_cm_add_route_rule "$config" "" "$tag" "$outbound")

    echo "$config"
}

sing_box_cf_add_proxy_outbound() {
    local config="$1"
    local section="$2"
    local url="$3"
    local udp_over_tcp="$4"

    url=$(url_decode "$url")
    url=$(url_strip_fragment "$url")

    local scheme
    scheme="$(url_get_scheme "$url")"
    case "$scheme" in
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
            "$([ "$udp_over_tcp" == "1" ] && echo 2)" # if udp_over_tcp is enabled, enable version 2
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
    ss)
        local userinfo tag host port method password udp_over_tcp

        userinfo=$(url_get_userinfo "$url")
        if ! is_shadowsocks_userinfo_format "$userinfo"; then
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
                "$([ "$udp_over_tcp" == "1" ] && echo 2)" # if udp_over_tcp is enabled, enable version 2
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
        local tag host port password obfuscator_type obfuscator_password upload_mbps download_mbps
        tag=$(get_outbound_tag_by_section "$section")
        host=$(url_get_host "$url")
        port="$(url_get_port "$url")"
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
    security=$(url_get_query_param "$url" "security")
    if [ -z "$security" ]; then
        scheme="$(url_get_scheme "$url")"
        if [ "$scheme" = "hysteria2" ] || [ "$scheme" = "hy2" ]; then
            security="tls"
        fi
    fi

    case "$security" in
    tls | reality)
        local sni insecure alpn fingerprint public_key short_id
        sni=$(url_get_query_param "$url" "sni")
        insecure=$(_get_insecure_query_param_from_url "$url")
        alpn=$(comma_string_to_json_array "$(url_get_query_param "$url" "alpn")")
        if [ "$alpn" = "[]" ] && [ "$(url_get_query_param "$url" "type")" = "xhttp" ]; then
            alpn='["h2","http/1.1"]'
        fi
        fingerprint=$(url_get_query_param "$url" "fp")
        public_key=$(url_get_query_param "$url" "pbk")
        short_id=$(url_get_query_param "$url" "sid")

        config=$(
            sing_box_cm_set_tls_for_outbound \
                "$config" \
                "$outbound_tag" \
                "$sni" \
                "$([ "$insecure" == "1" ] && echo true)" \
                "$([ "$alpn" == "[]" ] && echo null || echo "$alpn")" \
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
        http_hosts=$(comma_string_to_json_array "$(url_get_query_param "$url" "host")")

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
        local xhttp_path xhttp_host xhttp_mode xhttp_sni
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

        config=$(
            sing_box_cm_set_xhttp_transport_for_outbound "$config" "$outbound_tag" "$xhttp_path" "$xhttp_host" "$xhttp_mode"
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

sing_box_cf_add_interface_outbound() {
    local config="$1"
    local section="$2"
    local interface_name="$3"

    local tag
    tag=$(get_outbound_tag_by_section "$section")

    config=$(sing_box_cm_add_interface_outbound "$config" "$tag" "$interface_name")

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

    jq -c '[.outbounds[]? | select(
        type == "object" and
        .type != "selector" and
        .type != "urltest" and
        .type != "direct" and
        .type != "dns" and
        .type != "block"
    )]' "$subscription_json_path" 2>/dev/null
}

sing_box_cf_log_subscription_skips() {
    local prepared_json="$1"
    local context="$2"
    local skipped_count index display_name reason

    skipped_count="$(printf '%s' "$prepared_json" | jq -r '(.skipped_names // []) | length' 2>/dev/null)"
    [ -n "$skipped_count" ] || return 0

    index=0
    while [ "$index" -lt "$skipped_count" ]; do
        display_name="$(printf '%s' "$prepared_json" |
            jq -r --argjson index "$index" '(.skipped_names[$index] // "unknown") | tostring' 2>/dev/null |
            tr '\r\n\t' '   ' |
            sed 's/[[:space:]][[:space:]]*/ /g;s/^[[:space:]]*//;s/[[:space:]]*$//')"
        reason="$(printf '%s' "$prepared_json" |
            jq -r --argjson index "$index" '(.skipped_reasons[$index] // "unsupported or invalid outbound") | tostring' 2>/dev/null |
            tr '\r\n\t' '   ' |
            sed 's/[[:space:]][[:space:]]*/ /g;s/^[[:space:]]*//;s/[[:space:]]*$//')"
        log "Skipped subscription outbound '$display_name' $context: $reason" "warn"
        index=$((index + 1))
    done
}

sing_box_cf_subscription_plugin_supports() {
    local outbounds_json="$1"
    local plugin plugin_name plugin_supports_json supported

    plugin_supports_json="{}"
    while IFS= read -r plugin || [ -n "$plugin" ]; do
        [ -n "$plugin" ] || continue
        plugin_name="${plugin%%;*}"
        [ -n "$plugin_name" ] || continue

        if command -v "$plugin_name" >/dev/null 2>&1; then
            supported=true
        else
            supported=false
        fi

        plugin_supports_json="$(printf '%s' "$plugin_supports_json" |
            jq -c --arg plugin "$plugin_name" --argjson supported "$supported" '.[$plugin] = $supported' 2>/dev/null)"
        [ -n "$plugin_supports_json" ] || plugin_supports_json="{}"
    done <<EOF
$(printf '%s' "$outbounds_json" | jq -r '.[]? | select(.type == "shadowsocks") | .plugin // empty' 2>/dev/null)
EOF

    printf '%s\n' "$plugin_supports_json"
}

sing_box_cf_prepare_subscription_batch() {
    local config="$1"
    local outbounds_json="$2"
    local existing_tags_json existing_tags_tmp outbounds_tmp prepared_json jq_status supports_xhttp plugin_supports_json

    supports_xhttp=false
    if is_sing_box_extended; then
        supports_xhttp=true
    fi
    plugin_supports_json="$(sing_box_cf_subscription_plugin_supports "$outbounds_json")"
    [ -n "$plugin_supports_json" ] || plugin_supports_json="{}"

    existing_tags_json="$(printf '%s' "$config" | jq -c '[.outbounds[]?.tag // empty]' 2>/dev/null)"
    [ -n "$existing_tags_json" ] || existing_tags_json="[]"

    existing_tags_tmp="$(mktemp)" || return 1
    outbounds_tmp="$(mktemp)" || {
        rm -f "$existing_tags_tmp"
        return 1
    }

    printf '%s' "$existing_tags_json" > "$existing_tags_tmp" || {
        rm -f "$existing_tags_tmp" "$outbounds_tmp"
        return 1
    }
    printf '%s' "$outbounds_json" > "$outbounds_tmp" || {
        rm -f "$existing_tags_tmp" "$outbounds_tmp"
        return 1
    }

    prepared_json="$(jq -c --slurpfile existing_tags "$existing_tags_tmp" \
        --argjson supports_xhttp "$supports_xhttp" \
        --argjson plugin_supports "$plugin_supports_json" '
        ($existing_tags[0] // []) as $existing_tags
        |
        def safe_string($value; $fallback):
            (($value // $fallback) | tostring) as $result
            | if $result == "" or $result == "null" then $fallback else $result end;

        def non_empty_string($value):
            ($value | type) == "string" and $value != "";

        def valid_server($outbound):
            non_empty_string($outbound.server // null);

        def valid_server_port($outbound):
            ($outbound.server_port | type) == "number" and
            (($outbound.server_port | floor) == $outbound.server_port) and
            $outbound.server_port >= 1 and
            $outbound.server_port <= 65535;

        def type_requires_server($type):
            ["vless", "vmess", "trojan", "shadowsocks", "socks", "hysteria2"] | index($type) != null;

        def supported_flow($flow):
            ($flow == null) or ($flow == "") or ($flow == "xtls-rprx-vision");

        def supported_transport_type($transport):
            ["http", "ws", "quic", "grpc", "httpupgrade", "xhttp", "kcp"] | index($transport) != null;

        def supported_shadowsocks_method($method):
            [
                "none",
                "aes-128-gcm", "aes-192-gcm", "aes-256-gcm",
                "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
                "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
                "aes-128-cfb", "aes-192-cfb", "aes-256-cfb",
                "aes-128-ctr", "aes-192-ctr", "aes-256-ctr",
                "chacha20", "chacha20-ietf", "xchacha20",
                "salsa20", "rc4-md5"
            ] | index($method) != null;

        def reality_enabled($outbound):
            ($outbound.tls.reality? | type) == "object" and (($outbound.tls.reality.enabled // true) == true);

        def plugin_name($plugin):
            ($plugin | tostring | split(";")[0]);

        def prefilter_skip_reason($outbound):
            ($outbound.type // "" | tostring) as $type
            | if $type == "" then
                "missing outbound type"
              elif ($outbound.type != ($outbound.type | tostring)) then
                "outbound type must be a string"
              elif type_requires_server($type) and (valid_server($outbound) | not) then
                "missing or empty server"
              elif type_requires_server($type) and (valid_server_port($outbound) | not) then
                "missing or invalid server_port"
              elif ($type == "vless" or $type == "vmess") and (non_empty_string($outbound.uuid // null) | not) then
                "missing uuid"
              elif ($type == "trojan" or $type == "hysteria2") and (non_empty_string($outbound.password // null) | not) then
                "missing password"
              elif $type == "shadowsocks" and (non_empty_string($outbound.method // null) | not) then
                "missing shadowsocks method"
              elif $type == "shadowsocks" and (non_empty_string($outbound.password // null) | not) then
                "missing shadowsocks password"
              elif $type == "shadowsocks" and (supported_shadowsocks_method($outbound.method) | not) then
                "unsupported shadowsocks method: \($outbound.method)"
              elif $type == "shadowsocks" and non_empty_string($outbound.plugin // null) and (($plugin_supports[plugin_name($outbound.plugin)] // false) | not) then
                "shadowsocks plugin is not installed: \(plugin_name($outbound.plugin))"
              elif reality_enabled($outbound) and (non_empty_string($outbound.tls.reality.public_key // null) | not) then
                "reality public_key is missing"
              elif ($type == "vless") and (supported_flow($outbound.flow // "") | not) then
                "unsupported vless flow: \($outbound.flow)"
              elif (($outbound.transport? | type) == "object") and (($outbound.transport.type // "" | tostring) == "") then
                "missing transport type"
              elif (($outbound.transport? | type) == "object") and (supported_transport_type(($outbound.transport.type // "") | tostring) | not) then
                "unknown transport type: \($outbound.transport.type)"
              elif (($outbound.transport? | type) == "object") and (($outbound.transport.type // "" | tostring) == "xhttp") and ($supports_xhttp | not) then
                "transport xhttp requires sing-box-extended"
              elif ($type == "shadowsocks" and (($outbound.tls.enabled // false) == true)) then
                "shadowsocks with TLS is not supported"
              else
                ""
              end;

        def unique_tag($base; $taken):
            if (($taken[$base] // false) | not) then
                $base
            else
                first(range(1; 100000) as $n
                    | "\($base)-\($n)"
                    | select((($taken[.] // false) | not)))
            end;

        reduce .[] as $outbound (
            {
                outbounds: [],
                tags: [],
                names: [],
                links: [],
                skipped: 0,
                skipped_names: [],
                skipped_reasons: [],
                taken: (reduce $existing_tags[] as $tag ({}; .[$tag] = true))
            };
            ((.outbounds | length) + 1) as $index
            | safe_string($outbound.remark // $outbound.tag; "server-\($index)") as $display_name
            | prefilter_skip_reason($outbound) as $skip_reason
            | if $skip_reason != "" then
                .skipped += 1
                | .skipped_names += [$display_name]
                | .skipped_reasons += [$skip_reason]
              else
                safe_string($outbound.tag // $outbound.remark; "server-\($index)") as $base_tag
                | (.taken as $taken | unique_tag($base_tag; $taken)) as $tag
                | .outbounds += [($outbound | del(.tag, .remark, .share_link) + {tag: $tag})]
                | .tags += [$tag]
                | .names += [$display_name]
                | .links += [($outbound.share_link // "")]
                | .taken[$tag] = true
              end
        )
        | del(.taken)
    ' "$outbounds_tmp" 2>/dev/null)"
    jq_status=$?
    rm -f "$existing_tags_tmp" "$outbounds_tmp"

    [ "$jq_status" -eq 0 ] || return 1
    [ -n "$prepared_json" ] || return 1
    printf '%s\n' "$prepared_json"
}

sing_box_cf_validation_error_summary() {
    local output="$1"
    local summary

    summary="$(printf '%s\n' "$output" |
        sed 's/\x1b\[[0-9;]*m//g;s/^[[:space:]]*//;s/[[:space:]]*$//' |
        sed '/^$/d' |
        sed -n '1p')"
    [ -n "$summary" ] || summary="sing-box check failed"
    printf '%s\n' "$summary"
}

sing_box_cf_try_subscription_outbounds_batch() {
    local config="$1"
    local new_outbounds="$2"
    local new_outbounds_tmp config_tmp validation_tmp validation_config updated_config jq_status check_output

    SING_BOX_CF_VALIDATED_CONFIG=""
    SING_BOX_CF_VALIDATION_ERROR=""

    new_outbounds_tmp="$(mktemp)" || return 1
    config_tmp="$(mktemp)" || {
        rm -f "$new_outbounds_tmp"
        return 1
    }

    printf '%s' "$new_outbounds" > "$new_outbounds_tmp" || {
        rm -f "$new_outbounds_tmp" "$config_tmp"
        return 1
    }
    printf '%s' "$config" > "$config_tmp" || {
        rm -f "$new_outbounds_tmp" "$config_tmp"
        return 1
    }

    updated_config="$(jq -c --slurpfile new_outbounds "$new_outbounds_tmp" \
        '.outbounds += ($new_outbounds[0] // [])' "$config_tmp" 2>/dev/null)"
    jq_status=$?
    rm -f "$new_outbounds_tmp" "$config_tmp"

    [ "$jq_status" -eq 0 ] || return 1
    [ -n "$updated_config" ] || return 1
    updated_config="$(printf '%s' "$updated_config" | jq -c 'del(.outbounds[]?.share_link, .outbounds[]?.remark)' 2>/dev/null)" || return 1
    [ -n "$updated_config" ] || return 1

    validation_config="$(printf '%s' "$updated_config" | jq -c '
        (first(.outbounds[]? | select(.type == "direct") | .tag) // "direct-out") as $direct
        | .route = ((.route // {}) + {rules: [], rule_set: [], final: $direct})
    ' 2>/dev/null)" || return 1
    [ -n "$validation_config" ] || return 1

    validation_tmp="$(mktemp)" || return 1
    sing_box_cm_save_config_to_file "$validation_config" "$validation_tmp"
    if ! check_output="$(sing-box -c "$validation_tmp" check 2>&1)"; then
        SING_BOX_CF_VALIDATION_ERROR="$(sing_box_cf_validation_error_summary "$check_output")"
        rm -f "$validation_tmp"
        return 1
    fi
    rm -f "$validation_tmp"

    SING_BOX_CF_VALIDATED_CONFIG="$updated_config"
    return 0
}

sing_box_cf_prepared_links_json() {
    local prepared_json="$1"

    printf '%s' "$prepared_json" | jq -c '
        (.tags // []) as $tags
        | (.links // []) as $links
        | reduce range(0; ($tags | length)) as $index (
            {};
            .[$tags[$index]] = ($links[$index] // "")
        )
    ' 2>/dev/null
}

sing_box_cf_prepared_names_lines() {
    local prepared_json="$1"

    printf '%s' "$prepared_json" | jq -r '.names[]?' 2>/dev/null
}

sing_box_cf_subscription_prepared_slice() {
    local prepared_json="$1"
    local start="$2"
    local end="$3"

    printf '%s' "$prepared_json" | jq -c --argjson start "$start" --argjson end "$end" '
        . + {
            outbounds: ((.outbounds // [])[$start:$end]),
            tags: ((.tags // [])[$start:$end]),
            names: ((.names // [])[$start:$end]),
            links: ((.links // [])[$start:$end]),
            skipped: 0,
            skipped_names: [],
            skipped_reasons: []
        }
    ' 2>/dev/null
}

sing_box_cf_append_subscription_prepared_metadata() {
    local prepared_json="$1"
    local tags_json links_json names

    tags_json="$(printf '%s' "$prepared_json" | jq -c '.tags // []' 2>/dev/null)"
    [ -n "$tags_json" ] || tags_json="[]"

    links_json="$(sing_box_cf_prepared_links_json "$prepared_json")"
    [ -n "$links_json" ] || links_json="{}"

    SUBSCRIPTION_OUTBOUND_TAGS_JSON="$(printf '%s' "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" |
        jq -c --argjson tags "$tags_json" '. + $tags' 2>/dev/null)"
    [ -n "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" ] || SUBSCRIPTION_OUTBOUND_TAGS_JSON="[]"

    SUBSCRIPTION_OUTBOUND_LINKS_JSON="$(printf '%s' "$SUBSCRIPTION_OUTBOUND_LINKS_JSON" |
        jq -c --argjson links "$links_json" '. + $links' 2>/dev/null)"
    [ -n "$SUBSCRIPTION_OUTBOUND_LINKS_JSON" ] || SUBSCRIPTION_OUTBOUND_LINKS_JSON="{}"

    names="$(sing_box_cf_prepared_names_lines "$prepared_json")"
    if [ -n "$names" ]; then
        if [ -z "$SUBSCRIPTION_OUTBOUND_NAMES" ]; then
            SUBSCRIPTION_OUTBOUND_NAMES="$names"
        else
            SUBSCRIPTION_OUTBOUND_NAMES="$SUBSCRIPTION_OUTBOUND_NAMES
$names"
        fi
    fi
}

sing_box_cf_apply_subscription_batch() {
    local config="$1"
    local prepared_json="$2"
    local new_outbounds new_outbounds_count

    new_outbounds="$(printf '%s' "$prepared_json" | jq -c '.outbounds // []' 2>/dev/null)"
    [ -n "$new_outbounds" ] || return 1
    new_outbounds_count="$(printf '%s' "$new_outbounds" | jq -r 'length' 2>/dev/null)"
    [ -n "$new_outbounds_count" ] || return 1
    [ "$new_outbounds_count" -gt 0 ] || return 1

    if ! sing_box_cf_try_subscription_outbounds_batch "$config" "$new_outbounds"; then
        return 1
    fi

    SUBSCRIPTION_OUTBOUND_TAGS_JSON="$(printf '%s' "$prepared_json" | jq -c '.tags // []' 2>/dev/null)"
    [ -n "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" ] || SUBSCRIPTION_OUTBOUND_TAGS_JSON="[]"
    SUBSCRIPTION_OUTBOUND_TAGS="$(printf '%s' "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" | jq -r 'join(",")' 2>/dev/null)"
    SUBSCRIPTION_OUTBOUND_NAMES="$(sing_box_cf_prepared_names_lines "$prepared_json")"
    SUBSCRIPTION_OUTBOUND_LINKS_JSON="$(sing_box_cf_prepared_links_json "$prepared_json")"
    [ -n "$SUBSCRIPTION_OUTBOUND_LINKS_JSON" ] || SUBSCRIPTION_OUTBOUND_LINKS_JSON="{}"
    SING_BOX_CF_LAST_CONFIG="$SING_BOX_CF_VALIDATED_CONFIG"

    return 0
}

sing_box_cf_apply_subscription_outbounds_range() {
    local start="$1"
    local count="$2"
    local end chunk outbounds_json display_name half rest index

    [ "$count" -gt 0 ] || return 0

    end=$((start + count))
    chunk="$(sing_box_cf_subscription_prepared_slice "$SING_BOX_CF_FALLBACK_PREPARED_JSON" "$start" "$end")" || {
        SING_BOX_CF_FALLBACK_SKIPPED_COUNT=$((SING_BOX_CF_FALLBACK_SKIPPED_COUNT + count))
        return 0
    }

    outbounds_json="$(printf '%s' "$chunk" | jq -c '.outbounds // []' 2>/dev/null)"
    [ -n "$outbounds_json" ] || {
        SING_BOX_CF_FALLBACK_SKIPPED_COUNT=$((SING_BOX_CF_FALLBACK_SKIPPED_COUNT + count))
        return 0
    }

    if sing_box_cf_try_subscription_outbounds_batch "$SING_BOX_CF_FALLBACK_WORKING_CONFIG" "$outbounds_json"; then
        SING_BOX_CF_FALLBACK_WORKING_CONFIG="$SING_BOX_CF_VALIDATED_CONFIG"
        sing_box_cf_append_subscription_prepared_metadata "$chunk"
        SING_BOX_CF_FALLBACK_ADDED_COUNT=$((SING_BOX_CF_FALLBACK_ADDED_COUNT + count))
        return 0
    fi

    if [ "$count" -eq 1 ]; then
        display_name="$(printf '%s' "$chunk" |
            jq -r '(.names[0] // .outbounds[0].tag // "unknown") | tostring' 2>/dev/null |
            tr '\r\n\t' '   ' |
            sed 's/[[:space:]][[:space:]]*/ /g;s/^[[:space:]]*//;s/[[:space:]]*$//')"
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

    outbounds_count="$(printf '%s' "$prepared_json" | jq -r '(.outbounds // []) | length' 2>/dev/null)"
    [ -n "$outbounds_count" ] || return 1
    [ "$outbounds_count" -gt 0 ] || return 1

    SING_BOX_CF_FALLBACK_WORKING_CONFIG="$config"
    SING_BOX_CF_FALLBACK_PREPARED_JSON="$prepared_json"
    SING_BOX_CF_FALLBACK_ADDED_COUNT=0
    SING_BOX_CF_FALLBACK_SKIPPED_COUNT=0
    SUBSCRIPTION_OUTBOUND_TAGS_JSON="[]"
    SUBSCRIPTION_OUTBOUND_LINKS_JSON="{}"
    SUBSCRIPTION_OUTBOUND_NAMES=""

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

    SUBSCRIPTION_OUTBOUND_TAGS="$(printf '%s' "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" | jq -r 'join(",")' 2>/dev/null)"
    SING_BOX_CF_LAST_CONFIG="$SING_BOX_CF_FALLBACK_WORKING_CONFIG"

    return 0
}

sing_box_cf_add_subscription_outbounds() {
    local config="$1"
    local section="$2"
    local subscription_json_path="$3"
    local outbounds_json outbounds_count prepared_json skipped_count

    SUBSCRIPTION_OUTBOUND_TAGS=""
    SUBSCRIPTION_OUTBOUND_TAGS_JSON="[]"
    SUBSCRIPTION_OUTBOUND_LINKS_JSON="{}"
    SUBSCRIPTION_OUTBOUND_NAMES=""
    SING_BOX_CF_LAST_CONFIG="$config"

    if [ ! -f "$subscription_json_path" ]; then
        log "Subscription JSON file not found: $subscription_json_path" "error"
        echo "$config"
        return 1
    fi

    outbounds_json="$(sing_box_cf_subscription_candidate_outbounds "$subscription_json_path")"
    outbounds_count="$(printf '%s' "$outbounds_json" | jq -r 'length' 2>/dev/null)"

    if [ -z "$outbounds_count" ] || [ "$outbounds_count" -eq 0 ]; then
        log "No proxy outbounds found in subscription JSON" "error"
        echo "$config"
        return 1
    fi

    log "Found $outbounds_count proxy outbounds in subscription" "info"

    prepared_json="$(sing_box_cf_prepare_subscription_batch "$config" "$outbounds_json")"
    if [ -n "$prepared_json" ]; then
        skipped_count="$(printf '%s' "$prepared_json" | jq -r '.skipped // 0' 2>/dev/null)"
        if [ "${skipped_count:-0}" -gt 0 ]; then
            log "Skipped $skipped_count unsupported subscription outbounds before validation" "warn"
            sing_box_cf_log_subscription_skips "$prepared_json" "before validation"
        fi

        if sing_box_cf_apply_subscription_batch "$config" "$prepared_json"; then
            log "Added $(printf '%s' "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" | jq -r 'length' 2>/dev/null) subscription outbounds for rule '$section'" "info"
            echo "$SING_BOX_CF_LAST_CONFIG"
            return 0
        fi
    fi

    log "Batch subscription validation failed for rule '$section', trying chunked fallback validation" "warn"
    if [ -n "$prepared_json" ] && sing_box_cf_apply_subscription_outbounds_chunked "$config" "$prepared_json"; then
        log "Added $(printf '%s' "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" | jq -r 'length' 2>/dev/null) subscription outbounds for rule '$section'" "info"
        echo "$SING_BOX_CF_LAST_CONFIG"
        return 0
    fi

    log "No valid subscription outbounds remained after validation for rule '$section'" "error"

    echo "$config"
    return 1
}
