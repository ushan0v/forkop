# shellcheck shell=ash

sing_box_runtime_ucode() {
    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/sing_box_runtime.uc" "$@"
}

sing_box_managed_service_installed() {
    [ -r /etc/init.d/sing-box ] || return 1
    grep -q "${SB_MANAGED_SERVICE_MARKER:-Podkop Plus managed sing-box service for binary variants}" /etc/init.d/sing-box 2>/dev/null
}

sing_box_install_managed_service_script() {
    local tmp_file

    tmp_file="/etc/init.d/sing-box.podkop-plus.$$"
    cat >"$tmp_file" <<'EOF'
#!/bin/sh /etc/rc.common
# Podkop Plus managed sing-box service for binary variants

USE_PROCD=1
START=99
PROG="/usr/bin/sing-box"

start_service() {
    config_load "sing-box"
    local enabled config_file working_directory
    local log_stderr

    config_get_bool enabled "main" "enabled" "0"
    [ "$enabled" -eq "1" ] || return 0

    config_get config_file "main" "conffile" "/etc/sing-box/config.json"
    config_get working_directory "main" "workdir" "/usr/share/sing-box"
    config_get_bool log_stderr "main" "log_stderr" "1"

    procd_open_instance
    procd_set_param command "$PROG" run -c "$config_file" -D "$working_directory"
    procd_set_param file "$config_file"
    procd_set_param stderr "$log_stderr"
    procd_set_param limits core="unlimited"
    procd_set_param limits nofile="1000000 1000000"
    procd_set_param respawn
    procd_close_instance
}

service_triggers() {
    procd_add_reload_trigger "sing-box"
}
EOF

    chmod 0755 "$tmp_file" &&
        mv -f "$tmp_file" /etc/init.d/sing-box
}

sing_box_remove_managed_service_script() {
    sing_box_managed_service_installed || return 0

    /etc/init.d/sing-box stop >/dev/null 2>&1 || true
    /etc/init.d/sing-box disable >/dev/null 2>&1 || true
    rm -f /etc/init.d/sing-box
}

sing_box_disable_service_config() {
    command -v uci >/dev/null 2>&1 || return 0

    uci -q get sing-box.main >/dev/null 2>&1 ||
        uci -q set sing-box.main=sing-box >/dev/null 2>&1 || true
    uci -q set sing-box.main.enabled='0' >/dev/null 2>&1 || true
    uci -q commit sing-box >/dev/null 2>&1 || true
}

sing_box_prepare_service_disabled() {
    sing_box_disable_service_config
    [ -x /etc/init.d/sing-box ] && /etc/init.d/sing-box stop >/dev/null 2>&1 || true
    [ -x /etc/init.d/sing-box ] && /etc/init.d/sing-box disable >/dev/null 2>&1 || true
}

sing_box_configure_service() {
    local sing_box_enabled sing_box_user sing_box_config_path sing_box_conffile

    if is_sing_box_compressed_marker_set; then
        sing_box_install_managed_service_script || {
            log "Failed to install managed sing-box service for compressed binary. Aborted." "fatal"
            exit 1
        }
    fi

    sing_box_enabled="$(uci_get "sing-box" "main" "enabled")"
    sing_box_user="$(uci_get "sing-box" "main" "user")"

    if [ "$sing_box_enabled" -ne 1 ]; then
        uci_set "sing-box" "main" "enabled" 1
        uci_commit "sing-box"
        log "sing-box service has been enabled"
    fi

    if [ "$sing_box_user" != "root" ]; then
        uci_set "sing-box" "main" "user" "root"
        uci_commit "sing-box"
        log "sing-box service user has been changed to root"
    fi

    config_get sing_box_config_path "settings" "config_path"
    sing_box_conffile="$(uci_get "sing-box" "main" "conffile")"
    log "sing-box config path: $sing_box_config_path" "debug"
    log "sing-box service conffile: $sing_box_conffile" "debug"
    if [ "$sing_box_conffile" != "$sing_box_config_path" ]; then
        uci_set "sing-box" "main" "conffile" "$sing_box_config_path"
        uci_commit "sing-box"
        log "Configuration file path has been set to $sing_box_config_path"
    fi

    [ -f /etc/rc.d/S99sing-box ] && log "Disable sing-box" && /etc/init.d/sing-box disable
}

sing_box_init_config() {
    local config='{"log":{},"dns":{},"ntp":{},"certificate":{},"endpoints":[],"inbounds":[],"outbounds":[],"route":{},"services":[],"experimental":{}}'

    PODKOP_URLTEST_SELECTOR_SWITCHES=""
    configured_rulesets=""
    sing_box_configure_log
    sing_box_configure_inbounds
    sing_box_configure_dns
    sing_box_configure_route
    sing_box_configure_experimental
    sing_box_additional_inbounds
    sing_box_configure_outbounds
    sing_box_save_config
}

sing_box_configure_log() {
    log "Configure the log section of a sing-box JSON configuration"

    local log_level
    config_get log_level "settings" "log_level" "warn"
    config=$(sing_box_cm_configure_log "$config" false "$log_level" false)
}

sing_box_configure_inbounds() {
    log "Configure the inbounds section of a sing-box JSON configuration"

    config=$(
        sing_box_cm_add_tproxy_inbound \
            "$config" "$SB_TPROXY_INBOUND_TAG" "$SB_TPROXY_INBOUND_ADDRESS" "$SB_TPROXY_INBOUND_PORT" true true
    )
    config=$(
        sing_box_cm_add_direct_inbound "$config" "$SB_DNS_INBOUND_TAG" "$SB_DNS_INBOUND_ADDRESS" "$SB_DNS_INBOUND_PORT"
    )

    config_foreach configure_server_inbound "server"
}

sing_box_configure_outbounds() {
    log "Configure the outbounds section of a sing-box JSON configuration"

    config=$(sing_box_cm_add_direct_outbound "$config" "$SB_DIRECT_OUTBOUND_TAG")

    config_foreach configure_outbound_handler "section"
}

urltest_filter_mode_json() {
    local mode="$1"
    local tags_json="$2"
    local names_json="$3"
    local countries_json="$4"
    local include_names_json="$5"
    local include_regex_json="$6"
    local include_countries_json="$7"
    local exclude_names_json="$8"
    local exclude_regex_json="$9"
    local exclude_countries_json="${10}"
    local tmpdir result status

    tmpdir="$(mktemp -d)" || return 1

    if ! printf '%s' "$tags_json" > "$tmpdir/tags" ||
        ! printf '%s' "$names_json" > "$tmpdir/names" ||
        ! printf '%s' "$countries_json" > "$tmpdir/countries" ||
        ! printf '%s' "$include_names_json" > "$tmpdir/include_names" ||
        ! printf '%s' "$include_regex_json" > "$tmpdir/include_regex" ||
        ! printf '%s' "$include_countries_json" > "$tmpdir/include_countries" ||
        ! printf '%s' "$exclude_names_json" > "$tmpdir/exclude_names" ||
        ! printf '%s' "$exclude_regex_json" > "$tmpdir/exclude_regex" ||
        ! printf '%s' "$exclude_countries_json" > "$tmpdir/exclude_countries"; then
        rm -f "$tmpdir"/*
        rmdir "$tmpdir"
        return 1
    fi

    result="$(
        sing_box_runtime_ucode urltest-filter-mode "$mode" \
            "$tmpdir/tags" \
            "$tmpdir/names" \
            "$tmpdir/countries" \
            "$tmpdir/include_names" \
            "$tmpdir/include_regex" \
            "$tmpdir/include_countries" \
            "$tmpdir/exclude_names" \
            "$tmpdir/exclude_regex" \
            "$tmpdir/exclude_countries" 2>/dev/null
    )"
    status=$?
    rm -f "$tmpdir"/*
    rmdir "$tmpdir"

    [ "$status" -eq 0 ] || return 1
    [ -n "$result" ] || result="[]"
    printf '%s\n' "$result"
}

is_ipv6_literal() {
    sing_box_runtime_ucode valid-ipv6-literal "$1" >/dev/null 2>&1
}

normalize_country_server_key() {
    sing_box_runtime_ucode normalize-country-server-key "$1"
}

resolve_country_server_ip() {
    local server="$1"
    local normalized ip

    normalized="$(normalize_country_server_key "$server")"
    [ -n "$normalized" ] || return 1

    if is_ipv4 "$normalized" || is_ipv6_literal "$normalized"; then
        printf '%s\n' "$normalized"
        return 0
    fi

    is_domain "$normalized" || return 1

    if command -v dig >/dev/null 2>&1; then
        ip="$(
            dig +short "$normalized" A +time=2 +tries=1 2>/dev/null |
                sing_box_runtime_ucode stdin-first-dns-a-address 2>/dev/null
        )"
        if [ -z "$ip" ]; then
            ip="$(
                dig +short "$normalized" AAAA +time=2 +tries=1 2>/dev/null |
                    sing_box_runtime_ucode stdin-first-dns-aaaa-address 2>/dev/null
            )"
        fi
    elif command -v nslookup >/dev/null 2>&1; then
        ip="$(
            nslookup "$normalized" 2>/dev/null |
                sing_box_runtime_ucode stdin-first-nslookup-address 2>/dev/null
        )"
    fi

    [ -n "$ip" ] || return 1
    printf '%s\n' "$ip"
}

read_section_outbound_country_cache() {
    local section="$1"
    local cache_path countries_json

    case "$section" in
    "" | */* | *..*)
        printf '{}\n'
        return 0
        ;;
    esac

    cache_path="$(get_section_cache_path "$section")"
    if [ -s "$cache_path" ]; then
        countries_json="$(sing_box_runtime_ucode section-countries "$cache_path" 2>/dev/null)"
        if [ -n "$countries_json" ]; then
            printf '%s\n' "$countries_json"
            return 0
        fi
    fi

    printf '{}\n'
}

country_is_lookup_ips() {
    local ips_json="$1"
    local ip_count start end batch_json body_tmp http_code body_error
    local ips_tmp result_tmp result_json status

    ips_tmp="$(mktemp)" || return 1
    result_tmp="$(mktemp)" || return 1
    : > "$result_tmp"

    printf '%s' "$ips_json" > "$ips_tmp" || {
        rm -f "$ips_tmp" "$result_tmp"
        return 1
    }

    ip_count="$(printf '%s' "$ips_json" | sing_box_runtime_ucode stdin-length 2>/dev/null)"
    case "$ip_count" in
    '' | *[!0-9]*)
        rm -f "$ips_tmp" "$result_tmp"
        return 1
        ;;
    esac

    start=0
    while [ "$start" -lt "$ip_count" ]; do
        end=$((start + 100))
        batch_json="$(sing_box_runtime_ucode array-slice-file "$ips_tmp" "$start" "$end" 2>/dev/null)"
        if [ -z "$batch_json" ] || [ "$batch_json" = "[]" ]; then
            break
        fi

        body_tmp="$(mktemp)" || {
            rm -f "$ips_tmp" "$result_tmp"
            return 1
        }

        http_code="$(curl -sS -m 10 -o "$body_tmp" -w '%{http_code}' \
            -H 'Content-Type: application/json' \
            -d "$batch_json" \
            'https://api.country.is/' 2>/dev/null || true)"

        body_error="$(sing_box_runtime_ucode body-error "$body_tmp" 2>/dev/null)"
        if [ "$body_error" = "rate_limit" ]; then
            log "Server country lookup is rate-limited" "warn"
            rm -f "$body_tmp"
            break
        fi

        if [ "$http_code" = "200" ]; then
            sing_box_runtime_ucode ip-country-tsv "$body_tmp" >> "$result_tmp" 2>/dev/null || true
        elif [ "$http_code" = "429" ]; then
            log "Server country lookup is rate-limited" "warn"
            rm -f "$body_tmp"
            break
        else
            log "Server country lookup failed" "warn"
        fi

        rm -f "$body_tmp"
        start="$end"
        [ "$start" -lt "$ip_count" ] && sleep 1
    done

    result_json="$(sing_box_runtime_ucode tsv-to-object "$result_tmp" 2>/dev/null)"
    status=$?
    rm -f "$ips_tmp" "$result_tmp"

    [ "$status" -eq 0 ] || return 1
    [ -n "$result_json" ] || result_json="{}"
    printf '%s\n' "$result_json"
}

