# shellcheck shell=ash

UPDATES_TMP_DIR=""
UPDATES_TARGET_ARCH=""
UPDATES_ARCH_CANDIDATES=""
UPDATES_ZAPRET_ARCH=""
UPDATES_ZAPRET_BUNDLE_URL=""
UPDATES_ZAPRET_BUNDLE_NAME=""
UPDATES_ZAPRET_PACKAGE_FILE=""
UPDATES_ZAPRET_PACKAGE_NAME=""
UPDATES_ZAPRET_PACKAGE_VERSION=""
UPDATES_ZAPRET_RELEASE_URL=""
UPDATES_ZAPRET2_ARCH=""
UPDATES_ZAPRET2_BUNDLE_URL=""
UPDATES_ZAPRET2_BUNDLE_NAME=""
UPDATES_ZAPRET2_PACKAGE_FILE=""
UPDATES_ZAPRET2_PACKAGE_NAME=""
UPDATES_ZAPRET2_PACKAGE_VERSION=""
UPDATES_ZAPRET2_RELEASE_URL=""
UPDATES_BYEDPI_ARCH=""
UPDATES_BYEDPI_PACKAGE_URL=""
UPDATES_BYEDPI_PACKAGE_NAME=""
UPDATES_BYEDPI_PACKAGE_FILE=""
UPDATES_BYEDPI_PACKAGE_VERSION=""
UPDATES_BYEDPI_RELEASE_URL=""
UPDATES_PODKOP_BACKEND_URL=""
UPDATES_PODKOP_RELEASE_URL=""
UPDATES_PODKOP_BACKEND_NAME=""
UPDATES_PODKOP_BACKEND_FILE=""
UPDATES_PODKOP_APP_URL=""
UPDATES_PODKOP_APP_NAME=""
UPDATES_PODKOP_APP_FILE=""
UPDATES_PODKOP_I18N_URL=""
UPDATES_PODKOP_I18N_NAME=""
UPDATES_PODKOP_I18N_FILE=""
UPDATES_SING_BOX_EXTENDED_RELEASE_TAG=""
UPDATES_SING_BOX_EXTENDED_RELEASE_URL=""
UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX=""
UPDATES_SING_BOX_EXTENDED_ASSET_URL=""
UPDATES_SING_BOX_EXTENDED_ASSET_NAME=""
UPDATES_JOB_DIR="/var/run/podkop-plus/component-actions"
UPDATES_JOB_FINISHED_TTL_MINUTES=60
UPDATES_JOB_ORPHAN_OUTPUT_TTL_MINUTES=60
UPDATES_JOB_STALE_GRACE_SECONDS=15
UPDATES_TMP_STALE_TTL_MINUTES=30
UPDATES_TMP_FILE_STALE_TTL_MINUTES=10
UPDATES_LOCK_DIR="/var/run/podkop-plus/component-action.lock"
UPDATES_LOCK_HELD=0
UPDATES_DIRECT_JOB_ID=""
UPDATES_DIRECT_JOB_STATE_FILE=""
UPDATES_PODKOP_WAS_RUNNING=0
UPDATES_PODKOP_STOPPED_FOR_SING_BOX_CHANGE=0

updates_log() {
    local message="$1"
    local level="${2:-info}"

    log "Updates: $message" "$level"
}

updates_json_file_get_default() {
    local json_file="$1"
    local key="$2"
    local fallback="$3"

    updates_ucode json-file-field "$json_file" "$key" "$fallback" 2>/dev/null
}

updates_json_file_running_is() {
    local json_file="$1"
    local expected="$2"

    updates_ucode job-running-is "$json_file" "$expected" >/dev/null 2>&1
}

updates_init_tmp_dir() {
    [ -n "$UPDATES_TMP_DIR" ] && return 0

    updates_cleanup_stale_tmp_files

    UPDATES_TMP_DIR="$(mktemp -d /tmp/podkop-plus-updates.XXXXXX 2>/dev/null || true)"
    if [ -z "$UPDATES_TMP_DIR" ]; then
        UPDATES_TMP_DIR="/tmp/podkop-plus-updates.$$"
        mkdir -p "$UPDATES_TMP_DIR" || return 1
    fi
}

updates_cleanup_stale_tmp_files() {
    local tmp_path

    find /tmp -maxdepth 1 -type d -name 'podkop-plus-updates.*' -mmin "+$UPDATES_TMP_STALE_TTL_MINUTES" 2>/dev/null |
        while IFS= read -r tmp_path; do
            [ -n "$tmp_path" ] || continue
            [ "$tmp_path" = "$UPDATES_TMP_DIR" ] && continue
            rm -rf "$tmp_path" 2>/dev/null || true
        done

    find /tmp -maxdepth 1 -type f \( -name 'podkop-plus-updates-command.*' -o -name 'podkop-plus-updates-http.*' \) -mmin "+$UPDATES_TMP_FILE_STALE_TTL_MINUTES" -delete 2>/dev/null || true
}

updates_cleanup() {
    if [ -n "$UPDATES_TMP_DIR" ]; then
        rm -rf "$UPDATES_TMP_DIR"
        UPDATES_TMP_DIR=""
    fi
    updates_cleanup_stale_tmp_files
}

updates_acquire_component_lock() {
    local owner_pid

    mkdir -p /var/run/podkop-plus || return 1

    if mkdir "$UPDATES_LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" >"$UPDATES_LOCK_DIR/pid"
        UPDATES_LOCK_HELD=1
        return 0
    fi

    owner_pid="$(updates_ucode file-first-line "$UPDATES_LOCK_DIR/pid" 2>/dev/null)"
    if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
        return 1
    fi

    rm -f "$UPDATES_LOCK_DIR/pid" 2>/dev/null
    rmdir "$UPDATES_LOCK_DIR" 2>/dev/null || return 1

    mkdir "$UPDATES_LOCK_DIR" 2>/dev/null || return 1
    printf '%s\n' "$$" >"$UPDATES_LOCK_DIR/pid"
    UPDATES_LOCK_HELD=1
}

updates_release_component_lock() {
    [ "$UPDATES_LOCK_HELD" -eq 1 ] || return 0

    rm -f "$UPDATES_LOCK_DIR/pid" 2>/dev/null
    rmdir "$UPDATES_LOCK_DIR" 2>/dev/null
    UPDATES_LOCK_HELD=0
}

updates_component_action_cleanup() {
    updates_cleanup
    updates_release_component_lock
}

updates_json_response() {
    local success="$1"
    local component="$2"
    local action="$3"
    local message="$4"
    local current_version="${5:-}"
    local latest_version="${6:-}"
    local changed="${7:-0}"
    local status="${8:-}"
    local release_url="${9:-}"
    local response_file tmp_file updated_at exit_code

    if [ -n "$UPDATES_DIRECT_JOB_STATE_FILE" ]; then
        response_file="$(updates_job_tmp_file "${UPDATES_DIRECT_JOB_STATE_FILE}.response" 2>/dev/null || true)"
        if [ -n "$response_file" ] &&
            updates_ucode updates-json-response \
                "$success" \
                "$component" \
                "$action" \
                "$message" \
                "$current_version" \
                "$latest_version" \
                "$changed" \
                "$status" \
                "$release_url" >"$response_file"; then
            cat "$response_file"

            updated_at="$(date +%s 2>/dev/null)"
            case "$updated_at" in
            "" | *[!0-9]*) updated_at=0 ;;
            esac
            case "$success" in
            true | 1) exit_code=0 ;;
            *) exit_code=1 ;;
            esac

            tmp_file="$(updates_job_tmp_file "$UPDATES_DIRECT_JOB_STATE_FILE" 2>/dev/null || true)"
            if [ -n "$tmp_file" ]; then
                updates_ucode updates-finish-job-state "$response_file" "$exit_code" "$updated_at" >"$tmp_file" &&
                    mv "$tmp_file" "$UPDATES_DIRECT_JOB_STATE_FILE"
                rm -f "$tmp_file" 2>/dev/null
            fi

            rm -f "$response_file" 2>/dev/null
            return 0
        fi

        rm -f "$response_file" 2>/dev/null
    fi

    updates_ucode updates-json-response \
        "$success" \
        "$component" \
        "$action" \
        "$message" \
        "$current_version" \
        "$latest_version" \
        "$changed" \
        "$status" \
        "$release_url"
}

updates_success() {
    updates_json_response true "$@"
    updates_component_action_cleanup
    exit 0
}

updates_restart_podkop_after_failed_sing_box_change() {
    [ "$UPDATES_PODKOP_STOPPED_FOR_SING_BOX_CHANGE" -eq 1 ] || return 0
    [ "$UPDATES_PODKOP_WAS_RUNNING" = "1" ] || return 0
    [ -x "$PODKOP_SERVICE_INIT" ] || return 0

    updates_log "Restarting Podkop Plus after failed sing-box component change"
    "$PODKOP_SERVICE_INIT" start >/dev/null 2>&1 ||
        "$PODKOP_SERVICE_INIT" restart >/dev/null 2>&1 ||
        true
}

updates_fail() {
    local component="$1"
    local action="$2"
    local message="$3"
    local current_version="${4:-}"
    local latest_version="${5:-}"
    local status="${6:-}"
    local release_url="${7:-}"

    updates_log "$message" "error"
    updates_restart_podkop_after_failed_sing_box_change
    updates_json_response false "$component" "$action" "$message" "$current_version" "$latest_version" 0 "$status" "$release_url"
    updates_component_action_cleanup
    exit 1
}

updates_job_json_response() {
    local success="$1"
    local job_id="$2"
    local message="${3:-}"

    updates_ucode updates-job-json-response "$success" "$job_id" "$message"
}

updates_job_state_path() {
    local job_id="$1"

    case "$job_id" in
    *[!A-Za-z0-9._-]* | "" | "." | "..")
        return 1
        ;;
    esac

    printf '%s/%s.json\n' "$UPDATES_JOB_DIR" "$job_id"
}

updates_job_tmp_file() {
    local target_file="$1"
    local tmp_file

    tmp_file="$(mktemp "${target_file}.XXXXXX" 2>/dev/null || true)"
    if [ -z "$tmp_file" ]; then
        tmp_file="${target_file}.$$.$(date +%s 2>/dev/null).tmp"
        : >"$tmp_file" || return 1
    fi

    printf '%s\n' "$tmp_file"
}

updates_cleanup_component_jobs() {
    local output_file state_file

    [ -d "$UPDATES_JOB_DIR" ] || return 0

    find "$UPDATES_JOB_DIR" -type f -name '*.out' 2>/dev/null |
        while IFS= read -r output_file; do
            [ -f "$output_file" ] || continue
            state_file="${output_file%.out}.json"

            if [ -f "$state_file" ]; then
                updates_refresh_running_job_state "$state_file"
                if ! updates_json_file_running_is "$state_file" true; then
                    rm -f "$output_file" "$output_file.json" 2>/dev/null || true
                fi
            fi
        done

    find "$UPDATES_JOB_DIR" -type f -name '*.out' -mmin "+$UPDATES_JOB_ORPHAN_OUTPUT_TTL_MINUTES" 2>/dev/null |
        while IFS= read -r output_file; do
            [ -f "$output_file" ] || continue
            state_file="${output_file%.out}.json"

            if [ -f "$state_file" ]; then
                updates_refresh_running_job_state "$state_file"
                if updates_json_file_running_is "$state_file" true; then
                    continue
                fi
            fi

            rm -f "$output_file" "$output_file.json" 2>/dev/null || true
        done

    find "$UPDATES_JOB_DIR" -type f -name '*.out.json' -mmin "+$UPDATES_JOB_ORPHAN_OUTPUT_TTL_MINUTES" -delete 2>/dev/null || true
    find "$UPDATES_JOB_DIR" -type f -name '*.json.*' -mmin "+$UPDATES_TMP_FILE_STALE_TTL_MINUTES" -delete 2>/dev/null || true

    find "$UPDATES_JOB_DIR" -type f -name '*.json' -mmin "+$UPDATES_JOB_FINISHED_TTL_MINUTES" 2>/dev/null |
        while IFS= read -r state_file; do
            [ -f "$state_file" ] || continue
            if updates_json_file_running_is "$state_file" false; then
                rm -f "$state_file" 2>/dev/null || true
            fi
        done
}

updates_write_running_job_state() {
    local state_file="$1"
    local component="$2"
    local action="$3"
    local pid="${4:-}"
    local tmp_file started_at

    started_at="$(date +%s 2>/dev/null)"
    case "$started_at" in
    "" | *[!0-9]*) started_at=0 ;;
    esac

    mkdir -p "$UPDATES_JOB_DIR" || return 1
    tmp_file="$(updates_job_tmp_file "$state_file")" || return 1

    updates_ucode updates-running-job-state "$component" "$action" "$pid" "$started_at" >"$tmp_file" && mv "$tmp_file" "$state_file"

    local rc=$?
    rm -f "$tmp_file" 2>/dev/null
    return $rc
}

updates_update_running_job_pid() {
    local state_file="$1"
    local pid="$2"
    local tmp_file

    case "$pid" in
    "" | *[!0-9]*) return 1 ;;
    esac

    tmp_file="$(updates_job_tmp_file "$state_file")" || return 1
    updates_ucode updates-set-running-job-pid "$state_file" "$pid" >"$tmp_file" && mv "$tmp_file" "$state_file"

    local rc=$?
    rm -f "$tmp_file" 2>/dev/null
    return $rc
}

