# shellcheck shell=ash

updates_runtime_ucode() {
    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/updates_runtime.uc" "$@"
}

build_list_update_cron_job() {
    local update_interval
    local interval_seconds
    local cron_schedule

    update_interval="$(get_settings_update_interval)"
    [ -n "$update_interval" ] || return 1

    interval_seconds="$(duration_to_seconds "$update_interval")" || {
        log "Invalid update_interval value: $update_interval" "error"
        return 1
    }

    cron_schedule="$(seconds_to_due_check_cron_schedule "$interval_seconds")"
    printf '%s %s list_update_if_due %s\n' "$cron_schedule" "$PODKOP_BIN" "$PODKOP_LIST_UPDATE_CRON_MARKER"
}

build_subscription_update_cron_job() {
    local min_interval_seconds cron_schedule

    SUBSCRIPTION_MIN_UPDATE_INTERVAL_SECONDS=0
    config_foreach collect_subscription_update_interval_seconds "section"

    [ "$SUBSCRIPTION_MIN_UPDATE_INTERVAL_SECONDS" -gt 0 ] || return 1

    min_interval_seconds="$SUBSCRIPTION_MIN_UPDATE_INTERVAL_SECONDS"
    cron_schedule="$(seconds_to_subscription_cron_schedule "$min_interval_seconds")"
    printf '%s %s subscription_update_if_due %s\n' "$cron_schedule" "$PODKOP_BIN" "$PODKOP_SUBSCRIPTION_UPDATE_CRON_MARKER"
}

collect_subscription_update_interval_seconds() {
    local section="$1"
    local subscription_update_interval interval_seconds

    rule_is_subscription_proxy "$section" || return 0

    subscription_update_interval="$(get_subscription_update_interval_for_rule "$section")"
    [ -n "$subscription_update_interval" ] || return 0

    interval_seconds="$(duration_to_seconds "$subscription_update_interval")" || {
        log "Invalid subscription_update_interval value for rule '$section': $subscription_update_interval" "error"
        return 0
    }

    if [ "$SUBSCRIPTION_MIN_UPDATE_INTERVAL_SECONDS" -eq 0 ] ||
        [ "$interval_seconds" -lt "$SUBSCRIPTION_MIN_UPDATE_INTERVAL_SECONDS" ]; then
        SUBSCRIPTION_MIN_UPDATE_INTERVAL_SECONDS="$interval_seconds"
    fi
}

seconds_to_due_check_cron_schedule() {
    updates_ucode due-check-cron-schedule "$1"
}

seconds_to_subscription_cron_schedule() {
    seconds_to_due_check_cron_schedule "$1"
}

remove_cron_job() {
    crontab -l 2>/dev/null |
        updates_runtime_ucode filter-cron-markers \
            "$PODKOP_LIST_UPDATE_CRON_MARKER" \
            "$PODKOP_SUBSCRIPTION_UPDATE_CRON_MARKER" |
        crontab -
    log "The cron job removed"
}

duration_to_seconds() {
    updates_ucode duration-to-seconds "$1"
}

read_list_update_timestamp() {
    updates_ucode file-first-line "$PODKOP_LIST_UPDATE_STATE_FILE" 2>/dev/null
}

write_list_update_timestamp() {
    local timestamp="$1"

    mkdir -p "$PODKOP_RUNTIME_STATE_DIR"
    printf '%s\n' "$timestamp" > "$PODKOP_LIST_UPDATE_STATE_FILE"
}

list_update_if_due() {
    local update_interval interval_seconds now last_run

    config_load "$PODKOP_CONFIG_NAME"
    update_interval="$(get_settings_update_interval)"
    [ -n "$update_interval" ] || return 0

    interval_seconds="$(duration_to_seconds "$update_interval")" || {
        log "Invalid update_interval value: $update_interval" "error"
        return 1
    }
    now="$(date +%s 2>/dev/null)"
    last_run="$(read_list_update_timestamp)"

    case "$now" in
    '' | *[!0-9]*) return 1 ;;
    esac

    case "$last_run" in
    '' | *[!0-9]*) last_run=0 ;;
    esac

    if [ "$last_run" -gt 0 ] && [ $((now - last_run)) -lt "$interval_seconds" ]; then
        return 0
    fi

    list_update
}

list_update_section_handler() {
    local section="$1"
    local callback="$2"

    "$callback" "$section" || LIST_UPDATE_FOREACH_STATUS=1
}

list_update_for_each_section() {
    local callback="$1"

    LIST_UPDATE_FOREACH_STATUS=0
    config_foreach list_update_section_handler "section" "$callback"
    [ "$LIST_UPDATE_FOREACH_STATUS" -eq 0 ]
}

