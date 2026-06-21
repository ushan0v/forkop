# shellcheck shell=ash

server_runtime_ucode() {
    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/server_runtime.uc" "$@"
}

configure_server_inbound() {
    local section="$1"
    local protocol listen listen_port public_host inbound_tag required_proto port_conflict_owners users_tmp status \
        inbound_json inbound_json_tmp \
        shadowsocks_method server_password hysteria2_up_mbps hysteria2_down_mbps \
        hysteria2_obfs_type hysteria2_obfs_password mtproto_faketls mtproto_padding mtproto_concurrency \
        mtproto_domain_fronting_port mtproto_domain_fronting_ip \
        mtproto_domain_fronting_proxy_protocol mtproto_prefer_ip mtproto_auto_update \
        mtproto_allow_fallback_on_unknown_dc mtproto_tolerate_time_skewness \
        mtproto_idle_timeout mtproto_handshake_timeout

    server_is_enabled "$section" || return 0

    config_get protocol "$section" "protocol" "vless"
    case "$protocol" in
    shadowsocks | socks | vmess | vless | trojan | hysteria2 | mtproto | tailscale | json_inbound) ;;
    *)
        log "Server '$section' has unsupported protocol '$protocol'. Aborted." "fatal"
        exit 1
        ;;
    esac

    inbound_tag="$(get_server_inbound_tag_by_section "$section")"

    if [ "$protocol" = "tailscale" ]; then
        configure_tailscale_server_endpoint "$section"
        return 0
    fi

    if [ "$protocol" = "json_inbound" ]; then
        config_get inbound_json "$section" "inbound_json"
        if [ -z "$inbound_json" ]; then
            log "JSON inbound server '$section' has empty inbound_json. Aborted." "fatal"
            exit 1
        fi
        if ! printf '%s' "$inbound_json" | config_validation_ucode valid-inbound >/dev/null 2>&1; then
            log "JSON inbound server '$section' must contain a valid sing-box inbound JSON object with a type field. Aborted." "fatal"
            exit 1
        fi
        inbound_json_tmp="$(mktemp)" || {
            log "Failed to create temporary JSON inbound file for server '$section'. Aborted." "fatal"
            exit 1
        }
        printf '%s' "$inbound_json" > "$inbound_json_tmp" || {
            rm -f "$inbound_json_tmp"
            log "Failed to write temporary JSON inbound file for server '$section'. Aborted." "fatal"
            exit 1
        }
        config=$(sing_box_cm_add_raw_inbound_file "$config" "$inbound_tag" "$inbound_json_tmp")
        status=$?
        rm -f "$inbound_json_tmp"
        [ "$status" -eq 0 ] || {
            log "Failed to configure JSON inbound server '$section'. Aborted." "fatal"
            exit 1
        }
        return 0
    fi

    config_get listen "$section" "listen" "0.0.0.0"
    config_get listen_port "$section" "listen_port"
    config_get public_host "$section" "public_host"

    if ! is_ipv4 "$listen"; then
        log "Server '$section' has invalid listen address '$listen'. Use an IPv4 address. Aborted." "fatal"
        exit 1
    fi
    if ! server_port_is_valid "$listen_port"; then
        log "Server '$section' has invalid listen port '$listen_port'. Aborted." "fatal"
        exit 1
    fi
    if [ -n "$public_host" ] && ! server_host_is_valid "$public_host"; then
        log "Server '$section' has invalid public host '$public_host'. Use a domain name or IPv4 address. Aborted." "fatal"
        exit 1
    fi

    required_proto="$(server_required_inbound_proto "$protocol")"
    port_conflict_owners="$(server_required_port_conflict_owners "$listen" "$listen_port" "$required_proto")"
    if [ -n "$port_conflict_owners" ]; then
        log "Server '$section' cannot listen on $listen:$listen_port [$required_proto]: port is already used by $port_conflict_owners. Aborted." "fatal"
        exit 1
    fi

    case "$protocol" in
    shadowsocks)
        config_get shadowsocks_method "$section" "shadowsocks_method" "aes-128-gcm"
        config_get server_password "$section" "server_password"
        case "$shadowsocks_method" in
        aes-128-gcm | aes-256-gcm | chacha20-ietf-poly1305) ;;
        *)
            log "Server '$section' has unsupported Shadowsocks method '$shadowsocks_method'. Aborted." "fatal"
            exit 1
            ;;
        esac
        if [ -z "$server_password" ]; then
            log "Server '$section' has no client password. Aborted." "fatal"
            exit 1
        fi
        if ! server_client_value_is_valid "$server_password"; then
            log "Server '$section' has invalid Shadowsocks password. It must not contain control characters. Aborted." "fatal"
            exit 1
        fi
        config=$(sing_box_cm_add_shadowsocks_inbound "$config" "$inbound_tag" "$listen" "$listen_port" "$shadowsocks_method" "$server_password")
        status=$?
        ;;
    socks | vmess | vless | trojan | hysteria2 | mtproto)
        users_tmp="$(server_write_users_json "$section" "$protocol")" || {
            log "Failed to prepare users for server '$section'. Aborted." "fatal"
            exit 1
        }

        case "$protocol" in
        socks)
            config=$(sing_box_cm_add_socks_inbound "$config" "$inbound_tag" "$listen" "$listen_port" "$users_tmp")
            ;;
        vmess)
            config=$(sing_box_cm_add_vmess_inbound "$config" "$inbound_tag" "$listen" "$listen_port" "$users_tmp")
            ;;
        vless)
            config=$(sing_box_cm_add_vless_inbound "$config" "$inbound_tag" "$listen" "$listen_port" "$users_tmp")
            ;;
        trojan)
            config=$(sing_box_cm_add_trojan_inbound "$config" "$inbound_tag" "$listen" "$listen_port" "$users_tmp")
            ;;
        hysteria2)
            config_get hysteria2_up_mbps "$section" "hysteria2_up_mbps"
            config_get hysteria2_down_mbps "$section" "hysteria2_down_mbps"
            config_get hysteria2_obfs_type "$section" "hysteria2_obfs_type"
            config_get hysteria2_obfs_password "$section" "hysteria2_obfs_password"
            case "$hysteria2_obfs_type" in
            '' | salamander) ;;
            *)
                log "Server '$section' has unsupported Hysteria2 obfuscation '$hysteria2_obfs_type'. Aborted." "fatal"
                exit 1
                ;;
            esac
            if [ "$hysteria2_obfs_type" = "salamander" ] && [ -z "$hysteria2_obfs_password" ]; then
                log "Server '$section' uses Hysteria2 salamander obfuscation but password is not set. Aborted." "fatal"
                exit 1
            fi
            config=$(
                sing_box_cm_add_hysteria2_inbound \
                    "$config" "$inbound_tag" "$listen" "$listen_port" "$users_tmp" \
                    "$hysteria2_up_mbps" "$hysteria2_down_mbps" "$hysteria2_obfs_type" "$hysteria2_obfs_password"
            )
            ;;
        mtproto)
            config_get mtproto_faketls "$section" "mtproto_faketls" "google.com"
            config_get_bool mtproto_padding "$section" "mtproto_padding" 1
            config_get mtproto_concurrency "$section" "mtproto_concurrency"
            config_get mtproto_domain_fronting_port "$section" "mtproto_domain_fronting_port" "443"
            config_get mtproto_domain_fronting_ip "$section" "mtproto_domain_fronting_ip"
            config_get_bool mtproto_domain_fronting_proxy_protocol "$section" "mtproto_domain_fronting_proxy_protocol" 0
            config_get mtproto_prefer_ip "$section" "mtproto_prefer_ip" "prefer-ipv4"
            config_get_bool mtproto_auto_update "$section" "mtproto_auto_update" 0
            config_get_bool mtproto_allow_fallback_on_unknown_dc "$section" "mtproto_allow_fallback_on_unknown_dc" 0
            config_get mtproto_tolerate_time_skewness "$section" "mtproto_tolerate_time_skewness" "3s"
            config_get mtproto_idle_timeout "$section" "mtproto_idle_timeout" "5m"
            config_get mtproto_handshake_timeout "$section" "mtproto_handshake_timeout" "10s"

            if ! server_host_is_valid "$mtproto_faketls"; then
                log "Server '$section' has invalid FakeTLS host '$mtproto_faketls'. Use a domain name or IPv4 address. Aborted." "fatal"
                exit 1
            fi
            if [ "$mtproto_padding" -ne 1 ]; then
                log "Server '$section' has padding disabled, but sing-box-extended MTProxy requires padded FakeTLS secrets. Aborted." "fatal"
                exit 1
            fi
            if [ -n "$mtproto_concurrency" ]; then
                case "$mtproto_concurrency" in
                '' | *[!0-9]*)
                    log "Server '$section' has invalid concurrency '$mtproto_concurrency'. Use a non-negative integer. Aborted." "fatal"
                    exit 1
                    ;;
                esac
            fi
            if ! server_port_is_valid "$mtproto_domain_fronting_port"; then
                log "Server '$section' has invalid fronting port '$mtproto_domain_fronting_port'. Aborted." "fatal"
                exit 1
            fi
            if [ -n "$mtproto_domain_fronting_ip" ] && ! is_ipv4 "$mtproto_domain_fronting_ip"; then
                log "Server '$section' has invalid fronting IP '$mtproto_domain_fronting_ip'. Use an IPv4 address. Aborted." "fatal"
                exit 1
            fi
            case "$mtproto_prefer_ip" in
            prefer-ipv4 | prefer-ipv6 | only-ipv4 | only-ipv6) ;;
            *)
                log "Server '$section' has unsupported preferred IP mode '$mtproto_prefer_ip'. Aborted." "fatal"
                exit 1
                ;;
            esac
            if ! server_duration_is_valid "$mtproto_tolerate_time_skewness"; then
                log "Server '$section' has invalid time skew tolerance '$mtproto_tolerate_time_skewness'. Aborted." "fatal"
                exit 1
            fi
            if ! server_duration_is_valid "$mtproto_idle_timeout"; then
                log "Server '$section' has invalid idle timeout '$mtproto_idle_timeout'. Aborted." "fatal"
                exit 1
            fi
            if ! server_duration_is_valid "$mtproto_handshake_timeout"; then
                log "Server '$section' has invalid handshake timeout '$mtproto_handshake_timeout'. Aborted." "fatal"
                exit 1
            fi

            config=$(
                sing_box_cm_add_mtproxy_inbound \
                    "$config" "$inbound_tag" "$listen" "$listen_port" "$users_tmp" \
                    "$mtproto_concurrency" "$mtproto_domain_fronting_port" "$mtproto_domain_fronting_ip" \
                    "$mtproto_domain_fronting_proxy_protocol" "$mtproto_prefer_ip" "$mtproto_auto_update" \
                    "$mtproto_allow_fallback_on_unknown_dc" "$mtproto_tolerate_time_skewness" \
                    "$mtproto_idle_timeout" "$mtproto_handshake_timeout"
            )
            ;;
        esac
        status=$?
        rm -f "$users_tmp"
        ;;
    esac
    [ "$status" -eq 0 ] || {
        log "Failed to configure server inbound '$section'. Aborted." "fatal"
        exit 1
    }

    server_apply_tls "$section" "$inbound_tag"
    server_apply_transport "$section" "$inbound_tag"
}