updates_begin_direct_component_job_state() {
    local component="$1"
    local action="$2"
    local state_file

    [ "${PODKOP_UI_COMPONENT_ACTION_TRACKED:-0}" = "1" ] && return 0

    mkdir -p "$UPDATES_JOB_DIR" || return 0
    updates_cleanup_component_jobs

    UPDATES_DIRECT_JOB_ID="$(date +%s 2>/dev/null)-$$"
    state_file="$(updates_job_state_path "$UPDATES_DIRECT_JOB_ID" 2>/dev/null || true)"
    [ -n "$state_file" ] || return 0

    updates_write_running_job_state "$state_file" "$component" "$action" "$$" || return 0
    UPDATES_DIRECT_JOB_STATE_FILE="$state_file"
}

updates_mark_stale_job_state() {
    local state_file="$1"
    local tmp_file

    tmp_file="$(updates_job_tmp_file "$state_file")" || return 1
    updates_ucode updates-mark-stale-job-state "$state_file" >"$tmp_file" && mv "$tmp_file" "$state_file"

    local rc=$?
    rm -f "$tmp_file" 2>/dev/null
    return $rc
}

updates_started_at_is_within_stale_grace() {
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
    [ "$age" -lt "$UPDATES_JOB_STALE_GRACE_SECONDS" ]
}

updates_refresh_running_job_state() {
    local state_file="$1"
    local pid started_at

    updates_json_file_running_is "$state_file" true || return 0

    pid="$(updates_json_file_get_default "$state_file" pid "")"
    started_at="$(updates_json_file_get_default "$state_file" started_at 0)"
    case "$pid" in
    "" | *[!0-9]*)
        updates_started_at_is_within_stale_grace "$started_at" && return 0
        updates_json_file_running_is "$state_file" true || return 0
        updates_mark_stale_job_state "$state_file"
        return 0
        ;;
    esac

    if kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    updates_started_at_is_within_stale_grace "$started_at" && return 0
    updates_json_file_running_is "$state_file" true || return 0

    updates_mark_stale_job_state "$state_file"
}

updates_write_finished_job_state() {
    local state_file="$1"
    local component="$2"
    local action="$3"
    local exit_code="$4"
    local output_file="$5"
    local tmp_file json_file raw_output updated_at

    tmp_file="$(updates_job_tmp_file "$state_file")" || return 1
    json_file="$output_file.json"
    updated_at="$(date +%s 2>/dev/null)"
    case "$updated_at" in
    "" | *[!0-9]*) updated_at=0 ;;
    esac

    if updates_ucode file-json-valid "$output_file" >/dev/null 2>&1; then
        updates_ucode updates-finish-job-state "$output_file" "$exit_code" "$updated_at" >"$tmp_file" && mv "$tmp_file" "$state_file"
        rm -f "$tmp_file" "$output_file"
        return 0
    fi

    updates_ucode file-tail-json-object "$output_file" >"$json_file"
    if [ -s "$json_file" ] && updates_ucode file-json-valid "$json_file" >/dev/null 2>&1; then
        updates_ucode updates-finish-job-state "$json_file" "$exit_code" "$updated_at" >"$tmp_file" && mv "$tmp_file" "$state_file"
        rm -f "$tmp_file" "$json_file" "$output_file"
        return 0
    fi
    rm -f "$json_file"

    raw_output="$(updates_ucode file-flat-snippet "$output_file" 240 2>/dev/null)"
    [ -n "$raw_output" ] || raw_output="Failed to execute"

    updates_ucode updates-fallback-job-state "$component" "$action" "$raw_output" "$exit_code" "$updated_at" >"$tmp_file" && mv "$tmp_file" "$state_file"

    rm -f "$tmp_file" "$output_file"
}

component_action_async() {
    local component="$1"
    local action="$2"
    local job_id state_file output_file job_pid

    mkdir -p "$UPDATES_JOB_DIR" || {
        updates_job_json_response false "" "Failed to create component action state directory"
        exit 1
    }

    updates_cleanup_component_jobs
    job_id="$(date +%s 2>/dev/null)-$$"
    state_file="$(updates_job_state_path "$job_id")" || {
        updates_job_json_response false "" "Failed to prepare component action job"
        exit 1
    }
    output_file="$UPDATES_JOB_DIR/$job_id.out"

    updates_write_running_job_state "$state_file" "$component" "$action" || {
        updates_job_json_response false "" "Failed to write component action state"
        exit 1
    }

    (
        trap '' HUP
        PODKOP_UI_COMPONENT_ACTION_TRACKED=1 /usr/bin/podkop-plus component_action "$component" "$action" >"$output_file" 2>&1
        updates_write_finished_job_state "$state_file" "$component" "$action" "$?" "$output_file"
    ) >/dev/null 2>&1 &
    job_pid="$!"

    updates_update_running_job_pid "$state_file" "$job_pid" || {
        kill "$job_pid" 2>/dev/null || true
        updates_job_json_response false "" "Failed to write component action worker pid"
        exit 1
    }

    updates_job_json_response true "$job_id" "Component action started"
}

component_action_status() {
    local job_id="$1"
    local state_file

    mkdir -p "$UPDATES_JOB_DIR" 2>/dev/null || true
    updates_cleanup_component_jobs

    state_file="$(updates_job_state_path "$job_id")" || {
        updates_json_response false "unknown" "status" "Invalid component action job id" "" "" 0 ""
        exit 1
    }

    if [ ! -f "$state_file" ]; then
        updates_json_response false "unknown" "status" "Component action job was not found" "" "" 0 ""
        exit 1
    fi

    updates_refresh_running_job_state "$state_file"

    cat "$state_file"
}

updates_command_exists() {
    command -v "$1" >/dev/null 2>&1
}

updates_is_apk() {
    updates_command_exists apk
}

updates_read_openwrt_release_value() {
    local key="$1"

    [ -f /etc/openwrt_release ] || return 0
    updates_ucode openwrt-release-value /etc/openwrt_release "$key"
}

updates_get_service_proxy_address() {
    local service_proxy_address

    if ! command -v get_service_proxy_address >/dev/null 2>&1; then
        return 0
    fi

    if command -v sing_box_service_is_running >/dev/null 2>&1 && ! sing_box_service_is_running; then
        return 0
    fi

    service_proxy_address="$(get_service_proxy_address 2>/dev/null || true)"
    printf '%s' "$service_proxy_address"
}

updates_http_get_once() {
    local url="$1"
    local output_path="$2"
    local service_proxy_address="${3:-}"

    if updates_command_exists curl; then
        if [ -n "$service_proxy_address" ]; then
            curl --connect-timeout 5 -m 30 -fsSL -x "http://$service_proxy_address" "$url" -o "$output_path"
        else
            curl --connect-timeout 5 -m 30 -fsSL "$url" -o "$output_path"
        fi
        return $?
    fi

    if updates_command_exists wget; then
        if [ -n "$service_proxy_address" ]; then
            http_proxy="http://$service_proxy_address" https_proxy="http://$service_proxy_address" \
                wget -T 30 -q -O "$output_path" "$url"
        else
            wget -T 30 -q -O "$output_path" "$url"
        fi
        return $?
    fi

    return 1
}

updates_http_get() {
    local url="$1"
    local service_proxy_address output_path

    updates_init_tmp_dir >/dev/null 2>&1 || true
    if [ -n "$UPDATES_TMP_DIR" ] && [ -d "$UPDATES_TMP_DIR" ]; then
        output_path="$(mktemp "$UPDATES_TMP_DIR/http.XXXXXX" 2>/dev/null || true)"
    fi
    [ -n "$output_path" ] || output_path="$(mktemp /tmp/podkop-plus-updates-http.XXXXXX 2>/dev/null || true)"
    [ -n "$output_path" ] || return 1

    service_proxy_address="$(updates_get_service_proxy_address)"
    if [ -n "$service_proxy_address" ]; then
        if updates_http_get_once "$url" "$output_path" "$service_proxy_address"; then
            cat "$output_path"
            rm -f "$output_path"
            return 0
        fi

        rm -f "$output_path"
        updates_log "HTTP request via service proxy failed for $url; retrying directly" "warn"
    fi

    if updates_http_get_once "$url" "$output_path" ""; then
        cat "$output_path"
        rm -f "$output_path"
        return 0
    fi

    rm -f "$output_path"
    return 1
}

updates_download_file_once_with_proxy() {
    local url="$1"
    local output_path="$2"
    local service_proxy_address="${3:-}"

    if updates_command_exists curl; then
        if [ -n "$service_proxy_address" ]; then
            curl --connect-timeout 5 -m 120 -fsSL -x "http://$service_proxy_address" "$url" -o "$output_path"
        else
            curl --connect-timeout 5 -m 120 -fsSL "$url" -o "$output_path"
        fi
        return $?
    fi

    if updates_command_exists wget; then
        if [ -n "$service_proxy_address" ]; then
            http_proxy="http://$service_proxy_address" https_proxy="http://$service_proxy_address" \
                wget -T 120 -q -O "$output_path" "$url"
        else
            wget -T 120 -q -O "$output_path" "$url"
        fi
        return $?
    fi

    return 1
}

updates_download_file_once() {
    local url="$1"
    local output_path="$2"
    local service_proxy_address

    service_proxy_address="$(updates_get_service_proxy_address)"
    if [ -n "$service_proxy_address" ]; then
        if updates_download_file_once_with_proxy "$url" "$output_path" "$service_proxy_address"; then
            return 0
        fi

        rm -f "$output_path"
        updates_log "Download via service proxy failed for $url; retrying directly" "warn"
    fi

    updates_download_file_once_with_proxy "$url" "$output_path" ""
}

updates_download_with_retry() {
    local url="$1"
    local output_path="$2"
    local label="$3"
    local attempt=1
    local max_attempts=3

    while [ "$attempt" -le "$max_attempts" ]; do
        updates_log "Downloading $label ($attempt/$max_attempts)"

        if updates_download_file_once "$url" "$output_path" && [ -s "$output_path" ]; then
            return 0
        fi

        rm -f "$output_path"
        updates_log "Retrying $label" "warn"
        attempt=$((attempt + 1))
    done

    return 1
}

updates_log_command() {
    local description="$1"
    local status output_file line
    shift

    updates_init_tmp_dir >/dev/null 2>&1 || true
    if [ -n "$UPDATES_TMP_DIR" ] && [ -d "$UPDATES_TMP_DIR" ]; then
        output_file="$(mktemp "$UPDATES_TMP_DIR/command.XXXXXX" 2>/dev/null || true)"
    fi
    [ -n "$output_file" ] || output_file="$(mktemp /tmp/podkop-plus-updates-command.XXXXXX 2>/dev/null || true)"
    [ -n "$output_file" ] || output_file="/tmp/podkop-plus-updates-command.$$"

    updates_log "$description"
    "$@" >"$output_file" 2>&1
    status=$?

    while IFS= read -r line; do
        [ -n "$line" ] && updates_log "$line"
    done <"$output_file"

    rm -f "$output_file"
    [ "$status" -eq 0 ] || updates_log "$description failed with exit code $status" "warn"
    return "$status"
}

updates_pkg_is_installed() {
    local package_name="$1"

    if updates_is_apk; then
        apk info -e "$package_name" >/dev/null 2>&1
        return $?
    fi

    opkg_package_is_installed "$package_name"
}

updates_get_installed_package_version() {
    local package_name="$1"

    if updates_is_apk; then
        apk info -e "$package_name" >/dev/null 2>&1 || return 0
        get_apk_installed_package_version "$package_name"
        return 0
    fi

    get_opkg_installed_package_version "$package_name"
}

updates_get_available_package_version() {
    local package_name="$1"

    if updates_is_apk; then
        apk policy "$package_name" 2>/dev/null | updates_ucode updates-apk-policy-version
        return 0
    fi

    updates_opkg_package_version_from_list "$package_name" opkg list "$package_name"
}

updates_pkg_list_update() {
    if updates_is_apk; then
        apk update </dev/null
    else
        opkg update </dev/null
    fi
}

updates_pkg_install_name() {
    local package_name="$1"

    if updates_is_apk; then
        apk add "$package_name" </dev/null
    else
        opkg install "$package_name" </dev/null
    fi
}

updates_pkg_install_name_downgrade() {
    local package_name="$1"

    if updates_is_apk; then
        if updates_pkg_is_installed "$package_name"; then
            apk fix --reinstall --upgrade "$package_name" </dev/null
        else
            apk add "$package_name" </dev/null
        fi
    else
        opkg install --force-overwrite --force-reinstall --force-downgrade "$package_name" </dev/null ||
            opkg install --force-downgrade "$package_name" </dev/null
    fi
}

updates_pkg_install_files() {
    if updates_is_apk; then
        apk add --allow-untrusted "$@" </dev/null
    else
        opkg install --force-overwrite --force-downgrade "$@" </dev/null
    fi
}

updates_pkg_remove_name() {
    local package_name="$1"

    if ! updates_pkg_is_installed "$package_name"; then
        return 0
    fi

    if updates_is_apk; then
        apk del "$package_name" </dev/null
    else
        opkg remove --force-depends "$package_name" </dev/null
    fi
}

updates_pkg_remove_sing_box_conflict() {
    local package_name="$1"

    if ! updates_pkg_is_installed "$package_name"; then
        return 0
    fi

    if updates_is_apk; then
        apk del --force-broken-world "$package_name" </dev/null
    else
        opkg remove --force-depends "$package_name" </dev/null
    fi
}