detect_server_countries_for_tags() {
    local servers_json="$1"
    local section="${2:-}"
    local cache_tmp servers_tmp cache_json cached_countries_json missing_tmp resolved_tmp ips_json ip_country_json ip_country_tmp
    local result_json tag server ip
    local server_count missing_count resolved_count unresolved_count log_prefix

    server_count="$(printf '%s' "$servers_json" | sing_box_runtime_ucode stdin-length 2>/dev/null)"
    case "$server_count" in
    '' | *[!0-9]*) server_count=0 ;;
    esac
    if [ -z "$servers_json" ] || [ "$server_count" -eq 0 ]; then
        printf '{}\n'
        return 0
    fi

    if [ -n "$section" ]; then
        log_prefix="rule '$section'"
    else
        log_prefix="current proxy rule"
    fi

    log "Detecting server countries for $log_prefix" "info"

    cache_json="$(read_section_outbound_country_cache "$section")"
    servers_tmp="$(mktemp)" || {
        printf '{}\n'
        return 0
    }
    cache_tmp="$(mktemp)" || {
        rm -f "$servers_tmp"
        printf '{}\n'
        return 0
    }
    printf '%s' "$servers_json" > "$servers_tmp" || {
        rm -f "$servers_tmp" "$cache_tmp"
        printf '{}\n'
        return 0
    }
    printf '%s' "$cache_json" > "$cache_tmp" || {
        rm -f "$servers_tmp" "$cache_tmp"
        printf '{}\n'
        return 0
    }
    cached_countries_json="$(sing_box_runtime_ucode cached-countries-for-servers "$servers_tmp" "$cache_tmp" 2>/dev/null)"
    [ -n "$cached_countries_json" ] || cached_countries_json="{}"

    missing_tmp="$(mktemp)" || {
        rm -f "$servers_tmp" "$cache_tmp"
        printf '%s\n' "$cached_countries_json"
        return 0
    }
    resolved_tmp="$(mktemp)" || {
        rm -f "$servers_tmp" "$cache_tmp" "$missing_tmp"
        printf '%s\n' "$cached_countries_json"
        return 0
    }

    sing_box_runtime_ucode missing-servers-tsv "$servers_tmp" "$cache_tmp" > "$missing_tmp" 2>/dev/null || true

    missing_count="$(sing_box_runtime_ucode file-line-count "$missing_tmp" 2>/dev/null)"
    case "$missing_count" in
    '' | *[!0-9]*) missing_count=0 ;;
    esac
    while IFS="$(printf '\t')" read -r tag server || [ -n "$tag" ]; do
        [ -n "$tag" ] || continue
        ip="$(resolve_country_server_ip "$server")" || continue
        [ -n "$ip" ] || continue
        printf '%s\t%s\n' "$tag" "$ip" >> "$resolved_tmp"
    done < "$missing_tmp"

    resolved_count="$(sing_box_runtime_ucode file-line-count "$resolved_tmp" 2>/dev/null)"
    case "$resolved_count" in
    '' | *[!0-9]*) resolved_count=0 ;;
    esac

    if [ ! -s "$resolved_tmp" ]; then
        if [ "$missing_count" -gt 0 ]; then
            log "Server country detection for $log_prefix could not resolve some servers" "warn"
        fi
        rm -f "$servers_tmp" "$cache_tmp" "$missing_tmp" "$resolved_tmp"
        printf '%s\n' "$cached_countries_json"
        return 0
    fi

    unresolved_count=$((missing_count - resolved_count))
    [ "$unresolved_count" -le 0 ] || log "Server country detection for $log_prefix could not resolve some servers" "warn"

    ips_json="$(sing_box_runtime_ucode tsv-second-column-array "$resolved_tmp" 2>/dev/null)"
    [ -n "$ips_json" ] || ips_json="[]"
    ip_country_json="$(country_is_lookup_ips "$ips_json" 2>/dev/null || printf '{}')"
    [ -n "$ip_country_json" ] || ip_country_json="{}"
    if ! printf '%s' "$ip_country_json" | sing_box_runtime_ucode object-nonempty >/dev/null 2>&1; then
        log "Server country detection for $log_prefix returned no countries" "warn"
    fi

    ip_country_tmp="$(mktemp)" || {
        rm -f "$servers_tmp" "$cache_tmp" "$missing_tmp" "$resolved_tmp"
        printf '%s\n' "$cached_countries_json"
        return 0
    }
    printf '%s' "$ip_country_json" > "$ip_country_tmp" || {
        rm -f "$servers_tmp" "$cache_tmp" "$missing_tmp" "$resolved_tmp" "$ip_country_tmp"
        printf '%s\n' "$cached_countries_json"
        return 0
    }
    result_json="$(sing_box_runtime_ucode server-countries-result "$servers_tmp" "$cache_tmp" "$resolved_tmp" "$ip_country_tmp" 2>/dev/null)"
    [ -n "$result_json" ] || result_json="$cached_countries_json"

    rm -f "$servers_tmp" "$cache_tmp" "$missing_tmp" "$resolved_tmp" "$ip_country_tmp"
    log "Server country detection for $log_prefix completed" "info"
    printf '%s\n' "$result_json"
}

detect_server_countries_from_names() {
    local names_json="$1"
    local names_tmp result status

    names_tmp="$(mktemp)" || {
        printf '{}\n'
        return 0
    }

    printf '%s' "$names_json" > "$names_tmp" || {
        rm -f "$names_tmp"
        printf '{}\n'
        return 0
    }

    result="$(sing_box_runtime_ucode countries-from-flag-names "$names_tmp" 2>/dev/null)"
    status=$?
    rm -f "$names_tmp"

    [ "$status" -eq 0 ] || result="{}"
    [ -n "$result" ] || result="{}"
    printf '%s\n' "$result"
}

filter_urltest_outbounds() {
    local section="$1"
    local tags_json="$2"
    local names_json="$3"
    local countries_json="$4"
    local country_filter_enabled="$5"
    local filter_mode filtered_json filtered_count original_count
    local include_names_json include_regex_json include_countries_json
    local exclude_names_json exclude_regex_json exclude_countries_json

    config_get filter_mode "$section" "urltest_filter_mode" "disabled"

    case "$filter_mode" in
    disabled)
        printf '%s\n' "$tags_json"
        return 0
        ;;
    include | exclude | mixed) ;;
    *)
        printf '%s\n' "$tags_json"
        return 0
        ;;
    esac

    include_names_json="$(config_list_to_json "$section" "urltest_include_outbounds")"
    include_regex_json="$(config_list_to_json "$section" "urltest_include_regex")"
    exclude_names_json="$(config_list_to_json "$section" "urltest_exclude_outbounds")"
    exclude_regex_json="$(config_list_to_json "$section" "urltest_exclude_regex")"

    include_countries_json="[]"
    exclude_countries_json="[]"
    if [ "$country_filter_enabled" -eq 1 ]; then
        include_countries_json="$(config_list_to_json "$section" "urltest_include_countries" |
            sing_box_runtime_ucode normalized-country-list 2>/dev/null)"
        [ -n "$include_countries_json" ] || include_countries_json="[]"
        exclude_countries_json="$(config_list_to_json "$section" "urltest_exclude_countries" |
            sing_box_runtime_ucode normalized-country-list 2>/dev/null)"
        [ -n "$exclude_countries_json" ] || exclude_countries_json="[]"
    fi

    filtered_json="$(
        urltest_filter_mode_json "$filter_mode" "$tags_json" "$names_json" "$countries_json" \
            "$include_names_json" "$include_regex_json" "$include_countries_json" \
            "$exclude_names_json" "$exclude_regex_json" "$exclude_countries_json"
    )"

    [ -n "$filtered_json" ] || filtered_json="$tags_json"
    filtered_count="$(printf '%s' "$filtered_json" | sing_box_runtime_ucode stdin-length 2>/dev/null)"
    original_count="$(printf '%s' "$tags_json" | sing_box_runtime_ucode stdin-length 2>/dev/null)"

    if [ -z "$filtered_count" ] || [ "$filtered_count" -eq 0 ]; then
        if [ "$filter_mode" = "include" ]; then
            log "URLTest whitelist matched no outbounds for rule '$section'; URLTest will be disabled for this rule" "warn"
        elif [ "$filter_mode" = "mixed" ]; then
            log "URLTest mixed filters matched no outbounds for rule '$section'; URLTest will be disabled for this rule" "warn"
        else
            log "URLTest filters excluded all outbounds for rule '$section'; URLTest will be disabled for this rule" "warn"
        fi
        printf '[]\n'
        return 0
    fi

    if [ -n "$original_count" ] && [ "$filtered_count" -lt "$original_count" ]; then
        if [ "$filter_mode" = "include" ]; then
            log "URLTest whitelist selected $filtered_count of $original_count outbound(s) for rule '$section'" "info"
        elif [ "$filter_mode" = "mixed" ]; then
            log "URLTest mixed filters selected $filtered_count of $original_count outbound(s) for rule '$section'" "info"
        else
            log "URLTest filters excluded $((original_count - filtered_count)) outbound(s) for rule '$section'" "info"
        fi
    fi

    printf '%s\n' "$filtered_json"
}

final_urltest_outbounds() {
    local config_json="$1"
    local tags_json="$2"
    local tmpdir config_tmp tags_tmp result status

    tmpdir="$(mktemp -d)" || return 1
    config_tmp="$tmpdir/config.json"
    tags_tmp="$tmpdir/tags.json"

    status=1
    if printf '%s' "$config_json" >"$config_tmp" &&
        printf '%s' "$tags_json" >"$tags_tmp"; then
        result="$(
            sing_box_runtime_ucode final-urltest-outbounds "$config_tmp" "$tags_tmp" 2>/dev/null
        )"
        status=$?
    fi

    rm -rf "$tmpdir"
    [ "$status" -eq 0 ] || return 1
    [ -n "$result" ] || result="[]"
    printf '%s\n' "$result"
}

get_urltest_check_interval_for_config() {
    local section="$1"
    local urltest_check_interval

    urltest_check_interval="$(get_urltest_check_interval_for_rule "$section")"
    if [ -n "$urltest_check_interval" ]; then
        printf '%s\n' "$urltest_check_interval"
    else
        printf '%s\n' "$SING_BOX_DISABLED_UPDATE_INTERVAL"
    fi
}

get_urltest_idle_timeout_for_config() {
    local section="$1"
    local urltest_check_interval interval_seconds default_idle_seconds

    urltest_check_interval="$(get_urltest_check_interval_for_rule "$section")"
    if [ -z "$urltest_check_interval" ]; then
        printf '%s\n' "$SING_BOX_DISABLED_UPDATE_INTERVAL"
        return 0
    fi

    interval_seconds="$(duration_to_seconds "$urltest_check_interval" 2>/dev/null)" || {
        printf '\n'
        return 0
    }
    default_idle_seconds="$(duration_to_seconds "$SING_BOX_URLTEST_DEFAULT_IDLE_TIMEOUT")"

    if [ "$interval_seconds" -gt "$default_idle_seconds" ]; then
        printf '%s\n' "$urltest_check_interval"
    else
        printf '\n'
    fi
}

get_outbound_detour_tag_for_rule() {
    local section="$1"
    local detour_enabled detour_section

    config_get_bool detour_enabled "$section" "outbound_detour_enabled" 0
    [ "$detour_enabled" -eq 1 ] || return 0

    config_get detour_section "$section" "outbound_detour_section"
    [ -n "$detour_section" ] || return 0

    get_outbound_tag_by_section "$detour_section"
}

proxy_group_append_outbound() {
    local tag="$1"
    local link="${2:-}"
    local display_name="${3:-$tag}"
    local server="${4:-}"
    local tmpdir tags_tmp links_tmp names_tmp servers_tmp

    tmpdir="$(mktemp -d)" || {
        log "Failed to append outbound '$tag' for proxy rule '$PROXY_GROUP_SECTION'. Aborted." "fatal"
        exit 1
    }
    tags_tmp="$tmpdir/tags.json"
    links_tmp="$tmpdir/links.json"
    names_tmp="$tmpdir/names.json"
    servers_tmp="$tmpdir/servers.json"

    [ -n "$PROXY_GROUP_OUTBOUND_TAGS_JSON" ] || PROXY_GROUP_OUTBOUND_TAGS_JSON="[]"
    [ -n "$PROXY_GROUP_LINKS_JSON" ] || PROXY_GROUP_LINKS_JSON="{}"
    [ -n "$PROXY_GROUP_NAMES_JSON" ] || PROXY_GROUP_NAMES_JSON="{}"
    [ -n "$PROXY_GROUP_SERVERS_JSON" ] || PROXY_GROUP_SERVERS_JSON="{}"

    if printf '%s' "$PROXY_GROUP_OUTBOUND_TAGS_JSON" > "$tags_tmp" &&
        printf '%s' "$PROXY_GROUP_LINKS_JSON" > "$links_tmp" &&
        printf '%s' "$PROXY_GROUP_NAMES_JSON" > "$names_tmp" &&
        printf '%s' "$PROXY_GROUP_SERVERS_JSON" > "$servers_tmp" &&
        sing_box_runtime_ucode append-proxy-group-outbound-state \
            "$tags_tmp" "$links_tmp" "$names_tmp" "$servers_tmp" "$tag" "$link" "$display_name" "$server"; then
        PROXY_GROUP_OUTBOUND_TAGS_JSON="$(cat "$tags_tmp" 2>/dev/null)"
        [ -n "$PROXY_GROUP_OUTBOUND_TAGS_JSON" ] || PROXY_GROUP_OUTBOUND_TAGS_JSON="[]"
        PROXY_GROUP_LINKS_JSON="$(cat "$links_tmp" 2>/dev/null)"
        [ -n "$PROXY_GROUP_LINKS_JSON" ] || PROXY_GROUP_LINKS_JSON="{}"
        PROXY_GROUP_NAMES_JSON="$(cat "$names_tmp" 2>/dev/null)"
        [ -n "$PROXY_GROUP_NAMES_JSON" ] || PROXY_GROUP_NAMES_JSON="{}"
        PROXY_GROUP_SERVERS_JSON="$(cat "$servers_tmp" 2>/dev/null)"
        [ -n "$PROXY_GROUP_SERVERS_JSON" ] || PROXY_GROUP_SERVERS_JSON="{}"
        rm -rf "$tmpdir"
        return 0
    fi

    rm -rf "$tmpdir"
    log "Failed to append outbound '$tag' for proxy rule '$PROXY_GROUP_SECTION'. Aborted." "fatal"
    exit 1
}

