#
# Module: sing_box_config_manager.sh
#
# Purpose:
#   Thin ash wrappers for sing_box_config_manager.uc. Shell remains the
#   orchestration layer; JSON configuration mutations happen in ucode.
#

SERVICE_TAG="__service_tag"

sing_box_cm_ucode() {
    local operation="$1"
    local config="$2"
    shift 2

    printf '%s' "$config" |
        ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/sing_box_config_manager.uc" "$operation" "$@"
}

sing_box_cm_configure_log() {
    sing_box_cm_ucode configure-log "$1" "$2" "$3" "$4"
}

sing_box_cm_configure_dns() {
    sing_box_cm_ucode configure-dns "$1" "$2" "$3" "$4"
}

sing_box_cm_add_udp_dns_server() {
    sing_box_cm_ucode add-udp-dns-server "$1" "$2" "$3" "$4" "$5" "$6"
}

sing_box_cm_add_tls_dns_server() {
    sing_box_cm_ucode add-tls-dns-server "$1" "$2" "$3" "$4" "$5" "$6"
}

sing_box_cm_add_https_dns_server() {
    sing_box_cm_ucode add-https-dns-server "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}

sing_box_cm_add_fakeip_dns_server() {
    sing_box_cm_ucode add-fakeip-dns-server "$1" "$2" "$3"
}

sing_box_cm_add_dns_route_rule() {
    sing_box_cm_ucode add-dns-route-rule "$1" "$2" "$3"
}

sing_box_cm_patch_dns_route_rule() {
    sing_box_cm_ucode patch-dns-route-rule "$1" "$2" "$3" "$4"
}

sing_box_cm_add_dns_reject_rule() {
    sing_box_cm_ucode add-dns-reject-rule "$1" "$2" "$3"
}

sing_box_cm_add_tproxy_inbound() {
    sing_box_cm_ucode add-tproxy-inbound "$1" "$2" "$3" "$4" "$5" "$6"
}

sing_box_cm_add_direct_inbound() {
    sing_box_cm_ucode add-direct-inbound "$1" "$2" "$3" "$4"
}

sing_box_cm_add_mixed_inbound() {
    sing_box_cm_ucode add-mixed-inbound "$1" "$2" "$3" "$4" "$5" "$6"
}

sing_box_cm_add_vless_inbound() {
    sing_box_cm_ucode add-vless-inbound-file "$1" "$2" "$3" "$4" "$5"
}

sing_box_cm_add_trojan_inbound() {
    sing_box_cm_ucode add-trojan-inbound-file "$1" "$2" "$3" "$4" "$5"
}

sing_box_cm_add_vmess_inbound() {
    sing_box_cm_ucode add-vmess-inbound-file "$1" "$2" "$3" "$4" "$5"
}

sing_box_cm_add_socks_inbound() {
    sing_box_cm_ucode add-socks-inbound-file "$1" "$2" "$3" "$4" "$5"
}

sing_box_cm_add_shadowsocks_inbound() {
    sing_box_cm_ucode add-shadowsocks-inbound "$1" "$2" "$3" "$4" "$5" "$6"
}

sing_box_cm_add_hysteria2_inbound() {
    sing_box_cm_ucode add-hysteria2-inbound-file "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
}

sing_box_cm_add_tailscale_endpoint() {
    sing_box_cm_ucode add-tailscale-endpoint "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" "${13}"
}

sing_box_cm_set_tls_for_inbound() {
    sing_box_cm_ucode set-inbound-tls "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}"
}

sing_box_cm_set_transport_for_inbound() {
    sing_box_cm_ucode set-inbound-transport "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

sing_box_cm_add_direct_outbound() {
    sing_box_cm_ucode add-direct-outbound "$1" "$2" "$3"
}

sing_box_cm_add_socks_outbound() {
    sing_box_cm_ucode add-socks-outbound "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
}

sing_box_cm_add_shadowsocks_outbound() {
    sing_box_cm_ucode add-shadowsocks-outbound "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}"
}

sing_box_cm_add_vless_outbound() {
    sing_box_cm_ucode add-vless-outbound "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}

sing_box_cm_add_trojan_outbound() {
    sing_box_cm_ucode add-trojan-outbound "$1" "$2" "$3" "$4" "$5" "$6"
}

sing_box_cm_add_hysteria2_outbound() {
    sing_box_cm_ucode add-hysteria2-outbound "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}"
}

sing_box_cm_set_grpc_transport_for_outbound() {
    sing_box_cm_ucode set-grpc-transport "$1" "$2" "$3" "$4" "$5" "$6"
}

sing_box_cm_set_ws_transport_for_outbound() {
    sing_box_cm_ucode set-ws-transport "$1" "$2" "$3" "$4" "$5" "$6"
}

sing_box_cm_set_http_transport_for_outbound() {
    sing_box_cm_ucode set-http-transport "$1" "$2" "$3" "$4"
}

sing_box_cm_set_httpupgrade_transport_for_outbound() {
    sing_box_cm_ucode set-httpupgrade-transport "$1" "$2" "$3" "$4"
}

sing_box_cm_set_xhttp_transport_for_outbound() {
    sing_box_cm_ucode set-xhttp-transport "$1" "$2" "$3" "$4" "$5"
}

sing_box_cm_set_tls_for_outbound() {
    sing_box_cm_ucode set-tls "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}

sing_box_cm_add_interface_outbound() {
    sing_box_cm_ucode add-interface-outbound "$1" "$2" "$3" "$4"
}

sing_box_cm_add_raw_outbound() {
    sing_box_cm_ucode add-raw-outbound "$1" "$2" "$3"
}

sing_box_cm_add_urltest_outbound() {
    local config="$1"
    local tag="$2"
    local outbounds="$3"
    local url="$4"
    local interval="$5"
    local tolerance="$6"
    local idle_timeout="$7"
    local interrupt="$8"
    local outbounds_tmp result status

    outbounds_tmp="$(mktemp)" || return 1
    printf '%s' "$outbounds" > "$outbounds_tmp" || {
        rm -f "$outbounds_tmp"
        return 1
    }

    result="$(sing_box_cm_ucode add-urltest-outbound-file "$config" "$tag" "$outbounds_tmp" \
        "$url" "$interval" "$tolerance" "$idle_timeout" "$interrupt")"
    status=$?
    rm -f "$outbounds_tmp"

    [ "$status" -eq 0 ] || return 1
    [ -n "$result" ] || return 1
    printf '%s\n' "$result"
}

sing_box_cm_add_selector_outbound() {
    local config="$1"
    local tag="$2"
    local outbounds="$3"
    local default="$4"
    local interrupt="$5"
    local outbounds_tmp result status

    outbounds_tmp="$(mktemp)" || return 1
    printf '%s' "$outbounds" > "$outbounds_tmp" || {
        rm -f "$outbounds_tmp"
        return 1
    }

    result="$(sing_box_cm_ucode add-selector-outbound-file "$config" "$tag" "$outbounds_tmp" "$default" "$interrupt")"
    status=$?
    rm -f "$outbounds_tmp"

    [ "$status" -eq 0 ] || return 1
    [ -n "$result" ] || return 1
    printf '%s\n' "$result"
}

sing_box_cm_configure_route() {
    sing_box_cm_ucode configure-route "$1" "$2" "$3" "$4" "$5" "$6"
}

sing_box_cm_add_route_rule() {
    sing_box_cm_ucode add-route-rule "$1" "$2" "$3" "$4"
}

sing_box_cm_add_resolve_rule() {
    sing_box_cm_ucode add-resolve-rule "$1" "$2" "$3" "${4:-dns-server}"
}

sing_box_cm_patch_route_rule() {
    sing_box_cm_ucode patch-route-rule "$1" "$2" "$3" "$4"
}

sing_box_cm_add_reject_route_rule() {
    sing_box_cm_ucode add-reject-route-rule "$1" "$2" "$3"
}

sing_box_cm_add_hijack_dns_route_rule() {
    sing_box_cm_ucode add-hijack-dns-route-rule "$1" "$2" "$3"
}

sing_box_cm_add_options_route_rule() {
    sing_box_cm_ucode add-options-route-rule "$1" "$2"
}

sing_box_cm_sniff_route_rule() {
    sing_box_cm_ucode sniff-route-rule "$1" "$2" "$3"
}

sing_box_cm_clone_route_rules_for_inbound() {
    sing_box_cm_ucode clone-route-rules-for-inbound "$1" "$2" "$3" "$4"
}

sing_box_cm_add_inline_ruleset() {
    sing_box_cm_ucode add-inline-ruleset "$1" "$2"
}

sing_box_cm_add_inline_ruleset_rule() {
    sing_box_cm_ucode add-inline-ruleset-rule "$1" "$2" "$3" "$4"
}

sing_box_cm_add_local_ruleset() {
    sing_box_cm_ucode add-local-ruleset "$1" "$2" "$3" "$4"
}

sing_box_cm_add_remote_ruleset() {
    sing_box_cm_ucode add-remote-ruleset "$1" "$2" "$3" "$4" "$5" "$6"
}

sing_box_cm_configure_cache_file() {
    sing_box_cm_ucode configure-cache-file "$1" "$2" "$3" "$4"
}

sing_box_cm_configure_clash_api() {
    sing_box_cm_ucode configure-clash-api "$1" "$2" "$3" "$4"
}

sing_box_cm_save_config_to_file() {
    local config="$1"
    local filepath="$2"

    printf '%s' "$config" |
        ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/sing_box_config_manager.uc" save-config "$filepath"
}

_normalize_arg() {
    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/sing_box_config_manager.uc" normalize-arg "$1"
}