updates_compare_versions() {
    local lhs="$1"
    local rhs="$2"

    [ -n "$lhs" ] || return 1
    [ -n "$rhs" ] || return 1

    [ "$lhs" = "$rhs" ] && echo 0 && return 0

    if updates_is_apk; then
        case "$(apk version -t "$lhs" "$rhs" 2>/dev/null || true)" in
        ">") echo 1 && return 0 ;;
        "<") echo -1 && return 0 ;;
        "=") echo 0 && return 0 ;;
        esac
    fi

    if updates_command_exists opkg; then
        if opkg compare-versions "$lhs" ">" "$rhs" >/dev/null 2>&1; then
            echo 1
            return 0
        fi
        if opkg compare-versions "$lhs" "<" "$rhs" >/dev/null 2>&1; then
            echo -1
            return 0
        fi
        if opkg compare-versions "$lhs" "=" "$rhs" >/dev/null 2>&1; then
            echo 0
            return 0
        fi
    fi

    if helpers_ucode version-at-least "$lhs" "$rhs" >/dev/null 2>&1; then
        echo 1
    else
        echo -1
    fi
}

updates_status_from_compare() {
    local compare_result="$1"

    case "$compare_result" in
    -1) printf '%s\n' "outdated" ;;
    0) printf '%s\n' "latest" ;;
    1) printf '%s\n' "dev" ;;
    *) return 1 ;;
    esac
}

updates_check_success() {
    local component="$1"
    local current_version="$2"
    local latest_version="$3"
    local release_url="${4:-}"

    updates_check_success_compared "$component" "$current_version" "$latest_version" "$current_version" "$latest_version" "$release_url"
}

updates_check_success_compared() {
    local component="$1"
    local current_version="$2"
    local latest_version="$3"
    local compare_current_version="$4"
    local compare_latest_version="$5"
    local release_url="${6:-}"
    local compare_result status message

    compare_result="$(updates_compare_versions "$compare_current_version" "$compare_latest_version" 2>/dev/null || true)"
    [ -n "$compare_result" ] || updates_fail "$component" "check_update" "Failed to compare versions" "$current_version" "$latest_version"

    status="$(updates_status_from_compare "$compare_result")" || updates_fail "$component" "check_update" "Failed to compare versions" "$current_version" "$latest_version"

    case "$status" in
    latest)
        message="Latest version is installed"
        updates_log "$component is up to date ($current_version)"
        ;;
    outdated)
        message="Update is available"
        updates_log "$component update is available: $current_version -> $latest_version"
        ;;
    dev)
        message="Installed version is newer than release"
        updates_log "$component installed version is newer than upstream release: $current_version -> $latest_version"
        ;;
    esac

    updates_success "$component" "check_update" "$message" "$current_version" "$latest_version" 0 "$status" "$release_url"
}

updates_fetch_podkop_latest_release_metadata() {
    local release_json metadata

    release_json="$(fetch_latest_podkop_release_json)" || return 1
    metadata="$(printf '%s' "$release_json" | updates_ucode release-metadata-tsv 2>/dev/null)"
    [ -n "$metadata" ] || return 1

    printf '%s\n' "$metadata"
}

updates_ensure_package_tool() {
    local tool_name="$1"
    local package_name="$2"

    if updates_command_exists "$tool_name"; then
        return 0
    fi

    updates_log_command "Updating package lists before installing $package_name" updates_pkg_list_update || return 1
    updates_log_command "Installing bootstrap package $package_name" updates_pkg_install_name "$package_name"
}

updates_retry_resolve() {
    local description="$1"
    local command_name="$2"
    local attempt=1
    local max_attempts=3

    while [ "$attempt" -le "$max_attempts" ]; do
        if "$command_name"; then
            return 0
        fi

        updates_log "$description failed ($attempt/$max_attempts)" "warn"
        attempt=$((attempt + 1))
        sleep 2
    done

    return 1
}

updates_clear_version_caches() {
    rm -f /tmp/podkop-plus.latest-version.cache
    rm -f "$PODKOP_SYSTEM_INFO_CACHE_FILE"
    rm -f /tmp/podkop-plus/system-info.json
}

updates_sing_box_managed_service_installed() {
    [ -r /etc/init.d/sing-box ] || return 1
    grep -q "${SB_MANAGED_SERVICE_MARKER:-Podkop Plus managed sing-box service for binary variants}" /etc/init.d/sing-box 2>/dev/null
}

