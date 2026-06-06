# shellcheck shell=ash

PODKOP_UI_STATE_DIR="${PODKOP_UI_STATE_DIR:-/var/run/podkop-plus/ui-state}"
PODKOP_UI_SERVICE_ACTION_DIR="${PODKOP_UI_SERVICE_ACTION_DIR:-$PODKOP_UI_STATE_DIR/service-actions}"
PODKOP_UI_LATENCY_ACTION_DIR="${PODKOP_UI_LATENCY_ACTION_DIR:-$PODKOP_UI_STATE_DIR/latency-actions}"
PODKOP_UI_SING_BOX_VERSION_CACHE_FILE="${PODKOP_UI_SING_BOX_VERSION_CACHE_FILE:-$PODKOP_UI_STATE_DIR/sing-box-version}"
PODKOP_UI_ACTION_FINISHED_TTL_MINUTES="${PODKOP_UI_ACTION_FINISHED_TTL_MINUTES:-60}"
PODKOP_UI_ACTION_STALE_GRACE_SECONDS="${PODKOP_UI_ACTION_STALE_GRACE_SECONDS:-5}"
PODKOP_UI_SERVICE_ACTION_TIMEOUT_SECONDS="${PODKOP_UI_SERVICE_ACTION_TIMEOUT_SECONDS:-120}"
PODKOP_UI_SERVICE_ACTION_SETTLE_SECONDS="${PODKOP_UI_SERVICE_ACTION_SETTLE_SECONDS:-2}"
PODKOP_UI_COMPONENT_ACTION_DIR="${UPDATES_JOB_DIR:-/var/run/podkop-plus/component-actions}"
PODKOP_UI_SUBSCRIPTION_ACTION_DIR="${PODKOP_SUBSCRIPTION_UPDATE_JOB_DIR:-/var/run/podkop-plus/subscription-update-jobs}"

ui_runtime_ucode() {
    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/ui_runtime.uc" "$@"
}

ui_runtime_now() {
    local now

    now="$(date +%s 2>/dev/null)"
    case "$now" in
    "" | *[!0-9]*) now=0 ;;
    esac
    printf '%s\n' "$now"
}

ui_runtime_ensure_dirs() {
    mkdir -p \
        "$PODKOP_UI_STATE_DIR" \
        "$PODKOP_UI_SERVICE_ACTION_DIR" \
        "$PODKOP_UI_LATENCY_ACTION_DIR" \
        "$PODKOP_UI_COMPONENT_ACTION_DIR" \
        "$PODKOP_UI_SUBSCRIPTION_ACTION_DIR"
}

ui_runtime_job_id() {
    printf '%s-%s\n' "$(ui_runtime_now)" "$$"
}

ui_runtime_job_id_is_safe() {
    case "$1" in
    *[!A-Za-z0-9._-]* | "" | "." | "..")
        return 1
        ;;
    esac
}

ui_runtime_job_state_path() {
    local dir="$1"
    local job_id="$2"

    ui_runtime_job_id_is_safe "$job_id" || return 1
    printf '%s/%s.json\n' "$dir" "$job_id"
}

ui_runtime_tmp_file() {
    local target_file="$1"
    local tmp_file

    tmp_file="$(mktemp "${target_file}.XXXXXX" 2>/dev/null || true)"
    if [ -z "$tmp_file" ]; then
        tmp_file="${target_file}.$$.$(ui_runtime_now).tmp"
        : >"$tmp_file" || return 1
    fi

    printf '%s\n' "$tmp_file"
}

ui_runtime_write_state() {
    local state_file="$1"
    local tmp_file
    shift

    tmp_file="$(ui_runtime_tmp_file "$state_file")" || return 1
    "$@" >"$tmp_file" && mv "$tmp_file" "$state_file"

    local rc=$?
    rm -f "$tmp_file" 2>/dev/null
    return "$rc"
}

ui_runtime_json_field() {
    local state_file="$1"
    local key="$2"
    local fallback="${3:-}"

    ui_runtime_ucode json-file-field "$state_file" "$key" "$fallback" 2>/dev/null
}

ui_runtime_write_finished_state() {
    local state_file="$1"
    local success="$2"
    local message="$3"
    local exit_code="${4:-}"
    local updated_at

    updated_at="$(ui_runtime_now)"
    ui_runtime_write_state "$state_file" \
        ui_runtime_ucode finished-action-state "$state_file" "$success" "$message" "$exit_code" "$updated_at"
}