proxy_group_add_manual_link() {
    local link="$1"
    local section="$2"
    local udp_over_tcp="$3"
    local outbound_tag display_name server

    PROXY_GROUP_MANUAL_INDEX=$((PROXY_GROUP_MANUAL_INDEX + 1))
    config="$(sing_box_cf_add_proxy_outbound "$config" "$section-$PROXY_GROUP_MANUAL_INDEX" "$link" "$udp_over_tcp")"
    outbound_tag="$(get_outbound_tag_by_section "$section-$PROXY_GROUP_MANUAL_INDEX")"
    display_name="$(subscription_url_get_fragment "$link")"
    [ -n "$display_name" ] || display_name="$outbound_tag"
    server="$(printf '%s' "$config" | sing_box_runtime_ucode outbound-server-by-tag "$outbound_tag" 2>/dev/null)"
    proxy_group_append_outbound "$outbound_tag" "$link" "$display_name" "$server"
}

proxy_group_merge_subscription_metadata() {
    local tmpdir tags_tmp link_refs_tmp names_tmp servers_tmp sub_tags_tmp sub_link_refs_tmp sub_names_tmp sub_servers_tmp status

    tmpdir="$(mktemp -d)" || return 1
    tags_tmp="$tmpdir/tags.json"
    link_refs_tmp="$tmpdir/link-refs.json"
    names_tmp="$tmpdir/names.json"
    servers_tmp="$tmpdir/servers.json"
    sub_tags_tmp="$tmpdir/sub-tags.json"
    sub_link_refs_tmp="$tmpdir/sub-link-refs.json"
    sub_names_tmp="$tmpdir/sub-names.json"
    sub_servers_tmp="$tmpdir/sub-servers.json"

    status=1
    [ -n "$PROXY_GROUP_OUTBOUND_TAGS_JSON" ] || PROXY_GROUP_OUTBOUND_TAGS_JSON="[]"
    [ -n "$PROXY_GROUP_LINK_REFS_JSON" ] || PROXY_GROUP_LINK_REFS_JSON="{}"
    [ -n "$PROXY_GROUP_NAMES_JSON" ] || PROXY_GROUP_NAMES_JSON="{}"
    [ -n "$PROXY_GROUP_SERVERS_JSON" ] || PROXY_GROUP_SERVERS_JSON="{}"
    [ -n "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" ] || SUBSCRIPTION_OUTBOUND_TAGS_JSON="[]"
    [ -n "$SUBSCRIPTION_OUTBOUND_LINK_REFS_JSON" ] || SUBSCRIPTION_OUTBOUND_LINK_REFS_JSON="{}"
    [ -n "$SUBSCRIPTION_OUTBOUND_NAMES_JSON" ] || SUBSCRIPTION_OUTBOUND_NAMES_JSON="{}"
    [ -n "$SUBSCRIPTION_OUTBOUND_SERVERS_JSON" ] || SUBSCRIPTION_OUTBOUND_SERVERS_JSON="{}"

    if printf '%s' "$PROXY_GROUP_OUTBOUND_TAGS_JSON" > "$tags_tmp" &&
        printf '%s' "$PROXY_GROUP_LINK_REFS_JSON" > "$link_refs_tmp" &&
        printf '%s' "$PROXY_GROUP_NAMES_JSON" > "$names_tmp" &&
        printf '%s' "$PROXY_GROUP_SERVERS_JSON" > "$servers_tmp" &&
        printf '%s' "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" > "$sub_tags_tmp" &&
        printf '%s' "$SUBSCRIPTION_OUTBOUND_LINK_REFS_JSON" > "$sub_link_refs_tmp" &&
        printf '%s' "$SUBSCRIPTION_OUTBOUND_NAMES_JSON" > "$sub_names_tmp" &&
        printf '%s' "$SUBSCRIPTION_OUTBOUND_SERVERS_JSON" > "$sub_servers_tmp" &&
        sing_box_runtime_ucode merge-proxy-group-subscription-state \
            "$tags_tmp" "$link_refs_tmp" "$names_tmp" "$servers_tmp" \
            "$sub_tags_tmp" "$sub_link_refs_tmp" "$sub_names_tmp" "$sub_servers_tmp"; then
        IFS= read -r PROXY_GROUP_OUTBOUND_TAGS_JSON < "$tags_tmp" || PROXY_GROUP_OUTBOUND_TAGS_JSON=""
        [ -n "$PROXY_GROUP_OUTBOUND_TAGS_JSON" ] || PROXY_GROUP_OUTBOUND_TAGS_JSON="[]"
        IFS= read -r PROXY_GROUP_LINK_REFS_JSON < "$link_refs_tmp" || PROXY_GROUP_LINK_REFS_JSON=""
        [ -n "$PROXY_GROUP_LINK_REFS_JSON" ] || PROXY_GROUP_LINK_REFS_JSON="{}"
        IFS= read -r PROXY_GROUP_NAMES_JSON < "$names_tmp" || PROXY_GROUP_NAMES_JSON=""
        [ -n "$PROXY_GROUP_NAMES_JSON" ] || PROXY_GROUP_NAMES_JSON="{}"
        IFS= read -r PROXY_GROUP_SERVERS_JSON < "$servers_tmp" || PROXY_GROUP_SERVERS_JSON=""
        [ -n "$PROXY_GROUP_SERVERS_JSON" ] || PROXY_GROUP_SERVERS_JSON="{}"
        status=0
    fi

    rm -rf "$tmpdir"
    return "$status"
}

proxy_group_add_subscription_source() {
    local section="$1"
    local index="$2"
    local entry="$3"
    local source_section subscription_json_path

    if ! parse_subscription_source_entry "$entry"; then
        log "Invalid subscription source for rule '$section': $SUBSCRIPTION_SOURCE_PARSE_ERROR. Aborted." "fatal"
        exit 1
    fi

    source_section="$(subscription_source_id "$section" "$index")"
    if subscription_source_is_marked_unavailable "$source_section"; then
        log "Skipping unavailable subscription source '$index' for rule '$section'" "warn"
        return 0
    fi

    if ! ensure_subscription_cache_for_source \
        "$section" "$source_section" "$SUBSCRIPTION_SOURCE_URL" "$SUBSCRIPTION_SOURCE_USER_AGENT" 0 "$index"; then
        subscription_mark_unavailable_source "$source_section"
        log "Skipping unavailable subscription source '$index' for rule '$section'" "warn"
        return 0
    fi

    subscription_json_path="$(get_subscription_json_path "$source_section")"
    if ! sing_box_cf_add_subscription_outbounds "$config" "$section" "$subscription_json_path" "$source_section" > /dev/null; then
        log "Skipping subscription source '$index' for rule '$section': no valid proxy outbounds found" "warn"
        return 0
    fi

    config="$SING_BOX_CF_LAST_CONFIG"
    if ! proxy_group_merge_subscription_metadata; then
        log "Failed to merge subscription metadata for rule '$section'. Aborted." "fatal"
        exit 1
    fi
}