updates_install_managed_sing_box_service_script() {
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

updates_remove_managed_sing_box_service_script() {
    updates_sing_box_managed_service_installed || return 0

    /etc/init.d/sing-box stop >/dev/null 2>&1 || true
    /etc/init.d/sing-box disable >/dev/null 2>&1 || true
    rm -f /etc/init.d/sing-box
}

updates_disable_sing_box_service_config() {
    updates_command_exists uci || return 0

    uci -q get sing-box.main >/dev/null 2>&1 ||
        uci -q set sing-box.main=sing-box >/dev/null 2>&1 || true
    uci -q set sing-box.main.enabled='0' >/dev/null 2>&1 || true
    uci -q commit sing-box >/dev/null 2>&1 || true
}

updates_prepare_sing_box_service_disabled() {
    updates_disable_sing_box_service_config
    [ -x /etc/init.d/sing-box ] && /etc/init.d/sing-box stop >/dev/null 2>&1 || true
    [ -x /etc/init.d/sing-box ] && /etc/init.d/sing-box disable >/dev/null 2>&1 || true
}

updates_prepare_sing_box_package_service_install() {
    updates_prepare_sing_box_service_disabled
    updates_remove_managed_sing_box_service_script
}

updates_capture_podkop_running_state() {
    UPDATES_PODKOP_WAS_RUNNING=0

    [ -x "$PODKOP_SERVICE_INIT" ] || return 0

    if "$PODKOP_SERVICE_INIT" status >/dev/null 2>&1; then
        UPDATES_PODKOP_WAS_RUNNING=1
    fi
}

updates_restart_podkop_after_successful_change() {
    [ -x "$PODKOP_SERVICE_INIT" ] || return 0

    if [ "$UPDATES_PODKOP_WAS_RUNNING" != "1" ]; then
        updates_log "Podkop Plus was not running before component change; restart skipped"
        updates_prepare_sing_box_service_disabled
        return 0
    fi

    updates_log_command "Restarting Podkop Plus after successful component change" "$PODKOP_SERVICE_INIT" restart || true
}

updates_stop_podkop_before_sing_box_change() {
    [ "$UPDATES_PODKOP_STOPPED_FOR_SING_BOX_CHANGE" -eq 0 ] || return 0
    UPDATES_PODKOP_STOPPED_FOR_SING_BOX_CHANGE=1

    if [ "$UPDATES_PODKOP_WAS_RUNNING" = "1" ] && [ -x "$PODKOP_SERVICE_INIT" ]; then
        updates_log_command "Stopping Podkop Plus before sing-box package change" "$PODKOP_SERVICE_INIT" stop || true
    fi

    if [ "$UPDATES_PODKOP_WAS_RUNNING" = "1" ] && [ -x "$PODKOP_BIN" ]; then
        "$PODKOP_BIN" restore_dnsmasq >/dev/null 2>&1 || true
    fi

    updates_prepare_sing_box_service_disabled
}

updates_podkop_status_running_with_timeout() {
    local output_file pid watcher rc

    updates_init_tmp_dir || return 1
    output_file="$UPDATES_TMP_DIR/podkop-status.$$"
    rm -f "$output_file"

    "$PODKOP_BIN" get_status >"$output_file" 2>/dev/null &
    pid="$!"
    (
        sleep 6
        kill "$pid" 2>/dev/null || true
    ) &
    watcher="$!"

    wait "$pid" 2>/dev/null
    rc="$?"
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true

    [ "$rc" -eq 0 ] || return 1
    grep -Eq '"running"[[:space:]]*:[[:space:]]*1' "$output_file"
}

updates_wait_podkop_running_after_sing_box_change() {
    local waited=0

    [ "$UPDATES_PODKOP_WAS_RUNNING" = "1" ] || return 0
    [ -x "$PODKOP_BIN" ] || return 1

    while [ "$waited" -lt 60 ]; do
        if updates_podkop_status_running_with_timeout; then
            sleep 8
            updates_podkop_status_running_with_timeout && return 0
        fi

        sleep 4
        waited=$((waited + 4))
    done

    return 1
}

updates_resolve_arch_candidates() {
    local arch_list apk_arch_list release_arch resolved old_ifs

    UPDATES_TARGET_ARCH=""
    UPDATES_ARCH_CANDIDATES=""

    if updates_is_apk; then
        if [ -f /etc/apk/arch ]; then
            apk_arch_list="$(updates_ucode file-whitespace-list /etc/apk/arch 2>/dev/null || true)"
            [ -n "$apk_arch_list" ] && arch_list="$arch_list $apk_arch_list"
        fi

        apk_arch_list="$(apk --print-arch 2>/dev/null || true)"
        [ -n "$apk_arch_list" ] && arch_list="$arch_list $apk_arch_list"
    else
        arch_list="$(updates_opkg_arch_list)"
    fi

    release_arch="$(updates_read_openwrt_release_value "DISTRIB_ARCH")"
    [ -n "$release_arch" ] && arch_list="$arch_list $release_arch"

    if ! updates_ucode string-has-whitespace-field "$arch_list" >/dev/null 2>&1; then
        arch_list="$(uname -m 2>/dev/null || true)"
    fi

    resolved="$(updates_ucode updates-arch-candidates "$arch_list" 2>/dev/null)" || return 1
    old_ifs="$IFS"
    IFS="$(printf '\t')" read -r UPDATES_TARGET_ARCH UPDATES_ARCH_CANDIDATES <<EOF
$resolved
EOF
    IFS="$old_ifs"

    [ -n "$UPDATES_TARGET_ARCH" ] || return 1
    updates_log "Detected package architecture candidates: $UPDATES_ARCH_CANDIDATES"
}

updates_fetch_github_release_json() {
    local owner="$1"
    local repo="$2"
    local response

    response="$(updates_http_get "https://api.github.com/repos/${owner}/${repo}/releases/latest" 2>/dev/null || true)"
    [ -n "$response" ] || return 1
    printf '%s' "$response" | updates_ucode github-response-ok >/dev/null 2>&1 || return 1

    printf '%s' "$response"
}

updates_fetch_github_releases_json() {
    local owner="$1"
    local repo="$2"
    local per_page="${3:-30}"
    local response

    response="$(updates_http_get "https://api.github.com/repos/${owner}/${repo}/releases?per_page=${per_page}" 2>/dev/null || true)"
    [ -n "$response" ] || return 1
    printf '%s' "$response" | updates_ucode github-response-ok >/dev/null 2>&1 || return 1

    printf '%s' "$response"
}

updates_extract_arch_package_version() {
    local package_name="$1"
    local package_arch="$2"

    updates_ucode updates-arch-package-version "$package_name" "$package_arch"
}

updates_select_inner_package_path() {
    local bundle_file="$1"
    local component="$2"
    local arch="$3"
    local ext="$4"

    unzip -l "$bundle_file" | updates_ucode updates-zip-inner-package-path "$component" "$arch" "$ext"
}

updates_select_archive_member_path() {
    local archive_file="$1"
    local member_name="$2"

    tar -tzf "$archive_file" 2>/dev/null | updates_ucode updates-archive-member-path "$member_name"
}

updates_opkg_arch_list() {
    opkg print-architecture 2>/dev/null | updates_ucode updates-opkg-arch-list
}

updates_opkg_package_version_from_list() {
    local package_name="$1"
    shift

    "$@" 2>/dev/null | updates_ucode updates-opkg-package-version "$package_name"
}

updates_select_release_asset_name() {
    local release_json="$1"
    local package_prefix="$2"
    local asset_ext="$3"

    printf '%s' "$release_json" | updates_ucode release-asset-name "$package_prefix" "$asset_ext"
}

updates_select_release_asset_url() {
    local release_json="$1"
    local asset_name="$2"

    printf '%s' "$release_json" | updates_ucode release-asset-url "$asset_name"
}

updates_resolve_podkop_plus_release() {
    local latest_version="$1"
    local owner repo asset_ext release_json release_tag

    UPDATES_PODKOP_BACKEND_URL=""
    UPDATES_PODKOP_RELEASE_URL=""
    UPDATES_PODKOP_BACKEND_NAME=""
    UPDATES_PODKOP_APP_URL=""
    UPDATES_PODKOP_APP_NAME=""
    UPDATES_PODKOP_I18N_URL=""
    UPDATES_PODKOP_I18N_NAME=""

    owner="${PODKOP_RELEASE_REPO%%/*}"
    repo="${PODKOP_RELEASE_REPO#*/}"
    [ -n "$owner" ] || return 1
    [ -n "$repo" ] || return 1
    [ "$owner" != "$repo" ] || return 1

    asset_ext="ipk"
    updates_is_apk && asset_ext="apk"

    release_json="$(updates_fetch_github_release_json "$owner" "$repo")" || return 1
    [ -n "$release_json" ] || return 1
    release_tag="$(printf '%s' "$release_json" | updates_ucode object-get-default tag_name "" 2>/dev/null)"
    [ "$release_tag" = "$latest_version" ] || return 1
    UPDATES_PODKOP_RELEASE_URL="$(printf '%s' "$release_json" | updates_ucode object-get-default html_url "" 2>/dev/null)"

    UPDATES_PODKOP_BACKEND_NAME="$(updates_select_release_asset_name "$release_json" "podkop-plus" "$asset_ext")"
    UPDATES_PODKOP_APP_NAME="$(updates_select_release_asset_name "$release_json" "luci-app-podkop-plus" "$asset_ext")"
    [ -n "$UPDATES_PODKOP_BACKEND_NAME" ] || return 1
    [ -n "$UPDATES_PODKOP_APP_NAME" ] || return 1

    UPDATES_PODKOP_BACKEND_URL="$(updates_select_release_asset_url "$release_json" "$UPDATES_PODKOP_BACKEND_NAME")"
    UPDATES_PODKOP_APP_URL="$(updates_select_release_asset_url "$release_json" "$UPDATES_PODKOP_APP_NAME")"
    [ -n "$UPDATES_PODKOP_BACKEND_URL" ] || return 1
    [ -n "$UPDATES_PODKOP_APP_URL" ] || return 1

    if updates_pkg_is_installed "luci-i18n-podkop-plus-ru"; then
        UPDATES_PODKOP_I18N_NAME="$(updates_select_release_asset_name "$release_json" "luci-i18n-podkop-plus-ru" "$asset_ext")"
        [ -n "$UPDATES_PODKOP_I18N_NAME" ] || return 1
        UPDATES_PODKOP_I18N_URL="$(updates_select_release_asset_url "$release_json" "$UPDATES_PODKOP_I18N_NAME")"
        [ -n "$UPDATES_PODKOP_I18N_URL" ] || return 1
    fi
}

updates_download_podkop_plus_packages() {
    UPDATES_PODKOP_BACKEND_FILE="$UPDATES_TMP_DIR/$UPDATES_PODKOP_BACKEND_NAME"
    UPDATES_PODKOP_APP_FILE="$UPDATES_TMP_DIR/$UPDATES_PODKOP_APP_NAME"
    UPDATES_PODKOP_I18N_FILE=""

    updates_download_with_retry "$UPDATES_PODKOP_BACKEND_URL" "$UPDATES_PODKOP_BACKEND_FILE" "$UPDATES_PODKOP_BACKEND_NAME" || return 1
    updates_download_with_retry "$UPDATES_PODKOP_APP_URL" "$UPDATES_PODKOP_APP_FILE" "$UPDATES_PODKOP_APP_NAME" || return 1

    if [ -n "$UPDATES_PODKOP_I18N_URL" ]; then
        UPDATES_PODKOP_I18N_FILE="$UPDATES_TMP_DIR/$UPDATES_PODKOP_I18N_NAME"
        updates_download_with_retry "$UPDATES_PODKOP_I18N_URL" "$UPDATES_PODKOP_I18N_FILE" "$UPDATES_PODKOP_I18N_NAME" || return 1
    fi
}

updates_refresh_luci_after_app_update() {
    rm -f /var/luci-indexcache* /tmp/luci-indexcache* 2>/dev/null || true
    rm -rf /tmp/luci-modulecache/ 2>/dev/null || true
    [ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1 && return 0
    [ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1 && return 0
    killall -HUP rpcd 2>/dev/null || true
}

updates_get_openwrt_release_series() {
    updates_ucode openwrt-release-series /etc/openwrt_release
}

updates_resolve_zapret_release() {
    local release_json candidate_name arch url

    UPDATES_ZAPRET_ARCH=""
    UPDATES_ZAPRET_BUNDLE_URL=""
    UPDATES_ZAPRET_BUNDLE_NAME=""
    UPDATES_ZAPRET_PACKAGE_VERSION=""
    UPDATES_ZAPRET_RELEASE_URL=""

    release_json="$(updates_fetch_github_release_json "remittor" "zapret-openwrt")" || return 1
    UPDATES_ZAPRET_RELEASE_URL="$(printf '%s' "$release_json" | updates_ucode object-get-default html_url "" 2>/dev/null)"

    for arch in $UPDATES_ARCH_CANDIDATES; do
        candidate_name="$(printf '%s' "$release_json" | updates_ucode release-asset-name-by-suffix "_${arch}.zip" 2>/dev/null)"
        if [ -n "$candidate_name" ]; then
            UPDATES_ZAPRET_ARCH="$arch"
            UPDATES_ZAPRET_BUNDLE_NAME="$candidate_name"
            break
        fi
    done

    [ -n "$UPDATES_ZAPRET_BUNDLE_NAME" ] || return 1

    url="$(printf '%s' "$release_json" | updates_ucode release-asset-url "$UPDATES_ZAPRET_BUNDLE_NAME" 2>/dev/null)"
    [ -n "$url" ] || return 1
    UPDATES_ZAPRET_BUNDLE_URL="$url"
    UPDATES_ZAPRET_PACKAGE_VERSION="$(updates_extract_zapret_bundle_version "$UPDATES_ZAPRET_BUNDLE_NAME")"
    [ -n "$UPDATES_ZAPRET_PACKAGE_VERSION" ] || UPDATES_ZAPRET_PACKAGE_VERSION="$(updates_ucode string-remove-suffix "$UPDATES_ZAPRET_BUNDLE_NAME" ".zip")"
}

updates_download_and_extract_zapret_package() {
    local bundle_file inner_package_path

    UPDATES_ZAPRET_PACKAGE_FILE=""
    UPDATES_ZAPRET_PACKAGE_NAME=""
    UPDATES_ZAPRET_PACKAGE_VERSION=""

    bundle_file="$UPDATES_TMP_DIR/$UPDATES_ZAPRET_BUNDLE_NAME"
    updates_download_with_retry "$UPDATES_ZAPRET_BUNDLE_URL" "$bundle_file" "$UPDATES_ZAPRET_BUNDLE_NAME" || return 1

    if updates_is_apk; then
        inner_package_path="$(updates_select_inner_package_path "$bundle_file" "zapret" "" "apk")"
    else
        inner_package_path="$(updates_select_inner_package_path "$bundle_file" "zapret" "$UPDATES_ZAPRET_ARCH" "ipk")"
    fi

    [ -n "$inner_package_path" ] || return 1

    UPDATES_ZAPRET_PACKAGE_NAME="$(basename "$inner_package_path")"
    UPDATES_ZAPRET_PACKAGE_FILE="$UPDATES_TMP_DIR/$UPDATES_ZAPRET_PACKAGE_NAME"

    unzip -p "$bundle_file" "$inner_package_path" >"$UPDATES_ZAPRET_PACKAGE_FILE" || return 1
    [ -s "$UPDATES_ZAPRET_PACKAGE_FILE" ] || return 1

    [ -n "$UPDATES_ZAPRET_PACKAGE_VERSION" ] || UPDATES_ZAPRET_PACKAGE_VERSION="$(updates_extract_zapret_bundle_version "$UPDATES_ZAPRET_BUNDLE_NAME")"
    [ -n "$UPDATES_ZAPRET_PACKAGE_VERSION" ] || UPDATES_ZAPRET_PACKAGE_VERSION="$(updates_extract_arch_package_version "$UPDATES_ZAPRET_PACKAGE_NAME" "$UPDATES_ZAPRET_ARCH")"
}

updates_resolve_zapret2_release() {
    local releases_json resolved resolved_arch resolved_name resolved_url resolved_release_url resolved_tag

    UPDATES_ZAPRET2_ARCH=""
    UPDATES_ZAPRET2_BUNDLE_URL=""
    UPDATES_ZAPRET2_BUNDLE_NAME=""
    UPDATES_ZAPRET2_PACKAGE_VERSION=""
    UPDATES_ZAPRET2_RELEASE_URL=""

    releases_json="$(updates_fetch_github_releases_json "remittor" "zapret-openwrt" 30)" || return 1

    resolved="$(
        printf '%s' "$releases_json" |
            updates_ucode named-release-select-asset "zapret2 " "zapret2" "zip" "$UPDATES_ARCH_CANDIDATES" 2>/dev/null
    )"
    [ -n "$resolved" ] || return 1

    IFS="$(printf '\t')" read -r resolved_arch resolved_name resolved_url resolved_release_url resolved_tag <<EOF
$resolved
EOF
    UPDATES_ZAPRET2_ARCH="$resolved_arch"
    UPDATES_ZAPRET2_BUNDLE_NAME="$resolved_name"
    UPDATES_ZAPRET2_BUNDLE_URL="$resolved_url"
    UPDATES_ZAPRET2_RELEASE_URL="$resolved_release_url"
    [ -n "$UPDATES_ZAPRET2_ARCH" ] || return 1
    [ -n "$UPDATES_ZAPRET2_BUNDLE_NAME" ] || return 1
    [ -n "$UPDATES_ZAPRET2_BUNDLE_URL" ] || return 1
    UPDATES_ZAPRET2_PACKAGE_VERSION="$(updates_extract_zapret2_bundle_version "$UPDATES_ZAPRET2_BUNDLE_NAME")"
    [ -n "$UPDATES_ZAPRET2_PACKAGE_VERSION" ] || UPDATES_ZAPRET2_PACKAGE_VERSION="$(updates_ucode string-remove-suffix "$UPDATES_ZAPRET2_BUNDLE_NAME" ".zip")"
}

updates_download_and_extract_zapret2_package() {
    local bundle_file inner_package_path

    UPDATES_ZAPRET2_PACKAGE_FILE=""
    UPDATES_ZAPRET2_PACKAGE_NAME=""
    UPDATES_ZAPRET2_PACKAGE_VERSION=""

    bundle_file="$UPDATES_TMP_DIR/$UPDATES_ZAPRET2_BUNDLE_NAME"
    updates_download_with_retry "$UPDATES_ZAPRET2_BUNDLE_URL" "$bundle_file" "$UPDATES_ZAPRET2_BUNDLE_NAME" || return 1

    if updates_is_apk; then
        inner_package_path="$(updates_select_inner_package_path "$bundle_file" "zapret2" "" "apk")"
    else
        inner_package_path="$(updates_select_inner_package_path "$bundle_file" "zapret2" "$UPDATES_ZAPRET2_ARCH" "ipk")"
    fi

    [ -n "$inner_package_path" ] || return 1

    UPDATES_ZAPRET2_PACKAGE_NAME="$(basename "$inner_package_path")"
    UPDATES_ZAPRET2_PACKAGE_FILE="$UPDATES_TMP_DIR/$UPDATES_ZAPRET2_PACKAGE_NAME"

    unzip -p "$bundle_file" "$inner_package_path" >"$UPDATES_ZAPRET2_PACKAGE_FILE" || return 1
    [ -s "$UPDATES_ZAPRET2_PACKAGE_FILE" ] || return 1

    [ -n "$UPDATES_ZAPRET2_PACKAGE_VERSION" ] || UPDATES_ZAPRET2_PACKAGE_VERSION="$(updates_extract_zapret2_bundle_version "$UPDATES_ZAPRET2_BUNDLE_NAME")"
    [ -n "$UPDATES_ZAPRET2_PACKAGE_VERSION" ] || UPDATES_ZAPRET2_PACKAGE_VERSION="$(updates_extract_arch_package_version "$UPDATES_ZAPRET2_PACKAGE_NAME" "$UPDATES_ZAPRET2_ARCH")"
}

updates_resolve_byedpi_release() {
    local response release_series asset_ext resolved resolved_arch resolved_name resolved_url resolved_release_url

    UPDATES_BYEDPI_ARCH=""
    UPDATES_BYEDPI_PACKAGE_URL=""
    UPDATES_BYEDPI_PACKAGE_NAME=""
    UPDATES_BYEDPI_PACKAGE_VERSION=""
    UPDATES_BYEDPI_RELEASE_URL=""

    asset_ext="ipk"
    updates_is_apk && asset_ext="apk"
    release_series="$(updates_get_openwrt_release_series)"

    response="$(updates_fetch_github_releases_json "DPITrickster" "ByeDPI-OpenWrt" 30)" || return 1

    resolved="$(printf '%s' "$response" | updates_ucode byedpi-select-asset "$release_series" "$asset_ext" "$UPDATES_ARCH_CANDIDATES" 2>/dev/null)"

    [ -n "$resolved" ] || return 1

    IFS="$(printf '\t')" read -r resolved_arch resolved_name resolved_url resolved_release_url <<EOF
$resolved
EOF
    UPDATES_BYEDPI_ARCH="$resolved_arch"
    UPDATES_BYEDPI_PACKAGE_NAME="$resolved_name"
    UPDATES_BYEDPI_PACKAGE_URL="$resolved_url"
    UPDATES_BYEDPI_RELEASE_URL="$resolved_release_url"

    [ -n "$UPDATES_BYEDPI_ARCH" ] || return 1
    [ -n "$UPDATES_BYEDPI_PACKAGE_NAME" ] || return 1
    [ -n "$UPDATES_BYEDPI_PACKAGE_URL" ] || return 1

    UPDATES_BYEDPI_PACKAGE_VERSION="$(updates_extract_arch_package_version "$UPDATES_BYEDPI_PACKAGE_NAME" "$UPDATES_BYEDPI_ARCH")"
}

updates_download_byedpi_package() {
    UPDATES_BYEDPI_PACKAGE_FILE="$UPDATES_TMP_DIR/$UPDATES_BYEDPI_PACKAGE_NAME"
    updates_download_with_retry "$UPDATES_BYEDPI_PACKAGE_URL" "$UPDATES_BYEDPI_PACKAGE_FILE" "$UPDATES_BYEDPI_PACKAGE_NAME" || return 1
    [ -s "$UPDATES_BYEDPI_PACKAGE_FILE" ] || return 1

    [ -n "$UPDATES_BYEDPI_PACKAGE_VERSION" ] || UPDATES_BYEDPI_PACKAGE_VERSION="$(updates_extract_arch_package_version "$UPDATES_BYEDPI_PACKAGE_NAME" "$UPDATES_BYEDPI_ARCH")"
}

updates_disable_standalone_zapret_service() {
    [ -x /etc/init.d/zapret ] || return 0

    updates_log_command "Stopping standalone zapret service" /etc/init.d/zapret stop || true
    updates_log_command "Disabling standalone zapret autostart" /etc/init.d/zapret disable || true
}

updates_disable_standalone_zapret2_service() {
    [ -x /etc/init.d/zapret2 ] || return 0

    updates_log_command "Stopping standalone zapret2 service" /etc/init.d/zapret2 stop || true
    updates_log_command "Disabling standalone zapret2 autostart" /etc/init.d/zapret2 disable || true
}

updates_disable_standalone_byedpi_service() {
    [ -x /etc/init.d/byedpi ] || return 0

    updates_log_command "Stopping standalone byedpi service" /etc/init.d/byedpi stop || true
    updates_log_command "Disabling standalone byedpi autostart" /etc/init.d/byedpi disable || true
}

updates_install_zapret() {
    local action="$1"
    local current_version installed normalized_current normalized_latest

    updates_init_tmp_dir || updates_fail "zapret" "$action" "Failed to create temporary directory"
    updates_resolve_arch_candidates || updates_fail "zapret" "$action" "Failed to detect package architecture"
    updates_retry_resolve "Resolving zapret package" updates_resolve_zapret_release ||
        updates_fail "zapret" "$action" "Failed to resolve zapret package for this router architecture"

    installed=0
    is_zapret_installed && installed=1
    current_version="$(get_zapret_package_version)"

    if [ "$action" = "check_update" ]; then
        [ "$installed" -eq 1 ] || updates_fail "zapret" "$action" "zapret is not installed" "$current_version" "$UPDATES_ZAPRET_PACKAGE_VERSION"
        normalized_current="$(updates_normalize_zapret_version "$current_version")"
        normalized_latest="$(updates_normalize_zapret_version "$UPDATES_ZAPRET_PACKAGE_VERSION")"
        updates_check_success_compared "zapret" "$current_version" "$UPDATES_ZAPRET_PACKAGE_VERSION" "$normalized_current" "$normalized_latest" "$UPDATES_ZAPRET_RELEASE_URL"
    fi

    updates_ensure_package_tool "unzip" "unzip" || updates_fail "zapret" "$action" "Failed to install unzip"
    updates_download_and_extract_zapret_package || updates_fail "zapret" "$action" "Failed to download zapret package"

    if ! updates_log_command "Installing zapret package $UPDATES_ZAPRET_PACKAGE_NAME" updates_pkg_install_files "$UPDATES_ZAPRET_PACKAGE_FILE"; then
        updates_fail "zapret" "$action" "Failed to install zapret package" "$current_version" "$UPDATES_ZAPRET_PACKAGE_VERSION"
    fi

    updates_disable_standalone_zapret_service
    updates_restart_podkop_after_successful_change
    updates_clear_version_caches

    current_version="$(get_zapret_package_version)"
    updates_success "zapret" "$action" "zapret package has been installed" "$current_version" "$UPDATES_ZAPRET_PACKAGE_VERSION" 1 "latest"
}

updates_install_zapret2() {
    local action="$1"
    local current_version installed normalized_current normalized_latest

    updates_init_tmp_dir || updates_fail "zapret2" "$action" "Failed to create temporary directory"
    updates_resolve_arch_candidates || updates_fail "zapret2" "$action" "Failed to detect package architecture"
    updates_retry_resolve "Resolving zapret2 package" updates_resolve_zapret2_release ||
        updates_fail "zapret2" "$action" "Failed to resolve zapret2 package for this router architecture"

    installed=0
    is_zapret2_installed && installed=1
    current_version="$(get_zapret2_package_version)"

    if [ "$action" = "check_update" ]; then
        [ "$installed" -eq 1 ] ||
            updates_fail "zapret2" "$action" "zapret2 is not installed" "$current_version" "$UPDATES_ZAPRET2_PACKAGE_VERSION" "" "$UPDATES_ZAPRET2_RELEASE_URL"
        normalized_current="$(updates_normalize_zapret_version "$current_version")"
        normalized_latest="$(updates_normalize_zapret_version "$UPDATES_ZAPRET2_PACKAGE_VERSION")"
        updates_check_success_compared "zapret2" "$current_version" "$UPDATES_ZAPRET2_PACKAGE_VERSION" "$normalized_current" "$normalized_latest" "$UPDATES_ZAPRET2_RELEASE_URL"
    fi

    updates_ensure_package_tool "unzip" "unzip" || updates_fail "zapret2" "$action" "Failed to install unzip"
    updates_download_and_extract_zapret2_package ||
        updates_fail "zapret2" "$action" "Failed to download zapret2 package" "$current_version" "$UPDATES_ZAPRET2_PACKAGE_VERSION" "" "$UPDATES_ZAPRET2_RELEASE_URL"

    if ! updates_log_command "Installing zapret2 package $UPDATES_ZAPRET2_PACKAGE_NAME" updates_pkg_install_files "$UPDATES_ZAPRET2_PACKAGE_FILE"; then
        updates_fail "zapret2" "$action" "Failed to install zapret2 package" "$current_version" "$UPDATES_ZAPRET2_PACKAGE_VERSION" "" "$UPDATES_ZAPRET2_RELEASE_URL"
    fi

    updates_disable_standalone_zapret2_service
    updates_restart_podkop_after_successful_change
    updates_clear_version_caches

    current_version="$(get_zapret2_package_version)"
    updates_success "zapret2" "$action" "zapret2 package has been installed" "$current_version" "$UPDATES_ZAPRET2_PACKAGE_VERSION" 1 "latest" "$UPDATES_ZAPRET2_RELEASE_URL"
}

updates_install_byedpi() {
    local action="$1"
    local current_version installed

    updates_init_tmp_dir || updates_fail "byedpi" "$action" "Failed to create temporary directory"
    updates_resolve_arch_candidates || updates_fail "byedpi" "$action" "Failed to detect package architecture"
    updates_retry_resolve "Resolving ByeDPI package" updates_resolve_byedpi_release ||
        updates_fail "byedpi" "$action" "Failed to resolve ByeDPI package for this router architecture"

    installed=0
    is_byedpi_installed && installed=1
    current_version="$(get_byedpi_package_version)"

    if [ "$action" = "check_update" ]; then
        [ "$installed" -eq 1 ] || updates_fail "byedpi" "$action" "ByeDPI is not installed" "$current_version" "$UPDATES_BYEDPI_PACKAGE_VERSION"
        updates_check_success "byedpi" "$current_version" "$UPDATES_BYEDPI_PACKAGE_VERSION" "$UPDATES_BYEDPI_RELEASE_URL"
    fi

    updates_download_byedpi_package || updates_fail "byedpi" "$action" "Failed to download ByeDPI package"

    if ! updates_log_command "Installing ByeDPI package $UPDATES_BYEDPI_PACKAGE_NAME" updates_pkg_install_files "$UPDATES_BYEDPI_PACKAGE_FILE"; then
        updates_fail "byedpi" "$action" "Failed to install ByeDPI package" "$current_version" "$UPDATES_BYEDPI_PACKAGE_VERSION"
    fi

    updates_disable_standalone_byedpi_service
    updates_restart_podkop_after_successful_change
    updates_clear_version_caches

    current_version="$(get_byedpi_package_version)"
    updates_success "byedpi" "$action" "ByeDPI package has been installed" "$current_version" "$UPDATES_BYEDPI_PACKAGE_VERSION" 1 "latest"
}

updates_remove_optional_component() {
    local component="$1"
    local action="remove"
    local package_name="$2"
    local label="$3"
    local provider_check="$4"
    local version_getter="$5"
    local current_version

    if ! updates_pkg_is_installed "$package_name"; then
        if "$provider_check"; then
            updates_fail "$component" "$action" "$label exists outside the package manager and was not removed automatically"
        fi

        updates_success "$component" "$action" "$label is already removed" "" "" 0
    fi

    current_version="$("$version_getter")"

    if ! updates_log_command "Removing $label package" updates_pkg_remove_name "$package_name"; then
        updates_fail "$component" "$action" "Failed to remove $label package" "$current_version"
    fi

    updates_clear_version_caches

    if "$provider_check"; then
        updates_fail "$component" "$action" "$label package was removed, but provider files are still present" "$current_version"
    fi

    updates_restart_podkop_after_successful_change

    updates_success "$component" "$action" "$label package has been removed" "$current_version" "" 1
}

updates_normalize_sing_box_version() {
    updates_ucode updates-normalize-sing-box-version "$1"
}

updates_select_sing_box_extended_asset_url() {
    local release_json="$1"
    local compressed="${2:-0}"

    printf '%s' "$release_json" | updates_ucode sing-box-extended-asset-url "$UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX" 0 "$compressed" 2>/dev/null
}

updates_select_sing_box_extended_package_asset_url() {
    local release_json="$1"
    local distrib_arch asset_ext

    distrib_arch="$(updates_read_openwrt_release_value "DISTRIB_ARCH")"
    [ -n "$distrib_arch" ] || return 1

    asset_ext="ipk"
    updates_is_apk && asset_ext="apk"

    printf '%s' "$release_json" | updates_ucode sing-box-extended-package-asset-url "$distrib_arch" "$asset_ext" 2>/dev/null
}

updates_write_sing_box_variant_marker() {
    local variant="$1"
    local marker="${SB_VARIANT_STATE_FILE:-/etc/podkop-plus/sing-box-variant}"
    local marker_dir

    marker_dir="$(dirname "$marker")"
    mkdir -p "$marker_dir" || return 1
    printf '%s\n' "$variant" >"$marker"
}

updates_read_sing_box_variant_marker() {
    local marker="${SB_VARIANT_STATE_FILE:-/etc/podkop-plus/sing-box-variant}"

    [ -r "$marker" ] || return 1
    sed -n '1p' "$marker" 2>/dev/null
}

updates_write_sing_box_version_state() {
    local version="$1"
    local state_file="${SB_VERSION_STATE_FILE:-/etc/podkop-plus/sing-box-version}"
    local state_dir

    [ -n "$version" ] || return 1
    state_dir="$(dirname "$state_file")"
    mkdir -p "$state_dir" || return 1
    printf '%s\n' "$version" >"$state_file"
}

updates_read_sing_box_version_state() {
    read_sing_box_version_state
}

updates_clear_sing_box_version_state() {
    rm -f "${SB_VERSION_STATE_FILE:-/etc/podkop-plus/sing-box-version}" 2>/dev/null || true
}

updates_restore_sing_box_version_state() {
    local previous_version="$1"

    if [ -n "$previous_version" ]; then
        updates_write_sing_box_version_state "$previous_version"
    else
        updates_clear_sing_box_version_state
    fi
}

updates_restore_sing_box_variant_marker() {
    local previous_marker="$1"

    if [ -n "$previous_marker" ]; then
        updates_write_sing_box_variant_marker "$previous_marker"
    else
        updates_clear_sing_box_variant_marker
    fi
}

updates_clear_sing_box_variant_marker() {
    rm -f "${SB_VARIANT_STATE_FILE:-/etc/podkop-plus/sing-box-variant}" 2>/dev/null || true
}

updates_read_sing_box_binary_version() {
    local binary="$1"
    local library_dir="${2:-}"

    [ -n "$binary" ] || return 1
    [ -x "$binary" ] || return 1

    if [ -n "$library_dir" ]; then
        LD_LIBRARY_PATH="$library_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$binary" version 2>/dev/null |
            helpers_ucode stdin-first-line-last-field
        return $?
    fi

    "$binary" version 2>/dev/null | helpers_ucode stdin-first-line-last-field
}

updates_validate_sing_box_extended_binary() {
    local binary="$1"
    local library_dir="${2:-}"
    local version

    version="$(updates_read_sing_box_binary_version "$binary" "$library_dir")"
    case "$version" in
    *extended*)
        printf '%s\n' "$version"
        return 0
        ;;
    esac

    return 1
}

updates_restore_sing_box_backup() {
    local backup_binary="$1"

    if [ -n "$backup_binary" ] && [ -s "$backup_binary" ]; then
        mv -f "$backup_binary" /usr/bin/sing-box && chmod 0755 /usr/bin/sing-box
        return $?
    fi

    rm -f /usr/bin/sing-box
}

updates_restore_file_backup() {
    local target_path="$1"
    local backup_path="$2"

    if [ -n "$backup_path" ] && [ -s "$backup_path" ]; then
        mv -f "$backup_path" "$target_path"
        return $?
    fi

    rm -f "$target_path"
}

updates_move_file_to_backup() {
    local target_path="$1"
    local backup_path="$2"

    [ -e "$target_path" ] || return 0
    rm -f "$backup_path"
    mv -f "$target_path" "$backup_path"
}

updates_restore_sing_box_service_from_marker() {
    local marker="$1"

    if [ "$marker" = "extended-compressed" ]; then
        updates_install_managed_sing_box_service_script >/dev/null 2>&1 || return 1
        return 0
    fi

    updates_remove_managed_sing_box_service_script >/dev/null 2>&1 || true
}

updates_restore_sing_box_extended_package_variant() {
    local package_file new_version

    updates_init_tmp_dir || return 1
    updates_resolve_sing_box_extended_release 0 || return 1
    package_file="$UPDATES_TMP_DIR/$UPDATES_SING_BOX_EXTENDED_ASSET_NAME"

    updates_download_with_retry "$UPDATES_SING_BOX_EXTENDED_ASSET_URL" "$package_file" "$UPDATES_SING_BOX_EXTENDED_ASSET_NAME" || return 1
    updates_prepare_sing_box_package_service_install
    updates_pkg_remove_sing_box_conflict "sing-box-tiny" >/dev/null 2>&1 || true
    updates_pkg_remove_sing_box_conflict "sing-box" >/dev/null 2>&1 || true
    updates_pkg_install_files "$package_file" || {
        rm -f "$package_file"
        return 1
    }
    rm -f "$package_file"

    new_version="$(updates_validate_sing_box_extended_binary /usr/bin/sing-box /usr/lib)" || return 1
    updates_write_sing_box_variant_marker "extended" >/dev/null 2>&1 || true
    updates_write_sing_box_version_state "$new_version" >/dev/null 2>&1 || true
}

updates_restore_sing_box_package_variant() {
    local previous_variant="$1"

    case "$previous_variant" in
    tiny)
        updates_replace_sing_box_package_variant "sing-box-tiny" "sing-box"
        ;;
    stable)
        updates_replace_sing_box_package_variant "sing-box" "sing-box-tiny"
        ;;
    extended)
        updates_restore_sing_box_extended_package_variant
        ;;
    not-installed)
        updates_pkg_remove_sing_box_conflict "sing-box-extended" >/dev/null 2>&1 || true
        updates_pkg_remove_sing_box_conflict "sing-box-tiny" >/dev/null 2>&1 || true
        updates_pkg_remove_sing_box_conflict "sing-box" >/dev/null 2>&1 || true
        updates_remove_managed_sing_box_service_script >/dev/null 2>&1 || true
        rm -f /usr/bin/sing-box
        ;;
    *)
        return 1
        ;;
    esac
}

