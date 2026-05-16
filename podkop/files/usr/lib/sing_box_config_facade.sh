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

sing_box_cf_prepare_subscription_batch() {
    local config="$1"
    local outbounds_json="$2"
    local existing_tags_json existing_tags_tmp outbounds_tmp prepared_json jq_status

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

    prepared_json="$(jq -c --slurpfile existing_tags "$existing_tags_tmp" '
        ($existing_tags[0] // []) as $existing_tags
        |
        def safe_string($value; $fallback):
            (($value // $fallback) | tostring) as $result
            | if $result == "" or $result == "null" then $fallback else $result end;

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
                taken: (reduce $existing_tags[] as $tag ({}; .[$tag] = true))
            };
            ((.outbounds | length) + 1) as $index
            | safe_string($outbound.remark // $outbound.tag; "server-\($index)") as $display_name
            | if ($outbound.type == "shadowsocks" and (($outbound.tls.enabled // false) == true)) then
                .skipped += 1
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

sing_box_cf_apply_subscription_batch() {
    local config="$1"
    local prepared_json="$2"
    local new_outbounds new_outbounds_tmp config_tmp validation_tmp validation_config updated_config jq_status

    new_outbounds="$(printf '%s' "$prepared_json" | jq -c '.outbounds // []' 2>/dev/null)"
    [ -n "$new_outbounds" ] || return 1
    [ "$(printf '%s' "$new_outbounds" | jq -r 'length' 2>/dev/null)" -gt 0 ] || return 1

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
        | .route = {rules: [], rule_set: [], final: $direct}
    ' 2>/dev/null)" || return 1
    [ -n "$validation_config" ] || return 1

    validation_tmp="$(mktemp)" || return 1
    sing_box_cm_save_config_to_file "$validation_config" "$validation_tmp"
    if ! sing-box -c "$validation_tmp" check > /dev/null 2>&1; then
        rm -f "$validation_tmp"
        return 1
    fi
    rm -f "$validation_tmp"

    SUBSCRIPTION_OUTBOUND_TAGS_JSON="$(printf '%s' "$prepared_json" | jq -c '.tags // []' 2>/dev/null)"
    [ -n "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" ] || SUBSCRIPTION_OUTBOUND_TAGS_JSON="[]"
    SUBSCRIPTION_OUTBOUND_TAGS="$(printf '%s' "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" | jq -r 'join(",")' 2>/dev/null)"
    SUBSCRIPTION_OUTBOUND_NAMES="$(printf '%s' "$prepared_json" | jq -r '.names[]?' 2>/dev/null)"
    SUBSCRIPTION_OUTBOUND_LINKS_JSON="$(printf '%s' "$prepared_json" | jq -c '
        (.tags // []) as $tags
        | (.links // []) as $links
        | reduce range(0; ($tags | length)) as $index (
            {};
            .[$tags[$index]] = ($links[$index] // "")
        )
    ' 2>/dev/null)"
    [ -n "$SUBSCRIPTION_OUTBOUND_LINKS_JSON" ] || SUBSCRIPTION_OUTBOUND_LINKS_JSON="{}"
    SING_BOX_CF_LAST_CONFIG="$updated_config"

    return 0
}

sing_box_cf_apply_subscription_outbounds_individually() {
    local config="$1"
    local prepared_json="$2"
    local working_config="$config"
    local outbounds_count index outbound_tag display_name raw_outbound try_config validation_config validation_tmp
    local added_count skipped_count tags_json links_json names source_link

    outbounds_count="$(printf '%s' "$prepared_json" | jq -r '(.outbounds // []) | length' 2>/dev/null)"
    [ -n "$outbounds_count" ] || return 1
    [ "$outbounds_count" -gt 0 ] || return 1

    index=0
    added_count=0
    skipped_count=0
    tags_json="[]"
    links_json="{}"
    names=""

    while [ "$index" -lt "$outbounds_count" ]; do
        outbound_tag="$(printf '%s' "$prepared_json" | jq -r --argjson index "$index" '.outbounds[$index].tag // empty' 2>/dev/null)"
        display_name="$(printf '%s' "$prepared_json" | jq -r --argjson index "$index" '.names[$index] // .outbounds[$index].tag // ("server-" + (($index + 1) | tostring))' 2>/dev/null)"
        raw_outbound="$(printf '%s' "$prepared_json" | jq -c --argjson index "$index" '.outbounds[$index] | del(.tag, .share_link, .remark)' 2>/dev/null)"
        source_link="$(printf '%s' "$prepared_json" | jq -r --argjson index "$index" '.links[$index] // empty' 2>/dev/null)"

        if [ -z "$outbound_tag" ] || [ -z "$raw_outbound" ] || [ "$raw_outbound" = "null" ]; then
            skipped_count=$((skipped_count + 1))
            index=$((index + 1))
            continue
        fi

        try_config="$(sing_box_cm_add_raw_outbound "$working_config" "$outbound_tag" "$raw_outbound")"
        if [ -z "$try_config" ]; then
            log "Skipped invalid subscription outbound '$display_name'" "warn"
            skipped_count=$((skipped_count + 1))
            index=$((index + 1))
            continue
        fi

        validation_config="$(printf '%s' "$try_config" | jq -c '
            (first(.outbounds[]? | select(.type == "direct") | .tag) // "direct-out") as $direct
            | .route = {rules: [], rule_set: [], final: $direct}
        ' 2>/dev/null)"
        if [ -z "$validation_config" ]; then
            log "Skipped invalid subscription outbound '$display_name'" "warn"
            skipped_count=$((skipped_count + 1))
            index=$((index + 1))
            continue
        fi

        validation_tmp="$(mktemp)" || return 1
        sing_box_cm_save_config_to_file "$validation_config" "$validation_tmp"
        if sing-box -c "$validation_tmp" check > /dev/null 2>&1; then
            working_config="$try_config"
            tags_json="$(printf '%s' "$tags_json" | jq -c --arg tag "$outbound_tag" '. + [$tag]' 2>/dev/null)"
            links_json="$(printf '%s' "$links_json" | jq -c --arg tag "$outbound_tag" --arg link "$source_link" '.[$tag] = $link' 2>/dev/null)"
            if [ -z "$names" ]; then
                names="$display_name"
            else
                names="$names
$display_name"
            fi
            added_count=$((added_count + 1))
        else
            log "Skipped unsupported subscription outbound '$display_name'" "warn"
            skipped_count=$((skipped_count + 1))
        fi
        rm -f "$validation_tmp"

        index=$((index + 1))
    done

    if [ "$added_count" -eq 0 ]; then
        return 1
    fi

    if [ "$skipped_count" -gt 0 ]; then
        log "Skipped $skipped_count unsupported subscription outbounds during fallback validation" "warn"
    fi

    SUBSCRIPTION_OUTBOUND_TAGS_JSON="$tags_json"
    SUBSCRIPTION_OUTBOUND_TAGS="$(printf '%s' "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" | jq -r 'join(",")' 2>/dev/null)"
    SUBSCRIPTION_OUTBOUND_LINKS_JSON="$links_json"
    SUBSCRIPTION_OUTBOUND_NAMES="$names"
    SING_BOX_CF_LAST_CONFIG="$working_config"

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
        fi

        if sing_box_cf_apply_subscription_batch "$config" "$prepared_json"; then
            log "Added $(printf '%s' "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" | jq -r 'length' 2>/dev/null) subscription outbounds for rule '$section'" "info"
            echo "$SING_BOX_CF_LAST_CONFIG"
            return 0
        fi
    fi

    log "Batch subscription validation failed for rule '$section', trying per-outbound validation" "warn"
    if [ -n "$prepared_json" ] && sing_box_cf_apply_subscription_outbounds_individually "$config" "$prepared_json"; then
        log "Added $(printf '%s' "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" | jq -r 'length' 2>/dev/null) subscription outbounds for rule '$section'" "info"
        echo "$SING_BOX_CF_LAST_CONFIG"
        return 0
    fi

    log "No valid subscription outbounds remained after validation for rule '$section'" "error"

    echo "$config"
    return 1
}