configure_outbound_handler() {
    local section="$1"
    local action

    rule_is_enabled "$section" || return 0
    if subscription_section_is_deferred "$section"; then
        log "Skipping outbound for deferred subscription rule '$section' until its cache is recovered" "warn"
        write_subscription_metadata_json "$section" ""
        write_subscription_outbound_link_cache "$section" "{}" "{}"
        write_outbound_metadata "$section" "{}" "{}" "{}"
        return 0
    fi

    action="$(get_rule_action "$section")"

    if [ "$action" = "zapret" ]; then
        write_subscription_metadata_json "$section" ""
        if ! is_zapret_installed; then
            return 0
        fi

        local routing_mark outbound_tag zapret_index

        zapret_index="$(get_zapret_rule_index "$section")"
        if [ "${zapret_index:-0}" -le 0 ]; then
            log "Unable to resolve Zapret index for rule '$section'. Aborted." "fatal"
            exit 1
        fi

        routing_mark="$(get_zapret_rule_mark_value "$zapret_index")"
        outbound_tag="$(get_outbound_tag_by_section "$section")"
        config=$(sing_box_cm_add_direct_outbound "$config" "$outbound_tag" "$routing_mark")
        return 0
    fi

    if [ "$action" = "zapret2" ]; then
        write_subscription_metadata_json "$section" ""
        if ! is_zapret2_installed; then
            return 0
        fi

        local routing_mark outbound_tag zapret2_index

        zapret2_index="$(get_zapret2_rule_index "$section")"
        if [ "${zapret2_index:-0}" -le 0 ]; then
            log "Unable to resolve Zapret2 index for rule '$section'. Aborted." "fatal"
            exit 1
        fi

        routing_mark="$(get_zapret2_rule_mark_value "$zapret2_index")"
        outbound_tag="$(get_outbound_tag_by_section "$section")"
        config=$(sing_box_cm_add_direct_outbound "$config" "$outbound_tag" "$routing_mark")
        return 0
    fi

    if [ "$action" = "byedpi" ]; then
        if ! is_byedpi_installed; then
            return 0
        fi

        local outbound_tag byedpi_index byedpi_port

        byedpi_index="$(get_byedpi_rule_index "$section")"
        if [ "${byedpi_index:-0}" -le 0 ]; then
            log "Unable to resolve ByeDPI index for rule '$section'. Aborted." "fatal"
            exit 1
        fi

        byedpi_port="$(get_byedpi_rule_port "$byedpi_index")"
        outbound_tag="$(get_outbound_tag_by_section "$section")"
        config=$(sing_box_cm_add_socks_outbound "$config" "$outbound_tag" "$BYEDPI_LISTEN_ADDRESS" "$byedpi_port" "5" "" "" "" "")
        write_subscription_metadata_json "$section" ""
        return 0
    fi

    if [ "$action" = "outbound" ]; then
        local outbound_json outbound_tag detour_tag

        config_get outbound_json "$section" "outbound_json"
        if [ -z "$outbound_json" ]; then
            log "JSON outbound is not set for rule '$section'. Aborted." "fatal"
            exit 1
        fi

        outbound_tag="$(get_outbound_tag_by_section "$section")"
        config=$(sing_box_cf_add_json_outbound "$config" "$section" "$outbound_json")
        detour_tag="$(get_outbound_detour_tag_for_rule "$section")"
        if [ -n "$detour_tag" ]; then
            if ! config="$(sing_box_cm_set_outbound_detour "$config" "$outbound_tag" "$detour_tag")"; then
                log "Failed to apply outbound detour for JSON outbound rule '$section'. Aborted." "fatal"
                exit 1
            fi
        fi
        write_subscription_outbound_link_cache "$section" "{}" "{}"
        write_subscription_metadata_json "$section" ""
        return 0
    fi

    if [ "$action" = "proxy" ]; then
        local selector_proxy_links udp_over_tcp urltest_enabled urltest_tag selector_tag selector_outbounds selector_default \
            urltest_check_interval urltest_idle_timeout urltest_tolerance urltest_testing_url outbounds_count \
            detect_server_country urltest_filter_mode urltest_country_filter_enabled urltest_outbounds urltest_outbounds_count has_subscription_sources \
            metadata_countries_json metadata_tmpfile metadata_count detour_tag

        config_get selector_proxy_links "$section" "selector_proxy_links"
        config_get udp_over_tcp "$section" "enable_udp_over_tcp"
        config_get_bool urltest_enabled "$section" "urltest_enabled" 0
        config_get detect_server_country "$section" "detect_server_country" "$SERVER_COUNTRY_METHOD_FLAG_EMOJI"
        detect_server_country="$(normalize_detect_server_country_method "$detect_server_country")"
        config_get urltest_filter_mode "$section" "urltest_filter_mode" "disabled"
        detour_tag="$(get_outbound_detour_tag_for_rule "$section")"
        rule_has_subscription_urls "$section" && has_subscription_sources=1 || has_subscription_sources=0

        PROXY_GROUP_SECTION="$section"
        PROXY_GROUP_MANUAL_INDEX=0
        PROXY_GROUP_OUTBOUND_TAGS_JSON="[]"
        PROXY_GROUP_LINKS_JSON="{}"
        PROXY_GROUP_LINK_REFS_JSON="{}"
        PROXY_GROUP_NAMES_JSON="{}"
        PROXY_GROUP_SERVERS_JSON="{}"
        PROXY_GROUP_COUNTRIES_JSON="{}"
        metadata_countries_json="{}"

        config_list_foreach "$section" "selector_proxy_links" proxy_group_add_manual_link "$section" "$udp_over_tcp"

        metadata_tmpfile=""
        if [ "$has_subscription_sources" -eq 1 ]; then
            metadata_tmpfile="$(mktemp "$TMP_SUBSCRIPTION_FOLDER/${section}.metadata-section.XXXXXX" 2>/dev/null || true)"
            if [ -n "$metadata_tmpfile" ]; then
                printf '[]\n' > "$metadata_tmpfile"
                SUBSCRIPTION_SECTION_METADATA_TMP="$metadata_tmpfile"
            else
                SUBSCRIPTION_SECTION_METADATA_TMP=""
            fi
            for_each_subscription_source "$section" proxy_group_add_subscription_source
            SUBSCRIPTION_SECTION_METADATA_TMP=""

            if [ -n "$metadata_tmpfile" ]; then
                metadata_count="$(subscription_cache_ucode json-length "$metadata_tmpfile" 2>/dev/null)"
                if [ -n "$metadata_count" ] && [ "$metadata_count" -gt 0 ]; then
                    write_subscription_metadata_json "$section" "$metadata_tmpfile"
                else
                    write_subscription_metadata_json "$section" ""
                fi
                rm -f "$metadata_tmpfile"
            fi
        else
            write_subscription_metadata_json "$section" ""
        fi

        if [ "$urltest_enabled" -eq 1 ] && urltest_filter_mode_filters_enabled "$urltest_filter_mode" &&
            [ "$detect_server_country" = "$SERVER_COUNTRY_METHOD_COUNTRY_IS" ]; then
            PROXY_GROUP_COUNTRIES_JSON="$(detect_server_countries_for_tags "$PROXY_GROUP_SERVERS_JSON" "$section")"
            [ -n "$PROXY_GROUP_COUNTRIES_JSON" ] || PROXY_GROUP_COUNTRIES_JSON="{}"
            metadata_countries_json="$PROXY_GROUP_COUNTRIES_JSON"
        elif [ "$urltest_enabled" -eq 1 ] && urltest_filter_mode_filters_enabled "$urltest_filter_mode" &&
            [ "$detect_server_country" = "$SERVER_COUNTRY_METHOD_FLAG_EMOJI" ]; then
            PROXY_GROUP_COUNTRIES_JSON="$(detect_server_countries_from_names "$PROXY_GROUP_NAMES_JSON")"
            [ -n "$PROXY_GROUP_COUNTRIES_JSON" ] || PROXY_GROUP_COUNTRIES_JSON="{}"
        fi

        outbounds_count="$(printf '%s' "$PROXY_GROUP_OUTBOUND_TAGS_JSON" | sing_box_runtime_ucode stdin-length 2>/dev/null)"
        if [ -z "$outbounds_count" ] || [ "$outbounds_count" -eq 0 ]; then
            log "Proxy rule '$section' has no usable proxy outbounds configured. Aborted." "fatal"
            exit 1
        fi

        if [ -n "$detour_tag" ]; then
            if ! config="$(sing_box_cm_set_outbounds_detour "$config" "$PROXY_GROUP_OUTBOUND_TAGS_JSON" "$detour_tag")"; then
                log "Failed to apply outbound detour for proxy rule '$section'. Aborted." "fatal"
                exit 1
            fi
        fi

        selector_tag="$(get_outbound_tag_by_section "$section")"

        if [ "$urltest_enabled" -eq 1 ]; then
            urltest_check_interval="$(get_urltest_check_interval_for_config "$section")"
            urltest_idle_timeout="$(get_urltest_idle_timeout_for_config "$section")"
            config_get urltest_tolerance "$section" "urltest_tolerance" 50
            config_get urltest_testing_url "$section" "urltest_testing_url" "https://www.gstatic.com/generate_204"
            urltest_country_filter_enabled=0
            if urltest_filter_mode_filters_enabled "$urltest_filter_mode"; then
                urltest_country_filter_enabled=1
            fi

            urltest_outbounds="$(final_urltest_outbounds "$config" "$PROXY_GROUP_OUTBOUND_TAGS_JSON")" || {
                log "Failed to build final outbound list for URLTest rule '$section'. Aborted." "fatal"
                exit 1
            }
            [ -n "$urltest_outbounds" ] || urltest_outbounds="[]"

            urltest_outbounds="$(filter_urltest_outbounds "$section" "$urltest_outbounds" \
                "$PROXY_GROUP_NAMES_JSON" "$PROXY_GROUP_COUNTRIES_JSON" "$urltest_country_filter_enabled")"
            [ -n "$urltest_outbounds" ] || urltest_outbounds="[]"
            urltest_outbounds_count="$(printf '%s' "$urltest_outbounds" | sing_box_runtime_ucode stdin-length 2>/dev/null)"
            case "$urltest_outbounds_count" in
            '' | *[!0-9]*) urltest_outbounds_count=0 ;;
            esac

            if [ "$urltest_outbounds_count" -gt 0 ]; then
                urltest_tag="$(get_outbound_tag_by_section "$section-urltest")"
                selector_outbounds="$(printf '%s' "$PROXY_GROUP_OUTBOUND_TAGS_JSON" |
                    sing_box_runtime_ucode array-append-string "$urltest_tag" 2>/dev/null)"
                if [ -z "$selector_outbounds" ]; then
                    log "Failed to build selector outbounds for proxy rule '$section'. Aborted." "fatal"
                    exit 1
                fi

                config="$(sing_box_cm_add_urltest_outbound "$config" "$urltest_tag" "$urltest_outbounds" \
                    "$urltest_testing_url" "$urltest_check_interval" "$urltest_tolerance" "$urltest_idle_timeout" "true")"
                if list_has_item "$PODKOP_URLTEST_NEW_ENABLED_SECTIONS" "$section"; then
                    schedule_urltest_selector_switch "$selector_tag" "$urltest_tag"
                fi
                config="$(sing_box_cm_add_selector_outbound "$config" "$selector_tag" "$selector_outbounds" "$urltest_tag" "true")"
            else
                selector_default="$(printf '%s' "$PROXY_GROUP_OUTBOUND_TAGS_JSON" | sing_box_runtime_ucode array-item 0 2>/dev/null)"
                if [ -z "$selector_default" ]; then
                    log "Unable to determine default selector outbound for rule '$section'. Aborted." "fatal"
                    exit 1
                fi

                config="$(sing_box_cm_add_selector_outbound "$config" "$selector_tag" "$PROXY_GROUP_OUTBOUND_TAGS_JSON" "$selector_default" "true")"
            fi
        else
            selector_default="$(printf '%s' "$PROXY_GROUP_OUTBOUND_TAGS_JSON" | sing_box_runtime_ucode array-item 0 2>/dev/null)"
            if [ -z "$selector_default" ]; then
                log "Unable to determine default selector outbound for rule '$section'. Aborted." "fatal"
                exit 1
            fi

            config="$(sing_box_cm_add_selector_outbound "$config" "$selector_tag" "$PROXY_GROUP_OUTBOUND_TAGS_JSON" "$selector_default" "true")"
        fi

        write_subscription_outbound_link_cache "$section" "$PROXY_GROUP_LINKS_JSON" "$PROXY_GROUP_LINK_REFS_JSON"
        write_outbound_metadata "$section" "$PROXY_GROUP_NAMES_JSON" "$metadata_countries_json" "$PROXY_GROUP_SERVERS_JSON"
        return 0
    fi

    if [ "$action" = "vpn" ]; then
        local interface_name domain_resolver_enabled domain_resolver_dns_type domain_resolver_dns_server \
            domain_resolver_dns_server_address outbound_tag domain_resolver_tag dns_domain_resolver outbound_mark

        config_get interface_name "$section" "interface"
        config_get_bool domain_resolver_enabled "$section" "domain_resolver_enabled" 0
        config_get domain_resolver_dns_type "$section" "domain_resolver_dns_type"
        config_get domain_resolver_dns_server "$section" "domain_resolver_dns_server"

        if [ -z "$interface_name" ]; then
            log "VPN interface is not set for rule '$section'. Aborted." "fatal"
            exit 1
        fi

        outbound_tag="$(get_outbound_tag_by_section "$section")"

        if [ "$domain_resolver_enabled" -eq 1 ]; then
            domain_resolver_dns_server_address="$(url_get_host "$domain_resolver_dns_server")"
            if ! is_ipv4 "$domain_resolver_dns_server_address"; then
                dns_domain_resolver=$SB_BOOTSTRAP_SERVER_TAG
            fi
            domain_resolver_tag="$(get_domain_resolver_tag "$section")"
            config=$(sing_box_cf_add_dns_server "$config" "$domain_resolver_dns_type" "$domain_resolver_tag" \
                "$domain_resolver_dns_server" "$dns_domain_resolver" "$outbound_tag")
        fi

        outbound_mark="$((NFT_OUTBOUND_MARK))"
        config=$(sing_box_cm_add_interface_outbound "$config" "$outbound_tag" "$interface_name" "$domain_resolver_tag" "$outbound_mark")
        write_subscription_metadata_json "$section" ""
        return 0
    fi

    if [ "$action" = "direct" ]; then
        local outbound_tag

        outbound_tag="$(get_outbound_tag_by_section "$section")"
        config=$(sing_box_cm_add_direct_outbound "$config" "$outbound_tag")
        write_subscription_metadata_json "$section" ""
        return 0
    fi

    case "$action" in
    block)
        write_subscription_metadata_json "$section" ""
        return 0
        ;;
    "")
        log "Rule '$section' has no action. Aborted." "fatal"
        ;;
    *)
        log "Unsupported action '$action' for rule '$section'. Aborted." "fatal"
        ;;
    esac
    exit 1
}

sing_box_configure_dns() {
    log "Configure the DNS section of a sing-box JSON configuration"
    config=$(sing_box_cm_configure_dns "$config" "$SB_DNS_SERVER_TAG" "ipv4_only" true)

    log "Adding DNS Servers" "debug"
    local dns_type dns_server bootstrap_dns_server dns_domain_resolver dns_server_address
    config_get dns_type "settings" "dns_type" "doh"
    config_get dns_server "settings" "dns_server" "1.1.1.1"
    config_get bootstrap_dns_server "settings" "bootstrap_dns_server" "77.88.8.8"

    dns_server_address="$(url_get_host "$dns_server")"
    if ! is_ipv4 "$dns_server_address"; then
        dns_domain_resolver=$SB_BOOTSTRAP_SERVER_TAG
    fi

    config=$(sing_box_cm_add_udp_dns_server "$config" "$SB_BOOTSTRAP_SERVER_TAG" "$bootstrap_dns_server" 53)
    config=$(sing_box_cf_add_dns_server "$config" "$dns_type" "$SB_DNS_SERVER_TAG" "$dns_server" "$dns_domain_resolver")
    config=$(sing_box_cm_add_fakeip_dns_server "$config" "$SB_FAKEIP_DNS_SERVER_TAG" "$SB_FAKEIP_INET4_RANGE")

    log "Adding DNS Rules"
    local rewrite_ttl service_domains
    config_get rewrite_ttl "settings" "dns_rewrite_ttl" "60"
    service_domains=$(sing_box_runtime_ucode csv-to-json-array "$FAKEIP_TEST_DOMAIN,$CHECK_PROXY_IP_DOMAIN")

    config=$(sing_box_cm_add_dns_reject_rule "$config" "query_type" "HTTPS")
    config=$(sing_box_cm_add_dns_reject_rule "$config" "domain_suffix" '"use-application-dns.net"')
    configure_tailscale_server_dns_bypass
    config=$(sing_box_cm_add_dns_route_rule "$config" "$SB_FAKEIP_DNS_SERVER_TAG" "$SB_SERVICE_FAKEIP_DNS_RULE_TAG")
    config=$(sing_box_cm_patch_dns_route_rule "$config" "$SB_SERVICE_FAKEIP_DNS_RULE_TAG" "rewrite_ttl" "$rewrite_ttl")
    config=$(sing_box_cm_patch_dns_route_rule "$config" "$SB_SERVICE_FAKEIP_DNS_RULE_TAG" "domain" "$service_domains")
}

configure_tailscale_server_dns_bypass() {
    config_foreach configure_tailscale_server_dns_bypass_handler "server"
}

configure_tailscale_server_dns_bypass_handler() {
    local section="$1"
    local protocol inbound_tag dns_server_tag rule_tag

    server_is_enabled "$section" || return 0

    config_get protocol "$section" "protocol"
    [ "$protocol" = "tailscale" ] || return 0

    inbound_tag="$(get_server_inbound_tag_by_section "$section")"
    dns_server_tag="$(get_tailscale_dns_server_tag_by_section "$section")"
    rule_tag="tailscale-server-dns-$(server_safe_filename "$section")"

    config=$(sing_box_cm_add_tailscale_dns_server "$config" "$dns_server_tag" "$inbound_tag" "1")
    config=$(sing_box_cm_add_dns_route_rule "$config" "$dns_server_tag" "$rule_tag")
    config=$(sing_box_cm_patch_dns_route_rule "$config" "$rule_tag" "inbound" "\"$inbound_tag\"")
}

