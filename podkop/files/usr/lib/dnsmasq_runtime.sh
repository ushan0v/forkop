# shellcheck shell=ash

uci_del_list_value() {
    local package="$1"
    local section="$2"
    local option="$3"
    local value="$4"

    uci -q del_list "$package.$section.$option=$value" >/dev/null 2>&1
}

uci_remove_quiet() {
    local package="$1"
    local section="$2"
    local option="${3:-}"

    uci -q delete "$package.$section${option:+.$option}" >/dev/null 2>&1
}

dnsmasq_server_list_has_podkop_dns() {
    local server_list="$1"
    local server

    for server in $server_list; do
        [ "$server" = "$SB_DNS_INBOUND_ADDRESS" ] && return 0
    done

    return 1
}

dnsmasq_default_has_podkop_dns() {
    dnsmasq_server_list_has_podkop_dns "$(uci_get "dhcp" "@dnsmasq[0]" "server")"
}

dnsmasq_legacy_instance_exists() {
    uci -q show "dhcp.podkop_plus" >/dev/null 2>&1
}

dnsmasq_has_podkop_dns() {
    dnsmasq_default_has_podkop_dns || dnsmasq_legacy_instance_exists
}

dnsmasq_management_disabled() {
    local dont_touch_dhcp

    config_get_bool dont_touch_dhcp "settings" "dont_touch_dhcp" 0
    [ "$dont_touch_dhcp" -eq 1 ]
}

dnsmasq_default_config_is_complete() {
    local cachesize noresolv

    noresolv="$(uci_get "dhcp" "@dnsmasq[0]" "noresolv")"
    cachesize="$(uci_get "dhcp" "@dnsmasq[0]" "cachesize")"

    dnsmasq_default_has_podkop_dns || return 1
    [ "$noresolv" = "1" ] || return 1
    [ "$cachesize" = "0" ] || return 1
    ! dnsmasq_legacy_instance_exists || return 1

    return 0
}

backup_dnsmasq_config_option() {
    local key="$1"
    local backup_key="$2"
    local value

    [ -n "$(uci_get "dhcp" "@dnsmasq[0]" "$backup_key")" ] && return 0

    value="$(uci_get "dhcp" "@dnsmasq[0]" "$key")"
    [ -n "$value" ] || return 0

    uci_set "dhcp" "@dnsmasq[0]" "$backup_key" "$value"
}

backup_dnsmasq_server_list() {
    local server backup_servers

    backup_servers="$(uci_get "dhcp" "@dnsmasq[0]" "podkop_server")"
    [ -n "$backup_servers" ] && return 0

    for server in $(uci_get "dhcp" "@dnsmasq[0]" "server"); do
        [ "$server" = "$SB_DNS_INBOUND_ADDRESS" ] && continue
        uci_add_list "dhcp" "@dnsmasq[0]" "podkop_server" "$server"
    done
}

restore_dnsmasq_config_option() {
    local key="$1"
    local backup_key="$2"
    local default_value="${3:-}"
    local value

    value="$(uci_get "dhcp" "@dnsmasq[0]" "$backup_key")"
    if [ -n "$value" ]; then
        uci_set "dhcp" "@dnsmasq[0]" "$key" "$value"
        uci_remove_quiet "dhcp" "@dnsmasq[0]" "$backup_key"
    elif [ -n "$default_value" ]; then
        uci_set "dhcp" "@dnsmasq[0]" "$key" "$default_value"
    else
        uci_remove_quiet "dhcp" "@dnsmasq[0]" "$key"
    fi
}

dnsmasq_legacy_interfaces() {
    local interfaces

    interfaces="$(uci_get "dhcp" "podkop_plus" "interface")"
    if [ -z "$interfaces" ]; then
        config_get interfaces "settings" "source_network_interfaces" "br-lan"
    fi

    printf '%s\n' "$interfaces"
}

dnsmasq_cleanup_legacy_instance() {
    local legacy_instance_present legacy_interfaces backup_notinterfaces value

    legacy_instance_present=0
    legacy_interfaces=""
    if dnsmasq_legacy_instance_exists; then
        legacy_instance_present=1
        legacy_interfaces="$(dnsmasq_legacy_interfaces)"
    fi

    uci_remove_quiet "dhcp" "podkop_plus"

    backup_notinterfaces="$(uci_get "dhcp" "@dnsmasq[0]" "podkop_notinterface")"
    if [ -n "$backup_notinterfaces" ]; then
        uci_remove_quiet "dhcp" "@dnsmasq[0]" "notinterface"
        for value in $backup_notinterfaces; do
            uci_add_list "dhcp" "@dnsmasq[0]" "notinterface" "$value"
        done
        uci_remove_quiet "dhcp" "@dnsmasq[0]" "podkop_notinterface"
        return 0
    fi

    [ "$legacy_instance_present" -eq 1 ] || return 0
    for value in $legacy_interfaces; do
        uci_del_list_value "dhcp" "@dnsmasq[0]" "notinterface" "$value"
    done
    uci_remove_quiet "dhcp" "@dnsmasq[0]" "podkop_notinterface"
}