updates_restore_sing_box_install_backup() {
    local previous_variant="$1"
    local backup_binary="$2"

    if [ -n "$backup_binary" ]; then
        updates_restore_sing_box_backup "$backup_binary"
        return $?
    fi

    updates_restore_sing_box_package_variant "$previous_variant"
}

updates_restore_sing_box_after_failed_extended_install() {
    local previous_variant="$1"
    local backup_binary="$2"
    local backup_cronet="$3"
    local previous_marker="$4"
    local previous_version_state="$5"
    local archive_file="${6:-}"
    local cronet_touched="${7:-0}"

    [ -n "$archive_file" ] && rm -f "$archive_file"

    if [ "$cronet_touched" -eq 1 ]; then
        updates_restore_file_backup /usr/lib/libcronet.so "$backup_cronet" >/dev/null 2>&1 || true
    fi

    if updates_restore_sing_box_install_backup "$previous_variant" "$backup_binary"; then
        updates_restore_sing_box_variant_marker "$previous_marker" >/dev/null 2>&1 || true
        updates_restore_sing_box_version_state "$previous_version_state" >/dev/null 2>&1 || true
        updates_restore_sing_box_service_from_marker "$previous_marker" >/dev/null 2>&1 || true
        updates_clear_version_caches
        return 0
    fi

    updates_restore_sing_box_variant_marker "$previous_marker" >/dev/null 2>&1 || true
    updates_restore_sing_box_version_state "$previous_version_state" >/dev/null 2>&1 || true
    updates_restore_sing_box_service_from_marker "$previous_marker" >/dev/null 2>&1 || true
    updates_clear_version_caches
    return 1
}