sing_box_configure_route() {
    log "Configure the route section of a sing-box JSON configuration"

    local output_network_interface outbound_mark
    outbound_mark="$((NFT_OUTBOUND_MARK))"
    config_get output_network_interface "settings" "output_network_interface"
    if [ -z "$output_network_interface" ]; then
        if mwan3_is_active; then
            log "mwan3 is active; disabling sing-box auto_detect_interface so mwan3 can control egress routing" "warn"
            config=$(sing_box_cm_configure_route "$config" "$SB_DIRECT_OUTBOUND_TAG" false "$SB_DNS_SERVER_TAG" "" "$outbound_mark")
        else
            config=$(sing_box_cm_configure_route "$config" "$SB_DIRECT_OUTBOUND_TAG" true "$SB_DNS_SERVER_TAG" "" "$outbound_mark")
        fi
    else
        if mwan3_is_active; then
            log "mwan3 is active and Output Network Interface is set to '$output_network_interface'; sing-box egress is pinned to this interface" "warn"
        fi
        config=$(sing_box_cm_configure_route "$config" "$SB_DIRECT_OUTBOUND_TAG" false "$SB_DNS_SERVER_TAG" \
            "$output_network_interface" "$outbound_mark")
    fi

    local sniff_inbounds
    sniff_inbounds=$(sing_box_runtime_ucode csv-to-json-array "$SB_TPROXY_INBOUND_TAG,$SB_DNS_INBOUND_TAG")
    config=$(sing_box_cm_sniff_route_rule "$config" "inbound" "$sniff_inbounds")
    config_foreach add_server_sniff_route_rule "server"

    config=$(sing_box_cm_add_hijack_dns_route_rule "$config" "port" "53")
    config=$(sing_box_cm_add_hijack_dns_route_rule "$config" "protocol" "dns")

    config=$(sing_box_cf_add_single_key_reject_rule "$config" "" "ip_version" 6)

    local disable_quic
    config_get_bool disable_quic "settings" "disable_quic" 0
    if [ "$disable_quic" -eq 1 ]; then
        config=$(sing_box_cf_add_single_key_reject_rule "$config" "$SB_TPROXY_INBOUND_TAG" "protocol" "quic")
    fi

    local first_outbound_section
    first_outbound_section="$(get_first_outbound_section)"
    if [ -n "$first_outbound_section" ]; then
        first_outbound_tag="$(get_outbound_tag_by_section "$first_outbound_section")"
        config=$(sing_box_cf_proxy_domain "$config" "$SB_TPROXY_INBOUND_TAG" "$CHECK_PROXY_IP_DOMAIN" "$first_outbound_tag")
    fi
    config=$(sing_box_cf_override_domain_port "$config" "$FAKEIP_TEST_DOMAIN" 8443)

    local routing_excluded_ips
    config_get routing_excluded_ips "settings" "routing_excluded_ips"
    if [ -n "$routing_excluded_ips" ]; then
        rule_tag="$(gen_id)"
        config=$(sing_box_cm_add_route_rule "$config" "$rule_tag" "$SB_TPROXY_INBOUND_TAG" "$SB_DIRECT_OUTBOUND_TAG")
        config_list_foreach "settings" "routing_excluded_ips" exclude_source_ip_from_routing_handler "$rule_tag"
    fi

    config_foreach configure_route_rule_handler "section"
    config_foreach configure_server_route "server"
}

add_server_sniff_route_rule() {
    local section="$1"
    local inbound_tag

    server_is_enabled "$section" || return 0

    inbound_tag="$(get_server_inbound_tag_by_section "$section")"
    config=$(sing_box_cm_sniff_route_rule "$config" "inbound" "\"$inbound_tag\"")
}

configure_server_route() {
    local section="$1"
    local routing_mode routing_section inbound_tag action route_rule_tag

    server_is_enabled "$section" || return 0

    inbound_tag="$(get_server_inbound_tag_by_section "$section")"
    config_get routing_mode "$section" "routing_mode" "rules"

    case "$routing_mode" in
    rules)
        config=$(
            sing_box_cm_clone_route_rules_for_inbound \
                "$config" \
                "$SB_TPROXY_INBOUND_TAG" \
                "$inbound_tag" \
                "$CHECK_PROXY_IP_DOMAIN"
        )
        ;;
    direct)
        route_rule_tag="$(gen_id)"
        config=$(sing_box_cm_add_route_rule "$config" "$route_rule_tag" "$inbound_tag" "$SB_DIRECT_OUTBOUND_TAG")
        ;;
    section)
        config_get routing_section "$section" "routing_section"
        if [ -z "$routing_section" ]; then
            log "Server '$section' routing mode is section, but routing_section is empty. Aborted." "fatal"
            exit 1
        fi
        action="$(get_rule_action "$routing_section")"
        if [ -z "$action" ]; then
            log "Server '$section' references missing routing section '$routing_section'. Aborted." "fatal"
            exit 1
        fi
        if ! rule_is_enabled "$routing_section"; then
            log "Server '$section' references disabled routing section '$routing_section'. Aborted." "fatal"
            exit 1
        fi
        route_rule_tag="$(gen_id)"
        create_route_rule_for_action "$routing_section" "$action" "$route_rule_tag" "$inbound_tag"
        ;;
    *)
        log "Server '$section' has unsupported routing mode '$routing_mode'. Aborted." "fatal"
        exit 1
        ;;
    esac
}

create_route_rule_for_action() {
    local section="$1"
    local action="$2"
    local rule_tag="$3"
    local inbound_tag="${4:-$SB_TPROXY_INBOUND_TAG}"

    case "$action" in
    proxy | outbound | vpn | byedpi)
        local outbound_tag
        outbound_tag="$(get_outbound_tag_by_section "$section")"
        config=$(sing_box_cm_add_route_rule "$config" "$rule_tag" "$inbound_tag" "$outbound_tag")
        ;;
    zapret | zapret2)
        local provider_outbound_tag
        provider_outbound_tag="$(get_outbound_tag_by_section "$section")"
        config=$(sing_box_cm_add_route_rule "$config" "$rule_tag" "$inbound_tag" "$provider_outbound_tag")
        ;;
    direct)
        local direct_outbound_tag
        direct_outbound_tag="$(get_outbound_tag_by_section "$section")"
        config=$(sing_box_cm_add_route_rule "$config" "$rule_tag" "$inbound_tag" "$direct_outbound_tag")
        ;;
    block)
        config=$(sing_box_cm_add_reject_route_rule "$config" "$rule_tag" "$inbound_tag")
        ;;
    *)
        log "Unsupported action '$action' for rule '$section'. Aborted." "fatal"
        exit 1
        ;;
    esac
}

dns_route_rule_exists() {
    local tag="$1"

    printf '%s' "$config" | sing_box_runtime_ucode dns-route-rule-exists "$SERVICE_TAG" "$tag" >/dev/null 2>&1
}

ensure_fakeip_dns_route_rule() {
    local tag="$1"
    local rewrite_ttl

    dns_route_rule_exists "$tag" && return 0

    config=$(sing_box_cm_add_dns_route_rule "$config" "$SB_FAKEIP_DNS_SERVER_TAG" "$tag")
    config_get rewrite_ttl "settings" "dns_rewrite_ttl" "60"
    config=$(sing_box_cm_patch_dns_route_rule "$config" "$tag" "rewrite_ttl" "$rewrite_ttl")
}

route_rule_has_resolve_matchers() {
    local tag="$1"

    printf '%s' "$config" | sing_box_runtime_ucode route-rule-has-resolve-matchers "$SERVICE_TAG" "$tag" >/dev/null 2>&1
}

configure_rule_set_reference_handler() {
    local reference="$1"
    local route_rule_tag="$2"

    resolve_ruleset_reference "$reference"
    if [ -n "$ENSURED_RULESET_TAG" ]; then
        config=$(sing_box_cm_patch_route_rule "$config" "$route_rule_tag" "rule_set" "$ENSURED_RULESET_TAG")
        if [ "$ENSURED_RULESET_KIND" = "domains" ]; then
            ensure_fakeip_dns_route_rule "$SB_FAKEIP_RULESET_DNS_RULE_TAG"
            config=$(sing_box_cm_patch_dns_route_rule "$config" "$SB_FAKEIP_RULESET_DNS_RULE_TAG" "rule_set" "$ENSURED_RULESET_TAG")
        else
            log "Skip DNS FakeIP rule patch for '$reference' ruleset kind '$ENSURED_RULESET_KIND'" "debug"
        fi
    fi
}

get_domain_ip_list_ruleset_tag() {
    local section="$1"

    get_ruleset_tag "$section" "lists" ""
}

get_domain_ip_list_ruleset_path() {
    local section="$1"

    printf '%s/%s.json\n' "$TMP_RULESET_FOLDER" "$(get_domain_ip_list_ruleset_tag "$section")"
}

reset_domain_ip_list_ruleset() {
    local section="$1"
    local ruleset_filepath

    ruleset_filepath="$(get_domain_ip_list_ruleset_path "$section")"

    rm -f "$ruleset_filepath"
    create_source_rule_set "$ruleset_filepath" >/dev/null 2>&1
}

source_ruleset_has_rules() {
    local filepath="$1"

    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/rulesets.uc" has-rules "$filepath" >/dev/null 2>&1
}

source_ruleset_has_domain_matchers() {
    local filepath="$1"

    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/rulesets.uc" has-domain-matchers "$filepath" >/dev/null 2>&1
}

cleanup_empty_domain_ip_list_ruleset() {
    local section="$1"
    local ruleset_filepath

    ruleset_filepath="$(get_domain_ip_list_ruleset_path "$section")"
    source_ruleset_has_rules "$ruleset_filepath" && return 0

    rm -f "$ruleset_filepath"
    return 1
}

ensure_domain_ip_list_ruleset() {
    local section="$1"
    local route_rule_tag="$2"
    local ruleset_tag ruleset_filepath

    ruleset_tag="$(get_domain_ip_list_ruleset_tag "$section")"
    ruleset_filepath="$(get_domain_ip_list_ruleset_path "$section")"

    if ! cleanup_empty_domain_ip_list_ruleset "$section"; then
        log "Domain/IP list ruleset for '$section' is empty, skipping route rule_set" "debug"
        return 0
    fi

    config=$(sing_box_cm_add_local_ruleset "$config" "$ruleset_tag" "source" "$ruleset_filepath")
    config=$(sing_box_cm_patch_route_rule "$config" "$route_rule_tag" "rule_set" "$ruleset_tag")

    if source_ruleset_has_domain_matchers "$ruleset_filepath"; then
        ensure_fakeip_dns_route_rule "$SB_FAKEIP_RULESET_DNS_RULE_TAG"
        config=$(sing_box_cm_patch_dns_route_rule "$config" "$SB_FAKEIP_RULESET_DNS_RULE_TAG" "rule_set" "$ruleset_tag")
    fi
}

import_domain_ip_list_file_into_rulesets() {
    local filepath="$1"
    local section="$2"
    local domains_tmpfile subnets_tmpfile ruleset_filepath status

    [ -f "$filepath" ] || return 0

    domains_tmpfile="$(mktemp)"
    subnets_tmpfile="$(mktemp)"
    ruleset_filepath="$(get_domain_ip_list_ruleset_path "$section")"
    status=0

    split_domain_or_subnet_file "$filepath" "$domains_tmpfile" "$subnets_tmpfile" || status=1
    if [ "$status" -eq 0 ]; then
        import_plain_domain_list_to_local_source_ruleset_chunked "$domains_tmpfile" "$ruleset_filepath" || status=1
        import_plain_subnet_list_to_local_source_ruleset_chunked "$subnets_tmpfile" "$ruleset_filepath" || status=1
        add_plain_subnet_file_to_nft_for_section "$section" "$subnets_tmpfile" || status=1
    fi

    rm -f "$domains_tmpfile" "$subnets_tmpfile"
    return "$status"
}

import_domain_ip_list_reference_into_rulesets() {
    local reference="$1"
    local section="$2"
    local tmpfile http_proxy_address status download_status
    status=0

    case "$reference" in
    http://* | https://*)
        tmpfile="$(mktemp)"
        http_proxy_address="$(get_service_proxy_address lists)"
        download_to_file "$reference" "$tmpfile" "$http_proxy_address"
        download_status="$?"
        if [ "$download_status" -eq 0 ] && [ -s "$tmpfile" ]; then
            convert_crlf_to_lf "$tmpfile"
            import_domain_ip_list_file_into_rulesets "$tmpfile" "$section" || status=1
        else
            log "Failed to download remote domain/IP list $reference; skipping it until the next successful update" "warn"
        fi
        rm -f "$tmpfile"
        return "$status"
        ;;
    *)
        import_domain_ip_list_file_into_rulesets "$reference" "$section"
        ;;
    esac
}

configure_domain_ip_lists() {
    local section="$1"
    local route_rule_tag="$2"

    reset_domain_ip_list_ruleset "$section"
    config_list_foreach "$section" "domain_ip_lists" configure_domain_ip_lists_reference_handler "$section"
    ensure_domain_ip_list_ruleset "$section" "$route_rule_tag"
}

configure_domain_ip_lists_reference_handler() {
    local reference="$1"
    local section="$2"

    case "$reference" in
    http://* | https://*) return 0 ;;
    esac

    import_domain_ip_list_reference_into_rulesets "$reference" "$section"
}