list_update() {
    echolog "Starting lists update..."

    local pidfile="/var/run/podkop_list_update.pid"
    local existing_pid
    if [ -f "$pidfile" ]; then
        existing_pid=$(cat "$pidfile" 2> /dev/null)
        if [ -n "$existing_pid" ] && [ "$existing_pid" != "$$" ] && kill -0 "$existing_pid" 2> /dev/null; then
            echolog "Another lists update is already running, skipping"
            return 0
        fi
    fi

    echo $$ > "$pidfile"
    trap 'rm -f "$pidfile"' EXIT INT TERM

    local dns_probe_timeout=3
    local dns_probe_attempts=10
    local curl_timeout=5
    local curl_attempts=10
    local curl_max_timeout=10
    local delay=3
    local i service_proxy_address dns_probe_answer dns_probe_ok curl_ok

    # DNS Check
    service_proxy_address="$(get_service_proxy_address lists)"
    if [ -n "$service_proxy_address" ]; then
        echolog "DNS check skipped because list downloads use service proxy"
    else
        dns_probe_ok=0
        i=1
        while [ "$i" -le "$dns_probe_attempts" ]; do
            dns_probe_answer="$(
                dig +short openwrt.org A +timeout=$dns_probe_timeout +tries=1 2> /dev/null |
                    updates_runtime_ucode stdin-first-ipv4-line 2>/dev/null
            )"
            if [ -n "$dns_probe_answer" ]; then
                echolog "DNS check passed"
                dns_probe_ok=1
                break
            fi
            echolog "DNS is unavailable [$i/$dns_probe_attempts]"
            sleep $delay
            i=$((i + 1))
        done

        if [ "$dns_probe_ok" -ne 1 ]; then
            echolog "DNS check failed after $dns_probe_attempts attempts; skipping remote lists update until the next attempt"
            return 0
        fi
    fi

    # Github Check
    curl_ok=0
    i=1
    while [ "$i" -le "$curl_attempts" ]; do
        if [ -n "$service_proxy_address" ]; then
            if curl -s -x "http://$service_proxy_address" -m $curl_timeout https://github.com > /dev/null; then
                echolog "GitHub connection check passed (via proxy)"
                curl_ok=1
                break
            fi
        else
            if curl -s -m $curl_timeout https://github.com > /dev/null; then
                echolog "GitHub connection check passed"
                curl_ok=1
                break
            fi
        fi

        echolog "GitHub is unavailable [$i/$curl_attempts] (max-timeout=$curl_timeout)"
        if [ "$curl_timeout" -lt $curl_max_timeout ]; then
            curl_timeout=$((curl_timeout + 1))
        fi
        sleep $delay
        i=$((i + 1))
    done

    if [ "$curl_ok" -ne 1 ]; then
        echolog "GitHub connection check failed after $curl_attempts attempts; trying configured list downloads individually"
    fi

    echolog "Downloading and processing lists..."

    local update_status now
    update_status=0

    list_update_for_each_section rebuild_domain_ip_lists_from_rule || update_status=1
    list_update_for_each_section import_builtin_subnets_from_rule || update_status=1
    list_update_for_each_section import_domains_from_remote_domain_lists || update_status=1
    list_update_for_each_section import_subnets_from_remote_subnet_lists || update_status=1
    list_update_for_each_section import_rule_sets_with_subnets_from_rule || update_status=1
    # Keep legacy rule_set references inside sing-box only.
    # Mirroring them into nft via decompile/import regressed compared to the
    # original Podkop behavior and causes long-running list updates plus
    # unstable routing when third-party SRS files are large or incompatible.

    if [ "$update_status" -eq 0 ]; then
        now="$(date +%s 2>/dev/null)"
        case "$now" in
        '' | *[!0-9]*) ;;
        *)
            write_list_update_timestamp "$now"
            ;;
        esac
        echolog "Lists update completed successfully"
    else
        echolog "Lists update failed"
    fi

    [ "$update_status" -eq 0 ] || return 1
}

read_subscription_update_timestamp() {
    local section="$1"

    updates_ucode file-first-line "$(get_subscription_update_timestamp_path "$section")" 2>/dev/null
}

write_subscription_update_timestamp() {
    local section="$1"
    local timestamp="$2"

    mkdir -p "$PODKOP_SUBSCRIPTION_UPDATE_STATE_DIR"
    printf '%s\n' "$timestamp" > "$(get_subscription_update_timestamp_path "$section")"
}