ui_runtime_mark_stale_state() {
    local state_file="$1"
    local message="$2"
    local updated_at

    updated_at="$(ui_runtime_now)"
    ui_runtime_write_state "$state_file" \
        ui_runtime_ucode stale-action-state "$state_file" "$message" "$updated_at"
}

ui_runtime_update_running_pid() {
    local state_file="$1"
    local pid="$2"

    case "$pid" in
    "" | *[!0-9]*) return 1 ;;
    esac

    ui_runtime_write_state "$state_file" ui_runtime_ucode set-running-job-pid "$state_file" "$pid"
}

ui_runtime_started_at_is_younger_than() {
    local started_at="$1"
    local max_age="$2"
    local now

    case "$started_at" in
    "" | *[!0-9]*) return 1 ;;
    esac
    [ "$started_at" -gt 0 ] || return 1

    now="$(ui_runtime_now)"
    [ "$now" -gt 0 ] || return 1
    [ $((now - started_at)) -lt "$max_age" ]
}

ui_runtime_refresh_pid_job_state() {
    local state_file="$1"
    local stale_message="$2"
    local pid started_at

    [ "$(ui_runtime_json_field "$state_file" running false)" = "true" ] || return 0

    pid="$(ui_runtime_json_field "$state_file" pid "")"
    started_at="$(ui_runtime_json_field "$state_file" started_at 0)"

    case "$pid" in
    "" | *[!0-9]*)
        ui_runtime_mark_stale_state "$state_file" "$stale_message"
        return 0
        ;;
    esac

    kill -0 "$pid" 2>/dev/null && return 0
    ui_runtime_started_at_is_younger_than "$started_at" "$PODKOP_UI_ACTION_STALE_GRACE_SECONDS" && return 0
    [ "$(ui_runtime_json_field "$state_file" running false)" = "true" ] || return 0
    ui_runtime_mark_stale_state "$state_file" "$stale_message"
}

ui_runtime_service_action_reached_expected_state() {
    case "$1" in
    start | restart | reload)
        ui_runtime_podkop_running
        ;;
    stop)
        ! ui_runtime_podkop_running
        ;;
    *)
        return 1
        ;;
    esac
}

ui_runtime_service_action_wait_for_expected_state() {
    local action="$1"
    local timeout="${2:-$PODKOP_UI_SERVICE_ACTION_TIMEOUT_SECONDS}"
    local settle_seconds="${3:-$PODKOP_UI_SERVICE_ACTION_SETTLE_SECONDS}"
    local now deadline stable_seconds

    now="$(ui_runtime_now)"
    deadline=$((now + timeout))
    stable_seconds=0

    while :; do
        if ui_runtime_service_action_reached_expected_state "$action"; then
            stable_seconds=$((stable_seconds + 1))
            [ "$stable_seconds" -ge "$settle_seconds" ] && return 0
        else
            stable_seconds=0
        fi

        now="$(ui_runtime_now)"
        [ "$now" -ge "$deadline" ] && return 1
        sleep 1
    done
}

ui_runtime_refresh_service_state_file() {
    local state_file="$1"

    ui_runtime_refresh_pid_job_state "$state_file" "Service action worker exited unexpectedly"
}

ui_runtime_refresh_latency_state_file() {
    ui_runtime_refresh_pid_job_state "$1" "Latency test worker exited unexpectedly"
}

ui_runtime_cleanup_dir() {
    local dir="$1"
    local state_file

    [ -d "$dir" ] || return 0
    find "$dir" -type f -name '*.json' -mmin "+$PODKOP_UI_ACTION_FINISHED_TTL_MINUTES" 2>/dev/null |
        while IFS= read -r state_file; do
            [ -f "$state_file" ] || continue
            if [ "$(ui_runtime_json_field "$state_file" running false)" = "false" ]; then
                rm -f "$state_file" 2>/dev/null || true
            fi
        done
}