add_plain_subnet_file_to_nft_for_section() {
    local section="$1"
    local filepath="$2"
    local ports

    [ -s "$filepath" ] || return 0

    ports="$(get_rule_ports_commas_string "$section")"
    if [ -n "$ports" ]; then
        nft_add_ip_port_set_elements_from_ip_file_chunked "$filepath" "$NFT_TABLE_NAME" "$NFT_IP_PORT_SET_NAME" "$ports"
    else
        nft_add_set_elements_from_file_chunked "$filepath" "$NFT_TABLE_NAME" "$NFT_COMMON_SET_NAME"
    fi
}

extract_json_ruleset_nft_files_for_section() {
    local json_file="$1"
    local unscoped_output_file="$2"
    local scoped_output_file="$3"
    local section="$4"
    local port_values_json port_ranges_json

    port_values_json="[]"
    port_ranges_json="[]"
    if [ -n "$section" ]; then
        port_values_json="$(get_rule_port_values_json_array "$section")"
        port_ranges_json="$(get_rule_port_ranges_json_array "$section")"
    fi

    extract_ip_cidr_nft_elements_from_json_ruleset_to_files \
        "$json_file" "$unscoped_output_file" "$scoped_output_file" "$port_values_json" "$port_ranges_json"
}

add_extracted_ruleset_subnets_to_nft_for_section() {
    local section="$1"
    local unscoped_file="$2"
    local scoped_file="$3"
    local label="$4"
    local has_entries

    has_entries=0

    if [ -s "$unscoped_file" ]; then
        nft_add_set_elements_from_file_chunked "$unscoped_file" "$NFT_TABLE_NAME" "$NFT_COMMON_SET_NAME" || return 1
        has_entries=1
    fi

    if [ -s "$scoped_file" ]; then
        nft_add_ip_port_set_elements_from_file_chunked "$scoped_file" "$NFT_TABLE_NAME" "$NFT_IP_PORT_SET_NAME" || return 1
        has_entries=1
    fi

    if [ "$has_entries" -eq 0 ]; then
        log "$label has no ip_cidr entries for nftables" "warn"
    fi

    return 0
}

rebuild_domain_ip_lists_from_rule() {
    local section="$1"
    local references

    rule_is_enabled "$section" || return 0
    config_get references "$section" "domain_ip_lists"
    [ -n "$references" ] || return 0

    reset_domain_ip_list_ruleset "$section"
    config_list_foreach "$section" "domain_ip_lists" import_domain_ip_list_reference_into_rulesets "$section"
    cleanup_empty_domain_ip_list_ruleset "$section" || true
}

rule_has_primary_matchers() {
    local section="$1"
    local domain domain_suffix domain_keyword domain_regex ip_cidr ports community_lists rule_set rule_set_with_subnets domain_ip_lists

    domain="$(get_rule_condition_commas_string "$section" "domain" "domains")"
    domain_suffix="$(get_rule_condition_commas_string "$section" "domain_suffix" "domains")"
    domain_keyword="$(get_rule_condition_commas_string "$section" "domain_keyword" "generic")"
    domain_regex="$(get_rule_condition_commas_string "$section" "domain_regex" "generic")"
    ip_cidr="$(get_rule_condition_commas_string "$section" "ip_cidr" "subnets")"
    ports="$(get_rule_ports_commas_string "$section")"
    config_get community_lists "$section" "community_lists"
    config_get rule_set "$section" "rule_set"
    config_get rule_set_with_subnets "$section" "rule_set_with_subnets"
    config_get domain_ip_lists "$section" "domain_ip_lists"

    if [ -n "$domain" ] ||
        [ -n "$domain_suffix" ] ||
        [ -n "$domain_keyword" ] ||
        [ -n "$domain_regex" ] ||
        [ -n "$ip_cidr" ] ||
        [ -n "$ports" ] ||
        [ -n "$community_lists" ] ||
        [ -n "$rule_set" ] ||
        [ -n "$rule_set_with_subnets" ] ||
        [ -n "$domain_ip_lists" ]; then
        return 0
    fi

    return 1
}

configure_route_rule_handler() {
    local section="$1"
    local action route_rule_tag ip_values_json ip_values port_values_json port_ranges_json

    rule_is_enabled "$section" || return 0
    if subscription_section_is_deferred "$section"; then
        log "Skipping route rule '$section' until its subscription cache is recovered" "warn"
        return 0
    fi

    action="$(get_rule_action "$section")"
    [ -n "$action" ] || return 0

    if [ "$action" = "zapret" ] && ! is_zapret_installed; then
        return 0
    fi

    if [ "$action" = "zapret2" ] && ! is_zapret2_installed; then
        return 0
    fi

    if [ "$action" = "byedpi" ] && ! is_byedpi_installed; then
        return 0
    fi

    log "Configuring route rule '$section' with action '$action'"

    configure_fully_routed_ips_for_section "$section" "$action"

    if ! rule_has_primary_matchers "$section"; then
        log "Rule '$section' has no destination matchers and action '$action', skipping regular route creation" "warn"
        return 0
    fi

    route_rule_tag="$(gen_id)"
    create_route_rule_for_action "$section" "$action" "$route_rule_tag"

    local domain_json domain_suffix_json domain_keyword_json domain_regex_json
    domain_json="$(get_rule_condition_json_array "$section" "domain" "domains")"
    [ "$domain_json" != "[]" ] && config=$(sing_box_cm_patch_route_rule "$config" "$route_rule_tag" "domain" "$domain_json") && \
        ensure_fakeip_dns_route_rule "$SB_FAKEIP_DNS_RULE_TAG" && \
        config=$(sing_box_cm_patch_dns_route_rule "$config" "$SB_FAKEIP_DNS_RULE_TAG" "domain" "$domain_json")

    domain_suffix_json="$(get_rule_condition_json_array "$section" "domain_suffix" "domains")"
    [ "$domain_suffix_json" != "[]" ] && config=$(sing_box_cm_patch_route_rule "$config" "$route_rule_tag" "domain_suffix" "$domain_suffix_json") && \
        ensure_fakeip_dns_route_rule "$SB_FAKEIP_DNS_RULE_TAG" && \
        config=$(sing_box_cm_patch_dns_route_rule "$config" "$SB_FAKEIP_DNS_RULE_TAG" "domain_suffix" "$domain_suffix_json")

    domain_keyword_json="$(get_rule_condition_json_array "$section" "domain_keyword" "generic")"
    [ "$domain_keyword_json" != "[]" ] && config=$(sing_box_cm_patch_route_rule "$config" "$route_rule_tag" "domain_keyword" "$domain_keyword_json") && \
        ensure_fakeip_dns_route_rule "$SB_FAKEIP_DNS_RULE_TAG" && \
        config=$(sing_box_cm_patch_dns_route_rule "$config" "$SB_FAKEIP_DNS_RULE_TAG" "domain_keyword" "$domain_keyword_json")

    domain_regex_json="$(get_rule_condition_json_array "$section" "domain_regex" "generic")"
    [ "$domain_regex_json" != "[]" ] && config=$(sing_box_cm_patch_route_rule "$config" "$route_rule_tag" "domain_regex" "$domain_regex_json") && \
        ensure_fakeip_dns_route_rule "$SB_FAKEIP_DNS_RULE_TAG" && \
        config=$(sing_box_cm_patch_dns_route_rule "$config" "$SB_FAKEIP_DNS_RULE_TAG" "domain_regex" "$domain_regex_json")

    ip_values_json="$(get_rule_condition_json_array "$section" "ip_cidr" "subnets")"
    if [ "$ip_values_json" != "[]" ]; then
        config=$(sing_box_cm_patch_route_rule "$config" "$route_rule_tag" "ip_cidr" "$ip_values_json")
        if [ "$PODKOP_NFT_POPULATE_ENABLED" = "1" ]; then
            ip_values="$(get_rule_condition_commas_string "$section" "ip_cidr" "subnets")"
            add_section_ip_cidr_to_nft_sets "$section" "$ip_values"
        fi
    fi

    port_values_json="$(get_rule_port_values_json_array "$section")"
    [ "$port_values_json" != "[]" ] && config=$(sing_box_cm_patch_route_rule "$config" "$route_rule_tag" "port" "$port_values_json")

    port_ranges_json="$(get_rule_port_ranges_json_array "$section")"
    [ "$port_ranges_json" != "[]" ] && config=$(sing_box_cm_patch_route_rule "$config" "$route_rule_tag" "port_range" "$port_ranges_json")

    if [ "$PODKOP_NFT_POPULATE_ENABLED" = "1" ]; then
        add_section_ports_to_nft_set_if_needed "$section"
    fi

    local source_ip_values_json
    source_ip_values_json="$(get_rule_condition_json_array "$section" "source_ip_cidr" "subnets")"
    if [ "$source_ip_values_json" != "[]" ]; then
        config=$(sing_box_cm_patch_route_rule "$config" "$route_rule_tag" "source_ip_cidr" "$source_ip_values_json")
    fi

    local domain_ip_lists rule_set_with_subnets
    config_get domain_ip_lists "$section" "domain_ip_lists"
    config_get rule_set_with_subnets "$section" "rule_set_with_subnets"
    config_list_foreach "$section" "community_lists" configure_community_list_handler "$section" "$route_rule_tag"
    config_list_foreach "$section" "rule_set" configure_rule_set_reference_handler "$route_rule_tag"
    config_list_foreach "$section" "rule_set_with_subnets" configure_rule_set_reference_handler "$route_rule_tag"
    if [ -n "$domain_ip_lists" ]; then
        configure_domain_ip_lists "$section" "$route_rule_tag"
    fi

    if [ "$action" = "proxy" ] || [ "$action" = "outbound" ] || [ "$action" = "vpn" ] || [ "$action" = "byedpi" ]; then
        local resolve_real_ip_for_routing
        if [ "$action" = "byedpi" ]; then
            resolve_real_ip_for_routing=1
        else
            config_get_bool resolve_real_ip_for_routing "$section" "resolve_real_ip_for_routing" 0
        fi
        if [ "$resolve_real_ip_for_routing" -eq 1 ]; then
            if route_rule_has_resolve_matchers "$route_rule_tag"; then
                config=$(sing_box_cm_add_resolve_rule "$config" "$route_rule_tag" "$(gen_id)" "$SB_DNS_SERVER_TAG")
                log "Added resolve rule for '$section' rule" "debug"
            else
                log "Resolve real IP is enabled for '$section', but no domain or rule-set matchers found" "warn"
            fi
        fi
    fi
}

configure_fully_routed_ips_for_section() {
    local section="$1"
    local action="$2"

    local fully_routed_ips rule_tag

    if [ "$action" = "zapret" ] && ! is_zapret_installed; then
        return 0
    fi

    if [ "$action" = "zapret2" ] && ! is_zapret2_installed; then
        return 0
    fi

    if [ "$action" = "byedpi" ] && ! is_byedpi_installed; then
        return 0
    fi

    config_get fully_routed_ips "$section" "fully_routed_ips"
    if [ -n "$fully_routed_ips" ]; then
        rule_tag="$(gen_id)"
        create_route_rule_for_action "$section" "$action" "$rule_tag"
        config_list_foreach "$section" "fully_routed_ips" configure_fully_routed_ip_route_rule "$rule_tag"
    fi
}

configure_fully_routed_ip_route_rule() {
    local source_ip="$1"
    local rule_tag="$2"

    populate_fully_routed_ip_nft "$source_ip"
    config=$(sing_box_cm_patch_route_rule "$config" "$rule_tag" "source_ip_cidr" "$source_ip")
}

exclude_source_ip_from_routing_handler() {
    local source_ip="$1"
    local rule_tag="$2"

    config=$(sing_box_cm_patch_route_rule "$config" "$rule_tag" "source_ip_cidr" "$source_ip")
}

configure_community_list_handler() {
    local tag="$1"
    local section="$2"
    local route_rule_tag="$3"

    local ruleset_tag format url update_interval detour
    ruleset_tag="$(get_ruleset_tag "$section" "$tag" "community")"
    format="binary"
    url="$(get_community_ruleset_url "$tag")"
    detour="$(get_download_detour_tag)"
    update_interval="$(get_remote_ruleset_update_interval)"

    config=$(sing_box_cm_add_remote_ruleset "$config" "$ruleset_tag" "$format" "$url" "$detour" "$update_interval")
    config=$(sing_box_cm_patch_route_rule "$config" "$route_rule_tag" "rule_set" "$ruleset_tag")
    ensure_fakeip_dns_route_rule "$SB_FAKEIP_RULESET_DNS_RULE_TAG"
    config=$(sing_box_cm_patch_dns_route_rule "$config" "$SB_FAKEIP_RULESET_DNS_RULE_TAG" "rule_set" "$ruleset_tag")
}