subscription_update_section_is_due() {
    local section="$1"
    local update_interval interval_seconds now last_run

    update_interval="$(get_subscription_update_interval_for_rule "$section")"
    [ -n "$update_interval" ] || return 1

    interval_seconds="$(duration_to_seconds "$update_interval")" || {
        log "Invalid subscription_update_interval value for rule '$section': $update_interval" "error"
        return 2
    }

    now="$(date +%s 2>/dev/null)"
    last_run="$(read_subscription_update_timestamp "$section")"

    case "$now" in
    '' | *[!0-9]*) return 2 ;;
    esac

    case "$last_run" in
    '' | *[!0-9]*) last_run=0 ;;
    esac

    [ "$last_run" -le 0 ] || [ $((now - last_run)) -ge "$interval_seconds" ]
}

subscription_update_section() {
    local section="$1"
    local force="$2"
    local update_result now metadata_tmpfile metadata_count

    rule_is_subscription_proxy "$section" || return 3

    if [ "$force" -eq 0 ]; then
        subscription_update_section_is_due "$section"
        case "$?" in
        0) ;;
        1) return 3 ;;
        *) return 1 ;;
        esac
    fi

    mkdir -p "$TMP_SUBSCRIPTION_FOLDER"

    echolog "Updating subscriptions for rule '$section'..."

    metadata_tmpfile="$(mktemp "$TMP_SUBSCRIPTION_FOLDER/${section}.metadata-section.XXXXXX" 2>/dev/null || true)"
    if [ -n "$metadata_tmpfile" ]; then
        printf '[]\n' > "$metadata_tmpfile"
        SUBSCRIPTION_SECTION_METADATA_TMP="$metadata_tmpfile"
    else
        SUBSCRIPTION_SECTION_METADATA_TMP=""
    fi

    SUBSCRIPTION_SECTION_UPDATE_CHANGED=0
    SUBSCRIPTION_SECTION_UPDATE_UNCHANGED=0
    SUBSCRIPTION_SECTION_UPDATE_FAILED=0
    SUBSCRIPTION_SECTION_UPDATE_SUPERSEDED=0
    SUBSCRIPTION_SECTION_UPDATE_TOTAL=0
    for_each_subscription_source "$section" subscription_update_source_handler
    SUBSCRIPTION_SECTION_METADATA_TMP=""

    if [ "$SUBSCRIPTION_SECTION_UPDATE_TOTAL" -eq 0 ]; then
        rm -f "$metadata_tmpfile"
        echolog "Subscription URL is not set for rule '$section'"
        return 1
    fi

    if [ "$SUBSCRIPTION_SECTION_UPDATE_CHANGED" -gt 0 ]; then
        update_result=0
    elif [ "$SUBSCRIPTION_SECTION_UPDATE_FAILED" -gt 0 ]; then
        update_result=1
    elif [ "$SUBSCRIPTION_SECTION_UPDATE_SUPERSEDED" -gt 0 ]; then
        update_result=4
    else
        update_result=2
    fi

    if [ -n "$metadata_tmpfile" ]; then
        if [ "$SUBSCRIPTION_SECTION_UPDATE_SUPERSEDED" -eq 0 ]; then
            metadata_count="$(updates_runtime_ucode json-length "$metadata_tmpfile" 2>/dev/null)"
            if [ -n "$metadata_count" ] && [ "$metadata_count" -gt 0 ]; then
                write_subscription_metadata_json "$section" "$metadata_tmpfile"
            else
                write_subscription_metadata_json "$section" ""
            fi
        fi
        rm -f "$metadata_tmpfile"
    fi

    case "$update_result" in
    0)
        now="$(date +%s 2>/dev/null)"
        case "$now" in
        '' | *[!0-9]*) ;;
        *) write_subscription_update_timestamp "$section" "$now" ;;
        esac

        echolog "Subscriptions updated for rule '$section'"
        return 0
        ;;
    2)
        now="$(date +%s 2>/dev/null)"
        case "$now" in
        '' | *[!0-9]*) ;;
        *) write_subscription_update_timestamp "$section" "$now" ;;
        esac

        echolog "Subscriptions for rule '$section' are unchanged"
        return 2
        ;;
    4)
        echolog "Subscription update for rule '$section' was superseded by newer URLs"
        return 4
        ;;
    *)
        echolog "Failed to download subscriptions for rule '$section'"
        return 1
        ;;
    esac
}