ui_runtime_refresh_action_dirs() {
    local state_file

    ui_runtime_cleanup_dir "$PODKOP_UI_SERVICE_ACTION_DIR"
    ui_runtime_cleanup_dir "$PODKOP_UI_LATENCY_ACTION_DIR"

    if [ -d "$PODKOP_UI_SERVICE_ACTION_DIR" ]; then
        for state_file in "$PODKOP_UI_SERVICE_ACTION_DIR"/*.json; do
            [ -f "$state_file" ] || continue
            ui_runtime_refresh_service_state_file "$state_file"
        done
    fi

    if [ -d "$PODKOP_UI_LATENCY_ACTION_DIR" ]; then
        for state_file in "$PODKOP_UI_LATENCY_ACTION_DIR"/*.json; do
            [ -f "$state_file" ] || continue
            ui_runtime_refresh_latency_state_file "$state_file"
        done
    fi
}

ui_runtime_state_paths() {
    local state_file

    for state_file in "$PODKOP_UI_SERVICE_ACTION_DIR"/*.json; do
        [ -f "$state_file" ] && printf 'service\t%s\n' "$state_file"
    done

    for state_file in "$PODKOP_UI_LATENCY_ACTION_DIR"/*.json; do
        [ -f "$state_file" ] && printf 'latency\t%s\n' "$state_file"
    done

    for state_file in "$PODKOP_UI_COMPONENT_ACTION_DIR"/*.json; do
        [ -f "$state_file" ] && printf 'component\t%s\n' "$state_file"
    done

    for state_file in "$PODKOP_UI_SUBSCRIPTION_ACTION_DIR"/*.json; do
        [ -f "$state_file" ] && printf 'subscription\t%s\n' "$state_file"
    done
}

ui_runtime_service_enabled() {
    [ -x "/etc/rc.d/S99${PODKOP_SERVICE_NAME:-podkop-plus}" ]
}

ui_runtime_sing_box_enabled() {
    [ -x /etc/rc.d/S99sing-box ]
}

ui_runtime_sing_box_running() {
    local service_json='{"name":"sing-box"}'

    if ubus call service list "$service_json" 2>/dev/null |
        ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/status_diagnostics.uc" service-list-instance-running sing-box >/dev/null 2>&1; then
        return 0
    fi

    pgrep -x "sing-box" >/dev/null 2>&1 ||
        pgrep -f "^/usr/bin/sing-box[[:space:]]" >/dev/null 2>&1
}

ui_runtime_network_configured() {
    nft list table inet "$NFT_TABLE_NAME" >/dev/null 2>&1 || return 1
    ip rule show 2>/dev/null | grep -q "lookup ${RT_TABLE_NAME:-podkopplus}" || return 1
    ip route show table "${RT_TABLE_NAME:-podkopplus}" 2>/dev/null | grep -q .
}

ui_runtime_podkop_running() {
    ui_runtime_sing_box_running && ui_runtime_network_configured
}

ui_runtime_dns_configured() {
    uci -q get 'dhcp.@dnsmasq[0].server' 2>/dev/null | grep -q "${SB_DNS_INBOUND_ADDRESS:-127.0.0.42}"
}

ui_runtime_sing_box_signature() {
    set -- $(ls -ln /usr/bin/sing-box 2>/dev/null) || return 1
    [ -n "${5:-}" ] || return 1
    printf '%s:%s:%s:%s\n' "${5:-}" "${6:-}" "${7:-}" "${8:-}"
}

ui_runtime_sing_box_version() {
    local signature cache_signature cache_version version_line version

    command -v sing-box >/dev/null 2>&1 || return 1

    signature="$(ui_runtime_sing_box_signature 2>/dev/null || true)"
    if [ -n "$signature" ] && [ -r "$PODKOP_UI_SING_BOX_VERSION_CACHE_FILE" ]; then
        cache_signature="$(sed -n '1p' "$PODKOP_UI_SING_BOX_VERSION_CACHE_FILE" 2>/dev/null)"
        cache_version="$(sed -n '2p' "$PODKOP_UI_SING_BOX_VERSION_CACHE_FILE" 2>/dev/null)"
        if [ "$cache_signature" = "$signature" ] && [ -n "$cache_version" ]; then
            printf '%s\n' "$cache_version"
            return 0
        fi
    fi

    version_line="$(sing-box version 2>/dev/null | sed -n '1p')"
    version="${version_line##* }"
    [ -n "$version" ] || return 1

    if [ -n "$signature" ]; then
        mkdir -p "$PODKOP_UI_STATE_DIR" 2>/dev/null || true
        {
            printf '%s\n' "$signature"
            printf '%s\n' "$version"
        } >"$PODKOP_UI_SING_BOX_VERSION_CACHE_FILE" 2>/dev/null || true
    fi

    printf '%s\n' "$version"
}

ui_runtime_status_text() {
    local running="$1"
    local enabled="$2"

    if [ "$running" -eq 1 ]; then
        [ "$enabled" -eq 1 ] && printf '%s\n' "running & enabled" || printf '%s\n' "running but disabled"
        return 0
    fi

    [ "$enabled" -eq 1 ] && printf '%s\n' "stopped but enabled" || printf '%s\n' "stopped & disabled"
}

ui_runtime_active_service_action() {
    local state_file action

    for state_file in "$PODKOP_UI_SERVICE_ACTION_DIR"/*.json; do
        [ -f "$state_file" ] || continue
        [ "$(ui_runtime_json_field "$state_file" running false)" = "true" ] || continue
        action="$(ui_runtime_json_field "$state_file" action "")"
        [ -n "$action" ] && {
            printf '%s\n' "$action"
            return 0
        }
    done

    return 1
}

ui_runtime_write_ui_state() {
    local podkop_running="$1"
    local podkop_enabled="$2"
    local podkop_status="$3"
    local dns_configured="$4"
    local sing_box_running="$5"
    local sing_box_enabled="$6"
    local sing_box_status="$7"
    local sing_box_extended="$8"
    local zapret_installed="$9"
    local zapret2_installed="${10}"
    local byedpi_installed="${11}"
    local server_inbounds_enabled_count="${12}"

    ui_runtime_state_paths | ui_runtime_ucode ui-state-json \
        "$podkop_running" \
        "$podkop_enabled" \
        "$podkop_status" \
        "$dns_configured" \
        "$sing_box_running" \
        "$sing_box_enabled" \
        "$sing_box_status" \
        "$sing_box_extended" \
        "$zapret_installed" \
        "$zapret2_installed" \
        "$byedpi_installed" \
        "$server_inbounds_enabled_count"
}

ui_runtime_service_action_valid() {
    case "$1" in
    start | stop | restart | reload)
        return 0
        ;;
    esac
    return 1
}

ui_runtime_service_action_begin() {
    local action="$1"
    local source="${2:-ui}"
    local job_id state_file

    ui_runtime_service_action_valid "$action" || return 1
    ui_runtime_ensure_dirs || return 1

    job_id="$(ui_runtime_job_id)"
    state_file="$(ui_runtime_job_state_path "$PODKOP_UI_SERVICE_ACTION_DIR" "$job_id")" || return 1

    ui_runtime_write_state "$state_file" \
        ui_runtime_ucode running-service-action "$action" "$source" "$(ui_runtime_now)" || return 1

    printf '%s\n' "$job_id"
}

ui_runtime_service_action_finish_job() {
    local job_id="$1"
    local success="${2:-true}"
    local message="${3:-Service action completed}"
    local exit_code="${4:-0}"
    local state_file

    state_file="$(ui_runtime_job_state_path "$PODKOP_UI_SERVICE_ACTION_DIR" "$job_id")" || return 1
    [ -f "$state_file" ] || return 1

    ui_runtime_write_finished_state "$state_file" "$success" "$message" "$exit_code"
}

ui_runtime_service_action_async() {
    local action="$1"
    local job_id state_file job_pid

    ui_runtime_service_action_valid "$action" || {
        ui_runtime_ucode action-start-response false "" "Invalid service action"
        exit 1
    }

    job_id="$(ui_runtime_service_action_begin "$action" "ui")" || {
        ui_runtime_ucode action-start-response false "" "Failed to write service action state"
        exit 1
    }
    state_file="$(ui_runtime_job_state_path "$PODKOP_UI_SERVICE_ACTION_DIR" "$job_id")" || {
        ui_runtime_ucode action-start-response false "" "Failed to prepare service action state"
        exit 1
    }

    (
        trap '' HUP
        PODKOP_UI_ACTION_TRACKED=1 /etc/init.d/podkop-plus "$action" >/dev/null 2>&1
        rc="$?"
        if [ "$rc" -ne 0 ]; then
            ui_runtime_write_finished_state "$state_file" false "Service $action failed" "$rc"
        elif ui_runtime_service_action_wait_for_expected_state "$action"; then
            ui_runtime_write_finished_state "$state_file" true "Service $action completed" "$rc"
        else
            ui_runtime_write_finished_state "$state_file" false "Service $action did not reach expected state" 1
        fi
    ) >/dev/null 2>&1 &
    job_pid="$!"

    ui_runtime_update_running_pid "$state_file" "$job_pid" || {
        kill "$job_pid" 2>/dev/null || true
        ui_runtime_ucode action-start-response false "" "Failed to write service action worker pid"
        exit 1
    }

    ui_runtime_ucode action-start-response true "$job_id" "Service $action started"
}

ui_runtime_service_action_status() {
    local job_id="$1"
    local state_file

    state_file="$(ui_runtime_job_state_path "$PODKOP_UI_SERVICE_ACTION_DIR" "$job_id")" || {
        ui_runtime_ucode action-start-response false "" "Invalid service action job id"
        exit 1
    }

    [ -f "$state_file" ] || {
        ui_runtime_ucode action-start-response false "" "Service action job was not found"
        exit 1
    }

    ui_runtime_refresh_service_state_file "$state_file"
    cat "$state_file"
}

ui_runtime_latency_type_valid() {
    case "$1" in
    group | proxy)
        return 0
        ;;
    esac
    return 1
}

ui_runtime_latency_test_async() {
    local latency_type="$1"
    local section="$2"
    local tag="$3"
    local job_id state_file job_pid clash_method timeout

    ui_runtime_latency_type_valid "$latency_type" || {
        ui_runtime_ucode action-start-response false "" "Invalid latency test type"
        exit 1
    }

    [ -n "$tag" ] || {
        ui_runtime_ucode action-start-response false "" "Latency test tag is required"
        exit 1
    }

    ui_runtime_ensure_dirs || {
        ui_runtime_ucode action-start-response false "" "Failed to create UI action state directory"
        exit 1
    }

    job_id="$(ui_runtime_job_id)"
    state_file="$(ui_runtime_job_state_path "$PODKOP_UI_LATENCY_ACTION_DIR" "$job_id")" || {
        ui_runtime_ucode action-start-response false "" "Failed to prepare latency test state"
        exit 1
    }

    ui_runtime_write_state "$state_file" \
        ui_runtime_ucode running-latency-action "$latency_type" "$section" "$tag" "$(ui_runtime_now)" || {
        ui_runtime_ucode action-start-response false "" "Failed to write latency test state"
        exit 1
    }

    if [ "$latency_type" = "group" ]; then
        clash_method="get_group_latency"
        timeout="10000"
    else
        clash_method="get_proxy_latency"
        timeout="5000"
    fi

    (
        trap '' HUP
        /usr/bin/podkop-plus clash_api "$clash_method" "$tag" "$timeout" >/dev/null 2>&1
        rc="$?"
        if [ "$rc" -eq 0 ]; then
            ui_runtime_write_finished_state "$state_file" true "Latency test completed" "$rc"
        else
            ui_runtime_write_finished_state "$state_file" false "Latency test failed" "$rc"
        fi
    ) >/dev/null 2>&1 &
    job_pid="$!"

    ui_runtime_update_running_pid "$state_file" "$job_pid" || {
        kill "$job_pid" 2>/dev/null || true
        ui_runtime_ucode action-start-response false "" "Failed to write latency test worker pid"
        exit 1
    }

    ui_runtime_ucode action-start-response true "$job_id" "Latency test started"
}

ui_runtime_latency_test_status() {
    local job_id="$1"
    local state_file

    state_file="$(ui_runtime_job_state_path "$PODKOP_UI_LATENCY_ACTION_DIR" "$job_id")" || {
        ui_runtime_ucode action-start-response false "" "Invalid latency test job id"
        exit 1
    }

    [ -f "$state_file" ] || {
        ui_runtime_ucode action-start-response false "" "Latency test job was not found"
        exit 1
    }

    ui_runtime_refresh_latency_state_file "$state_file"
    cat "$state_file"
}

ui_runtime_action_ack() {
    local kind="$1"
    local job_id="$2"
    local dir state_file

    case "$kind" in
    service) dir="$PODKOP_UI_SERVICE_ACTION_DIR" ;;
    latency) dir="$PODKOP_UI_LATENCY_ACTION_DIR" ;;
    component) dir="$PODKOP_UI_COMPONENT_ACTION_DIR" ;;
    subscription) dir="$PODKOP_UI_SUBSCRIPTION_ACTION_DIR" ;;
    *)
        ui_runtime_ucode action-start-response false "" "Invalid UI action kind"
        exit 1
        ;;
    esac

    state_file="$(ui_runtime_job_state_path "$dir" "$job_id")" || {
        ui_runtime_ucode action-start-response false "" "Invalid UI action job id"
        exit 1
    }

    rm -f "$state_file" "${state_file%.json}.out" "${state_file%.json}.out.json" 2>/dev/null || true
    ui_runtime_ucode action-start-response true "$job_id" "UI action acknowledged"
}