sing_box_configure_experimental() {
    log "Configure the experimental section of a sing-box JSON configuration"

    log "Configuring cache database"
    local cache_file
    config_get cache_file "settings" "cache_path" "/tmp/sing-box/cache.db"
    config=$(sing_box_cm_configure_cache_file "$config" true "$cache_file" true)

    log "Configuring Clash API"
    local enable_yacd enable_yacd_wan_access clash_api_controller_address
    config_get_bool enable_yacd "settings" "enable_yacd" 0
    config_get_bool enable_yacd_wan_access "settings" "enable_yacd_wan_access" 0

    if [ "$enable_yacd" -eq 1 ] && [ "$enable_yacd_wan_access" -eq 1 ]; then
        clash_api_controller_address="0.0.0.0"
    else
        clash_api_controller_address="$(get_service_listen_address)"
        if [ -z "$clash_api_controller_address" ]; then
            log "Could not determine the listening IP address for the Clash API controller. It will run only on localhost." "warn"
            clash_api_controller_address="127.0.0.1"
        fi
    fi

    if [ "$enable_yacd" -eq 1 ]; then
        log "YACD is enabled, enabling Clash API with downloadable YACD" "debug"
        local yacd_secret_key external_controller_ui
        config_get yacd_secret_key "settings" "yacd_secret_key"
        external_controller_ui="ui"

        config=$(
            sing_box_cm_configure_clash_api \
                "$config" \
                "$clash_api_controller_address:$SB_CLASH_API_CONTROLLER_PORT" \
                "$external_controller_ui" \
                "$yacd_secret_key"
        )
    else
        log "YACD is disabled, enabling Clash API in online mode" "debug"
        config=$(
            sing_box_cm_configure_clash_api "$config" "$clash_api_controller_address:$SB_CLASH_API_CONTROLLER_PORT"
        )
    fi
}

sing_box_additional_inbounds() {
    log "Configure the additional inbounds of a sing-box JSON configuration"

    if download_via_proxy_any_enabled; then
        local download_lists_via_proxy_section section_outbound_tag
        config_get download_lists_via_proxy_section "settings" "download_lists_via_proxy_section"
        section_outbound_tag="$(get_outbound_tag_by_section "$download_lists_via_proxy_section")"
        config=$(
            sing_box_cf_add_mixed_inbound_and_route_rule \
                "$config" \
                "$SB_SERVICE_MIXED_INBOUND_TAG" \
                "$SB_SERVICE_MIXED_INBOUND_ADDRESS" \
                "$SB_SERVICE_MIXED_INBOUND_PORT" \
                "$section_outbound_tag"
        )
    fi

    config_foreach configure_section_mixed_proxy "section"
}

configure_section_mixed_proxy() {
    local section="$1"
    local action

    rule_is_enabled "$section" || return 0
    subscription_section_is_deferred "$section" && return 0

    action="$(get_rule_action "$section")"
    [ "$action" = "proxy" ] || [ "$action" = "outbound" ] || [ "$action" = "vpn" ] || [ "$action" = "byedpi" ] || [ "$action" = "zapret" ] || [ "$action" = "zapret2" ] || return 0
    if [ "$action" = "byedpi" ] && ! is_byedpi_installed; then
        return 0
    fi
    if [ "$action" = "zapret" ] && ! is_zapret_installed; then
        return 0
    fi
    if [ "$action" = "zapret2" ] && ! is_zapret2_installed; then
        return 0
    fi

    local mixed_inbound_enabled mixed_proxy_port mixed_inbound_tag mixed_outbound_tag mixed_proxy_address \
        mixed_proxy_auth_enabled mixed_proxy_username mixed_proxy_password
    config_get_bool mixed_inbound_enabled "$section" "mixed_proxy_enabled" 0
    mixed_proxy_address="$(get_service_listen_address)"
    if [ -z "$mixed_proxy_address" ]; then
        log "Could not determine the listening IP address for the Mixed Proxy. The proxy will not be created." "warn"
        return 1
    fi
    config_get mixed_proxy_port "$section" "mixed_proxy_port"
    if [ "$mixed_inbound_enabled" -eq 1 ]; then
        config_get_bool mixed_proxy_auth_enabled "$section" "mixed_proxy_auth_enabled" 0
        if [ "$mixed_proxy_auth_enabled" -eq 1 ]; then
            config_get mixed_proxy_username "$section" "mixed_proxy_username"
            config_get mixed_proxy_password "$section" "mixed_proxy_password"
            if [ -z "$mixed_proxy_username" ] || [ -z "$mixed_proxy_password" ]; then
                log "Mixed Proxy authentication for '$section' is enabled, but username or password is empty. The proxy will not be created." "warn"
                return 1
            fi
        fi
        mixed_inbound_tag="$(get_inbound_tag_by_section "$section-mixed")"
        mixed_outbound_tag="$(get_outbound_tag_by_section "$section")"
        config=$(
            sing_box_cf_add_mixed_inbound_and_route_rule \
                "$config" \
                "$mixed_inbound_tag" \
                "$mixed_proxy_address" \
                "$mixed_proxy_port" \
                "$mixed_outbound_tag" \
                "$mixed_proxy_username" \
                "$mixed_proxy_password"
        )
    fi
}

sing_box_save_config() {
    local sing_box_config_path temp_file_path current_config_hash temp_config_hash
    config_get sing_box_config_path "settings" "config_path"
    temp_file_path="$(mktemp)"

    log "Save sing-box temporary config to $temp_file_path" "debug"
    sing_box_cm_save_config_to_file "$config" "$temp_file_path"

    sing_box_config_check "$temp_file_path"

    current_config_hash=$(md5sum "$sing_box_config_path" 2> /dev/null | sing_box_runtime_ucode stdin-first-field)
    temp_config_hash=$(md5sum "$temp_file_path" | sing_box_runtime_ucode stdin-first-field)
    log "Current sing-box config hash: $current_config_hash" "debug"
    log "Temporary sing-box config hash: $temp_config_hash" "debug"
    if [ "$current_config_hash" != "$temp_config_hash" ]; then
        log "sing-box configuration has changed and will be updated"
        mv "$temp_file_path" "$sing_box_config_path"
    else
        log "sing-box configuration is unchanged"
        rm "$temp_file_path"
    fi
}

sing_box_config_check() {
    local config_path="$1"

    if ! sing-box -c "$config_path" check > /dev/null 2>&1; then
        log "Sing-box configuration $config_path is invalid. Aborted." "fatal"
        exit 1
    fi
}

import_builtin_subnets_from_rule() {
    local section="$1"

    rule_is_enabled "$section" || return 0
    BUILTIN_SUBNET_IMPORT_STATUS=0
    config_list_foreach "$section" "community_lists" import_builtin_subnets_reference_handler "$section"
    return "$BUILTIN_SUBNET_IMPORT_STATUS"
}

import_builtin_subnets_reference_handler() {
    local reference="$1"
    local section="$2"

    if helpers_ucode whitespace-list-contains "$COMMUNITY_SERVICES" "$reference" >/dev/null 2>&1; then
        import_community_service_subnet_list_handler "$reference" "$section" || BUILTIN_SUBNET_IMPORT_STATUS=1
    fi
    return 0
}

import_rule_sets_with_subnets_from_rule() {
    local section="$1"
    local rule_set_with_subnets

    rule_is_enabled "$section" || return 0

    config_get rule_set_with_subnets "$section" "rule_set_with_subnets"
    if [ -n "$rule_set_with_subnets" ]; then
        RULE_SET_WITH_SUBNETS_IMPORT_STATUS=0
        log "Importing subnets from rule sets with subnets for '$section' section"
        config_list_foreach "$section" "rule_set_with_subnets" import_rule_set_with_subnets_reference_handler "$section"
        return "$RULE_SET_WITH_SUBNETS_IMPORT_STATUS"
    fi
}