subscription_update_source_handler() {
    local section="$1"
    local index="$2"
    local entry="$3"
    local source_section subscription_json_path subscription_url_cache_path metadata_output_path \
        had_usable_cache service_proxy_address update_result

    SUBSCRIPTION_SECTION_UPDATE_TOTAL=$((SUBSCRIPTION_SECTION_UPDATE_TOTAL + 1))

    if ! parse_subscription_source_entry "$entry"; then
        echolog "Invalid subscription URL in rule '$section': $SUBSCRIPTION_SOURCE_PARSE_ERROR"
        SUBSCRIPTION_SECTION_UPDATE_FAILED=$((SUBSCRIPTION_SECTION_UPDATE_FAILED + 1))
        return 0
    fi

    source_section="$(subscription_source_id "$section" "$index")"
    subscription_json_path="$(get_subscription_json_path "$source_section")"
    subscription_url_cache_path="$(get_subscription_url_cache_path "$source_section")"
    restore_persistent_subscription_cache \
        "$source_section" "$subscription_json_path" "$subscription_url_cache_path" "$(get_subscription_user_agent_cache_path "$source_section")" \
        "$SUBSCRIPTION_SOURCE_URL" "$SUBSCRIPTION_SOURCE_USER_AGENT" || true
    had_usable_cache=0
    subscription_cache_is_usable "$subscription_json_path" && had_usable_cache=1
    service_proxy_address="$(get_subscription_download_proxy_address "$section" "$had_usable_cache" "runtime")"
    metadata_output_path=""
    if [ -n "$SUBSCRIPTION_SECTION_METADATA_TMP" ]; then
        metadata_output_path="$(mktemp "$TMP_SUBSCRIPTION_FOLDER/${source_section}.metadata-output.XXXXXX" 2>/dev/null || true)"
    fi

    download_subscription_into_cache \
        "$section" "$SUBSCRIPTION_SOURCE_URL" "$subscription_json_path" "$subscription_url_cache_path" "$service_proxy_address" \
        "$SUBSCRIPTION_SOURCE_USER_AGENT" "$source_section" "$metadata_output_path"
    update_result=$?

    case "$update_result" in
    0)
        subscription_metadata_append_file "$SUBSCRIPTION_SECTION_METADATA_TMP" "$metadata_output_path" "$index" "$source_section"
        SUBSCRIPTION_SECTION_UPDATE_CHANGED=$((SUBSCRIPTION_SECTION_UPDATE_CHANGED + 1))
        ;;
    2)
        subscription_metadata_append_file "$SUBSCRIPTION_SECTION_METADATA_TMP" "$metadata_output_path" "$index" "$source_section"
        SUBSCRIPTION_SECTION_UPDATE_UNCHANGED=$((SUBSCRIPTION_SECTION_UPDATE_UNCHANGED + 1))
        ;;
    4)
        SUBSCRIPTION_SECTION_UPDATE_SUPERSEDED=$((SUBSCRIPTION_SECTION_UPDATE_SUPERSEDED + 1))
        ;;
    *)
        subscription_metadata_append_cached_source "$SUBSCRIPTION_SECTION_METADATA_TMP" "$section" "$index" "$source_section" || true
        SUBSCRIPTION_SECTION_UPDATE_FAILED=$((SUBSCRIPTION_SECTION_UPDATE_FAILED + 1))
        ;;
    esac
    rm -f "$metadata_output_path"
}

subscription_update_selected_source_handler() {
    local section="$1"
    local index="$2"
    local entry="$3"
    local source_section subscription_json_path subscription_url_cache_path metadata_output_path \
        had_usable_cache service_proxy_address update_result

    [ "$index" = "$SUBSCRIPTION_SELECTED_SOURCE_INDEX" ] || return 0

    SUBSCRIPTION_SELECTED_SOURCE_FOUND=1
    if ! parse_subscription_source_entry "$entry"; then
        echolog "Invalid subscription URL in rule '$section': $SUBSCRIPTION_SOURCE_PARSE_ERROR"
        SUBSCRIPTION_SELECTED_SOURCE_RESULT=1
        return 0
    fi

    source_section="$(subscription_source_id "$section" "$index")"
    subscription_json_path="$(get_subscription_json_path "$source_section")"
    subscription_url_cache_path="$(get_subscription_url_cache_path "$source_section")"
    restore_persistent_subscription_cache \
        "$source_section" "$subscription_json_path" "$subscription_url_cache_path" "$(get_subscription_user_agent_cache_path "$source_section")" \
        "$SUBSCRIPTION_SOURCE_URL" "$SUBSCRIPTION_SOURCE_USER_AGENT" || true
    had_usable_cache=0
    subscription_cache_is_usable "$subscription_json_path" && had_usable_cache=1
    service_proxy_address="$(get_subscription_download_proxy_address "$section" "$had_usable_cache" "runtime")"
    metadata_output_path="$(mktemp "$TMP_SUBSCRIPTION_FOLDER/${source_section}.metadata-output.XXXXXX" 2>/dev/null || true)"

    download_subscription_into_cache \
        "$section" "$SUBSCRIPTION_SOURCE_URL" "$subscription_json_path" "$subscription_url_cache_path" "$service_proxy_address" \
        "$SUBSCRIPTION_SOURCE_USER_AGENT" "$source_section" "$metadata_output_path"
    update_result=$?

    case "$update_result" in
    0 | 2)
        write_subscription_source_metadata_json "$section" "$index" "$source_section" "$metadata_output_path"
        ;;
    esac

    rm -f "$metadata_output_path"
    SUBSCRIPTION_SELECTED_SOURCE_RESULT="$update_result"
}

