# shellcheck shell=ash

ensure_runtime_dirs() {
    mkdir -p "$TMP_SING_BOX_FOLDER"
    mkdir -p "$TMP_RULESET_FOLDER"
    mkdir -p "$TMP_SUBSCRIPTION_FOLDER"
    mkdir -p "$PODKOP_RUNTIME_STATE_DIR"
    mkdir -p "$PODKOP_SUBSCRIPTION_UPDATE_STATE_DIR"
    mkdir -p "$PODKOP_SUBSCRIPTION_UPDATE_JOB_DIR"
    mkdir -p "$PODKOP_SUBSCRIPTION_LINKS_DIR"
    mkdir -p "$PODKOP_SUBSCRIPTION_METADATA_DIR"
    mkdir -p "$PODKOP_OUTBOUND_METADATA_DIR"
    mkdir -p "$PODKOP_SECTION_CACHE_DIR"
}

get_subscription_json_path() {
    local section="$1"

    echo "$TMP_SUBSCRIPTION_FOLDER/${section}.json"
}

get_subscription_url_cache_path() {
    local section="$1"

    echo "$TMP_SUBSCRIPTION_FOLDER/${section}.url"
}

get_subscription_user_agent_cache_path() {
    local section="$1"

    echo "$TMP_SUBSCRIPTION_FOLDER/${section}.user_agent"
}