updates_restore_sing_box_after_failed_extended_package_install() {
    local previous_variant="$1"
    local backup_binary="$2"
    local backup_cronet="$3"
    local previous_marker="$4"
    local previous_version_state="$5"
    local package_file="${6:-}"
    local cronet_touched="${7:-0}"

    [ -n "$package_file" ] && rm -f "$package_file"
    updates_pkg_remove_sing_box_conflict "sing-box-extended" >/dev/null 2>&1 || true

    if [ -n "$backup_binary" ]; then
        updates_restore_sing_box_backup "$backup_binary" >/dev/null 2>&1 || true
    else
        updates_restore_sing_box_package_variant "$previous_variant" >/dev/null 2>&1 || true
    fi

    if [ "$cronet_touched" -eq 1 ]; then
        updates_restore_file_backup /usr/lib/libcronet.so "$backup_cronet" >/dev/null 2>&1 || true
        [ -s /usr/lib/libcronet.so ] && chmod 0644 /usr/lib/libcronet.so >/dev/null 2>&1 || true
    fi

    updates_restore_sing_box_variant_marker "$previous_marker" >/dev/null 2>&1 || true
    updates_restore_sing_box_version_state "$previous_version_state" >/dev/null 2>&1 || true
    updates_restore_sing_box_service_from_marker "$previous_marker" >/dev/null 2>&1 || true
    updates_clear_version_caches
}

updates_extract_zapret_bundle_version() {
    updates_ucode updates-zapret-bundle-version "$1"
}

updates_extract_zapret2_bundle_version() {
    updates_ucode updates-zapret2-bundle-version "$1"
}

updates_normalize_zapret_version() {
    updates_ucode updates-normalize-zapret-version "$1"
}

updates_resolve_sing_box_extended_arch_suffix() {
    local host_arch distrib_arch

    host_arch="$(uname -m 2>/dev/null || true)"
    distrib_arch="$(updates_read_openwrt_release_value "DISTRIB_ARCH")"

    UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="$(updates_ucode sing-box-extended-arch-suffix "$host_arch" "$distrib_arch" 2>/dev/null)" || return 1
    [ -n "$UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX" ] || return 1
}

updates_sing_box_extended_tag_is_stable() {
    local tag="$1"
    local lowered

    [ -n "$tag" ] || return 1
    lowered="$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]')"
    case "$lowered" in
    *alpha* | *beta* | *rc*)
        return 1
        ;;
    esac

    return 0
}

updates_set_sing_box_extended_release_from_json() {
    local release_json="$1"
    local compressed="${2:-0}"
    local tag asset_url

    [ -n "$release_json" ] || return 1

    tag="$(printf '%s' "$release_json" | updates_ucode object-get-default tag_name "" 2>/dev/null)"
    updates_sing_box_extended_tag_is_stable "$tag" || return 1

    if [ "$compressed" -eq 1 ]; then
        asset_url="$(updates_select_sing_box_extended_asset_url "$release_json" "$compressed")" || return 1
    else
        asset_url="$(updates_select_sing_box_extended_package_asset_url "$release_json")" || return 1
    fi
    [ -n "$asset_url" ] || return 1

    UPDATES_SING_BOX_EXTENDED_RELEASE_TAG="$tag"
    UPDATES_SING_BOX_EXTENDED_RELEASE_URL="$(printf '%s' "$release_json" | updates_ucode object-get-default html_url "" 2>/dev/null)"
    UPDATES_SING_BOX_EXTENDED_ASSET_URL="$asset_url"
    UPDATES_SING_BOX_EXTENDED_ASSET_NAME="$(basename "$asset_url")"
}

updates_resolve_sing_box_extended_release() {
    local compressed="${1:-0}"
    local response tag release_json

    UPDATES_SING_BOX_EXTENDED_RELEASE_TAG=""
    UPDATES_SING_BOX_EXTENDED_RELEASE_URL=""
    UPDATES_SING_BOX_EXTENDED_ASSET_URL=""
    UPDATES_SING_BOX_EXTENDED_ASSET_NAME=""

    if [ "$compressed" -eq 1 ]; then
        updates_resolve_sing_box_extended_arch_suffix || return 1
    fi

    release_json="$(updates_fetch_github_release_json "shtorm-7" "sing-box-extended" 2>/dev/null || true)"
    if updates_set_sing_box_extended_release_from_json "$release_json" "$compressed"; then
        return 0
    fi

    response="$(updates_fetch_github_releases_json "shtorm-7" "sing-box-extended" 30)" || return 1

    tag="$(printf '%s' "$response" | updates_ucode sing-box-extended-release-tag 2>/dev/null)"

    [ -n "$tag" ] || return 1
    release_json="$(printf '%s' "$response" | updates_ucode release-by-tag "$tag" 2>/dev/null)"
    updates_set_sing_box_extended_release_from_json "$release_json" "$compressed"
}

updates_replace_sing_box_package_variant() {
    local target_package="$1"
    local conflict_package="$2"

    updates_prepare_sing_box_package_service_install

    if { [ -z "$conflict_package" ] || ! updates_pkg_is_installed "$conflict_package"; } &&
        { [ "$target_package" = "sing-box-extended" ] || ! updates_pkg_is_installed "sing-box-extended"; }; then
        updates_pkg_install_name_downgrade "$target_package" && return 0
    fi

    if [ "$target_package" != "sing-box-extended" ]; then
        updates_pkg_remove_sing_box_conflict "sing-box-extended" || return 1
    fi
    if [ -n "$conflict_package" ]; then
        updates_pkg_remove_sing_box_conflict "$conflict_package" || return 1
    fi

    updates_pkg_install_name_downgrade "$target_package"
}

updates_install_sing_box_extended_package() {
    local action="$1"
    local current_version latest_version normalized_current normalized_latest package_file new_version backup_binary backup_cronet previous_marker previous_version_state current_variant cronet_touched changed

    updates_init_tmp_dir || updates_fail "sing_box" "$action" "Failed to create temporary directory"
    current_version="$(get_sing_box_version)"
    current_variant="$(get_sing_box_variant)"
    previous_marker="$(updates_read_sing_box_variant_marker 2>/dev/null || true)"
    previous_version_state="$(updates_read_sing_box_version_state 2>/dev/null || true)"

    updates_resolve_sing_box_extended_release 0 || updates_fail "sing_box" "$action" "Failed to resolve sing-box-extended package release" "$current_version"
    latest_version="$(updates_normalize_sing_box_version "$UPDATES_SING_BOX_EXTENDED_RELEASE_TAG")"
    normalized_current="$(updates_normalize_sing_box_version "$current_version")"
    normalized_latest="$(updates_normalize_sing_box_version "$latest_version")"

    if [ "$action" = "check_update" ]; then
        is_sing_box_extended "$current_version" || updates_fail "sing_box" "$action" "sing-box-extended is not installed" "$current_version" "$latest_version"
        updates_check_success "sing_box" "$normalized_current" "$normalized_latest" "$UPDATES_SING_BOX_EXTENDED_RELEASE_URL"
    fi

    updates_stop_podkop_before_sing_box_change
    updates_prepare_sing_box_package_service_install

    package_file="$UPDATES_TMP_DIR/$UPDATES_SING_BOX_EXTENDED_ASSET_NAME"
    if ! updates_download_with_retry "$UPDATES_SING_BOX_EXTENDED_ASSET_URL" "$package_file" "$UPDATES_SING_BOX_EXTENDED_ASSET_NAME"; then
        updates_fail "sing_box" "$action" "Failed to download sing-box-extended package" "$current_version" "$latest_version"
    fi

    updates_log_command "Updating package lists before sing-box-extended package installation" updates_pkg_list_update ||
        updates_fail "sing_box" "$action" "Failed to update package lists" "$current_version" "$latest_version"

    backup_binary=""
    backup_cronet=""
    cronet_touched=0

    case "$current_variant" in
    extended | extended-compressed)
        if [ -e /usr/bin/sing-box ]; then
            backup_binary="/usr/bin/sing-box.podkop-backup.$$"
            if ! updates_move_file_to_backup /usr/bin/sing-box "$backup_binary"; then
                rm -f "$backup_binary"
                rm -f "$package_file"
                updates_fail "sing_box" "$action" "Failed to backup current sing-box binary" "$current_version" "$latest_version"
            fi
        fi
        if [ -e /usr/lib/libcronet.so ]; then
            cronet_touched=1
            backup_cronet="/usr/lib/libcronet.so.podkop-backup.$$"
            if ! updates_move_file_to_backup /usr/lib/libcronet.so "$backup_cronet"; then
                rm -f "$backup_cronet"
                backup_cronet=""
                cronet_touched=0
                updates_restore_sing_box_after_failed_extended_package_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$package_file" "$cronet_touched" >/dev/null 2>&1 || true
                updates_fail "sing_box" "$action" "Failed to backup current libcronet.so" "$current_version" "$latest_version"
            fi
        fi
        ;;
    esac

    if ! updates_log_command "Removing sing-box-tiny before sing-box-extended package installation" updates_pkg_remove_sing_box_conflict "sing-box-tiny"; then
        updates_restore_sing_box_after_failed_extended_package_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$package_file" "$cronet_touched" >/dev/null 2>&1 || true
        updates_fail "sing_box" "$action" "Failed to remove sing-box-tiny before sing-box-extended package installation" "$current_version" "$latest_version"
    fi
    if ! updates_log_command "Removing sing-box before sing-box-extended package installation" updates_pkg_remove_sing_box_conflict "sing-box"; then
        updates_restore_sing_box_after_failed_extended_package_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$package_file" "$cronet_touched" >/dev/null 2>&1 || true
        updates_fail "sing_box" "$action" "Failed to remove sing-box before sing-box-extended package installation" "$current_version" "$latest_version"
    fi

    if [ -z "$backup_binary" ] && [ -e /usr/bin/sing-box ]; then
        backup_binary="/usr/bin/sing-box.podkop-backup.$$"
        if ! updates_move_file_to_backup /usr/bin/sing-box "$backup_binary"; then
            rm -f "$backup_binary"
            backup_binary=""
            updates_restore_sing_box_after_failed_extended_package_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$package_file" "$cronet_touched" >/dev/null 2>&1 || true
            updates_fail "sing_box" "$action" "Failed to backup existing sing-box binary" "$current_version" "$latest_version"
        fi
    fi

    if [ "$cronet_touched" -eq 0 ] && [ -e /usr/lib/libcronet.so ]; then
        cronet_touched=1
        backup_cronet="/usr/lib/libcronet.so.podkop-backup.$$"
        if ! updates_move_file_to_backup /usr/lib/libcronet.so "$backup_cronet"; then
            rm -f "$backup_cronet"
            backup_cronet=""
            cronet_touched=0
            updates_restore_sing_box_after_failed_extended_package_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$package_file" "$cronet_touched" >/dev/null 2>&1 || true
            updates_fail "sing_box" "$action" "Failed to backup current libcronet.so" "$current_version" "$latest_version"
        fi
    fi

    if ! updates_log_command "Installing sing-box-extended package $UPDATES_SING_BOX_EXTENDED_ASSET_NAME" updates_pkg_install_files "$package_file"; then
        updates_restore_sing_box_after_failed_extended_package_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$package_file" "$cronet_touched" >/dev/null 2>&1 || true
        updates_fail "sing_box" "$action" "Failed to install sing-box-extended package" "$current_version" "$latest_version"
    fi

    rm -f "$package_file"

    new_version="$(updates_validate_sing_box_extended_binary /usr/bin/sing-box /usr/lib)" || {
        if updates_restore_sing_box_after_failed_extended_package_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$package_file" "$cronet_touched"; then
            updates_fail "sing_box" "$action" "Installed sing-box-extended package failed validation; previous sing-box variant was restored" "$current_version" "$latest_version"
        fi
        updates_fail "sing_box" "$action" "Installed sing-box-extended package failed validation and previous sing-box variant could not be restored" "$current_version" "$latest_version"
    }

    updates_write_sing_box_variant_marker "extended" || updates_log "Failed to write sing-box variant marker" "warn"
    updates_write_sing_box_version_state "$new_version" || updates_log "Failed to write sing-box version state" "warn"
    updates_restart_podkop_after_successful_change
    if ! updates_wait_podkop_running_after_sing_box_change; then
        updates_log "sing-box-extended package did not start cleanly; restoring previous sing-box variant" "error"
        [ -x "$PODKOP_SERVICE_INIT" ] && "$PODKOP_SERVICE_INIT" stop >/dev/null 2>&1 || true
        if updates_restore_sing_box_after_failed_extended_package_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$package_file" "$cronet_touched"; then
            rm -f "$backup_binary" "$backup_cronet"
            updates_fail "sing_box" "$action" "sing-box-extended package was installed but Podkop Plus did not start cleanly; previous sing-box variant was restored" "$current_version" "$latest_version"
        fi

        updates_fail "sing_box" "$action" "sing-box-extended package was installed but Podkop Plus did not start cleanly and previous sing-box variant could not be restored" "$current_version" "$latest_version"
    fi

    rm -f "$backup_binary" "$backup_cronet"
    updates_clear_version_caches
    updates_log "Installed sing-box-extended ${new_version:-unknown} from package"
    changed=1
    [ "$new_version" = "$current_version" ] && changed=0
    updates_success "sing_box" "$action" "sing-box-extended has been installed" "$new_version" "$latest_version" "$changed" "latest" "$UPDATES_SING_BOX_EXTENDED_RELEASE_URL"
}