subscription_update_selected_source() {
    local section="$1"
    local source_index="$2"
    local force="$3"
    local now

    case "$section" in
    "" | */* | *..*)
        echolog "Invalid subscription rule name"
        return 1
        ;;
    esac

    case "$source_index" in
    "" | *[!0-9]*)
        echolog "Invalid subscription source index for rule '$section'"
        return 1
        ;;
    esac

    [ "$source_index" -gt 0 ] || {
        echolog "Invalid subscription source index for rule '$section'"
        return 1
    }

    rule_is_subscription_proxy "$section" || {
        echolog "Rule '$section' has no subscription sources"
        return 1
    }

    if [ "$force" -eq 0 ]; then
        subscription_update_section_is_due "$section"
        case "$?" in
        0) ;;
        1) return 3 ;;
        *) return 1 ;;
        esac
    fi

    mkdir -p "$TMP_SUBSCRIPTION_FOLDER"

    echolog "Updating subscription source '$source_index' for rule '$section'..."

    SUBSCRIPTION_SELECTED_SOURCE_INDEX="$source_index"
    SUBSCRIPTION_SELECTED_SOURCE_FOUND=0
    SUBSCRIPTION_SELECTED_SOURCE_RESULT=3
    for_each_subscription_source "$section" subscription_update_selected_source_handler

    if [ "$SUBSCRIPTION_SELECTED_SOURCE_FOUND" -eq 0 ]; then
        echolog "Subscription source '$source_index' was not found for rule '$section'"
        return 1
    fi

    case "$SUBSCRIPTION_SELECTED_SOURCE_RESULT" in
    0)
        now="$(date +%s 2>/dev/null)"
        case "$now" in
        '' | *[!0-9]*) ;;
        *) write_subscription_update_timestamp "$section" "$now" ;;
        esac

        echolog "Subscription source '$source_index' updated for rule '$section'"
        return 0
        ;;
    2)
        now="$(date +%s 2>/dev/null)"
        case "$now" in
        '' | *[!0-9]*) ;;
        *) write_subscription_update_timestamp "$section" "$now" ;;
        esac

        echolog "Subscription source '$source_index' for rule '$section' is unchanged"
        return 2
        ;;
    4)
        echolog "Subscription source '$source_index' update for rule '$section' was superseded by newer URLs"
        return 4
        ;;
    *)
        echolog "Failed to download subscription source '$source_index' for rule '$section'"
        return 1
        ;;
    esac
}

subscription_update_handler() {
    local section="$1"
    local result

    subscription_update_section "$section" "$SUBSCRIPTION_UPDATE_FORCE"
    result=$?

    case "$result" in
    0) SUBSCRIPTION_UPDATED_SECTIONS=$((SUBSCRIPTION_UPDATED_SECTIONS + 1)) ;;
    1) SUBSCRIPTION_FAILED_SECTIONS=$((SUBSCRIPTION_FAILED_SECTIONS + 1)) ;;
    2) SUBSCRIPTION_UNCHANGED_SECTIONS=$((SUBSCRIPTION_UNCHANGED_SECTIONS + 1)) ;;
    4) SUBSCRIPTION_SUPERSEDED_SECTIONS=$((SUBSCRIPTION_SUPERSEDED_SECTIONS + 1)) ;;
    3) ;;
    esac
}

subscription_update_abort_cleanup() {
    local status="${1:-1}"

    trap - EXIT INT TERM
    release_runtime_dir_lock "$PODKOP_RELOAD_LOCK_DIR"
    release_runtime_dir_lock "$PODKOP_SUBSCRIPTION_UPDATE_LOCK_DIR"
    exit "$status"
}

subscription_update_common_locked() {
    local force="$1"
    local target_section="${2:-}"
    local target_source_index="${3:-}"

    SUBSCRIPTION_UPDATE_FORCE="$force"
    SUBSCRIPTION_UPDATED_SECTIONS=0
    SUBSCRIPTION_FAILED_SECTIONS=0
    SUBSCRIPTION_UNCHANGED_SECTIONS=0
    SUBSCRIPTION_SUPERSEDED_SECTIONS=0

    if [ -n "$target_section" ]; then
        local result
        if [ -n "$target_source_index" ]; then
            subscription_update_selected_source "$target_section" "$target_source_index" "$force"
        else
            subscription_update_section "$target_section" "$force"
        fi
        result=$?

        case "$result" in
        0) SUBSCRIPTION_UPDATED_SECTIONS=$((SUBSCRIPTION_UPDATED_SECTIONS + 1)) ;;
        1) SUBSCRIPTION_FAILED_SECTIONS=$((SUBSCRIPTION_FAILED_SECTIONS + 1)) ;;
        2) SUBSCRIPTION_UNCHANGED_SECTIONS=$((SUBSCRIPTION_UNCHANGED_SECTIONS + 1)) ;;
        4) SUBSCRIPTION_SUPERSEDED_SECTIONS=$((SUBSCRIPTION_SUPERSEDED_SECTIONS + 1)) ;;
        3) ;;
        esac
    else
        config_foreach subscription_update_handler "section"
    fi

    if [ "$SUBSCRIPTION_UPDATED_SECTIONS" -eq 0 ]; then
        if [ "$SUBSCRIPTION_SUPERSEDED_SECTIONS" -gt 0 ]; then
            echolog "Subscription update was superseded by newer configuration"
            return 0
        fi

        if [ "$SUBSCRIPTION_FAILED_SECTIONS" -gt 0 ]; then
            echolog "Subscription update finished with errors; keeping the last working cache"
            return 1
        fi

        if [ "$SUBSCRIPTION_UNCHANGED_SECTIONS" -gt 0 ]; then
            echolog "Subscription update completed: no changes detected"
        else
            echolog "No subscription rules are due for update"
        fi
        return 0
    fi

    echolog "Reloading sing-box to apply updated subscriptions..."
    config_load "$PODKOP_CONFIG_NAME"
    prepare_all_server_defaults
    validate_runtime_settings
    sing_box_configure_service
    PODKOP_NFT_POPULATE_ENABLED=0
    sing_box_init_config
    PODKOP_NFT_POPULATE_ENABLED=1
    reload_sing_box_runtime
    capture_reload_state
    write_reload_state

    if [ "$SUBSCRIPTION_FAILED_SECTIONS" -gt 0 ]; then
        echolog "Subscription update applied for changed rules; failed rules kept their previous cache"
    else
        echolog "Subscription update completed"
    fi
}

subscription_update_common() {
    local force="$1"
    local target_section="${2:-}"
    local target_source_index="${3:-}"
    local result

    config_load "$PODKOP_CONFIG_NAME"
    migration
    ensure_runtime_dirs

    if [ "$force" -eq 1 ]; then
        if ! acquire_runtime_dir_lock_wait "$PODKOP_SUBSCRIPTION_UPDATE_LOCK_DIR" 300; then
            echolog "Subscription update is already running"
            mark_pending_reload "subscription_update_busy"
            return 1
        fi
    elif ! acquire_runtime_dir_lock "$PODKOP_SUBSCRIPTION_UPDATE_LOCK_DIR"; then
        echolog "Subscription update is already running"
        return 0
    fi

    if [ "$force" -eq 1 ]; then
        if ! acquire_runtime_dir_lock_wait "$PODKOP_RELOAD_LOCK_DIR" 300; then
            release_runtime_dir_lock "$PODKOP_SUBSCRIPTION_UPDATE_LOCK_DIR"
            echolog "Podkop Plus reload is already running; skipping subscription update"
            mark_pending_reload "reload_busy"
            return 1
        fi
    elif ! acquire_runtime_dir_lock "$PODKOP_RELOAD_LOCK_DIR"; then
        release_runtime_dir_lock "$PODKOP_SUBSCRIPTION_UPDATE_LOCK_DIR"
        echolog "Podkop Plus reload is already running; skipping subscription update"
        return 0
    fi

    trap 'subscription_update_abort_cleanup "$?"' EXIT INT TERM

    subscription_update_common_locked "$force" "$target_section" "$target_source_index"
    result=$?

    trap - EXIT INT TERM

    release_runtime_dir_lock "$PODKOP_RELOAD_LOCK_DIR"
    release_runtime_dir_lock "$PODKOP_SUBSCRIPTION_UPDATE_LOCK_DIR"
    run_pending_reload_if_requested
    return "$result"
}

subscription_update_if_due() {
    echolog "Starting due subscription update..."
    subscription_update_common 0
}

subscription_update() {
    local target_section="${1:-}"
    local target_source_index="${2:-}"

    if [ -n "$target_section" ]; then
        echolog "Starting subscription update for rule '$target_section'..."
    else
        echolog "Starting subscription update..."
    fi
    subscription_update_common 1 "$target_section" "$target_source_index"
}

subscription_update_job_json_response() {
    local success="$1"
    local job_id="$2"
    local message="${3:-}"

    updates_runtime_ucode subscription-job-json-response "$success" "$job_id" "$message"
}

subscription_update_job_state_path() {
    local job_id="$1"

    case "$job_id" in
    *[!A-Za-z0-9._-]* | "" | "." | "..")
        return 1
        ;;
    esac

    printf '%s/%s.json\n' "$PODKOP_SUBSCRIPTION_UPDATE_JOB_DIR" "$job_id"
}

subscription_update_job_tmp_file() {
    local target_file="$1"
    local tmp_file

    tmp_file="$(mktemp "${target_file}.XXXXXX" 2>/dev/null || true)"
    if [ -z "$tmp_file" ]; then
        tmp_file="${target_file}.$$.$(date +%s 2>/dev/null).tmp"
        : >"$tmp_file" || return 1
    fi

    printf '%s\n' "$tmp_file"
}

subscription_update_write_running_job_state() {
    local state_file="$1"
    local section="${2:-}"
    local source_index="${3:-}"
    local tmp_file started_at

    started_at="$(date +%s 2>/dev/null)"
    case "$started_at" in
    "" | *[!0-9]*) started_at=0 ;;
    esac

    mkdir -p "$PODKOP_SUBSCRIPTION_UPDATE_JOB_DIR" || return 1
    tmp_file="$(subscription_update_job_tmp_file "$state_file")" || return 1

    updates_runtime_ucode subscription-running-job-state "$section" "$source_index" "$started_at" >"$tmp_file" && mv "$tmp_file" "$state_file"

    local rc=$?
    rm -f "$tmp_file" 2>/dev/null
    return "$rc"
}

subscription_update_update_running_job_pid() {
    local state_file="$1"
    local pid="$2"
    local tmp_file

    case "$pid" in
    "" | *[!0-9]*) return 1 ;;
    esac

    tmp_file="$(subscription_update_job_tmp_file "$state_file")" || return 1
    updates_ucode updates-set-running-job-pid "$state_file" "$pid" >"$tmp_file" && mv "$tmp_file" "$state_file"

    local rc=$?
    rm -f "$tmp_file" 2>/dev/null
    return "$rc"
}

subscription_update_started_at_is_within_stale_grace() {
    local started_at="$1"
    local now age

    case "$started_at" in
    "" | *[!0-9]*) return 1 ;;
    esac
    [ "$started_at" -gt 0 ] || return 1

    now="$(date +%s 2>/dev/null)"
    case "$now" in
    "" | *[!0-9]*) return 1 ;;
    esac

    age=$((now - started_at))
    [ "$age" -lt "${PODKOP_UI_ACTION_STALE_GRACE_SECONDS:-15}" ]
}

subscription_update_cleanup_jobs() {
    local state_file

    [ -d "$PODKOP_SUBSCRIPTION_UPDATE_JOB_DIR" ] || return 0

    find "$PODKOP_SUBSCRIPTION_UPDATE_JOB_DIR" -type f -name '*.out' -mmin "+$PODKOP_SUBSCRIPTION_UPDATE_JOB_ORPHAN_OUTPUT_TTL_MINUTES" -delete 2>/dev/null || true

    find "$PODKOP_SUBSCRIPTION_UPDATE_JOB_DIR" -type f -name '*.json' -mmin "+$PODKOP_SUBSCRIPTION_UPDATE_JOB_FINISHED_TTL_MINUTES" 2>/dev/null |
        while IFS= read -r state_file; do
            [ -f "$state_file" ] || continue
            if updates_ucode job-running-is "$state_file" false >/dev/null 2>&1; then
                rm -f "$state_file" 2>/dev/null || true
            fi
        done
}

subscription_update_output_message() {
    local output_file="$1"
    local fallback="$2"

    updates_ucode file-last-nonblank-line "$output_file" "$fallback" 240
}

subscription_update_write_finished_job_state() {
    local state_file="$1"
    local exit_code="$2"
    local output_file="$3"
    local tmp_file updated_at success message section source_index started_at

    updated_at="$(date +%s 2>/dev/null)"
    case "$updated_at" in
    "" | *[!0-9]*) updated_at=0 ;;
    esac

    success=false
    message="$(subscription_update_output_message "$output_file" "Subscription update failed")"
    if [ "$exit_code" -eq 0 ]; then
        success=true
        message="$(subscription_update_output_message "$output_file" "Subscription update completed")"
    fi

    section="$(updates_ucode json-file-field "$state_file" section "" 2>/dev/null)"
    source_index="$(updates_ucode json-file-field "$state_file" source_index "" 2>/dev/null)"
    started_at="$(updates_ucode json-file-field "$state_file" started_at 0 2>/dev/null)"

    tmp_file="$(subscription_update_job_tmp_file "$state_file")" || return 1
    updates_runtime_ucode subscription-finished-job-state "$success" "$message" "$exit_code" "$updated_at" "$section" "$source_index" "$started_at" >"$tmp_file" && mv "$tmp_file" "$state_file"

    local rc=$?
    rm -f "$tmp_file" "$output_file" 2>/dev/null
    return "$rc"
}

subscription_update_mark_stale_job_state() {
    local state_file="$1"
    local tmp_file updated_at section source_index started_at

    updated_at="$(date +%s 2>/dev/null)"
    case "$updated_at" in
    "" | *[!0-9]*) updated_at=0 ;;
    esac

    section="$(updates_ucode json-file-field "$state_file" section "" 2>/dev/null)"
    source_index="$(updates_ucode json-file-field "$state_file" source_index "" 2>/dev/null)"
    started_at="$(updates_ucode json-file-field "$state_file" started_at 0 2>/dev/null)"

    tmp_file="$(subscription_update_job_tmp_file "$state_file")" || return 1
    updates_runtime_ucode subscription-stale-job-state "$updated_at" "$section" "$source_index" "$started_at" >"$tmp_file" && mv "$tmp_file" "$state_file"

    local rc=$?
    rm -f "$tmp_file" 2>/dev/null
    return "$rc"
}

subscription_update_refresh_running_job_state() {
    local state_file="$1"
    local pid started_at

    updates_ucode job-running-is "$state_file" true >/dev/null 2>&1 || return 0

    pid="$(updates_runtime_ucode job-pid "$state_file" 2>/dev/null)"
    case "$pid" in
    "" | *[!0-9]*)
        started_at="$(updates_ucode json-file-field "$state_file" started_at 0 2>/dev/null)"
        if subscription_update_started_at_is_within_stale_grace "$started_at"; then
            return 0
        fi
        updates_ucode job-running-is "$state_file" true >/dev/null 2>&1 || return 0
        subscription_update_mark_stale_job_state "$state_file"
        return 0
        ;;
    esac

    kill -0 "$pid" 2>/dev/null && return 0
    sleep 1
    updates_ucode job-running-is "$state_file" true >/dev/null 2>&1 || return 0
    kill -0 "$pid" 2>/dev/null && return 0
    updates_ucode job-running-is "$state_file" true >/dev/null 2>&1 || return 0
    subscription_update_mark_stale_job_state "$state_file"
}

subscription_update_async() {
    local target_section="${1:-}"
    local target_source_index="${2:-}"
    local job_id state_file output_file job_pid

    ensure_runtime_dirs
    mkdir -p "$PODKOP_SUBSCRIPTION_UPDATE_JOB_DIR" || {
        subscription_update_job_json_response false "" "Failed to create subscription update state directory"
        exit 1
    }
    subscription_update_cleanup_jobs

    job_id="$(date +%s 2>/dev/null)-$$"
    state_file="$(subscription_update_job_state_path "$job_id")" || {
        subscription_update_job_json_response false "" "Failed to prepare subscription update job"
        exit 1
    }
    output_file="$PODKOP_SUBSCRIPTION_UPDATE_JOB_DIR/$job_id.out"

    subscription_update_write_running_job_state "$state_file" "$target_section" "$target_source_index" || {
        subscription_update_job_json_response false "" "Failed to write subscription update state"
        exit 1
    }

    (
        trap '' HUP
        /usr/bin/podkop-plus subscription_update "$target_section" "$target_source_index" >"$output_file" 2>&1
        subscription_update_write_finished_job_state "$state_file" "$?" "$output_file"
    ) >/dev/null 2>&1 &
    job_pid="$!"

    subscription_update_update_running_job_pid "$state_file" "$job_pid" || {
        kill "$job_pid" 2>/dev/null || true
        subscription_update_job_json_response false "" "Failed to write subscription update worker pid"
        exit 1
    }

    subscription_update_job_json_response true "$job_id" "Subscription update started"
}

subscription_update_status() {
    local job_id="$1"
    local state_file

    mkdir -p "$PODKOP_SUBSCRIPTION_UPDATE_JOB_DIR" 2>/dev/null || true
    subscription_update_cleanup_jobs

    state_file="$(subscription_update_job_state_path "$job_id")" || {
        updates_runtime_ucode subscription-status-error "Invalid subscription update job id"
        exit 1
    }

    if [ ! -f "$state_file" ]; then
        updates_runtime_ucode subscription-status-error "Subscription update job was not found"
        exit 1
    fi

    subscription_update_refresh_running_job_state "$state_file"

    cat "$state_file"
}

# sing-box funcs