subscription_cache_section_is_safe() {
    local section="$1"

    case "$section" in
    "" | */* | *..*)
        return 1
        ;;
    esac

    return 0
}

get_persistent_subscription_json_path() {
    local section="$1"

    echo "$PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR/${section}.json"
}

get_persistent_subscription_url_cache_path() {
    local section="$1"

    echo "$PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR/${section}.url"
}

get_persistent_subscription_user_agent_cache_path() {
    local section="$1"

    echo "$PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR/${section}.user_agent"
}

get_subscription_update_timestamp_path() {
    local section="$1"

    echo "$PODKOP_SUBSCRIPTION_UPDATE_STATE_DIR/${section}.timestamp"
}

get_subscription_links_path() {
    local section="$1"

    echo "$PODKOP_SUBSCRIPTION_LINKS_DIR/${section}.json"
}

get_subscription_metadata_path() {
    local section="$1"

    echo "$PODKOP_SUBSCRIPTION_METADATA_DIR/${section}.json"
}

get_outbound_metadata_path() {
    local section="$1"

    echo "$PODKOP_OUTBOUND_METADATA_DIR/${section}.json"
}

get_section_cache_path() {
    local section="$1"

    echo "$PODKOP_SECTION_CACHE_DIR/${section}.json"
}

clear_subscription_runtime_cache() {
    rm -rf \
        "$TMP_SUBSCRIPTION_FOLDER" \
        "$PODKOP_SUBSCRIPTION_LINKS_DIR" \
        "$PODKOP_SUBSCRIPTION_METADATA_DIR" \
        "$PODKOP_OUTBOUND_METADATA_DIR" \
        "$PODKOP_SECTION_CACHE_DIR"
}

ensure_runtime_cache_format() {
    local current_format persistent_format

    mkdir -p "$PODKOP_RUNTIME_STATE_DIR"
    current_format="$(subscription_cache_ucode file-first-line "$PODKOP_RUNTIME_CACHE_FORMAT_FILE" 2>/dev/null)"

    if [ "$current_format" != "$PODKOP_RUNTIME_CACHE_FORMAT" ]; then
        log "Runtime subscription cache format changed; clearing old subscription cache" "info"
        clear_subscription_runtime_cache
        ensure_runtime_dirs
        printf '%s\n' "$PODKOP_RUNTIME_CACHE_FORMAT" > "$PODKOP_RUNTIME_CACHE_FORMAT_FILE"
    fi

    persistent_format="$(subscription_cache_ucode file-first-line "$PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE" 2>/dev/null)"
    if [ "$persistent_format" != "$PODKOP_RUNTIME_CACHE_FORMAT" ]; then
        rm -rf "$PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR"
        mkdir -p "$PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR"
        chmod 700 "$PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR" 2>/dev/null || true
        printf '%s\n' "$PODKOP_RUNTIME_CACHE_FORMAT" > "$PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE"
        chmod 600 "$PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE" 2>/dev/null || true
    fi
}

remove_legacy_server_country_cache() {
    rm -f "$PODKOP_RUNTIME_STATE_DIR/server-country-cache.json"
}

subscription_cache_ucode() {
    ucode "$PODKOP_LIB/subscription_cache.uc" "$@"
}

subscription_cache_tmpfile() {
    local section="$1"
    local kind="$2"

    mktemp "$TMP_SUBSCRIPTION_FOLDER/${section}.${kind}.XXXXXX" 2>/dev/null
}

write_text_file_if_changed() {
    local path="$1"
    local value="$2"
    local tmp

    tmp="${path}.$$"
    printf '%s' "$value" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }

    if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
        chmod 600 "$path" 2>/dev/null || true
        return 0
    fi

    mv "$tmp" "$path" || {
        rm -f "$tmp"
        return 1
    }
    chmod 600 "$path" 2>/dev/null || true
}

copy_file_if_changed() {
    local source="$1"
    local target="$2"
    local tmp

    [ -s "$source" ] || return 1

    if [ -f "$target" ] && cmp -s "$source" "$target"; then
        chmod 600 "$target" 2>/dev/null || true
        return 0
    fi

    tmp="${target}.$$"
    cp "$source" "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv "$tmp" "$target" || {
        rm -f "$tmp"
        return 1
    }
    chmod 600 "$target" 2>/dev/null || true
}

persist_subscription_cache() {
    local source_section="$1"
    local subscription_json_path="$2"
    local subscription_url="$3"
    local effective_user_agent="$4"
    local already_validated="${5:-0}"
    local persistent_json_path persistent_url_path persistent_user_agent_path

    subscription_cache_section_is_safe "$source_section" || return 1
    [ "$already_validated" -eq 1 ] || subscription_cache_is_usable "$subscription_json_path" || return 1
    mkdir -p "$PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR" || return 1
    chmod 700 "$PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR" 2>/dev/null || true

    persistent_json_path="$(get_persistent_subscription_json_path "$source_section")"
    persistent_url_path="$(get_persistent_subscription_url_cache_path "$source_section")"
    persistent_user_agent_path="$(get_persistent_subscription_user_agent_cache_path "$source_section")"

    copy_file_if_changed "$subscription_json_path" "$persistent_json_path" &&
        write_text_file_if_changed "$persistent_url_path" "$subscription_url" &&
        write_text_file_if_changed "$persistent_user_agent_path" "$effective_user_agent"
}

restore_persistent_subscription_cache() {
    local source_section="$1"
    local subscription_json_path="$2"
    local subscription_url_cache_path="$3"
    local subscription_user_agent_cache_path="$4"
    local expected_url="$5"
    local expected_user_agent="$6"
    local persistent_json_path persistent_url_path persistent_user_agent_path \
        cached_subscription_url cached_subscription_user_agent tmp_json

    subscription_cache_section_is_safe "$source_section" || return 1
    subscription_cache_is_usable "$subscription_json_path" && return 0

    persistent_json_path="$(get_persistent_subscription_json_path "$source_section")"
    persistent_url_path="$(get_persistent_subscription_url_cache_path "$source_section")"
    persistent_user_agent_path="$(get_persistent_subscription_user_agent_cache_path "$source_section")"

    subscription_cache_is_usable "$persistent_json_path" || return 1
    cached_subscription_url="$(cat "$persistent_url_path" 2>/dev/null)"
    cached_subscription_user_agent="$(cat "$persistent_user_agent_path" 2>/dev/null)"

    [ "$cached_subscription_url" = "$expected_url" ] || return 1
    subscription_cached_user_agent_matches_config "$expected_user_agent" "$cached_subscription_user_agent" || return 1

    mkdir -p "$TMP_SUBSCRIPTION_FOLDER" || return 1
    tmp_json="$(subscription_cache_tmpfile "$source_section" "restore")" || return 1
    cp "$persistent_json_path" "$tmp_json" || {
        rm -f "$tmp_json"
        return 1
    }
    mv "$tmp_json" "$subscription_json_path" || {
        rm -f "$tmp_json"
        return 1
    }
    printf '%s' "$cached_subscription_url" > "$subscription_url_cache_path" || return 1
    printf '%s' "$cached_subscription_user_agent" > "$subscription_user_agent_cache_path" || return 1

    log "Restored last working subscription cache for source '$source_section'" "info"
}

write_subscription_outbound_link_cache() {
    local section="$1"
    local links_json="$2"
    local link_refs_json="${3:-}"
    local links_tmp link_refs_tmp status

    ensure_runtime_dirs
    [ -n "$links_json" ] || links_json="{}"
    [ -n "$link_refs_json" ] || link_refs_json="{}"

    links_tmp="$(subscription_cache_tmpfile "$section" "links")" || return 1
    link_refs_tmp="$(subscription_cache_tmpfile "$section" "link-refs")" || {
        rm -f "$links_tmp"
        return 1
    }

    printf '%s' "$links_json" > "$links_tmp" || {
        rm -f "$links_tmp" "$link_refs_tmp"
        return 1
    }
    printf '%s' "$link_refs_json" > "$link_refs_tmp" || {
        rm -f "$links_tmp" "$link_refs_tmp"
        return 1
    }

    subscription_cache_ucode write-link-cache \
        "$PODKOP_SECTION_CACHE_DIR" "$PODKOP_RUNTIME_CACHE_FORMAT" "$section" \
        "$links_tmp" "$link_refs_tmp"
    status=$?
    rm -f "$links_tmp" "$link_refs_tmp"
    return "$status"
}

write_outbound_metadata() {
    local section="$1"
    local names_json="$2"
    local countries_json="$3"
    local servers_json="${4:-}"
    local names_tmp countries_tmp servers_tmp status

    ensure_runtime_dirs
    [ -n "$names_json" ] || names_json="{}"
    [ -n "$countries_json" ] || countries_json="{}"
    [ -n "$servers_json" ] || servers_json="{}"

    names_tmp="$(subscription_cache_tmpfile "$section" "names")" || return 1
    countries_tmp="$(subscription_cache_tmpfile "$section" "countries")" || {
        rm -f "$names_tmp"
        return 1
    }
    servers_tmp="$(subscription_cache_tmpfile "$section" "servers")" || {
        rm -f "$names_tmp" "$countries_tmp"
        return 1
    }

    printf '%s' "$names_json" > "$names_tmp" || {
        rm -f "$names_tmp" "$countries_tmp" "$servers_tmp"
        return 1
    }
    printf '%s' "$countries_json" > "$countries_tmp" || {
        rm -f "$names_tmp" "$countries_tmp" "$servers_tmp"
        return 1
    }
    printf '%s' "$servers_json" > "$servers_tmp" || {
        rm -f "$names_tmp" "$countries_tmp" "$servers_tmp"
        return 1
    }

    subscription_cache_ucode write-outbound-metadata \
        "$PODKOP_SECTION_CACHE_DIR" "$PODKOP_RUNTIME_CACHE_FORMAT" "$section" \
        "$names_tmp" "$countries_tmp" "$servers_tmp"
    status=$?
    rm -f "$names_tmp" "$countries_tmp" "$servers_tmp"
    return "$status"
}

subscription_metadata_append_file() {
    local array_path="$1"
    local metadata_path="$2"
    local source_index="${3:-0}"
    local source_section="${4:-}"

    [ -n "$array_path" ] || return 0
    [ -n "$metadata_path" ] || return 0

    subscription_cache_ucode append-metadata-file "$array_path" "$metadata_path" "$source_index" "$source_section" || true
}

subscription_metadata_append_cached_source() {
    local array_path="$1"
    local section="$2"
    local source_index="${3:-0}"
    local source_section="${4:-}"
    local legacy_target_path

    [ -n "$array_path" ] || return 0
    [ -n "$section" ] || return 0

    legacy_target_path="$(get_subscription_metadata_path "$section")"
    subscription_cache_ucode append-cached-metadata \
        "$array_path" "$PODKOP_SECTION_CACHE_DIR" "$section" "$legacy_target_path" \
        "$source_index" "$source_section"
}

write_subscription_metadata_json() {
    local section="$1"
    local metadata_json_path="$2"

    ensure_runtime_dirs
    [ -n "$metadata_json_path" ] || metadata_json_path="/dev/null"

    subscription_cache_ucode write-subscription-metadata \
        "$PODKOP_SECTION_CACHE_DIR" "$PODKOP_RUNTIME_CACHE_FORMAT" "$section" "$metadata_json_path"
}

write_subscription_source_metadata_json() {
    local section="$1"
    local source_index="$2"
    local source_section="$3"
    local metadata_json_path="$4"
    local legacy_target_path

    ensure_runtime_dirs
    [ -n "$metadata_json_path" ] || metadata_json_path="/dev/null"
    legacy_target_path="$(get_subscription_metadata_path "$section")"

    subscription_cache_ucode write-source-metadata \
        "$PODKOP_SECTION_CACHE_DIR" "$PODKOP_RUNTIME_CACHE_FORMAT" "$section" \
        "$source_index" "$source_section" "$metadata_json_path" "$legacy_target_path"
}

subscription_source_id() {
    local section="$1"
    local index="$2"

    printf '%s-subscription-%s\n' "$section" "$index"
}

subscription_mark_unavailable_source() {
    local source_section="$1"

    subscription_source_is_marked_unavailable "$source_section" && return 0
    SUBSCRIPTION_UNAVAILABLE_SOURCES="${SUBSCRIPTION_UNAVAILABLE_SOURCES}
${source_section}"
}

subscription_source_is_marked_unavailable() {
    local source_section="$1"

    case "
${SUBSCRIPTION_UNAVAILABLE_SOURCES}
" in
    *"
${source_section}
"*)
        return 0
        ;;
    esac

    return 1
}

parse_subscription_source_entry() {
    local entry="$1"
    local delimiter=" | "
    local url user_agent

    SUBSCRIPTION_SOURCE_URL=""
    SUBSCRIPTION_SOURCE_USER_AGENT=""
    SUBSCRIPTION_SOURCE_PARSE_ERROR=""

    entry="$(printf '%s' "$entry" | trim_string)"
    if [ -z "$entry" ]; then
        SUBSCRIPTION_SOURCE_PARSE_ERROR="Subscription URL cannot be empty"
        return 1
    fi

    case "$entry" in
    *"$delimiter"*)
        url="${entry%$delimiter*}"
        user_agent="${entry##*$delimiter}"
        url="$(printf '%s' "$url" | trim_string)"
        user_agent="$(printf '%s' "$user_agent" | trim_string)"
        if [ -z "$url" ] || [ -z "$user_agent" ]; then
            SUBSCRIPTION_SOURCE_PARSE_ERROR="Subscription User-Agent separator requires non-empty URL and User-Agent"
            return 1
        fi
        ;;
    *" |"* | *"| "*)
        SUBSCRIPTION_SOURCE_PARSE_ERROR="Use 'URL | User-Agent' with spaces on both sides of the separator"
        return 1
        ;;
    *)
        url="$entry"
        user_agent=""
        ;;
    esac

    case "$url" in
    http://* | https://*) ;;
    *)
        SUBSCRIPTION_SOURCE_PARSE_ERROR="Subscription URL must start with http:// or https://"
        return 1
        ;;
    esac

    SUBSCRIPTION_SOURCE_URL="$url"
    SUBSCRIPTION_SOURCE_USER_AGENT="$user_agent"
    return 0
}

for_each_subscription_source_dispatch() {
    local entry="$1"
    local section="$2"
    local callback="$3"
    shift 3

    SUBSCRIPTION_SOURCE_INDEX=$((SUBSCRIPTION_SOURCE_INDEX + 1))
    "$callback" "$section" "$SUBSCRIPTION_SOURCE_INDEX" "$entry" "$@"
}

for_each_subscription_source() {
    local section="$1"
    local callback="$2"
    local subscription_urls
    shift 2

    SUBSCRIPTION_SOURCE_INDEX=0
    config_get subscription_urls "$section" "subscription_urls"
    [ -n "$subscription_urls" ] || return 0

    config_list_foreach "$section" "subscription_urls" for_each_subscription_source_dispatch "$section" "$callback" "$@"
}

rule_has_subscription_urls() {
    local section="$1"
    local subscription_urls

    config_get subscription_urls "$section" "subscription_urls"

    [ -n "$subscription_urls" ]
}

subscription_config_match_handler() {
    local entry="$1"
    local expected_url="$2"
    local expected_user_agent="$3"

    parse_subscription_source_entry "$entry" >/dev/null 2>&1 || return 0
    if [ "$SUBSCRIPTION_SOURCE_URL" = "$expected_url" ] &&
        [ "$SUBSCRIPTION_SOURCE_USER_AGENT" = "$expected_user_agent" ]; then
        SUBSCRIPTION_CONFIG_MATCH_FOUND=1
    fi
}

subscription_config_is_current() {
    local section="$1"
    local subscription_url="$2"
    local subscription_user_agent="${3:-}"
    local subscription_urls

    config_get subscription_urls "$section" "subscription_urls"
    [ -n "$subscription_urls" ] || return 1

    SUBSCRIPTION_CONFIG_MATCH_FOUND=0
    config_list_foreach "$section" "subscription_urls" subscription_config_match_handler "$subscription_url" "$subscription_user_agent"
    [ "$SUBSCRIPTION_CONFIG_MATCH_FOUND" -eq 1 ]
}

subscription_auto_user_agent_is_supported() {
    local user_agent="$1"
    local default_user_agent="${2:-}"

    [ -n "$user_agent" ] || return 1
    [ -n "$default_user_agent" ] || default_user_agent="$(get_subscription_user_agent)"
    [ "$user_agent" = "$default_user_agent" ] && return 0

    case "$user_agent" in
    Happ | v2rayN | Hiddify | Clash.Meta | ClashMetaForAndroid)
        return 0
        ;;
    esac

    return 1
}

subscription_cached_user_agent_matches_config() {
    local configured_user_agent="${1:-}"
    local cached_user_agent="${2:-}"

    if [ -n "$configured_user_agent" ]; then
        [ "$cached_user_agent" = "$configured_user_agent" ]
        return $?
    fi

    subscription_auto_user_agent_is_supported "$cached_user_agent"
}

subscription_write_user_agent_candidates() {
    local output_path="$1"
    local configured_user_agent="${2:-}"
    local preferred_user_agent="${3:-}"
    local default_user_agent candidate

    if [ -n "$configured_user_agent" ]; then
        printf '%s\n' "$configured_user_agent" > "$output_path"
        return $?
    fi

    : > "$output_path" || return 1

    default_user_agent="$(get_subscription_user_agent)"
    for candidate in "$default_user_agent" "v2rayN" "$preferred_user_agent" "Happ" "Hiddify" "Clash.Meta" "ClashMetaForAndroid"; do
        [ -n "$candidate" ] || continue
        subscription_auto_user_agent_is_supported "$candidate" "$default_user_agent" || continue
        file_has_exact_line "$output_path" "$candidate" && continue
        printf '%s\n' "$candidate" >> "$output_path" || return 1
    done
}

file_has_exact_line() {
    local path="$1"
    local needle="$2"
    local line

    [ -f "$path" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        [ "$line" = "$needle" ] && return 0
    done < "$path"

    return 1
}

subscription_cache_is_usable() {
    local subscription_json_path="$1"

    [ -s "$subscription_json_path" ] || return 1

    validate_subscription_file "$subscription_json_path"
}

subscription_append_word_once() {
    local list="$1"
    local word="$2"

    [ -n "$word" ] || {
        printf '%s\n' "$list"
        return 0
    }

    list_has_item "$list" "$word" && {
        printf '%s\n' "$list"
        return 0
    }

    printf '%s\n' "${list}${list:+ }${word}"
}

subscription_mark_startup_blocked_section() {
    local section="$1"

    SUBSCRIPTION_STARTUP_BLOCKED_SECTIONS="$(subscription_append_word_once "$SUBSCRIPTION_STARTUP_BLOCKED_SECTIONS" "$section")"
}

subscription_startup_blocked_section_is_marked() {
    local section="$1"

    list_has_item "$SUBSCRIPTION_STARTUP_BLOCKED_SECTIONS" "$section"
}

subscription_mark_deferred_section() {
    local section="$1"

    SUBSCRIPTION_DEFERRED_SECTIONS="$(subscription_append_word_once "$SUBSCRIPTION_DEFERRED_SECTIONS" "$section")"
}

subscription_section_is_deferred() {
    local section="$1"

    list_has_item "$SUBSCRIPTION_DEFERRED_SECTIONS" "$section"
}

subscription_section_usable_cache_handler() {
    local section="$1"
    local index="$2"
    local entry="$3"
    local source_section subscription_json_path subscription_url_cache_path subscription_user_agent_cache_path \
        cached_subscription_url cached_subscription_user_agent

    [ "$SUBSCRIPTION_SECTION_USABLE_CACHE_FOUND" -eq 0 ] || return 0
    parse_subscription_source_entry "$entry" >/dev/null 2>&1 || return 0

    source_section="$(subscription_source_id "$section" "$index")"
    subscription_json_path="$(get_subscription_json_path "$source_section")"
    subscription_url_cache_path="$(get_subscription_url_cache_path "$source_section")"
    subscription_user_agent_cache_path="$(get_subscription_user_agent_cache_path "$source_section")"

    restore_persistent_subscription_cache \
        "$source_section" "$subscription_json_path" "$subscription_url_cache_path" "$subscription_user_agent_cache_path" \
        "$SUBSCRIPTION_SOURCE_URL" "$SUBSCRIPTION_SOURCE_USER_AGENT" || true

    subscription_cache_is_usable "$subscription_json_path" || return 0
    cached_subscription_url="$(cat "$subscription_url_cache_path" 2>/dev/null)"
    cached_subscription_user_agent="$(cat "$subscription_user_agent_cache_path" 2>/dev/null)"

    if [ "$cached_subscription_url" = "$SUBSCRIPTION_SOURCE_URL" ] &&
        subscription_cached_user_agent_matches_config "$SUBSCRIPTION_SOURCE_USER_AGENT" "$cached_subscription_user_agent"; then
        SUBSCRIPTION_SECTION_USABLE_CACHE_FOUND=1
    fi
}

subscription_section_has_current_usable_cache() {
    local section="$1"

    rule_has_subscription_urls "$section" || return 1

    SUBSCRIPTION_SECTION_USABLE_CACHE_FOUND=0
    for_each_subscription_source "$section" subscription_section_usable_cache_handler
    [ "$SUBSCRIPTION_SECTION_USABLE_CACHE_FOUND" -eq 1 ]
}

subscription_bootstrap_download_section_is_ready() {
    local download_lists_via_proxy_section action selector_proxy_links outbound_json interface_name

    download_via_proxy_enabled_for_purpose subscriptions || {
        log "Subscription startup cannot be deferred because subscription downloads via Proxy/VPN are disabled" "error"
        return 1
    }

    config_get download_lists_via_proxy_section "settings" "download_lists_via_proxy_section"
    [ -n "$download_lists_via_proxy_section" ] || return 1

    if subscription_startup_blocked_section_is_marked "$download_lists_via_proxy_section"; then
        log "Subscription startup cannot be deferred because selected download rule '$download_lists_via_proxy_section' is also waiting for an unavailable subscription cache" "error"
        return 1
    fi

    rule_is_enabled "$download_lists_via_proxy_section" || return 1

    action="$(get_rule_action "$download_lists_via_proxy_section")"
    case "$action" in
    proxy)
        config_get selector_proxy_links "$download_lists_via_proxy_section" "selector_proxy_links"
        if [ -n "$selector_proxy_links" ]; then
            return 0
        fi

        if subscription_section_has_current_usable_cache "$download_lists_via_proxy_section"; then
            return 0
        fi

        log "Subscription startup cannot be deferred because selected proxy rule '$download_lists_via_proxy_section' has no manual proxy links and no usable subscription cache" "error"
        return 1
        ;;
    outbound)
        config_get outbound_json "$download_lists_via_proxy_section" "outbound_json"
        [ -n "$outbound_json" ] || return 1
        return 0
        ;;
    vpn)
        config_get interface_name "$download_lists_via_proxy_section" "interface"
        [ -n "$interface_name" ] || return 1
        return 0
        ;;
    byedpi)
        is_byedpi_installed
        return $?
        ;;
    zapret)
        is_zapret_installed
        return $?
        ;;
    zapret2)
        is_zapret2_installed
        return $?
        ;;
    *)
        return 1
        ;;
    esac
}

subscription_defer_startup_blocked_sections() {
    local section

    for section in $SUBSCRIPTION_STARTUP_BLOCKED_SECTIONS; do
        subscription_mark_deferred_section "$section"
    done
}

subscription_log_startup_blocked_sections() {
    local section

    for section in $SUBSCRIPTION_STARTUP_BLOCKED_SECTIONS; do
        log "No usable subscription cache for rule '$section' and no manual proxy links are configured; startup cannot continue" "error"
    done
}

get_subscription_download_proxy_address() {
    local section="$1"
    local had_usable_cache="${2:-0}"
    local phase="${3:-runtime}"
    local service_proxy_address download_lists_via_proxy_section selector_proxy_links

    service_proxy_address="$(get_service_proxy_address subscriptions)"
    [ -n "$service_proxy_address" ] || return 0

    if ! sing_box_service_is_running; then
        if [ "$phase" = "startup" ]; then
            log "download_subscriptions_via_proxy is enabled, but sing-box is not running yet; bootstrapping subscription for rule '$section' directly" "info"
        else
            log "download_subscriptions_via_proxy is enabled, but sing-box service proxy is not running; downloading subscription for rule '$section' directly" "warn"
        fi
        return 0
    fi

    config_get download_lists_via_proxy_section "settings" "download_lists_via_proxy_section"
    if [ -n "$download_lists_via_proxy_section" ] &&
        [ "$section" = "$download_lists_via_proxy_section" ] &&
        [ "$had_usable_cache" -eq 0 ]; then
        config_get selector_proxy_links "$section" "selector_proxy_links"
        if [ -z "$selector_proxy_links" ]; then
            log "Rule '$section' is selected for downloading external resources but has no usable subscription cache; downloading it directly to avoid a bootstrap loop" "warn"
            return 0
        fi
    fi

    log "Downloading subscription for rule '$section' via service proxy $service_proxy_address" "debug"
    printf '%s\n' "$service_proxy_address"
}

download_subscription_into_cache() {
    local section="$1"
    local subscription_url="$2"
    local subscription_json_path="$3"
    local subscription_url_cache_path="$4"
    local service_proxy_address="$5"
    local subscription_user_agent="${6:-}"
    local cache_section="${7:-$section}"
    local metadata_output_path="${8:-}"
    local subscription_user_agent_cache_path raw_tmpfile headers_tmpfile normalized_tmpfile metadata_tmpfile \
        user_agents_tmpfile cached_subscription_user_agent effective_user_agent download_status

    mkdir -p "$TMP_SUBSCRIPTION_FOLDER"
    subscription_user_agent_cache_path="$(get_subscription_user_agent_cache_path "$cache_section")"
    raw_tmpfile="$(mktemp "$TMP_SUBSCRIPTION_FOLDER/${cache_section}.download.XXXXXX")" || return 1
    headers_tmpfile="$(mktemp "$TMP_SUBSCRIPTION_FOLDER/${cache_section}.headers.XXXXXX")" || {
        rm -f "$raw_tmpfile"
        return 1
    }
    normalized_tmpfile="$(mktemp "$TMP_SUBSCRIPTION_FOLDER/${cache_section}.normalized.XXXXXX")" || {
        rm -f "$raw_tmpfile" "$headers_tmpfile"
        return 1
    }
    metadata_tmpfile="$(mktemp "$TMP_SUBSCRIPTION_FOLDER/${cache_section}.metadata.XXXXXX")" || {
        rm -f "$raw_tmpfile" "$headers_tmpfile" "$normalized_tmpfile"
        return 1
    }
    user_agents_tmpfile="$(mktemp "$TMP_SUBSCRIPTION_FOLDER/${cache_section}.user-agents.XXXXXX")" || {
        rm -f "$raw_tmpfile" "$headers_tmpfile" "$normalized_tmpfile" "$metadata_tmpfile"
        return 1
    }

    cached_subscription_user_agent="$(subscription_cache_ucode file-first-line "$subscription_user_agent_cache_path" 2>/dev/null)"
    if ! subscription_write_user_agent_candidates "$user_agents_tmpfile" "$subscription_user_agent" "$cached_subscription_user_agent"; then
        rm -f "$raw_tmpfile" "$headers_tmpfile" "$normalized_tmpfile" "$metadata_tmpfile" "$user_agents_tmpfile"
        return 1
    fi

    while IFS= read -r effective_user_agent || [ -n "$effective_user_agent" ]; do
        [ -n "$effective_user_agent" ] || continue

        rm -f "$raw_tmpfile" "$headers_tmpfile" "$normalized_tmpfile" "$metadata_tmpfile"
        if [ -n "$subscription_user_agent" ]; then
            log "Trying configured subscription User-Agent for rule '$section': $effective_user_agent" "info"
        elif [ "$effective_user_agent" = "$cached_subscription_user_agent" ]; then
            log "Trying cached subscription User-Agent for rule '$section': $effective_user_agent" "info"
        else
            log "Trying subscription User-Agent for rule '$section': $effective_user_agent" "info"
        fi

        download_status=0
        download_subscription "$subscription_url" "$raw_tmpfile" "$service_proxy_address" 3 2 15 "$headers_tmpfile" "$effective_user_agent" || download_status="$?"
        if [ "$download_status" -ne 0 ]; then
            [ -n "$metadata_output_path" ] && rm -f "$metadata_output_path"
            if [ "$download_status" -eq 6 ]; then
                log "Subscription download failed for rule '$section' because the subscription host could not be resolved; skipping User-Agent fallbacks" "warn"
                break
            elif [ -n "$subscription_user_agent" ]; then
                log "Subscription download failed with configured User-Agent for rule '$section'" "warn"
            else
                log "Subscription download failed with User-Agent '$effective_user_agent' for rule '$section'; trying next fallback candidate" "warn"
            fi
            continue
        fi

        if subscription_try_decode_gzip_content_file "$raw_tmpfile"; then
            log "Decoded gzip-compressed subscription body for rule '$section'" "info"
        fi

        subscription_extract_ui_metadata "$headers_tmpfile" "$raw_tmpfile" "$metadata_tmpfile" >/dev/null 2>&1 || rm -f "$metadata_tmpfile"
        if [ -n "$metadata_output_path" ]; then
            if [ -s "$metadata_tmpfile" ] && subscription_cache_ucode object-has-extra-keys "$metadata_tmpfile" >/dev/null 2>&1; then
                cp "$metadata_tmpfile" "$metadata_output_path" || rm -f "$metadata_output_path"
            else
                rm -f "$metadata_output_path"
            fi
        fi

        if ! subscription_normalize_content_file "$raw_tmpfile" "$normalized_tmpfile"; then
            [ -n "$metadata_output_path" ] && rm -f "$metadata_output_path"
            if [ -n "$subscription_user_agent" ]; then
                log "Downloaded subscription for rule '$section' is invalid with configured User-Agent" "error"
            else
                log "Downloaded subscription for rule '$section' is invalid with User-Agent '$effective_user_agent'; trying next fallback candidate" "warn"
            fi
            continue
        fi

        if ! subscription_config_is_current "$section" "$subscription_url" "$subscription_user_agent"; then
            log "Subscription source settings changed while updating rule '$section'; discarding superseded download" "warn"
            [ -n "$metadata_output_path" ] && rm -f "$metadata_output_path"
            rm -f "$raw_tmpfile" "$headers_tmpfile" "$normalized_tmpfile" "$metadata_tmpfile" "$user_agents_tmpfile"
            return 4
        fi

        if [ -n "$subscription_user_agent" ]; then
            log "Configured subscription User-Agent for rule '$section' produced valid outbounds" "info"
        else
            log "Selected subscription User-Agent for rule '$section': $effective_user_agent" "info"
        fi

        if [ -f "$subscription_json_path" ] && cmp -s "$normalized_tmpfile" "$subscription_json_path"; then
            rm -f "$raw_tmpfile" "$headers_tmpfile" "$normalized_tmpfile" "$metadata_tmpfile" "$user_agents_tmpfile"
            printf '%s' "$subscription_url" > "$subscription_url_cache_path"
            printf '%s' "$effective_user_agent" > "$subscription_user_agent_cache_path"
            persist_subscription_cache "$cache_section" "$subscription_json_path" "$subscription_url" "$effective_user_agent" 1 ||
                log "Failed to persist last working subscription cache for source '$cache_section'" "warn"
            log "Subscription for rule '$section' is unchanged" "info"
            return 2
        fi

        if [ -f "$subscription_json_path" ] &&
            subscription_runtime_outbounds_equal "$normalized_tmpfile" "$subscription_json_path"; then
            mv "$normalized_tmpfile" "$subscription_json_path" || {
                [ -n "$metadata_output_path" ] && rm -f "$metadata_output_path"
                rm -f "$raw_tmpfile" "$headers_tmpfile" "$normalized_tmpfile" "$metadata_tmpfile" "$user_agents_tmpfile"
                return 1
            }

            rm -f "$raw_tmpfile" "$headers_tmpfile" "$metadata_tmpfile" "$user_agents_tmpfile"
            printf '%s' "$subscription_url" > "$subscription_url_cache_path"
            printf '%s' "$effective_user_agent" > "$subscription_user_agent_cache_path"
            persist_subscription_cache "$cache_section" "$subscription_json_path" "$subscription_url" "$effective_user_agent" 1 ||
                log "Failed to persist last working subscription cache for source '$cache_section'" "warn"
            log "Subscription runtime outbounds for rule '$section' are unchanged" "info"
            return 2
        fi

        mv "$normalized_tmpfile" "$subscription_json_path" || {
            [ -n "$metadata_output_path" ] && rm -f "$metadata_output_path"
            rm -f "$raw_tmpfile" "$headers_tmpfile" "$normalized_tmpfile" "$metadata_tmpfile" "$user_agents_tmpfile"
            return 1
        }

        rm -f "$raw_tmpfile" "$headers_tmpfile" "$metadata_tmpfile" "$user_agents_tmpfile"
        printf '%s' "$subscription_url" > "$subscription_url_cache_path"
        printf '%s' "$effective_user_agent" > "$subscription_user_agent_cache_path"
        persist_subscription_cache "$cache_section" "$subscription_json_path" "$subscription_url" "$effective_user_agent" 1 ||
            log "Failed to persist last working subscription cache for source '$cache_section'" "warn"
        return 0
    done < "$user_agents_tmpfile"

    [ -n "$metadata_output_path" ] && rm -f "$metadata_output_path"
    rm -f "$raw_tmpfile" "$headers_tmpfile" "$normalized_tmpfile" "$metadata_tmpfile" "$user_agents_tmpfile"
    if [ -n "$subscription_user_agent" ]; then
        log "Configured subscription User-Agent for rule '$section' did not produce valid outbounds" "error"
    else
        log "No subscription User-Agent candidate produced valid outbounds for rule '$section'" "error"
    fi
    return 1
}

rule_is_subscription_proxy() {
    local section="$1"
    local action

    rule_is_enabled "$section" || return 1

    action="$(get_rule_action "$section")"
    [ "$action" = "proxy" ] || return 1

    rule_has_subscription_urls "$section"
}

ensure_subscription_cache_for_source() {
    local section="$1"
    local source_section="$2"
    local subscription_url="$3"
    local subscription_user_agent="$4"
    local fatal_on_error="${5:-0}"
    local source_index="${6:-0}"
    local download_phase="${7:-runtime}"
    local subscription_json_path subscription_url_cache_path subscription_user_agent_cache_path metadata_output_path \
        cached_subscription_url cached_subscription_user_agent
    local had_usable_cache cache_needs_refresh service_proxy_address update_result

    if [ -z "$subscription_url" ]; then
        log "Subscription URL is not set for rule '$section'. Aborted." "fatal"
        exit 1
    fi

    mkdir -p "$TMP_SUBSCRIPTION_FOLDER"
    subscription_json_path="$(get_subscription_json_path "$source_section")"
    subscription_url_cache_path="$(get_subscription_url_cache_path "$source_section")"
    subscription_user_agent_cache_path="$(get_subscription_user_agent_cache_path "$source_section")"
    cached_subscription_url=""
    cached_subscription_user_agent=""
    had_usable_cache=0
    cache_needs_refresh=0

    restore_persistent_subscription_cache \
        "$source_section" "$subscription_json_path" "$subscription_url_cache_path" "$subscription_user_agent_cache_path" \
        "$subscription_url" "$subscription_user_agent" || true

    if subscription_cache_is_usable "$subscription_json_path"; then
        had_usable_cache=1
    else
        rm -f "$subscription_json_path"
    fi

    if [ -f "$subscription_url_cache_path" ]; then
        cached_subscription_url="$(cat "$subscription_url_cache_path" 2> /dev/null)"
    fi

    if [ -f "$subscription_user_agent_cache_path" ]; then
        cached_subscription_user_agent="$(cat "$subscription_user_agent_cache_path" 2> /dev/null)"
    fi

    if [ "$had_usable_cache" -eq 0 ] ||
        [ "$cached_subscription_url" != "$subscription_url" ] ||
        ! subscription_cached_user_agent_matches_config "$subscription_user_agent" "$cached_subscription_user_agent"; then
        cache_needs_refresh=1
    fi

    if [ "$cache_needs_refresh" -eq 0 ]; then
        if [ -n "$SUBSCRIPTION_SECTION_METADATA_TMP" ]; then
            if subscription_metadata_append_cached_source "$SUBSCRIPTION_SECTION_METADATA_TMP" "$section" "$source_index" "$source_section"; then
                return 0
            fi

            return 0
        else
            return 0
        fi
    fi

    metadata_output_path=""
    if [ -n "$SUBSCRIPTION_SECTION_METADATA_TMP" ]; then
        metadata_output_path="$(mktemp "$TMP_SUBSCRIPTION_FOLDER/${source_section}.metadata-output.XXXXXX" 2>/dev/null || true)"
    fi

    service_proxy_address="$(get_subscription_download_proxy_address "$section" "$had_usable_cache" "$download_phase")"

    download_subscription_into_cache \
        "$section" "$subscription_url" "$subscription_json_path" "$subscription_url_cache_path" "$service_proxy_address" "$subscription_user_agent" "$source_section" "$metadata_output_path"
    update_result="$?"
    case "$update_result" in
    0 | 2)
        subscription_metadata_append_file "$SUBSCRIPTION_SECTION_METADATA_TMP" "$metadata_output_path" "$source_index" "$source_section"
        rm -f "$metadata_output_path"
        return 0
        ;;
    esac

    rm -f "$metadata_output_path"

    if [ "$had_usable_cache" -eq 1 ] &&
        [ "$cached_subscription_url" = "$subscription_url" ] &&
        subscription_cached_user_agent_matches_config "$subscription_user_agent" "$cached_subscription_user_agent"; then
        log "Keeping cached subscription for rule '$section' until a fresh download succeeds" "warn"
        subscription_metadata_append_cached_source "$SUBSCRIPTION_SECTION_METADATA_TMP" "$section" "$source_index" "$source_section" || true
        return 0
    fi

    if [ "$fatal_on_error" -eq 1 ]; then
        log "Failed to download subscription for rule '$section'. Aborted." "fatal"
        exit 1
    fi

    log "No usable subscription cache for rule '$section'" "warn"
    return 1
}

prepare_subscription_cache_source() {
    local section="$1"
    local index="$2"
    local entry="$3"
    local source_section

    SUBSCRIPTION_SECTION_SOURCE_TOTAL=$((SUBSCRIPTION_SECTION_SOURCE_TOTAL + 1))

    if ! parse_subscription_source_entry "$entry"; then
        log "Invalid subscription source for rule '$section': $SUBSCRIPTION_SOURCE_PARSE_ERROR" "error"
        subscription_startup_blocked=1
        return 0
    fi

    source_section="$(subscription_source_id "$section" "$index")"
    if ensure_subscription_cache_for_source \
        "$section" "$source_section" "$SUBSCRIPTION_SOURCE_URL" "$SUBSCRIPTION_SOURCE_USER_AGENT" 0 "$index" "startup"; then
        SUBSCRIPTION_SECTION_SOURCE_READY=$((SUBSCRIPTION_SECTION_SOURCE_READY + 1))
    else
        SUBSCRIPTION_SECTION_SOURCE_FAILED=$((SUBSCRIPTION_SECTION_SOURCE_FAILED + 1))
        subscription_mark_unavailable_source "$source_section"
    fi
}

prepare_subscription_cache_for_startup() {
    local section="$1"
    local metadata_tmpfile metadata_count selector_proxy_links

    rule_is_subscription_proxy "$section" || return 0

    mkdir -p "$TMP_SUBSCRIPTION_FOLDER"
    metadata_tmpfile="$(mktemp "$TMP_SUBSCRIPTION_FOLDER/${section}.metadata-section.XXXXXX" 2>/dev/null || true)"
    if [ -n "$metadata_tmpfile" ]; then
        printf '[]\n' > "$metadata_tmpfile"
        SUBSCRIPTION_SECTION_METADATA_TMP="$metadata_tmpfile"
    else
        SUBSCRIPTION_SECTION_METADATA_TMP=""
    fi

    SUBSCRIPTION_SECTION_SOURCE_TOTAL=0
    SUBSCRIPTION_SECTION_SOURCE_READY=0
    SUBSCRIPTION_SECTION_SOURCE_FAILED=0
    for_each_subscription_source "$section" prepare_subscription_cache_source

    if [ "$SUBSCRIPTION_SECTION_SOURCE_TOTAL" -gt 0 ] &&
        [ "$SUBSCRIPTION_SECTION_SOURCE_READY" -eq 0 ]; then
        config_get selector_proxy_links "$section" "selector_proxy_links"
        if [ -n "$selector_proxy_links" ]; then
            log "All subscription sources for rule '$section' are unavailable; starting with manual proxy links only" "warn"
        else
            log "No usable subscription cache for rule '$section' and no manual proxy links are configured; checking whether startup can be bootstrapped through the selected proxy/VPN rule" "warn"
            subscription_mark_startup_blocked_section "$section"
        fi
    elif [ "$SUBSCRIPTION_SECTION_SOURCE_FAILED" -gt 0 ]; then
        log "Skipping unavailable subscription source(s) for rule '$section'; using available outbounds" "warn"
    fi

    if [ -n "$metadata_tmpfile" ]; then
        metadata_count="$(subscription_cache_ucode json-length "$metadata_tmpfile" 2>/dev/null)"
        if [ -n "$metadata_count" ] && [ "$metadata_count" -gt 0 ]; then
            write_subscription_metadata_json "$section" "$metadata_tmpfile"
        else
            write_subscription_metadata_json "$section" ""
        fi
        rm -f "$metadata_tmpfile"
    fi
    SUBSCRIPTION_SECTION_METADATA_TMP=""
}

prepare_subscription_caches_for_startup() {
    subscription_startup_blocked=0
    SUBSCRIPTION_UNAVAILABLE_SOURCES=""
    SUBSCRIPTION_DEFERRED_SECTIONS=""
    SUBSCRIPTION_STARTUP_BLOCKED_SECTIONS=""
    config_foreach prepare_subscription_cache_for_startup "section"

    [ "$subscription_startup_blocked" -eq 0 ] || return 1
    [ -n "$SUBSCRIPTION_STARTUP_BLOCKED_SECTIONS" ] || return 0

    if subscription_bootstrap_download_section_is_ready; then
        subscription_defer_startup_blocked_sections
        log "Starting temporarily without subscription-only rule(s): $SUBSCRIPTION_DEFERRED_SECTIONS. They will be retried through the service proxy after sing-box starts" "warn"
        return 0
    fi

    subscription_log_startup_blocked_sections
    return 1
}

wait_for_subscription_bootstrap_service_proxy() {
    local attempt

    attempt=1
    while [ "$attempt" -le 10 ]; do
        if sing_box_service_is_running; then
            return 0
        fi

        sleep 1
        attempt=$((attempt + 1))
    done

    return 1
}

retry_deferred_subscription_section() {
    local section="$1"
    local result

    if ! rule_is_subscription_proxy "$section"; then
        log "Deferred subscription rule '$section' no longer has subscription proxy sources; removing it from bootstrap retry list" "warn"
        return 0
    fi

    log "Retrying deferred subscription rule '$section' through the service proxy" "info"
    subscription_update_section "$section" 1
    result="$?"

    case "$result" in
    0 | 2)
        return 0
        ;;
    esac

    if subscription_section_has_current_usable_cache "$section"; then
        log "Deferred subscription rule '$section' has a usable cache after retry despite partial update errors" "warn"
        return 0
    fi

    return 1
}

rebuild_runtime_after_deferred_subscription_recovery() {
    local recovered_sections="$1"

    log "Recovered deferred subscription rule(s): $recovered_sections; rebuilding sing-box runtime" "info"
    config_load "$PODKOP_CONFIG_NAME"
    prepare_all_server_defaults
    validate_runtime_settings
    sing_box_configure_service
    rebuild_nft_runtime
    PODKOP_NFT_POPULATE_ENABLED=1
    sing_box_init_config
    reload_sing_box_runtime
    apply_pending_urltest_selector_switches
    capture_reload_state
    write_reload_state
}

deferred_subscription_bootstrap_retry_pass() {
    local section remaining_deferred recovered_sections

    [ -n "$SUBSCRIPTION_DEFERRED_SECTIONS" ] || return 0

    remaining_deferred=""
    recovered_sections=""
    for section in $SUBSCRIPTION_DEFERRED_SECTIONS; do
        if retry_deferred_subscription_section "$section"; then
            recovered_sections="${recovered_sections}${recovered_sections:+ }$section"
        else
            remaining_deferred="${remaining_deferred}${remaining_deferred:+ }$section"
            log "Deferred subscription rule '$section' is still unavailable; keeping it disabled for this startup" "warn"
        fi
    done

    [ -n "$recovered_sections" ] || {
        SUBSCRIPTION_DEFERRED_SECTIONS="$remaining_deferred"
        return 1
    }

    SUBSCRIPTION_DEFERRED_SECTIONS="$remaining_deferred"
    SUBSCRIPTION_UNAVAILABLE_SOURCES=""
    rebuild_runtime_after_deferred_subscription_recovery "$recovered_sections"

    if [ -n "$SUBSCRIPTION_DEFERRED_SECTIONS" ]; then
        log "Some deferred subscription rule(s) are still disabled for this startup: $SUBSCRIPTION_DEFERRED_SECTIONS" "warn"
        return 1
    fi

    return 0
}

subscription_bootstrap_retry_worker_cleanup() {
    local status="${1:-0}"

    trap - EXIT INT TERM
    rm -f "$PODKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE"
    release_runtime_dir_lock "$PODKOP_RELOAD_LOCK_DIR"
    release_runtime_dir_lock "$PODKOP_SUBSCRIPTION_UPDATE_LOCK_DIR"
    exit "$status"
}

deferred_subscription_bootstrap_retry_worker() {
    local remaining_sections="$1"

    trap 'subscription_bootstrap_retry_worker_cleanup "$?"' EXIT INT TERM

    while [ -n "$remaining_sections" ]; do
        sleep 30

        if ! sing_box_service_is_running; then
            log "Stopping subscription bootstrap retry worker because sing-box is not running" "warn"
            break
        fi

        config_load "$PODKOP_CONFIG_NAME"
        ensure_runtime_dirs

        if ! acquire_runtime_dir_lock "$PODKOP_SUBSCRIPTION_UPDATE_LOCK_DIR"; then
            log "Subscription bootstrap retry skipped because another subscription update is running" "debug"
            continue
        fi

        if ! acquire_runtime_dir_lock "$PODKOP_RELOAD_LOCK_DIR"; then
            release_runtime_dir_lock "$PODKOP_SUBSCRIPTION_UPDATE_LOCK_DIR"
            log "Subscription bootstrap retry skipped because Podkop Plus reload is running" "debug"
            continue
        fi

        SUBSCRIPTION_DEFERRED_SECTIONS="$remaining_sections"
        SUBSCRIPTION_UNAVAILABLE_SOURCES=""

        if deferred_subscription_bootstrap_retry_pass; then
            release_runtime_dir_lock "$PODKOP_RELOAD_LOCK_DIR"
            release_runtime_dir_lock "$PODKOP_SUBSCRIPTION_UPDATE_LOCK_DIR"
            break
        fi

        remaining_sections="$SUBSCRIPTION_DEFERRED_SECTIONS"
        release_runtime_dir_lock "$PODKOP_RELOAD_LOCK_DIR"
        release_runtime_dir_lock "$PODKOP_SUBSCRIPTION_UPDATE_LOCK_DIR"
    done
}

start_deferred_subscription_bootstrap_retry_worker() {
    local existing_pid

    [ -n "$SUBSCRIPTION_DEFERRED_SECTIONS" ] || return 0

    existing_pid="$(subscription_cache_ucode file-first-line "$PODKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE" 2>/dev/null)"
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
        log "Subscription bootstrap retry worker is already running with PID $existing_pid" "debug"
        return 0
    fi

    (close_inherited_service_lock_fd; deferred_subscription_bootstrap_retry_worker "$SUBSCRIPTION_DEFERRED_SECTIONS") &
    printf '%s\n' "$!" > "$PODKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE"
    log "Started subscription bootstrap retry worker for rule(s): $SUBSCRIPTION_DEFERRED_SECTIONS" "info"
}

stop_deferred_subscription_bootstrap_retry_worker() {
    local pid

    pid="$(subscription_cache_ucode file-first-line "$PODKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        log "Stopped subscription bootstrap retry worker"
    fi
    rm -f "$PODKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE"
}

run_deferred_subscription_bootstrap() {
    [ -n "$SUBSCRIPTION_DEFERRED_SECTIONS" ] || return 0

    log "Waiting for sing-box service proxy before retrying deferred subscription rule(s): $SUBSCRIPTION_DEFERRED_SECTIONS" "info"
    if ! wait_for_subscription_bootstrap_service_proxy; then
        log "sing-box service proxy did not become ready in time; deferred subscription rule(s) will remain disabled until the next successful subscription update" "warn"
        start_deferred_subscription_bootstrap_retry_worker
        return 0
    fi

    deferred_subscription_bootstrap_retry_pass || start_deferred_subscription_bootstrap_retry_worker
}