updates_install_sing_box_extended() {
    local action="$1"
    local compressed="${2:-0}"
    local current_version latest_version normalized_current normalized_latest archive_file binary_path cronet_path extract_error new_version backup_binary backup_cronet label marker_variant previous_marker previous_version_state current_variant cronet_touched tmp_binary tmp_cronet

    if [ "$compressed" -ne 1 ]; then
        updates_install_sing_box_extended_package "$action"
        return 0
    fi

    label="sing-box-extended compressed"
    marker_variant="extended-compressed"

    updates_init_tmp_dir || updates_fail "sing_box" "$action" "Failed to create temporary directory"
    current_version="$(get_sing_box_version)"
    current_variant="$(get_sing_box_variant)"
    previous_marker="$(updates_read_sing_box_variant_marker 2>/dev/null || true)"
    previous_version_state="$(updates_read_sing_box_version_state 2>/dev/null || true)"
    updates_resolve_sing_box_extended_release "$compressed" || updates_fail "sing_box" "$action" "Failed to resolve $label release" "$current_version"
    latest_version="$(updates_normalize_sing_box_version "$UPDATES_SING_BOX_EXTENDED_RELEASE_TAG")"
    normalized_current="$(updates_normalize_sing_box_version "$current_version")"
    normalized_latest="$(updates_normalize_sing_box_version "$latest_version")"

    if [ "$action" = "check_update" ]; then
        is_sing_box_extended "$current_version" || updates_fail "sing_box" "$action" "sing-box-extended is not installed" "$current_version" "$latest_version"
        if [ "$compressed" -eq 1 ] && ! is_sing_box_compressed_marker_set; then
            updates_fail "sing_box" "$action" "sing-box-extended compressed is not installed" "$current_version" "$latest_version"
        fi
        updates_check_success "sing_box" "$normalized_current" "$normalized_latest" "$UPDATES_SING_BOX_EXTENDED_RELEASE_URL"
    fi

    updates_stop_podkop_before_sing_box_change

    backup_binary=""
    backup_cronet=""
    cronet_touched=0
    tmp_binary="$UPDATES_TMP_DIR/sing-box.compressed.$$"
    tmp_cronet=""

    archive_file="$UPDATES_TMP_DIR/$UPDATES_SING_BOX_EXTENDED_ASSET_NAME"
    if ! updates_download_with_retry "$UPDATES_SING_BOX_EXTENDED_ASSET_URL" "$archive_file" "$UPDATES_SING_BOX_EXTENDED_ASSET_NAME"; then
        updates_fail "sing_box" "$action" "Failed to download $label" "$current_version" "$latest_version"
    fi

    binary_path="$(updates_select_archive_member_path "$archive_file" "sing-box")"
    if [ -z "$binary_path" ]; then
        rm -f "$archive_file"
        updates_fail "sing_box" "$action" "sing-box binary was not found in the downloaded archive" "$current_version" "$latest_version"
    fi
    cronet_path="$(updates_select_archive_member_path "$archive_file" "libcronet.so")"

    extract_error="$UPDATES_TMP_DIR/sing-box-extract.err"

    if ! tar -xzf "$archive_file" -O "$binary_path" >"$tmp_binary" 2>"$extract_error"; then
        while IFS= read -r line; do
            [ -n "$line" ] && updates_log "$line"
        done <"$extract_error"
        rm -f "$tmp_binary" "$archive_file"
        updates_fail "sing_box" "$action" "Failed to extract $label" "$current_version" "$latest_version"
    fi

    if [ ! -s "$tmp_binary" ]; then
        rm -f "$tmp_binary" "$archive_file"
        updates_fail "sing_box" "$action" "sing-box binary was empty after extraction" "$current_version" "$latest_version"
    fi

    if ! chmod 0755 "$tmp_binary"; then
        rm -f "$tmp_binary" "$archive_file"
        updates_fail "sing_box" "$action" "Failed to prepare sing-box-extended binary" "$current_version" "$latest_version"
    fi

    if [ -n "$cronet_path" ]; then
        tmp_cronet="$UPDATES_TMP_DIR/libcronet.so"
        if ! tar -xzf "$archive_file" -O "$cronet_path" >"$tmp_cronet" 2>"$extract_error"; then
            while IFS= read -r line; do
                [ -n "$line" ] && updates_log "$line"
            done <"$extract_error"
            rm -f "$tmp_binary" "$tmp_cronet" "$archive_file"
            updates_fail "sing_box" "$action" "Failed to extract libcronet.so from sing-box-extended archive" "$current_version" "$latest_version"
        fi

        if [ ! -s "$tmp_cronet" ]; then
            rm -f "$tmp_binary" "$tmp_cronet" "$archive_file"
            updates_fail "sing_box" "$action" "libcronet.so was empty after extraction" "$current_version" "$latest_version"
        fi

        if ! chmod 0644 "$tmp_cronet"; then
            rm -f "$tmp_binary" "$tmp_cronet" "$archive_file"
            updates_fail "sing_box" "$action" "Failed to prepare libcronet.so" "$current_version" "$latest_version"
        fi
    fi

    new_version="$(updates_validate_sing_box_extended_binary "$tmp_binary" "$UPDATES_TMP_DIR")" || {
        rm -f "$tmp_binary" "$tmp_cronet" "$archive_file"
        updates_fail "sing_box" "$action" "Downloaded $label failed validation" "$current_version" "$latest_version"
    }

    if [ -e /usr/bin/sing-box ]; then
        backup_binary="/usr/bin/sing-box.podkop-backup.$$"
        if ! updates_move_file_to_backup /usr/bin/sing-box "$backup_binary"; then
            rm -f "$backup_binary" "$tmp_binary" "$tmp_cronet" "$archive_file"
            updates_fail "sing_box" "$action" "Failed to backup current sing-box binary" "$current_version" "$latest_version"
        fi
    fi

    if [ -n "$cronet_path" ]; then
        cronet_touched=1
        if [ -e /usr/lib/libcronet.so ]; then
            backup_cronet="/usr/lib/libcronet.so.podkop-backup.$$"
            if ! updates_move_file_to_backup /usr/lib/libcronet.so "$backup_cronet"; then
                rm -f "$backup_cronet" "$tmp_binary" "$tmp_cronet" "$archive_file"
                updates_restore_sing_box_after_failed_extended_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$archive_file" "$cronet_touched" >/dev/null 2>&1 || true
                updates_fail "sing_box" "$action" "Failed to backup current libcronet.so" "$current_version" "$latest_version"
            fi
        fi
    fi

    if ! updates_log_command "Removing sing-box-extended package before $label installation" updates_pkg_remove_sing_box_conflict "sing-box-extended"; then
        updates_restore_sing_box_after_failed_extended_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$archive_file" "$cronet_touched" >/dev/null 2>&1 || true
        rm -f "$tmp_binary" "$tmp_cronet"
        updates_fail "sing_box" "$action" "Failed to remove sing-box-extended before $label installation" "$current_version" "$latest_version"
    fi
    if ! updates_log_command "Removing sing-box-tiny package before $label installation" updates_pkg_remove_sing_box_conflict "sing-box-tiny"; then
        updates_restore_sing_box_after_failed_extended_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$archive_file" "$cronet_touched" >/dev/null 2>&1 || true
        rm -f "$tmp_binary" "$tmp_cronet"
        updates_fail "sing_box" "$action" "Failed to remove sing-box-tiny before $label installation" "$current_version" "$latest_version"
    fi
    if ! updates_log_command "Removing sing-box package before $label installation" updates_pkg_remove_sing_box_conflict "sing-box"; then
        updates_restore_sing_box_after_failed_extended_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$archive_file" "$cronet_touched" >/dev/null 2>&1 || true
        rm -f "$tmp_binary" "$tmp_cronet"
        updates_fail "sing_box" "$action" "Failed to remove sing-box before $label installation" "$current_version" "$latest_version"
    fi

    updates_remove_managed_sing_box_service_script >/dev/null 2>&1 || true
    if ! updates_install_managed_sing_box_service_script; then
        updates_restore_sing_box_after_failed_extended_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$archive_file" "$cronet_touched" >/dev/null 2>&1 || true
        rm -f "$tmp_binary" "$tmp_cronet"
        updates_fail "sing_box" "$action" "Failed to install managed sing-box service for $label" "$current_version" "$latest_version"
    fi

    rm -f /usr/bin/sing-box
    if ! mv -f "$tmp_binary" /usr/bin/sing-box || ! chmod 0755 /usr/bin/sing-box; then
        rm -f /usr/bin/sing-box "$tmp_binary"
        updates_restore_sing_box_after_failed_extended_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$archive_file" "$cronet_touched" >/dev/null 2>&1 || true
        updates_fail "sing_box" "$action" "Failed to install $label binary" "$current_version" "$latest_version"
    fi

    if [ -n "$tmp_cronet" ]; then
        rm -f /usr/lib/libcronet.so
        if ! mv -f "$tmp_cronet" /usr/lib/libcronet.so || ! chmod 0644 /usr/lib/libcronet.so; then
            rm -f /usr/lib/libcronet.so "$tmp_cronet"
            updates_restore_sing_box_after_failed_extended_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$archive_file" "$cronet_touched" >/dev/null 2>&1 || true
            updates_fail "sing_box" "$action" "Failed to install libcronet.so for $label" "$current_version" "$latest_version"
        fi
    fi

    rm -f "$archive_file"

    new_version="$(updates_validate_sing_box_extended_binary /usr/bin/sing-box /usr/lib)" || {
        if updates_restore_sing_box_after_failed_extended_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$archive_file" "$cronet_touched"; then
            updates_fail "sing_box" "$action" "Installed $label failed validation; previous sing-box variant was restored" "$current_version" "$latest_version"
        fi
        updates_fail "sing_box" "$action" "Installed $label failed validation and previous sing-box variant could not be restored" "$current_version" "$latest_version"
    }

    updates_write_sing_box_variant_marker "$marker_variant" || updates_log "Failed to write sing-box variant marker" "warn"
    updates_write_sing_box_version_state "$new_version" || updates_log "Failed to write sing-box version state" "warn"
    updates_restart_podkop_after_successful_change
    if ! updates_wait_podkop_running_after_sing_box_change; then
        updates_log "$label did not start cleanly; restoring previous sing-box binary" "error"
        [ -x "$PODKOP_SERVICE_INIT" ] && "$PODKOP_SERVICE_INIT" stop >/dev/null 2>&1 || true
        if updates_restore_sing_box_after_failed_extended_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$archive_file" "$cronet_touched"; then
            rm -f "$backup_binary" "$backup_cronet"
            updates_fail "sing_box" "$action" "$label was installed but Podkop Plus did not start cleanly; previous sing-box variant was restored" "$current_version" "$latest_version"
        fi

        updates_fail "sing_box" "$action" "$label was installed but Podkop Plus did not start cleanly and previous sing-box variant could not be restored" "$current_version" "$latest_version"
    fi

    rm -f "$backup_binary" "$backup_cronet"
    updates_clear_version_caches
    updates_log "Installed $label ${new_version:-unknown}"
    updates_success "sing_box" "$action" "$label has been installed" "$new_version" "$latest_version" 1 "latest"
}