configure_tailscale_server_endpoint() {
    local section="$1"
    local endpoint_tag safe_name state_directory auth_key control_url hostname accept_routes \
        advertise_routes advertise_exit_node status

    endpoint_tag="$(get_server_inbound_tag_by_section "$section")"
    safe_name="$(server_safe_filename "$section")"

    state_directory="/etc/podkop-plus/tailscale/$safe_name"
    config_get auth_key "$section" "tailscale_auth_key"
    config_get control_url "$section" "tailscale_control_url" "https://controlplane.tailscale.com"
    config_get hostname "$section" "tailscale_hostname" "podkop-$safe_name"
    config_get_bool accept_routes "$section" "tailscale_accept_routes" 0
    config_get_bool advertise_exit_node "$section" "tailscale_advertise_exit_node" 0
    tailscale_collect_advertise_routes "$section"
    advertise_routes="$TAILSCALE_ADVERTISE_ROUTES_JSON"

    if ! server_absolute_path_is_valid "$state_directory"; then
        log "Server '$section' has invalid Tailscale state directory '$state_directory'. Use an absolute path. Aborted." "fatal"
        exit 1
    fi
    if [ -z "$auth_key" ]; then
        log "Server '$section' uses Tailscale but auth key is empty. Aborted." "fatal"
        exit 1
    fi
    if ! server_http_url_is_valid "$control_url"; then
        log "Server '$section' has invalid Tailscale control URL '$control_url'. Use an HTTP or HTTPS URL. Aborted." "fatal"
        exit 1
    fi
    if ! server_host_is_valid "$hostname"; then
        log "Server '$section' has invalid Tailscale hostname '$hostname'. Aborted." "fatal"
        exit 1
    fi

    mkdir -p "$state_directory" || {
        log "Failed to create Tailscale state directory for server '$section'. Aborted." "fatal"
        exit 1
    }

    config=$(
        sing_box_cm_add_tailscale_endpoint \
            "$config" \
            "$endpoint_tag" \
            "$state_directory" \
            "$auth_key" \
            "$control_url" \
            "0" \
            "$hostname" \
            "$accept_routes" \
            "" \
            "0" \
            "$advertise_routes" \
            "$advertise_exit_node" \
            ""
    )
    status=$?
    [ "$status" -eq 0 ] || {
        log "Failed to configure Tailscale endpoint '$section'. Aborted." "fatal"
        exit 1
    }
}