dnsmasq_configure_default_instance() {
    local default_has_podkop_dns

    default_has_podkop_dns=0
    dnsmasq_default_has_podkop_dns && default_has_podkop_dns=1

    backup_dnsmasq_server_list
    if [ "$default_has_podkop_dns" -eq 0 ]; then
        backup_dnsmasq_config_option "noresolv" "podkop_noresolv"
        backup_dnsmasq_config_option "cachesize" "podkop_cachesize"
    fi

    uci_remove_quiet "dhcp" "@dnsmasq[0]" "server"
    uci_add_list "dhcp" "@dnsmasq[0]" "server" "$SB_DNS_INBOUND_ADDRESS"
    uci_set "dhcp" "@dnsmasq[0]" "noresolv" 1
    uci_set "dhcp" "@dnsmasq[0]" "cachesize" 0
}

dnsmasq_restore_default_instance() {
    local server_list backup_servers server managed_global_dns noresolv cachesize

    server_list="$(uci_get "dhcp" "@dnsmasq[0]" "server")"
    backup_servers="$(uci_get "dhcp" "@dnsmasq[0]" "podkop_server")"
    managed_global_dns=0
    dnsmasq_server_list_has_podkop_dns "$server_list" && managed_global_dns=1

    uci_remove_quiet "dhcp" "@dnsmasq[0]" "server"
    if [ -n "$backup_servers" ]; then
        for server in $backup_servers; do
            uci_add_list "dhcp" "@dnsmasq[0]" "server" "$server"
        done
        uci_remove_quiet "dhcp" "@dnsmasq[0]" "podkop_server"
    else
        for server in $server_list; do
            [ "$server" = "$SB_DNS_INBOUND_ADDRESS" ] && continue
            uci_add_list "dhcp" "@dnsmasq[0]" "server" "$server"
        done
    fi
    uci_remove_quiet "dhcp" "@dnsmasq[0]" "podkop_server"

    noresolv="$(uci_get "dhcp" "@dnsmasq[0]" "podkop_noresolv")"
    if [ -n "$noresolv" ]; then
        restore_dnsmasq_config_option "noresolv" "podkop_noresolv"
    elif [ "$managed_global_dns" -eq 1 ]; then
        uci_set "dhcp" "@dnsmasq[0]" "noresolv" 0
    fi

    cachesize="$(uci_get "dhcp" "@dnsmasq[0]" "podkop_cachesize")"
    if [ -n "$cachesize" ]; then
        restore_dnsmasq_config_option "cachesize" "podkop_cachesize"
    elif [ "$managed_global_dns" -eq 1 ]; then
        uci_set "dhcp" "@dnsmasq[0]" "cachesize" 150
    fi
}

dnsmasq_configure() {
    local force="${1:-0}"
    local shutdown_correctly
    config_get shutdown_correctly "settings" "shutdown_correctly"
    if [ "$force" != "force" ] && [ "$shutdown_correctly" -eq 0 ]; then
        if dnsmasq_default_config_is_complete; then
            log "Previous shutdown of Podkop Plus was not correct, dnsmasq is already configured"
            return 0
        else
            log "Previous shutdown of Podkop Plus was not correct, but dnsmasq is not configured correctly. Applying Podkop Plus DNS settings"
        fi
    fi

    log "Configure dnsmasq for sing-box"
    dnsmasq_cleanup_legacy_instance
    dnsmasq_configure_default_instance
    uci_commit "dhcp"

    /etc/init.d/dnsmasq restart
}

dnsmasq_restore() {
    local force="${1:-0}"
    log "Restoring the dnsmasq configuration"
    local shutdown_correctly
    config_get shutdown_correctly "settings" "shutdown_correctly"
    if [ "$force" != "force" ] && [ "$shutdown_correctly" -eq 1 ]; then
        if ! dnsmasq_has_podkop_dns; then
            log "Previous shutdown of Podkop Plus was correct, reconfiguration of dnsmasq is not required"
            return 0
        fi

        log "Previous shutdown of Podkop Plus was correct, but Podkop Plus DNS is still present. Restoring dnsmasq"
    fi

    dnsmasq_cleanup_legacy_instance
    dnsmasq_restore_default_instance

    uci_commit "dhcp"

    /etc/init.d/dnsmasq restart
}

dnsmasq_restore_fail_safe() {
    if dnsmasq_management_disabled; then
        log "Fail-safe: dont_touch_dhcp is enabled, leaving dnsmasq unchanged" "warn"
        return 0
    fi

    log "Fail-safe: restoring dnsmasq away from Podkop Plus DNS" "warn"

    dnsmasq_restore force >/dev/null 2>&1 || true

    if dnsmasq_has_podkop_dns; then
        podkop_dnsmasq_failsafe_restore_raw
    fi

    return 0
}