updates_install_stable_sing_box() {
    local action="$1"
    local current_version latest_version new_version changed package_version binary_version

    package_version="$(updates_get_installed_package_version "sing-box")"
    binary_version="$(get_sing_box_version)"
    current_version="$package_version"
    if is_sing_box_extended "$binary_version"; then
        current_version="$binary_version"
    fi
    [ -n "$current_version" ] || current_version="$binary_version"
    latest_version="$(updates_get_available_package_version "sing-box")"
    [ -n "$latest_version" ] || latest_version="$(updates_get_installed_package_version "sing-box")"
    [ -n "$latest_version" ] || updates_fail "sing_box" "$action" "Failed to resolve stable sing-box package version" "$current_version"

    if [ "$action" = "check_update" ]; then
        updates_check_success "sing_box" "$current_version" "$latest_version"
    fi

    updates_stop_podkop_before_sing_box_change

    updates_log_command "Updating package lists before sing-box installation" updates_pkg_list_update ||
        updates_fail "sing_box" "$action" "Failed to update package lists" "$current_version" "$latest_version"

    latest_version="$(updates_get_available_package_version "sing-box")"
    [ -n "$latest_version" ] || latest_version="$(updates_get_installed_package_version "sing-box")"
    [ -n "$latest_version" ] || updates_fail "sing_box" "$action" "Failed to resolve stable sing-box package version" "$current_version"

    if ! updates_log_command "Installing stable sing-box package" updates_replace_sing_box_package_variant "sing-box" "sing-box-tiny"; then
        updates_fail "sing_box" "$action" "Failed to install stable sing-box" "$current_version" "$latest_version"
    fi

    new_version="$(updates_read_sing_box_binary_version /usr/bin/sing-box)"
    if [ -z "$new_version" ]; then
        updates_clear_version_caches
        updates_fail "sing_box" "$action" "Stable sing-box package was installed, but sing-box binary is not available" "$current_version" "$latest_version"
    fi

    if is_sing_box_extended "$new_version"; then
        updates_clear_version_caches
        updates_fail "sing_box" "$action" "Stable sing-box package was installed, but the active binary is still sing-box-extended" "$new_version" "$latest_version"
    fi

    updates_write_sing_box_variant_marker "stable" || updates_log "Failed to write sing-box variant marker" "warn"
    updates_write_sing_box_version_state "$new_version" || updates_log "Failed to write sing-box version state" "warn"
    updates_restart_podkop_after_successful_change
    if ! updates_wait_podkop_running_after_sing_box_change; then
        updates_clear_version_caches
        updates_fail "sing_box" "$action" "Stable sing-box was installed, but Podkop Plus did not start cleanly" "$new_version" "$latest_version"
    fi
    updates_clear_version_caches

    changed=1
    [ "$new_version" = "$current_version" ] && changed=0

    updates_success "sing_box" "$action" "stable sing-box has been installed" "$new_version" "$latest_version" "$changed" "latest"
}

updates_install_tiny_sing_box() {
    local action="$1"
    local current_version latest_version new_version changed package_version binary_version

    package_version="$(updates_get_installed_package_version "sing-box-tiny")"
    binary_version="$(get_sing_box_version)"
    current_version="$package_version"
    if is_sing_box_extended "$binary_version"; then
        current_version="$binary_version"
    fi
    [ -n "$current_version" ] || current_version="$binary_version"

    latest_version="$(updates_get_available_package_version "sing-box-tiny")"
    [ -n "$latest_version" ] || latest_version="$(updates_get_installed_package_version "sing-box-tiny")"
    [ -n "$latest_version" ] || updates_fail "sing_box" "$action" "Failed to resolve tiny sing-box package version" "$current_version"

    if [ "$action" = "check_update" ]; then
        is_sing_box_tiny "$binary_version" || updates_fail "sing_box" "$action" "sing-box-tiny is not installed" "$current_version" "$latest_version"
        updates_check_success "sing_box" "$current_version" "$latest_version"
    fi

    updates_stop_podkop_before_sing_box_change

    updates_log_command "Updating package lists before sing-box-tiny installation" updates_pkg_list_update ||
        updates_fail "sing_box" "$action" "Failed to update package lists" "$current_version" "$latest_version"

    latest_version="$(updates_get_available_package_version "sing-box-tiny")"
    [ -n "$latest_version" ] || latest_version="$(updates_get_installed_package_version "sing-box-tiny")"
    [ -n "$latest_version" ] || updates_fail "sing_box" "$action" "Failed to resolve tiny sing-box package version" "$current_version"

    if ! updates_log_command "Installing tiny sing-box package" updates_replace_sing_box_package_variant "sing-box-tiny" "sing-box"; then
        updates_fail "sing_box" "$action" "Failed to install sing-box-tiny" "$current_version" "$latest_version"
    fi

    new_version="$(updates_read_sing_box_binary_version /usr/bin/sing-box)"
    if [ -z "$new_version" ]; then
        updates_clear_version_caches
        updates_fail "sing_box" "$action" "sing-box-tiny package was installed, but sing-box binary is not available" "$current_version" "$latest_version"
    fi

    if is_sing_box_extended "$new_version"; then
        updates_clear_version_caches
        updates_fail "sing_box" "$action" "sing-box-tiny package was installed, but the active binary is still sing-box-extended" "$new_version" "$latest_version"
    fi

    updates_write_sing_box_variant_marker "tiny" || updates_log "Failed to write sing-box variant marker" "warn"
    updates_write_sing_box_version_state "$new_version" || updates_log "Failed to write sing-box version state" "warn"
    updates_restart_podkop_after_successful_change
    if ! updates_wait_podkop_running_after_sing_box_change; then
        updates_clear_version_caches
        updates_fail "sing_box" "$action" "Tiny sing-box was installed, but Podkop Plus did not start cleanly" "$new_version" "$latest_version"
    fi
    updates_clear_version_caches

    changed=1
    [ "$new_version" = "$current_version" ] && changed=0

    updates_success "sing_box" "$action" "tiny sing-box has been installed" "$new_version" "$latest_version" "$changed" "latest"
}

updates_check_podkop_plus() {
    local release_metadata latest_version release_url compare_result status message now

    release_metadata="$(updates_fetch_podkop_latest_release_metadata 2>/dev/null || true)"
    IFS="$(printf '\t')" read -r latest_version release_url <<EOF
$release_metadata
EOF
    [ -n "$latest_version" ] || latest_version="unknown"

    if [ "$latest_version" = "unknown" ]; then
        updates_fail "podkop" "check_update" "Failed to check Podkop Plus updates" "$PODKOP_VERSION" "$latest_version"
    fi

    now="$(date +%s 2>/dev/null)"
    case "$now" in
    '' | *[!0-9]*) now=0 ;;
    esac
    write_podkop_latest_version_cache "$latest_version" "$now"

    if ! is_podkop_release_version "$PODKOP_VERSION"; then
        updates_log "Podkop Plus current version is not a release version ($PODKOP_VERSION)"
        updates_success "podkop" "check_update" "Installed version is newer than release" "$PODKOP_VERSION" "$latest_version" 0 "dev" "$release_url"
    fi

    compare_result="$(podkop_release_version_compare "$PODKOP_VERSION" "$latest_version" 2>/dev/null || true)"
    if [ -z "$compare_result" ]; then
        updates_fail "podkop" "check_update" "Failed to compare Podkop Plus versions" "$PODKOP_VERSION" "$latest_version"
    fi

    status="$(updates_status_from_compare "$compare_result")" || updates_fail "podkop" "check_update" "Failed to compare Podkop Plus versions" "$PODKOP_VERSION" "$latest_version"
    case "$status" in
    latest)
        message="Latest version is installed"
        updates_log "Podkop Plus is already up to date ($PODKOP_VERSION)"
        ;;
    outdated)
        message="Update is available"
        updates_log "Podkop Plus update found: $PODKOP_VERSION -> $latest_version"
        ;;
    dev)
        message="Installed version is newer than release"
        updates_log "Podkop Plus installed version is newer than upstream release: $PODKOP_VERSION -> $latest_version"
        ;;
    esac

    updates_success "podkop" "check_update" "$message" "$PODKOP_VERSION" "$latest_version" 0 "$status" "$release_url"
}

updates_install_podkop_plus() {
    local latest_version now new_version

    latest_version="$(fetch_latest_podkop_version)"
    [ -n "$latest_version" ] || latest_version="unknown"

    if [ "$latest_version" = "unknown" ]; then
        updates_fail "podkop" "install" "Failed to resolve Podkop Plus release" "$PODKOP_VERSION" "$latest_version"
    fi

    now="$(date +%s 2>/dev/null)"
    case "$now" in
    '' | *[!0-9]*) now=0 ;;
    esac
    write_podkop_latest_version_cache "$latest_version" "$now"

    updates_init_tmp_dir || updates_fail "podkop" "install" "Failed to create temporary directory" "$PODKOP_VERSION" "$latest_version"
    updates_log "Resolving Podkop Plus release $latest_version packages"
    updates_resolve_podkop_plus_release "$latest_version" ||
        updates_fail "podkop" "install" "Failed to resolve Podkop Plus release packages" "$PODKOP_VERSION" "$latest_version"
    updates_download_podkop_plus_packages ||
        updates_fail "podkop" "install" "Failed to download Podkop Plus release packages" "$PODKOP_VERSION" "$latest_version"

    if ! updates_log_command "Installing LuCI app package $UPDATES_PODKOP_APP_NAME" updates_pkg_install_files "$UPDATES_PODKOP_APP_FILE"; then
        updates_fail "podkop" "install" "Failed to install LuCI app package" "$PODKOP_VERSION" "$latest_version"
    fi

    if [ -n "$UPDATES_PODKOP_I18N_FILE" ]; then
        if ! updates_log_command "Installing LuCI Russian i18n package $UPDATES_PODKOP_I18N_NAME" updates_pkg_install_files "$UPDATES_PODKOP_I18N_FILE"; then
            updates_fail "podkop" "install" "Failed to install LuCI Russian i18n package" "$PODKOP_VERSION" "$latest_version"
        fi
    fi

    if ! updates_log_command "Installing Podkop Plus package $UPDATES_PODKOP_BACKEND_NAME" updates_pkg_install_files "$UPDATES_PODKOP_BACKEND_FILE"; then
        updates_fail "podkop" "install" "Failed to install Podkop Plus package" "$PODKOP_VERSION" "$latest_version"
    fi

    updates_refresh_luci_after_app_update
    updates_restart_podkop_after_successful_change
    updates_clear_version_caches

    new_version="$(updates_get_installed_package_version "podkop-plus")"
    [ -n "$new_version" ] || new_version="$latest_version"
    updates_log "Podkop Plus updated to $new_version"
    updates_success "podkop" "install" "Podkop Plus has been installed" "$new_version" "$latest_version" 1 "latest" "$UPDATES_PODKOP_RELEASE_URL"
}

component_action() {
    local component="$1"
    local action="$2"

    trap updates_component_action_cleanup EXIT HUP INT TERM

    updates_acquire_component_lock || updates_fail "${component:-unknown}" "${action:-unknown}" "Another component action is already running"
    updates_begin_direct_component_job_state "$component" "$action"
    updates_init_tmp_dir || updates_fail "${component:-unknown}" "${action:-unknown}" "Failed to create temporary directory"
    updates_capture_podkop_running_state

    case "$component:$action" in
    podkop:check_update)
        updates_check_podkop_plus
        ;;
    podkop:install)
        updates_install_podkop_plus
        ;;
    sing_box:check_update)
        case "$(get_sing_box_variant)" in
        extended-compressed)
            updates_install_sing_box_extended "$action" 1
            ;;
        extended)
            updates_install_sing_box_extended "$action" 0
            ;;
        tiny)
            updates_install_tiny_sing_box "$action"
            ;;
        *)
            updates_install_stable_sing_box "$action"
            ;;
        esac
        ;;
    sing_box:install)
        case "$(get_sing_box_variant)" in
        extended-compressed)
            updates_install_sing_box_extended "$action" 1
            ;;
        extended)
            updates_install_sing_box_extended "$action" 0
            ;;
        tiny)
            updates_install_tiny_sing_box "$action"
            ;;
        *)
            updates_install_stable_sing_box "$action"
            ;;
        esac
        ;;
    sing_box:install_extended)
        updates_install_sing_box_extended "$action" 0
        ;;
    sing_box:install_extended_compressed)
        updates_install_sing_box_extended "$action" 1
        ;;
    sing_box:install_tiny)
        updates_install_tiny_sing_box "$action"
        ;;
    sing_box:install_stable)
        updates_install_stable_sing_box "$action"
        ;;
    zapret:check_update | zapret:install)
        updates_install_zapret "$action"
        ;;
    zapret:remove)
        updates_remove_optional_component "zapret" "zapret" "zapret" is_zapret_installed get_zapret_package_version
        ;;
    zapret2:check_update | zapret2:install)
        updates_install_zapret2 "$action"
        ;;
    zapret2:remove)
        updates_remove_optional_component "zapret2" "zapret2" "zapret2" is_zapret2_installed get_zapret2_package_version
        ;;
    byedpi:check_update | byedpi:install)
        updates_install_byedpi "$action"
        ;;
    byedpi:remove)
        updates_remove_optional_component "byedpi" "byedpi" "ByeDPI" is_byedpi_installed get_byedpi_package_version
        ;;
    *)
        updates_fail "${component:-unknown}" "${action:-unknown}" "Unknown component action"
        ;;
    esac
}
