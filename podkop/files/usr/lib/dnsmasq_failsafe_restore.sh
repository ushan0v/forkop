#!/bin/sh

PODKOP_CONFIG_NAME="${PODKOP_CONFIG_NAME:-podkop-plus}"
PODKOP_DNSMASQ_SECTION="${PODKOP_DNSMASQ_SECTION:-podkop_plus}"
SB_DNS_INBOUND_ADDRESS="${SB_DNS_INBOUND_ADDRESS:-127.0.0.42}"

podkop_dnsmasq_failsafe_restore() {
    local podkop_interfaces default_servers backup_servers backup_notinterfaces value
    local default_has_podkop_dns noresolv cachesize changed
    local split_instance_present

    command -v uci >/dev/null 2>&1 || return 0

    changed=0
    default_has_podkop_dns=0
    split_instance_present=0
    podkop_interfaces="$(uci -q get "dhcp.$PODKOP_DNSMASQ_SECTION.interface" 2>/dev/null)"
    [ -n "$podkop_interfaces" ] ||
        podkop_interfaces="$(uci -q get "$PODKOP_CONFIG_NAME.settings.source_network_interfaces" 2>/dev/null)"
    [ -n "$podkop_interfaces" ] || podkop_interfaces="br-lan"

    default_servers="$(uci -q get 'dhcp.@dnsmasq[0].server' 2>/dev/null)"
    for value in $default_servers; do
        [ "$value" = "$SB_DNS_INBOUND_ADDRESS" ] && default_has_podkop_dns=1
    done

    if uci -q show "dhcp.$PODKOP_DNSMASQ_SECTION" >/dev/null 2>&1; then
        split_instance_present=1
        changed=1
    fi
    uci -q delete "dhcp.$PODKOP_DNSMASQ_SECTION" >/dev/null 2>&1 || true

    backup_notinterfaces="$(uci -q get 'dhcp.@dnsmasq[0].podkop_notinterface' 2>/dev/null)"
    if [ -n "$backup_notinterfaces" ]; then
        uci -q delete 'dhcp.@dnsmasq[0].notinterface' >/dev/null 2>&1 || true
        for value in $backup_notinterfaces; do
            uci -q add_list "dhcp.@dnsmasq[0].notinterface=$value" >/dev/null 2>&1 || true
        done
        uci -q delete 'dhcp.@dnsmasq[0].podkop_notinterface' >/dev/null 2>&1 || true
        changed=1
    else
        if [ "$split_instance_present" -eq 1 ] || [ "$default_has_podkop_dns" -eq 1 ]; then
            for value in $podkop_interfaces; do
                uci -q del_list "dhcp.@dnsmasq[0].notinterface=$value" >/dev/null 2>&1 && changed=1
            done
        fi
        uci -q delete 'dhcp.@dnsmasq[0].podkop_notinterface' >/dev/null 2>&1 || true
    fi

    backup_servers="$(uci -q get 'dhcp.@dnsmasq[0].podkop_server' 2>/dev/null)"
    if [ -n "$backup_servers" ]; then
        uci -q delete 'dhcp.@dnsmasq[0].server' >/dev/null 2>&1 || true
        for value in $backup_servers; do
            uci -q add_list "dhcp.@dnsmasq[0].server=$value" >/dev/null 2>&1 || true
        done
        uci -q delete 'dhcp.@dnsmasq[0].podkop_server' >/dev/null 2>&1 || true
        changed=1
    else
        uci -q del_list "dhcp.@dnsmasq[0].server=$SB_DNS_INBOUND_ADDRESS" >/dev/null 2>&1 && changed=1
        uci -q delete 'dhcp.@dnsmasq[0].podkop_server' >/dev/null 2>&1 || true
    fi

    noresolv="$(uci -q get 'dhcp.@dnsmasq[0].podkop_noresolv' 2>/dev/null)"
    if [ -n "$noresolv" ]; then
        uci -q set "dhcp.@dnsmasq[0].noresolv=$noresolv" >/dev/null 2>&1 || true
        uci -q delete 'dhcp.@dnsmasq[0].podkop_noresolv' >/dev/null 2>&1 || true
        changed=1
    elif [ "$default_has_podkop_dns" -eq 1 ]; then
        uci -q set 'dhcp.@dnsmasq[0].noresolv=0' >/dev/null 2>&1 || true
        changed=1
    fi

    cachesize="$(uci -q get 'dhcp.@dnsmasq[0].podkop_cachesize' 2>/dev/null)"
    if [ -n "$cachesize" ]; then
        uci -q set "dhcp.@dnsmasq[0].cachesize=$cachesize" >/dev/null 2>&1 || true
        uci -q delete 'dhcp.@dnsmasq[0].podkop_cachesize' >/dev/null 2>&1 || true
        changed=1
    elif [ "$default_has_podkop_dns" -eq 1 ]; then
        uci -q set 'dhcp.@dnsmasq[0].cachesize=150' >/dev/null 2>&1 || true
        changed=1
    fi

    [ "$changed" -eq 1 ] || return 0

    uci -q commit dhcp >/dev/null 2>&1 || true
    [ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
}

podkop_dnsmasq_failsafe_restore
exit 0