import_rule_set_with_subnets_reference_handler() {
    local reference="$1"
    local section="$2"
    local extension format

    log "Importing subnets from rule set reference for '$section': $reference"

    case "$reference" in
    /*.srs)
        import_custom_ruleset_subnets_from_local "$reference" "binary" "$section" || {
            log "Failed to import subnets from local SRS rule set: $reference" "error"
            RULE_SET_WITH_SUBNETS_IMPORT_STATUS=1
        }
        ;;
    /*.json)
        import_custom_ruleset_subnets_from_local "$reference" "source" "$section" || {
            log "Failed to import subnets from local JSON rule set: $reference" "error"
            RULE_SET_WITH_SUBNETS_IMPORT_STATUS=1
        }
        ;;
    http://* | https://*)
        extension="$(url_get_file_extension "$reference")"
        case "$extension" in
        srs)
            import_custom_ruleset_subnets_from_remote "$reference" "binary" "$section" || {
                log "Failed to import subnets from remote SRS rule set: $reference" "error"
                RULE_SET_WITH_SUBNETS_IMPORT_STATUS=1
            }
            ;;
        json)
            import_custom_ruleset_subnets_from_remote "$reference" "source" "$section" || {
                log "Failed to import subnets from remote JSON rule set: $reference" "error"
                RULE_SET_WITH_SUBNETS_IMPORT_STATUS=1
            }
            ;;
        *)
            format="$(get_inline_remote_ruleset_format "$reference")"
            import_custom_ruleset_subnets_from_remote "$reference" "$format" "$section" || {
                log "Failed to import subnets from remote rule set: $reference" "error"
                RULE_SET_WITH_SUBNETS_IMPORT_STATUS=1
            }
            ;;
        esac
        ;;
    *)
        log "Unsupported rule set reference for subnet import: $reference" "error"
        RULE_SET_WITH_SUBNETS_IMPORT_STATUS=1
        ;;
    esac

    return 0
}

import_custom_ruleset_subnets_from_local() {
    local path="$1"
    local format="$2"
    local section="$3"
    local json_tmpfile unscoped_tmpfile scoped_tmpfile

    if [ ! -f "$path" ]; then
        log "Local rule set file $path not found" "error"
        return 1
    fi

    json_tmpfile="$(mktemp)"
    unscoped_tmpfile="$(mktemp)"
    scoped_tmpfile="$(mktemp)"

    if [ "$format" = "binary" ]; then
        if ! decompile_binary_ruleset "$path" "$json_tmpfile"; then
            rm -f "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile"
            return 1
        fi
    else
        if ! cp "$path" "$json_tmpfile"; then
            log "Failed to copy source rule set file $path" "error"
            rm -f "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile"
            return 1
        fi
    fi

    if ! extract_json_ruleset_nft_files_for_section "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile" "$section"; then
        log "Failed to extract ip_cidr entries from rule set $path" "error"
        rm -f "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile"
        return 1
    fi

    if ! add_extracted_ruleset_subnets_to_nft_for_section "$section" "$unscoped_tmpfile" "$scoped_tmpfile" "Rule set $path"; then
        log "Failed to add subnets from rule set $path to nftables" "error"
        rm -f "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile"
        return 1
    fi

    rm -f "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile"
}

import_custom_ruleset_subnets_from_remote() {
    local url="$1"
    local format="$2"
    local section="$3"
    local remote_tmpfile json_tmpfile unscoped_tmpfile scoped_tmpfile http_proxy_address download_status

    remote_tmpfile="$(mktemp)"
    json_tmpfile="$(mktemp)"
    unscoped_tmpfile="$(mktemp)"
    scoped_tmpfile="$(mktemp)"
    http_proxy_address="$(get_service_proxy_address lists)"

    download_to_file "$url" "$remote_tmpfile" "$http_proxy_address"
    download_status="$?"

    if [ "$download_status" -ne 0 ] || [ ! -s "$remote_tmpfile" ]; then
        log "Failed to download remote rule set $url; skipping it until the next successful update" "warn"
        rm -f "$remote_tmpfile" "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile"
        return 0
    fi

    if [ "$format" = "binary" ]; then
        if ! decompile_binary_ruleset "$remote_tmpfile" "$json_tmpfile"; then
            rm -f "$remote_tmpfile" "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile"
            return 1
        fi
    else
        if ! cp "$remote_tmpfile" "$json_tmpfile"; then
            log "Failed to copy downloaded source rule set $url" "error"
            rm -f "$remote_tmpfile" "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile"
            return 1
        fi
    fi

    if ! extract_json_ruleset_nft_files_for_section "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile" "$section"; then
        log "Failed to extract ip_cidr entries from rule set $url" "error"
        rm -f "$remote_tmpfile" "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile"
        return 1
    fi

    if ! add_extracted_ruleset_subnets_to_nft_for_section "$section" "$unscoped_tmpfile" "$scoped_tmpfile" "Rule set $url"; then
        log "Failed to add subnets from rule set $url to nftables" "error"
        rm -f "$remote_tmpfile" "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile"
        return 1
    fi

    rm -f "$remote_tmpfile" "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile"
}

ensure_discord_udp_fakeip_rule() {
    nft_create_ipv4_set "$NFT_TABLE_NAME" "$NFT_DISCORD_SET_NAME"

    if nft list chain inet "$NFT_TABLE_NAME" mangle 2> /dev/null |
        sing_box_runtime_ucode stdin-contains "iifname @$NFT_INTERFACE_SET_NAME ip daddr @$NFT_DISCORD_SET_NAME udp dport { 19000-20000, 50000-65535 } meta mark set $NFT_FAKEIP_MARK" >/dev/null 2>&1; then
        return 0
    fi

    nft add rule inet "$NFT_TABLE_NAME" mangle iifname "@$NFT_INTERFACE_SET_NAME" ip daddr \
        "@$NFT_DISCORD_SET_NAME" udp dport '{ 19000-20000, 50000-65535 }' meta mark set "$NFT_FAKEIP_MARK" counter
}

import_community_service_subnet_list_handler() {
    local service="$1"
    local section="$2"
    local ports status download_status

    ports="$(get_rule_ports_commas_string "$section")"

    case "$service" in
    "twitter")
        URL=$SUBNETS_TWITTER
        ;;
    "meta")
        URL=$SUBNETS_META
        ;;
    "telegram")
        URL=$SUBNETS_TELERAM
        ;;
    "cloudflare")
        URL=$SUBNETS_CLOUDFLARE
        ;;
    "hetzner")
        URL=$SUBNETS_HETZNER
        ;;
    "ovh")
        URL=$SUBNETS_OVH
        ;;
    "digitalocean")
        URL=$SUBNETS_DIGITALOCEAN
        ;;
    "cloudfront")
        URL=$SUBNETS_CLOUDFRONT
        ;;
    "discord")
        URL=$SUBNETS_DISCORD
        [ -n "$ports" ] || ensure_discord_udp_fakeip_rule
        ;;
    "roblox")
        URL=$SUBNETS_ROBLOX
        ;;
    *) return 0 ;;
    esac

    local tmpfile http_proxy_address
    tmpfile=$(mktemp)
    http_proxy_address="$(get_service_proxy_address lists)"

    download_to_file "$URL" "$tmpfile" "$http_proxy_address"
    download_status="$?"

    if [ "$download_status" -ne 0 ] || [ ! -s "$tmpfile" ]; then
        log "Failed to download built-in $service subnet list; skipping it until the next successful update" "warn"
        rm -f "$tmpfile"
        return 0
    fi

    status=0
    if [ "$service" = "discord" ] && [ -z "$ports" ]; then
        nft_add_set_elements_from_file_chunked "$tmpfile" "$NFT_TABLE_NAME" "$NFT_DISCORD_SET_NAME" || status=1
    else
        add_plain_subnet_file_to_nft_for_section "$section" "$tmpfile" || status=1
    fi

    rm -f "$tmpfile"
    return "$status"
}

import_domains_from_remote_domain_lists() {
    local section="$1"
    local remote_domain_lists

    rule_is_enabled "$section" || return 0

    config_get remote_domain_lists "$section" "remote_domain_lists"
    if [ -n "$remote_domain_lists" ]; then
        log "Importing domains from remote domain lists for '$section' section"
        config_list_foreach "$section" "remote_domain_lists" import_domains_from_remote_domain_list_handler "$section"
    fi
}

import_domains_from_remote_domain_list_handler() {
    local url="$1"
    local section="$2"

    log "Importing domains from URL: $url"

    local file_extension
    file_extension=$(url_get_file_extension "$url")
    log "Detected file extension: '$file_extension'" "debug"
    case "$file_extension" in
    json | srs)
        log "No update needed - sing-box manages updates automatically."
        ;;
    *)
        log "Import domains from a remote plain-text list"
        import_domains_from_remote_plain_file "$url" "$section"
        ;;
    esac
}

import_domains_from_remote_plain_file() {
    local url="$1"
    local section="$2"

    local tmpfile http_proxy_address download_status ruleset_tag ruleset_filepath
    tmpfile=$(mktemp)
    http_proxy_address="$(get_service_proxy_address lists)"

    download_to_file "$url" "$tmpfile" "$http_proxy_address"
    download_status="$?"

    if [ "$download_status" -ne 0 ] || [ ! -s "$tmpfile" ]; then
        log "Failed to download remote domain list $url; skipping it until the next successful update" "warn"
        rm -f "$tmpfile"
        return 0
    fi

    convert_crlf_to_lf "$tmpfile"
    ruleset_tag=$(get_ruleset_tag "$section" "remote" "domains")
    ruleset_filepath="$TMP_RULESET_FOLDER/$ruleset_tag.json"
    import_plain_domain_list_to_local_source_ruleset_chunked "$tmpfile" "$ruleset_filepath"

    rm -f "$tmpfile"
}

import_subnets_from_remote_subnet_lists() {
    local section="$1"
    local remote_subnet_lists

    rule_is_enabled "$section" || return 0

    config_get remote_subnet_lists "$section" "remote_subnet_lists"
    if [ -n "$remote_subnet_lists" ]; then
        REMOTE_SUBNET_IMPORT_STATUS=0
        log "Importing subnets from remote subnet lists for '$section' section"
        config_list_foreach "$section" "remote_subnet_lists" import_subnets_from_remote_subnet_list_handler "$section"
        return "$REMOTE_SUBNET_IMPORT_STATUS"
    fi
}

import_subnets_from_remote_subnet_list_handler() {
    local url="$1"
    local section="$2"

    log "Importing subnets from URL: $url"

    local file_extension
    file_extension="$(url_get_file_extension "$url")"
    log "Detected file extension: '$file_extension'" "debug"
    case "$file_extension" in
    json)
        log "Import subnets from a remote JSON list" "info"
        import_subnets_from_remote_json_file "$url" "$section" || REMOTE_SUBNET_IMPORT_STATUS=1
        ;;
    srs)
        log "Import subnets from a remote SRS list" "info"
        import_subnets_from_remote_srs_file "$url" "$section" || REMOTE_SUBNET_IMPORT_STATUS=1
        ;;
    *)
        log "Import subnets from a remote plain-text list" "info"
        import_subnets_from_remote_plain_file "$url" "$section" || REMOTE_SUBNET_IMPORT_STATUS=1
        ;;
    esac
    return 0
}

import_subnets_from_remote_json_file() {
    local url="$1"
    local section="$2"
    local json_tmpfile unscoped_tmpfile scoped_tmpfile http_proxy_address download_status
    json_tmpfile="$(mktemp)"
    unscoped_tmpfile="$(mktemp)"
    scoped_tmpfile="$(mktemp)"
    http_proxy_address="$(get_service_proxy_address lists)"

    download_to_file "$url" "$json_tmpfile" "$http_proxy_address"
    download_status="$?"

    if [ "$download_status" -ne 0 ] || [ ! -s "$json_tmpfile" ]; then
        log "Failed to download remote JSON subnet list $url; skipping it until the next successful update" "warn"
        rm -f "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile"
        return 0
    fi

    if ! extract_json_ruleset_nft_files_for_section "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile" "$section"; then
        log "Failed to extract ip_cidr entries from remote JSON list $url" "error"
        rm -f "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile"
        return 1
    fi

    if ! add_extracted_ruleset_subnets_to_nft_for_section "$section" "$unscoped_tmpfile" "$scoped_tmpfile" "Remote JSON rule set $url"; then
        log "Failed to add subnets from remote JSON list $url to nftables" "error"
        rm -f "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile"
        return 1
    fi

    rm -f "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile"
}

import_subnets_from_remote_srs_file() {
    local url="$1"
    local section="$2"

    local binary_tmpfile json_tmpfile unscoped_tmpfile scoped_tmpfile http_proxy_address download_status
    binary_tmpfile="$(mktemp)"
    json_tmpfile="$(mktemp)"
    unscoped_tmpfile="$(mktemp)"
    scoped_tmpfile="$(mktemp)"
    http_proxy_address="$(get_service_proxy_address lists)"

    download_to_file "$url" "$binary_tmpfile" "$http_proxy_address"
    download_status="$?"

    if [ "$download_status" -ne 0 ] || [ ! -s "$binary_tmpfile" ]; then
        log "Failed to download remote SRS subnet list $url; skipping it until the next successful update" "warn"
        rm -f "$binary_tmpfile" "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile"
        return 0
    fi

    if ! decompile_binary_ruleset "$binary_tmpfile" "$json_tmpfile"; then
        log "Failed to decompile binary rule set file" "error"
        rm -f "$binary_tmpfile" "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile"
        return 1
    fi

    if ! extract_json_ruleset_nft_files_for_section "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile" "$section"; then
        log "Failed to extract ip_cidr entries from remote SRS list $url" "error"
        rm -f "$binary_tmpfile" "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile"
        return 1
    fi

    if ! add_extracted_ruleset_subnets_to_nft_for_section "$section" "$unscoped_tmpfile" "$scoped_tmpfile" "Remote SRS rule set $url"; then
        log "Failed to add subnets from remote SRS list $url to nftables" "error"
        rm -f "$binary_tmpfile" "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile"
        return 1
    fi

    rm -f "$binary_tmpfile" "$json_tmpfile" "$unscoped_tmpfile" "$scoped_tmpfile"
}

import_subnets_from_remote_plain_file() {
    local url="$1"
    local section="$2"

    local tmpfile http_proxy_address ruleset_tag ruleset_filepath status download_status
    tmpfile=$(mktemp)
    http_proxy_address="$(get_service_proxy_address lists)"

    download_to_file "$url" "$tmpfile" "$http_proxy_address"
    download_status="$?"

    if [ "$download_status" -ne 0 ] || [ ! -s "$tmpfile" ]; then
        log "Failed to download remote plain subnet list $url; skipping it until the next successful update" "warn"
        rm -f "$tmpfile"
        return 0
    fi

    convert_crlf_to_lf "$tmpfile"

    ruleset_tag=$(get_ruleset_tag "$section" "remote" "subnets")
    ruleset_filepath="$TMP_RULESET_FOLDER/$ruleset_tag.json"
    status=0
    import_plain_subnet_list_to_local_source_ruleset_chunked "$tmpfile" "$ruleset_filepath" || status=1
    add_plain_subnet_file_to_nft_for_section "$section" "$tmpfile" || status=1

    rm -f "$tmpfile"
    return "$status"
}

## Support functions
get_service_proxy_address() {
    local purpose="${1:-lists}"

    if download_via_proxy_enabled_for_purpose "$purpose"; then
        echo "$SB_SERVICE_MIXED_INBOUND_ADDRESS:$SB_SERVICE_MIXED_INBOUND_PORT"
    else
        echo ""
    fi
}

get_download_detour_tag() {
    if download_via_proxy_enabled_for_purpose lists; then
        local download_lists_via_proxy_section section_outbound_tag
        config_get download_lists_via_proxy_section "settings" "download_lists_via_proxy_section"
        section_outbound_tag="$(get_outbound_tag_by_section "$download_lists_via_proxy_section")"
        echo "$section_outbound_tag"
    else
        echo ""
    fi
}

_determine_first_outbound_section() {
    local section="$1"
    local action

    rule_is_enabled "$section" || return 0
    subscription_section_is_deferred "$section" && return 0

    action="$(get_rule_action "$section")"
    if [ "$action" = "proxy" ] || [ "$action" = "outbound" ] || [ "$action" = "vpn" ] ||
        { [ "$action" = "byedpi" ] && is_byedpi_installed; } ||
        { [ "$action" = "zapret" ] && is_zapret_installed; } ||
        { [ "$action" = "zapret2" ] && is_zapret2_installed; }; then
        [ -z "$first_section" ] && first_section="$1"
    fi
}

get_first_outbound_section() {
    local first_section=""

    config_foreach _determine_first_outbound_section "section"

    echo "$first_section"
}

get_device_ipv4_address() {
    local device="$1"

    ip -4 addr show dev "$device" 2> /dev/null | sing_box_runtime_ucode ip-addr-first-inet4 2>/dev/null
}

get_service_listen_address() {
    local service_listen_address interface

    config_get service_listen_address "settings" "service_listen_address"
    if [ -n "$service_listen_address" ]; then
        log "Attention! The service_listen_address option is being used, overriding the automatic detection of the listening IP address!" "warn"
        echo "$service_listen_address"
        return 0
    fi

    interface="lan"
    network_get_ipaddr service_listen_address "$interface"
    if [ -n "$service_listen_address" ]; then
        echo "$service_listen_address"
        return 0
    fi

    local source_network_interfaces
    config_get source_network_interfaces "settings" "source_network_interfaces" "br-lan"
    for interface in $source_network_interfaces; do
        network_get_ipaddr service_listen_address "$interface"
        if [ -n "$service_listen_address" ]; then
            echo "$service_listen_address"
            return 0
        fi

        service_listen_address="$(get_device_ipv4_address "$interface")"
        if [ -n "$service_listen_address" ]; then
            echo "$service_listen_address"
            return 0
        fi
    done

    log "Failed to determine the listening IP address. Please open an issue to report this problem: https://github.com/ushan0v/podkop-plus/issues" "error"
    return 1
}

## nftables
nft_list_all_traffic_from_ip() {
    local ip="$1"

    if ! nft list chain inet "$NFT_TABLE_NAME" mangle |
        sing_box_runtime_ucode stdin-regex-matches "ip saddr $ip" >/dev/null 2>&1; then
        nft insert rule inet "$NFT_TABLE_NAME" mangle iifname "@$NFT_INTERFACE_SET_NAME" ip saddr "$ip" \
            meta l4proto tcp meta mark set "$NFT_FAKEIP_MARK" counter
        nft insert rule inet "$NFT_TABLE_NAME" mangle iifname "@$NFT_INTERFACE_SET_NAME" ip saddr "$ip" \
            meta l4proto udp meta mark set "$NFT_FAKEIP_MARK" counter
        nft insert rule inet "$NFT_TABLE_NAME" mangle ip saddr "$ip" ip daddr @localv4 return
    fi
}

# Diagnotics