tailscale_normalize_advertise_route() {
    local value="$1"

    case "$value" in
    */*)
        printf '%s\n' "$value"
        return 0
        ;;
    esac

    if is_ipv4 "$value"; then
        printf '%s/32\n' "$value"
        return 0
    fi

    if is_ipv6_literal "$value"; then
        printf '%s/128\n' "$value"
        return 0
    fi

    printf '%s\n' "$value"
}

tailscale_collect_advertise_route_handler() {
    local value="$1" normalized
    local section="$2"

    [ -n "$value" ] || return 0
    TAILSCALE_ADVERTISE_ROUTE_SEEN=1
    normalized="$(tailscale_normalize_advertise_route "$value")"

    if ! server_cidr_is_valid "$normalized"; then
        log "Server '$section' has invalid Tailscale advertised route '$value'. Use CIDR prefixes or IP addresses like 192.168.1.0/24 or 192.168.1.10. Aborted." "fatal"
        exit 1
    fi

    TAILSCALE_ADVERTISE_ROUTES_JSON="$(printf '%s' "$TAILSCALE_ADVERTISE_ROUTES_JSON" |
        server_runtime_ucode array-append-string "$normalized" 2>/dev/null)" || {
        log "Failed to prepare Tailscale advertised routes for server '$section'. Aborted." "fatal"
        exit 1
    }
}

tailscale_collect_advertise_routes() {
    local section="$1"
    local values value

    TAILSCALE_ADVERTISE_ROUTES_JSON="[]"
    TAILSCALE_ADVERTISE_ROUTE_SEEN=0

    config_list_foreach "$section" "tailscale_advertise_routes" tailscale_collect_advertise_route_handler "$section"
    [ "$TAILSCALE_ADVERTISE_ROUTE_SEEN" -eq 1 ] && return 0

    config_get values "$section" "tailscale_advertise_routes"
    [ -n "$values" ] || return 0

    for value in $values; do
        tailscale_collect_advertise_route_handler "$value" "$section"
    done
}

server_port_is_valid() {
    server_runtime_ucode valid-port "$1" >/dev/null 2>&1
}

server_normalize_host() {
    server_runtime_ucode normalize-host "$1"
}

server_host_is_valid() {
    server_runtime_ucode valid-host "$1" >/dev/null 2>&1
}

server_absolute_path_is_valid() {
    server_runtime_ucode valid-absolute-path "$1" >/dev/null 2>&1
}

server_file_path_is_valid() {
    server_runtime_ucode valid-file-path "$1" >/dev/null 2>&1
}

server_client_value_is_valid() {
    server_runtime_ucode valid-client-value "$1" >/dev/null 2>&1
}

server_http_url_is_valid() {
    server_runtime_ucode valid-http-url "$1" >/dev/null 2>&1
}

server_duration_is_valid() {
    server_runtime_ucode valid-duration "$1" >/dev/null 2>&1
}

server_default_security_for_protocol() {
    server_runtime_ucode default-security-for-protocol "$1"
}

server_effective_security() {
    local section="$1"
    local protocol="$2"
    local security

    config_get security "$section" "security"
    [ -n "$security" ] || security="$(server_default_security_for_protocol "$protocol")"

    case "$protocol" in
    shadowsocks | socks | mtproto | tailscale)
        security="none"
        ;;
    json_inbound)
        security="none"
        ;;
    hysteria2)
        security="tls"
        ;;
    vmess | trojan)
        [ "$security" != "reality" ] || security="$(server_default_security_for_protocol "$protocol")"
        ;;
    esac

    printf '%s\n' "$security"
}

server_default_set_option() {
    local section="$1"
    local option="$2"
    local value="$3"
    local current

    [ -n "$value" ] || return 0
    current="$(uci -q get "$PODKOP_CONFIG_NAME.$section.$option" 2>/dev/null)"
    [ -n "$current" ] && return 0

    uci set "$PODKOP_CONFIG_NAME.$section.$option=$value"
    SERVER_DEFAULTS_CHANGED=1
}

server_set_option() {
    local section="$1"
    local option="$2"
    local value="$3"
    local current

    [ -n "$value" ] || return 0
    current="$(uci -q get "$PODKOP_CONFIG_NAME.$section.$option" 2>/dev/null)"
    [ "$current" = "$value" ] && return 0

    uci set "$PODKOP_CONFIG_NAME.$section.$option=$value"
    SERVER_DEFAULTS_CHANGED=1
}

server_default_add_list() {
    local section="$1"
    local option="$2"
    local value="$3"
    local current quoted_value

    [ -n "$value" ] || return 0
    current="$(uci -q get "$PODKOP_CONFIG_NAME.$section.$option" 2>/dev/null)"
    [ -n "$current" ] && return 0

    quoted_value="$(server_runtime_ucode shell-single-quote "$value")"
    printf 'add_list %s.%s.%s=%s\n' "$PODKOP_CONFIG_NAME" "$section" "$option" "$quoted_value" | uci -q batch
    SERVER_DEFAULTS_CHANGED=1
}

server_generate_uuid() {
    sing-box generate uuid 2>/dev/null | server_runtime_ucode stdin-first-nonempty-line
}

server_generate_password() {
    sing-box generate rand --base64 18 2>/dev/null | server_runtime_ucode stdin-remove-newlines
}

server_generate_mtproto_secret() {
    local random_hex

    random_hex="$(sing-box generate rand --hex 16 2>/dev/null | server_runtime_ucode stdin-remove-newlines)"
    if [ -z "$random_hex" ]; then
        random_hex="$(head -c 16 /dev/urandom | hexdump -ve '1/1 "%02x"')"
    fi

    case "$random_hex" in
    00000000000000000000000000000000) random_hex="11111111111111111111111111111111" ;;
    esac

    printf '%s\n' "$random_hex"
}

server_mtproto_base_secret_from_value() {
    server_runtime_ucode mtproto-base-secret "$1"
}

server_mtproto_faketls_from_secret() {
    server_runtime_ucode mtproto-faketls-from-secret "$1"
}

server_mtproto_base_secret_is_valid() {
    server_runtime_ucode valid-mtproto-base-secret "$1" >/dev/null 2>&1
}

server_build_mtproto_secret() {
    local base="$1"
    local faketls="$2"
    local padding="$3"

    server_runtime_ucode mtproto-build-secret "$base" "$faketls" "$padding"
}

server_generate_short_id() {
    sing-box generate rand --hex 4 2>/dev/null | server_runtime_ucode stdin-remove-newlines
}

server_generate_reality_keypair() {
    local output parsed old_ifs

    SERVER_REALITY_PRIVATE_KEY=""
    SERVER_REALITY_PUBLIC_KEY=""
    output="$(sing-box generate reality-keypair 2>/dev/null)" || return 1
    parsed="$(printf '%s\n' "$output" | server_runtime_ucode reality-keypair-tsv)" || return 1

    old_ifs="$IFS"
    IFS="$(printf '\t')"
    read -r SERVER_REALITY_PRIVATE_KEY SERVER_REALITY_PUBLIC_KEY <<EOF
$parsed
EOF
    IFS="$old_ifs"

    [ -n "$SERVER_REALITY_PRIVATE_KEY" ] && [ -n "$SERVER_REALITY_PUBLIC_KEY" ]
}

generate_reality_keypair() {
    if ! server_generate_reality_keypair; then
        server_runtime_ucode error-response "Failed to generate Reality key pair"
        return 1
    fi

    server_runtime_ucode reality-keypair-response "$SERVER_REALITY_PRIVATE_KEY" "$SERVER_REALITY_PUBLIC_KEY"
}

server_safe_filename() {
    server_runtime_ucode safe-filename "$1"
}

server_generate_tls_keypair_files() {
    local server_name="$1"
    local certificate_path="$2"
    local key_path="$3"
    local output key_dir cert_dir

    output="$(sing-box generate tls-keypair "$server_name" 2>/dev/null)" || return 1

    key_dir="${key_path%/*}"
    cert_dir="${certificate_path%/*}"
    mkdir -p "$key_dir" "$cert_dir" || return 1

    printf '%s\n' "$output" | server_runtime_ucode write-tls-keypair-files "$key_path" "$certificate_path" || return 1
    chmod 600 "$key_path" 2>/dev/null || true
}

server_tls_certificate_sha256_from_file() {
    local certificate_path="$1"
    local b64_tmp der_tmp fingerprint

    server_file_path_is_valid "$certificate_path" || return 1
    [ -s "$certificate_path" ] || return 1

    b64_tmp="$(mktemp)" || return 1
    der_tmp="$(mktemp)" || {
        rm -f "$b64_tmp"
        return 1
    }

    if ! server_runtime_ucode certificate-base64 "$certificate_path" > "$b64_tmp" || [ ! -s "$b64_tmp" ]; then
        rm -f "$b64_tmp" "$der_tmp"
        return 1
    fi

    if ! base64 -d "$b64_tmp" > "$der_tmp" 2>/dev/null || [ ! -s "$der_tmp" ]; then
        rm -f "$b64_tmp" "$der_tmp"
        return 1
    fi

    fingerprint="$(sha256sum "$der_tmp" 2>/dev/null)" || {
        rm -f "$b64_tmp" "$der_tmp"
        return 1
    }
    fingerprint="${fingerprint%% *}"
    rm -f "$b64_tmp" "$der_tmp"

    server_runtime_ucode valid-sha256-hex "$fingerprint" >/dev/null 2>&1 || return 1
    printf '%s\n' "$fingerprint"
}

get_tls_certificate_sha256() {
    local section="$1"
    local protocol security certificate_path fingerprint

    if [ -z "$section" ]; then
        server_runtime_ucode error-response "Missing server section"
        return 1
    fi

    config_get protocol "$section" "protocol" "vless"
    security="$(server_effective_security "$section" "$protocol")"
    if [ "$security" != "tls" ]; then
        server_runtime_ucode error-response "Server does not use TLS"
        return 1
    fi

    config_get certificate_path "$section" "tls_certificate_path"
    if [ -z "$certificate_path" ]; then
        server_runtime_ucode error-response "TLS certificate path is empty"
        return 1
    fi

    fingerprint="$(server_tls_certificate_sha256_from_file "$certificate_path")" || {
        server_runtime_ucode error-response "Failed to read TLS certificate fingerprint"
        return 1
    }

    server_runtime_ucode tls-fingerprint-response "$fingerprint"
}

server_is_public_ipv4() {
    server_runtime_ucode valid-public-ipv4 "$1" >/dev/null 2>&1
}

server_cidr_is_valid() {
    server_runtime_ucode valid-cidr "$1" >/dev/null 2>&1
}

server_detect_default_public_host() {
    local interface ip lan_ip

    for interface in wan wwan; do
        ip="$(ubus -S call "network.interface.$interface" status 2>/dev/null | helpers_ucode network-status-ipv4-address 2>/dev/null)"
        if server_is_public_ipv4 "$ip"; then
            printf '%s\n' "$ip"
            return 0
        fi
    done

    lan_ip="$(uci -q get network.lan.ipaddr 2>/dev/null)"
    if server_runtime_ucode valid-dotted-ipv4 "$lan_ip" >/dev/null 2>&1; then
        printf '%s\n' "$lan_ip"
    fi
}

server_first_user_entry_handler() {
    local entry="$1"

    [ -n "$SERVER_FIRST_USER_ENTRY" ] && return 0
    SERVER_FIRST_USER_ENTRY="$entry"
}

server_prepare_legacy_user_defaults() {
    local section="$1"
    local protocol="$2"
    local entry name rest credential extra mtproto_faketls

    SERVER_FIRST_USER_ENTRY=""
    config_list_foreach "$section" "server_users" server_first_user_entry_handler
    entry="$SERVER_FIRST_USER_ENTRY"
    SERVER_FIRST_USER_ENTRY=""
    [ -n "$entry" ] || return 0

    name="${entry%%|*}"
    if [ "$entry" = "$name" ]; then
        credential="$entry"
        name="client"
        extra=""
    else
        rest="${entry#*|}"
        credential="${rest%%|*}"
        if [ "$rest" = "$credential" ]; then
            extra=""
        else
            extra="${rest#*|}"
        fi
    fi

    case "$protocol" in
    vless | vmess)
        server_default_set_option "$section" "server_uuid" "$credential"
        ;;
    shadowsocks | socks | trojan | hysteria2)
        server_default_set_option "$section" "server_password" "$credential"
        ;;
    mtproto)
        mtproto_faketls="$(server_mtproto_faketls_from_secret "$credential" 2>/dev/null || true)"
        credential="$(server_mtproto_base_secret_from_value "$credential" 2>/dev/null || printf '%s' "$credential")"
        server_default_set_option "$section" "mtproto_secret" "$credential"
        server_default_set_option "$section" "mtproto_faketls" "${mtproto_faketls:-google.com}"
        server_default_set_option "$section" "mtproto_padding" "1"
        ;;
    esac
    if [ "$protocol" = "socks" ] && [ -n "$name" ]; then
        server_default_set_option "$section" "server_username" "$name"
    fi
    if [ "$protocol" = "vless" ] && [ -n "$extra" ]; then
        server_default_set_option "$section" "vless_flow" "$extra"
    fi
}

server_prepare_tls_defaults() {
    local section="$1"
    local protocol="$2"
    local security="$3"
    local enabled tls_server_name certificate_path key_path safe_name default_dir

    [ "$security" = "tls" ] || return 0
    config_get_bool enabled "$section" "enabled" 1
    [ "$enabled" -eq 1 ] || return 0

    config_get tls_server_name "$section" "tls_server_name"
    [ -n "$tls_server_name" ] || tls_server_name="www.microsoft.com"
    server_default_set_option "$section" "tls_server_name" "$tls_server_name"

    config_get certificate_path "$section" "tls_certificate_path"
    config_get key_path "$section" "tls_key_path"
    if [ -z "$certificate_path" ] || [ -z "$key_path" ]; then
        safe_name="$(server_safe_filename "$section")"
        default_dir="/etc/podkop-plus/server-certs"
        certificate_path="${certificate_path:-$default_dir/$safe_name.crt}"
        key_path="${key_path:-$default_dir/$safe_name.key}"
        server_set_option "$section" "tls_certificate_path" "$certificate_path"
        server_set_option "$section" "tls_key_path" "$key_path"
    fi

    if ! server_file_path_is_valid "$certificate_path"; then
        log "Server '$section' has invalid TLS certificate path. Specify a file path. Aborted." "fatal"
        exit 1
    fi
    if ! server_file_path_is_valid "$key_path"; then
        log "Server '$section' has invalid TLS key path. Specify a file path. Aborted." "fatal"
        exit 1
    fi
    if [ "$certificate_path" = "$key_path" ]; then
        log "Server '$section' has the same TLS certificate and key path. Specify different files. Aborted." "fatal"
        exit 1
    fi

    if [ ! -s "$certificate_path" ] || [ ! -s "$key_path" ]; then
        log "Generating self-signed TLS certificate for server '$section'" "info"
        if ! server_generate_tls_keypair_files "$tls_server_name" "$certificate_path" "$key_path"; then
            log "Failed to generate TLS certificate for server '$section'. Aborted." "fatal"
            exit 1
        fi
    fi
}

prepare_server_defaults() {
    local section="$1"
    local protocol security uuid password server_username label short_id reality_private_key reality_public_key safe_name mtproto_secret mtproto_base_secret mtproto_faketls

    config_get protocol "$section" "protocol" "vless"
    case "$protocol" in
    shadowsocks | socks | vmess | vless | trojan | hysteria2 | mtproto | tailscale | json_inbound) ;;
    *)
        log "Server '$section' has unsupported protocol '$protocol'. Aborted." "fatal"
        exit 1
        ;;
    esac

    server_default_set_option "$section" "protocol" "$protocol"
    server_default_set_option "$section" "label" "$section"
    server_default_set_option "$section" "enabled" "1"
    server_default_set_option "$section" "routing_mode" "rules"

    if [ "$protocol" = "json_inbound" ]; then
        server_set_option "$section" "security" "none"
        return 0
    fi

    server_default_set_option "$section" "listen" "0.0.0.0"
    server_default_set_option "$section" "listen_port" "443"
    server_default_set_option "$section" "public_host" "$(server_detect_default_public_host)"

    security="$(server_effective_security "$section" "$protocol")"
    server_set_option "$section" "security" "$security"

    server_prepare_legacy_user_defaults "$section" "$protocol"

    case "$protocol" in
    vless | vmess)
        uuid="$(uci -q get "$PODKOP_CONFIG_NAME.$section.server_uuid" 2>/dev/null)"
        if [ -z "$uuid" ]; then
            uuid="$(server_generate_uuid)"
            server_default_set_option "$section" "server_uuid" "$uuid"
        fi
        ;;
    shadowsocks | socks | trojan | hysteria2)
        password="$(uci -q get "$PODKOP_CONFIG_NAME.$section.server_password" 2>/dev/null)"
        if [ -z "$password" ]; then
            password="$(server_generate_password)"
            server_default_set_option "$section" "server_password" "$password"
        fi
        ;;
    esac

    if [ "$protocol" = "mtproto" ]; then
        mtproto_secret="$(uci -q get "$PODKOP_CONFIG_NAME.$section.mtproto_secret" 2>/dev/null)"
        mtproto_faketls="$(server_mtproto_faketls_from_secret "$mtproto_secret" 2>/dev/null || true)"
        mtproto_base_secret="$(server_mtproto_base_secret_from_value "$mtproto_secret" 2>/dev/null || true)"
        if [ -z "$mtproto_base_secret" ]; then
            mtproto_base_secret="$(server_generate_mtproto_secret)"
        fi
        if [ "$mtproto_secret" != "$mtproto_base_secret" ]; then
            server_set_option "$section" "mtproto_secret" "$mtproto_base_secret"
        fi
        server_default_set_option "$section" "mtproto_faketls" "${mtproto_faketls:-google.com}"
        server_default_set_option "$section" "mtproto_padding" "1"
        server_default_set_option "$section" "mtproto_domain_fronting_port" "443"
        server_default_set_option "$section" "mtproto_prefer_ip" "prefer-ipv4"
        server_default_set_option "$section" "mtproto_tolerate_time_skewness" "3s"
        server_default_set_option "$section" "mtproto_idle_timeout" "5m"
        server_default_set_option "$section" "mtproto_handshake_timeout" "10s"
    fi

    if [ "$protocol" = "socks" ]; then
        server_username="$(uci -q get "$PODKOP_CONFIG_NAME.$section.server_username" 2>/dev/null)"
        if [ -z "$server_username" ]; then
            config_get label "$section" "label" "$section"
            server_default_set_option "$section" "server_username" "$label"
        fi
    fi

    if [ "$protocol" = "vless" ]; then
        server_default_set_option "$section" "vless_flow" "none"
    fi
    if [ "$protocol" = "vmess" ]; then
        server_default_set_option "$section" "vmess_alter_id" "0"
    fi
    if [ "$protocol" = "shadowsocks" ]; then
        server_default_set_option "$section" "shadowsocks_method" "aes-128-gcm"
    fi
    if [ "$protocol" = "tailscale" ]; then
        safe_name="$(server_safe_filename "$section")"
        server_default_set_option "$section" "tailscale_control_url" "https://controlplane.tailscale.com"
        server_default_set_option "$section" "tailscale_hostname" "podkop-$safe_name"
        server_default_set_option "$section" "tailscale_advertise_exit_node" "1"
    fi

    if [ "$security" = "reality" ]; then
        server_default_set_option "$section" "tls_server_name" "www.microsoft.com"
        server_default_set_option "$section" "client_fingerprint" "chrome"
        server_default_set_option "$section" "reality_handshake_server" "www.microsoft.com"
        server_default_set_option "$section" "reality_handshake_server_port" "443"
        short_id="$(uci -q get "$PODKOP_CONFIG_NAME.$section.reality_short_id" 2>/dev/null)"
        if [ -z "$short_id" ]; then
            server_default_set_option "$section" "reality_short_id" "$(server_generate_short_id)"
        fi
        server_default_set_option "$section" "reality_max_time_difference" "1m"

        reality_private_key="$(uci -q get "$PODKOP_CONFIG_NAME.$section.reality_private_key" 2>/dev/null)"
        reality_public_key="$(uci -q get "$PODKOP_CONFIG_NAME.$section.reality_public_key" 2>/dev/null)"
        if [ -z "$reality_private_key" ] || [ -z "$reality_public_key" ]; then
            log "Generating Reality key pair for server '$section'" "info"
            if ! server_generate_reality_keypair; then
                log "Failed to generate Reality key pair for server '$section'. Aborted." "fatal"
                exit 1
            fi
            server_set_option "$section" "reality_private_key" "$SERVER_REALITY_PRIVATE_KEY"
            server_set_option "$section" "reality_public_key" "$SERVER_REALITY_PUBLIC_KEY"
        fi
    fi

    server_prepare_tls_defaults "$section" "$protocol" "$security"
}

prepare_server_defaults_handler() {
    prepare_server_defaults "$1"
}

prepare_all_server_defaults() {
    SERVER_DEFAULTS_CHANGED=0
    config_foreach prepare_server_defaults_handler "server"
    if [ "$SERVER_DEFAULTS_CHANGED" -eq 1 ]; then
        commit_podkop_config
    fi
}

server_write_users_json() {
    local section="$1"
    local protocol="$2"
    local tsv_tmp users_tmp user_count server_user_name server_uuid server_password vless_flow vmess_alter_id credential extra \
        mtproto_base_secret mtproto_faketls mtproto_padding

    tsv_tmp="$(mktemp)" || return 1
    users_tmp="$(mktemp)" || {
        rm -f "$tsv_tmp"
        return 1
    }

    config_get server_user_name "$section" "label" "$section"
    [ -n "$server_user_name" ] || server_user_name="$section"

    case "$protocol" in
    vless | vmess)
        config_get server_uuid "$section" "server_uuid"
        credential="$server_uuid"
        if ! server_runtime_ucode valid-uuid "$credential" >/dev/null 2>&1; then
            rm -f "$tsv_tmp" "$users_tmp"
            log "Server '$section' has an invalid client UUID. Aborted." "fatal"
            exit 1
        fi
        if [ "$protocol" = "vless" ]; then
            config_get vless_flow "$section" "vless_flow"
            [ "$vless_flow" != "none" ] || vless_flow=""
            if [ -n "$vless_flow" ] && [ "$vless_flow" != "xtls-rprx-vision" ]; then
                rm -f "$tsv_tmp" "$users_tmp"
                log "Server '$section' has unsupported VLESS flow '$vless_flow'. Aborted." "fatal"
                exit 1
            fi
            extra="$vless_flow"
        else
            config_get vmess_alter_id "$section" "vmess_alter_id" "0"
            if ! server_runtime_ucode valid-nonnegative-integer "$vmess_alter_id" >/dev/null 2>&1; then
                rm -f "$tsv_tmp" "$users_tmp"
                log "Server '$section' has invalid VMess alter_id '$vmess_alter_id'. Use a non-negative integer. Aborted." "fatal"
                exit 1
            fi
            extra="$vmess_alter_id"
        fi
        ;;
    socks)
        config_get server_user_name "$section" "server_username"
        if [ -z "$server_user_name" ]; then
            config_get server_user_name "$section" "label" "$section"
        fi
        [ -n "$server_user_name" ] || server_user_name="$section"
        config_get server_password "$section" "server_password"
        credential="$server_password"
        extra=""
        ;;
    trojan | hysteria2)
        config_get server_password "$section" "server_password"
        credential="$server_password"
        extra=""
        ;;
    mtproto)
        config_get server_password "$section" "mtproto_secret"
        config_get mtproto_faketls "$section" "mtproto_faketls" "google.com"
        config_get_bool mtproto_padding "$section" "mtproto_padding" 1
        mtproto_base_secret="$(server_mtproto_base_secret_from_value "$server_password" 2>/dev/null || true)"
        if ! server_mtproto_base_secret_is_valid "$mtproto_base_secret"; then
            rm -f "$tsv_tmp" "$users_tmp"
            log "Server '$section' has invalid base secret. Use 32 non-zero hex characters. Aborted." "fatal"
            exit 1
        fi
        if ! server_host_is_valid "$mtproto_faketls"; then
            rm -f "$tsv_tmp" "$users_tmp"
            log "Server '$section' has invalid FakeTLS host '$mtproto_faketls'. Use a domain name or IPv4 address. Aborted." "fatal"
            exit 1
        fi
        if [ "$mtproto_padding" -ne 1 ]; then
            rm -f "$tsv_tmp" "$users_tmp"
            log "Server '$section' has padding disabled, but sing-box-extended MTProxy requires padded FakeTLS secrets. Aborted." "fatal"
            exit 1
        fi
        credential="$(server_build_mtproto_secret "$mtproto_base_secret" "$mtproto_faketls" "$mtproto_padding")"
        extra=""
        ;;
    *)
        rm -f "$tsv_tmp" "$users_tmp"
        return 1
        ;;
    esac

    if ! server_client_value_is_valid "$server_user_name"; then
        rm -f "$tsv_tmp" "$users_tmp"
        log "Server '$section' has invalid client name. It must not contain control characters. Aborted." "fatal"
        exit 1
    fi

    if [ -z "$credential" ]; then
        rm -f "$tsv_tmp" "$users_tmp"
        log "Server '$section' has no client credential. Aborted." "fatal"
        exit 1
    fi
    if ! server_client_value_is_valid "$credential"; then
        rm -f "$tsv_tmp" "$users_tmp"
        log "Server '$section' has invalid client credential. It must not contain control characters. Aborted." "fatal"
        exit 1
    fi

    printf '%s\t%s\t%s\n' "$server_user_name" "$credential" "$extra" > "$tsv_tmp"

    if ! server_runtime_ucode server-users-from-tsv "$protocol" "$tsv_tmp" > "$users_tmp"; then
        rm -f "$tsv_tmp" "$users_tmp"
        return 1
    fi

    rm -f "$tsv_tmp"

    user_count="$(server_runtime_ucode json-length "$users_tmp" 2>/dev/null)"
    case "$user_count" in
    '' | *[!0-9]*) user_count=0 ;;
    esac
    if [ "$user_count" -eq 0 ]; then
        rm -f "$users_tmp"
        log "Server '$section' has no valid users configured. Aborted." "fatal"
        exit 1
    fi

    printf '%s\n' "$users_tmp"
}

validate_server_reality_short_id() {
    local value="$1"
    local section="$2"

    if ! server_runtime_ucode valid-reality-short-id "$value" >/dev/null 2>&1; then
        log "Server '$section' has invalid Reality short_id '$value'. Use 1-8 hex digits. Aborted." "fatal"
        exit 1
    fi
}

validate_server_reality_short_id_counted() {
    SERVER_REALITY_SHORT_ID_COUNT=$((SERVER_REALITY_SHORT_ID_COUNT + 1))
    validate_server_reality_short_id "$@"
}

validate_server_reality_short_ids() {
    local section="$1"
    local value

    SERVER_REALITY_SHORT_ID_COUNT=0
    config_list_foreach "$section" "reality_short_id" validate_server_reality_short_id_counted "$section"
    if [ "$SERVER_REALITY_SHORT_ID_COUNT" -eq 0 ]; then
        config_get value "$section" "reality_short_id"
        if [ -n "$value" ]; then
            SERVER_REALITY_SHORT_ID_COUNT=1
            validate_server_reality_short_id "$value" "$section"
        fi
    fi
}

validate_server_transport_host_handler() {
    local value="$1"
    local section="$2"

    [ -n "$value" ] || return 0
    if ! server_host_is_valid "$value"; then
        log "Server '$section' has invalid HTTP transport host '$value'. Use a domain name or IPv4 address. Aborted." "fatal"
        exit 1
    fi
}

server_apply_tls() {
    local section="$1"
    local inbound_tag="$2"
    local protocol security tls_server_name tls_alpn tls_certificate_path tls_key_path \
        reality_handshake_server reality_handshake_server_port reality_private_key \
        reality_short_id reality_max_time_difference

    config_get protocol "$section" "protocol" "vless"
    security="$(server_effective_security "$section" "$protocol")"
    case "$security" in
    none | tls | reality) ;;
    *)
        log "Server '$section' has unsupported security '$security'. Aborted." "fatal"
        exit 1
        ;;
    esac

    [ "$security" != "none" ] || return 0

    config_get tls_server_name "$section" "tls_server_name"
    tls_alpn="$(config_list_to_json "$section" "tls_alpn")"
    config_get tls_certificate_path "$section" "tls_certificate_path"
    config_get tls_key_path "$section" "tls_key_path"
    config_get reality_handshake_server "$section" "reality_handshake_server" "www.microsoft.com"
    config_get reality_handshake_server_port "$section" "reality_handshake_server_port" "443"
    config_get reality_private_key "$section" "reality_private_key"
    reality_short_id="$(config_list_to_json "$section" "reality_short_id")"
    config_get reality_max_time_difference "$section" "reality_max_time_difference" "1m"

    if ! server_host_is_valid "$tls_server_name"; then
        log "Server '$section' has invalid TLS server name/SNI '$tls_server_name'. Use a domain name or IPv4 address. Aborted." "fatal"
        exit 1
    fi

    if [ "$security" = "tls" ]; then
        if [ -z "$tls_certificate_path" ] || [ -z "$tls_key_path" ]; then
            log "Server '$section' uses TLS but certificate/key paths are empty. Aborted." "fatal"
            exit 1
        fi
        if ! server_file_path_is_valid "$tls_certificate_path"; then
            log "Server '$section' has invalid TLS certificate path. Specify a file path. Aborted." "fatal"
            exit 1
        fi
        if ! server_file_path_is_valid "$tls_key_path"; then
            log "Server '$section' has invalid TLS key path. Specify a file path. Aborted." "fatal"
            exit 1
        fi
        if [ "$tls_certificate_path" = "$tls_key_path" ]; then
            log "Server '$section' has the same TLS certificate and key path. Specify different files. Aborted." "fatal"
            exit 1
        fi
    fi

    if [ "$security" = "reality" ]; then
        if [ -z "$reality_handshake_server" ] || ! server_host_is_valid "$reality_handshake_server" || ! server_port_is_valid "$reality_handshake_server_port"; then
            log "Server '$section' has invalid Reality handshake target. Aborted." "fatal"
            exit 1
        fi
        if [ -z "$reality_private_key" ]; then
            log "Server '$section' uses Reality but private key is not set. Aborted." "fatal"
            exit 1
        fi
        if ! server_duration_is_valid "$reality_max_time_difference"; then
            log "Server '$section' has invalid Reality max time difference '$reality_max_time_difference'. Use a duration like 30s, 5m, or 1h30m. Aborted." "fatal"
            exit 1
        fi
        validate_server_reality_short_ids "$section"
        if [ "$reality_short_id" = "[]" ]; then
            log "Server '$section' uses Reality but short_id is not set. Aborted." "fatal"
            exit 1
        fi
    fi

    config=$(
        sing_box_cm_set_tls_for_inbound \
            "$config" \
            "$inbound_tag" \
            "$security" \
            "$tls_server_name" \
            "$tls_alpn" \
            "$tls_certificate_path" \
            "$tls_key_path" \
            "$reality_handshake_server" \
            "$reality_handshake_server_port" \
            "$reality_private_key" \
            "$reality_short_id" \
            "$reality_max_time_difference"
    )
}

server_apply_transport() {
    local section="$1"
    local inbound_tag="$2"
    local protocol transport transport_path transport_host transport_service_name transport_hosts transport_xhttp_mode

    config_get protocol "$section" "protocol" "vless"
    case "$protocol" in
    vless | vmess | trojan) ;;
    *) return 0 ;;
    esac

    config_get transport "$section" "transport" "tcp"
    if ! config_validation_ucode enum-valid "$transport" tcp raw ws grpc http httpupgrade xhttp >/dev/null 2>&1; then
        log "Server '$section' has unsupported transport '$transport'. Aborted." "fatal"
        exit 1
    fi

    [ "$transport" != "tcp" ] && [ "$transport" != "raw" ] || return 0

    config_get transport_path "$section" "transport_path"
    config_get transport_host "$section" "transport_host"
    config_get transport_service_name "$section" "transport_service_name"
    config_get transport_xhttp_mode "$section" "transport_xhttp_mode" "auto"
    transport_hosts="$(config_list_to_json "$section" "transport_hosts")"

    case "$transport" in
    ws | http | httpupgrade | xhttp)
        if [ -n "$transport_path" ]; then
            case "$transport_path" in
            /*) ;;
            *)
                log "Server '$section' has invalid transport path '$transport_path'. It must start with /. Aborted." "fatal"
                exit 1
                ;;
            esac
        fi
        ;;
    esac
    if [ -n "$transport_host" ] && ! server_host_is_valid "$transport_host"; then
        log "Server '$section' has invalid transport host '$transport_host'. Use a domain name or IPv4 address. Aborted." "fatal"
        exit 1
    fi
    config_list_foreach "$section" "transport_hosts" validate_server_transport_host_handler "$section"
    if [ -n "$transport_service_name" ] && ! server_runtime_ucode valid-transport-service-name "$transport_service_name" >/dev/null 2>&1; then
        log "Server '$section' has invalid gRPC service name '$transport_service_name'. Aborted." "fatal"
        exit 1
    fi
    if [ "$transport" = "xhttp" ]; then
        if ! config_validation_ucode enum-valid "$transport_xhttp_mode" auto packet-up stream-up stream-one >/dev/null 2>&1; then
            log "Server '$section' has unsupported XHTTP mode '$transport_xhttp_mode'. Aborted." "fatal"
            exit 1
        fi
    fi

    config=$(
        sing_box_cm_set_transport_for_inbound \
            "$config" \
            "$inbound_tag" \
            "$transport" \
            "$transport_path" \
            "$transport_host" \
            "$transport_service_name" \
            "$transport_hosts" \
            "$transport_xhttp_mode"
    )
}
