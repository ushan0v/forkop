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
UPDATES_BYEDPI_ARCH=""
UPDATES_BYEDPI_PACKAGE_URL=""
UPDATES_BYEDPI_PACKAGE_NAME=""
UPDATES_BYEDPI_PACKAGE_FILE=""
UPDATES_BYEDPI_PACKAGE_VERSION=""
UPDATES_PODKOP_BACKEND_URL=""
UPDATES_PODKOP_BACKEND_NAME=""
UPDATES_PODKOP_BACKEND_FILE=""
UPDATES_PODKOP_APP_URL=""
UPDATES_PODKOP_APP_NAME=""
UPDATES_PODKOP_APP_FILE=""
UPDATES_PODKOP_I18N_URL=""
UPDATES_PODKOP_I18N_NAME=""
UPDATES_PODKOP_I18N_FILE=""
UPDATES_SING_BOX_EXTENDED_RELEASE_TAG=""
UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX=""
UPDATES_SING_BOX_EXTENDED_ASSET_URL=""
UPDATES_SING_BOX_EXTENDED_ASSET_NAME=""
UPDATES_JOB_DIR="/var/run/podkop-plus/component-actions"
UPDATES_JOB_FINISHED_TTL_MINUTES=60
UPDATES_JOB_ORPHAN_OUTPUT_TTL_MINUTES=60
UPDATES_JOB_STALE_GRACE_SECONDS=15
UPDATES_LOCK_DIR="/var/run/podkop-plus/component-action.lock"
UPDATES_LOCK_HELD=0
UPDATES_PODKOP_WAS_RUNNING=0

updates_log() {
    local message="$1"
    local level="${2:-info}"

    log "Updates: $message" "$level"
}

updates_json_file_get_default() {
    local json_file="$1"
    local key="$2"
    local fallback="$3"

    json_utils_ucode json-file-field "$json_file" "$key" "$fallback" 2>/dev/null
}

updates_json_file_running_is() {
    local json_file="$1"
    local expected="$2"

    json_utils_ucode job-running-is "$json_file" "$expected" >/dev/null 2>&1
}

updates_init_tmp_dir() {
    [ -n "$UPDATES_TMP_DIR" ] && return 0

    UPDATES_TMP_DIR="$(mktemp -d /tmp/podkop-plus-updates.XXXXXX 2>/dev/null || true)"
    if [ -z "$UPDATES_TMP_DIR" ]; then
        UPDATES_TMP_DIR="/tmp/podkop-plus-updates.$$"
        mkdir -p "$UPDATES_TMP_DIR" || return 1
    fi
}

updates_cleanup() {
    [ -n "$UPDATES_TMP_DIR" ] && rm -rf "$UPDATES_TMP_DIR"
}

updates_acquire_component_lock() {
    local owner_pid

    mkdir -p /var/run/podkop-plus || return 1

    if mkdir "$UPDATES_LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" >"$UPDATES_LOCK_DIR/pid"
        UPDATES_LOCK_HELD=1
        return 0
    fi

    owner_pid="$(sed -n '1p' "$UPDATES_LOCK_DIR/pid" 2>/dev/null)"
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

    json_utils_ucode object-json \
        success b "$success" \
        component s "$component" \
        action s "$action" \
        message s "$message" \
        current_version s "$current_version" \
        latest_version s "$latest_version" \
        changed n "$changed" \
        status s "$status"
}

updates_success() {
    updates_json_response true "$@"
    exit 0
}

updates_fail() {
    local component="$1"
    local action="$2"
    local message="$3"
    local current_version="${4:-}"
    local latest_version="${5:-}"

    updates_log "$message" "error"
    updates_json_response false "$component" "$action" "$message" "$current_version" "$latest_version" 0
    exit 1
}

updates_job_json_response() {
    local success="$1"
    local job_id="$2"
    local message="${3:-}"

    json_utils_ucode object-json \
        success b "$success" \
        job_id s "$job_id" \
        message s "$message"
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

    if [ -n "$pid" ]; then
        json_utils_ucode object-json \
            success b true \
            running b true \
            component s "$component" \
            action s "$action" \
            message s "Component action is running" \
            pid s "$pid" \
            started_at n "$started_at" \
            current_version s "" \
            latest_version s "" \
            changed n 0 \
            status s "" \
            exit_code j null >"$tmp_file" && mv "$tmp_file" "$state_file"
    else
        json_utils_ucode object-json \
            success b true \
            running b true \
            component s "$component" \
            action s "$action" \
            message s "Component action is running" \
            pid j null \
            started_at n "$started_at" \
            current_version s "" \
            latest_version s "" \
            changed n 0 \
            status s "" \
            exit_code j null >"$tmp_file" && mv "$tmp_file" "$state_file"
    fi

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
    json_utils_ucode updates-set-running-job-pid "$state_file" "$pid" >"$tmp_file" && mv "$tmp_file" "$state_file"

    local rc=$?
    rm -f "$tmp_file" 2>/dev/null
    return $rc
}

updates_mark_stale_job_state() {
    local state_file="$1"
    local tmp_file

    tmp_file="$(updates_job_tmp_file "$state_file")" || return 1
    json_utils_ucode updates-mark-stale-job-state "$state_file" >"$tmp_file" && mv "$tmp_file" "$state_file"

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

    if json_utils_ucode file-json-valid "$output_file" >/dev/null 2>&1; then
        json_utils_ucode updates-finish-job-state "$output_file" "$exit_code" "$updated_at" >"$tmp_file" && mv "$tmp_file" "$state_file"
        rm -f "$tmp_file" "$output_file"
        return 0
    fi

    sed -n 's/^[^{]*\({.*\)$/\1/p' "$output_file" 2>/dev/null | tail -n 1 >"$json_file"
    if [ -s "$json_file" ] && json_utils_ucode file-json-valid "$json_file" >/dev/null 2>&1; then
        json_utils_ucode updates-finish-job-state "$json_file" "$exit_code" "$updated_at" >"$tmp_file" && mv "$tmp_file" "$state_file"
        rm -f "$tmp_file" "$json_file" "$output_file"
        return 0
    fi
    rm -f "$json_file"

    raw_output="$(tr '\n' ' ' <"$output_file" 2>/dev/null | cut -c1-240)"
    [ -n "$raw_output" ] || raw_output="Failed to execute"

    json_utils_ucode updates-fallback-job-state "$component" "$action" "$raw_output" "$exit_code" "$updated_at" >"$tmp_file" && mv "$tmp_file" "$state_file"

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
        /usr/bin/podkop-plus component_action "$component" "$action" >"$output_file" 2>&1
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
    sed -n "s/^${key}='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null | head -n 1
}

updates_http_get() {
    local url="$1"

    if updates_command_exists curl; then
        curl --connect-timeout 5 -m 30 -fsSL "$url"
        return $?
    fi

    if updates_command_exists wget; then
        wget -T 30 -qO- "$url"
        return $?
    fi

    return 1
}

updates_download_file_once() {
    local url="$1"
    local output_path="$2"

    if updates_command_exists curl; then
        curl --connect-timeout 5 -m 120 -fsSL "$url" -o "$output_path"
        return $?
    fi

    if updates_command_exists wget; then
        wget -T 120 -q -O "$output_path" "$url"
        return $?
    fi

    return 1
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
    local status output_file line level
    shift

    output_file="$(mktemp /tmp/podkop-plus-updates-command.XXXXXX 2>/dev/null || true)"
    [ -n "$output_file" ] || output_file="/tmp/podkop-plus-updates-command.$$"

    updates_log "$description"
    "$@" >"$output_file" 2>&1
    status=$?

    level="info"
    [ "$status" -eq 0 ] || level="error"

    while IFS= read -r line; do
        [ -n "$line" ] && updates_log "$line" "$level"
    done <"$output_file"

    rm -f "$output_file"
    return "$status"
}

updates_pkg_is_installed() {
    local package_name="$1"

    if updates_is_apk; then
        apk info -e "$package_name" >/dev/null 2>&1
        return $?
    fi

    opkg list-installed 2>/dev/null | grep -Eq "^${package_name}([[:space:]-]|$)"
}

updates_get_installed_package_version() {
    local package_name="$1"

    if updates_is_apk; then
        apk info -e "$package_name" >/dev/null 2>&1 || return 0
        get_apk_installed_package_version "$package_name"
        return 0
    fi

    opkg list-installed 2>/dev/null | awk -v pkg="$package_name" '$1 == pkg && $2 == "-" {print $3; exit}'
}

updates_get_available_package_version() {
    local package_name="$1"

    if updates_is_apk; then
        apk policy "$package_name" 2>/dev/null |
            awk '
                /^  [^[:space:]][^[:space:]]*:/ {
                    version=$1
                    sub(/:$/, "", version)
                    print version
                    exit
                }
            '
        return 0
    fi

    opkg list "$package_name" 2>/dev/null |
        awk -v pkg="$package_name" '$1 == pkg && $2 == "-" {print $3; exit}'
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
        apk add "$package_name" </dev/null
    else
        opkg install --force-reinstall --force-downgrade "$package_name" </dev/null ||
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

updates_compare_versions() {
    local lhs="$1"
    local rhs="$2"
    local newest

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

    newest="$(printf '%s\n%s\n' "$rhs" "$lhs" | sort -V | tail -n 1)"
    if [ "$newest" = "$lhs" ]; then
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

    updates_check_success_compared "$component" "$current_version" "$latest_version" "$current_version" "$latest_version"
}

updates_check_success_compared() {
    local component="$1"
    local current_version="$2"
    local latest_version="$3"
    local compare_current_version="$4"
    local compare_latest_version="$5"
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

    updates_success "$component" "check_update" "$message" "$current_version" "$latest_version" 0 "$status"
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
        return 0
    fi

    updates_log_command "Restarting Podkop Plus after successful component change" "$PODKOP_SERVICE_INIT" restart || true
}

updates_append_arch_candidate() {
    local candidate="$1"

    [ -n "$candidate" ] || return 0

    case "$candidate" in
    all | noarch)
        return 0
        ;;
    esac

    case " $UPDATES_ARCH_CANDIDATES " in
    *" $candidate "*)
        return 0
        ;;
    esac

    if [ -n "$UPDATES_ARCH_CANDIDATES" ]; then
        UPDATES_ARCH_CANDIDATES="$UPDATES_ARCH_CANDIDATES $candidate"
    else
        UPDATES_ARCH_CANDIDATES="$candidate"
    fi
}

updates_append_arch_candidate_variants() {
    local candidate="$1"
    local base_candidate suffix

    [ -n "$candidate" ] || return 0

    updates_append_arch_candidate "$candidate"

    case "$candidate" in
    *+*)
        updates_append_arch_candidate "${candidate%%+*}"
        ;;
    esac

    for suffix in _musl _uclibc _glibc -musl -uclibc -glibc .musl .uclibc .glibc; do
        case "$candidate" in
        *"$suffix")
            base_candidate="${candidate%"$suffix"}"
            updates_append_arch_candidate "$base_candidate"
            ;;
        esac
    done
}

updates_add_arch_family_fallbacks() {
    local arch="$1"

    updates_append_arch_candidate_variants "$arch"

    case "$arch" in
    aarch64_*)
        updates_append_arch_candidate_variants "aarch64_generic"
        ;;
    riscv64_*)
        updates_append_arch_candidate_variants "riscv64_generic"
        ;;
    arm_cortex-a7_neon-vfpv4)
        updates_append_arch_candidate_variants "arm_cortex-a7_vfpv4"
        updates_append_arch_candidate_variants "arm_cortex-a7"
        ;;
    arm_cortex-a7_*)
        updates_append_arch_candidate_variants "arm_cortex-a7"
        ;;
    arm_cortex-a9_*)
        updates_append_arch_candidate_variants "arm_cortex-a9"
        ;;
    mipsel_24kc_24kf)
        updates_append_arch_candidate_variants "mipsel_24kc"
        ;;
    esac
}

updates_resolve_arch_candidates() {
    local arch_list apk_arch_list release_arch arch

    UPDATES_TARGET_ARCH=""
    UPDATES_ARCH_CANDIDATES=""

    if updates_is_apk; then
        if [ -f /etc/apk/arch ]; then
            apk_arch_list="$(tr '\r\n' '  ' </etc/apk/arch)"
            [ -n "$apk_arch_list" ] && arch_list="$arch_list $apk_arch_list"
        fi

        apk_arch_list="$(apk --print-arch 2>/dev/null || true)"
        [ -n "$apk_arch_list" ] && arch_list="$arch_list $apk_arch_list"
    else
        arch_list="$(opkg print-architecture 2>/dev/null | awk '$1 == "arch" && $2 !~ /^(all|noarch)$/ {print $2 " " $3}' | sort -k2,2nr | awk '{print $1}')"
    fi

    release_arch="$(updates_read_openwrt_release_value "DISTRIB_ARCH")"
    [ -n "$release_arch" ] && arch_list="$arch_list $release_arch"

    if [ -z "$(printf '%s' "$arch_list" | tr -d '[:space:]')" ]; then
        arch_list="$(uname -m 2>/dev/null || true)"
    fi

    for arch in $arch_list; do
        case "$arch" in
        all | noarch)
            continue
            ;;
        esac

        [ -n "$UPDATES_TARGET_ARCH" ] || UPDATES_TARGET_ARCH="$arch"
        updates_add_arch_family_fallbacks "$arch"
    done

    [ -n "$UPDATES_TARGET_ARCH" ] || return 1
    updates_log "Detected package architecture candidates: $UPDATES_ARCH_CANDIDATES"
}

updates_fetch_github_release_json() {
    local owner="$1"
    local repo="$2"
    local response

    response="$(updates_http_get "https://api.github.com/repos/${owner}/${repo}/releases/latest" 2>/dev/null || true)"
    [ -n "$response" ] || return 1
    printf '%s' "$response" | json_utils_ucode github-response-ok >/dev/null 2>&1 || return 1

    printf '%s' "$response"
}

updates_fetch_github_releases_json() {
    local owner="$1"
    local repo="$2"
    local per_page="${3:-30}"
    local response

    response="$(updates_http_get "https://api.github.com/repos/${owner}/${repo}/releases?per_page=${per_page}" 2>/dev/null || true)"
    [ -n "$response" ] || return 1
    printf '%s' "$response" | json_utils_ucode github-response-ok >/dev/null 2>&1 || return 1

    printf '%s' "$response"
}

updates_extract_arch_package_version() {
    local package_name="$1"
    local package_arch="$2"
    local version

    version="$(printf '%s\n' "$package_name" | sed 's/\.ipk$//;s/\.apk$//')"

    case "$version" in
    zapret_*) version="${version#zapret_}" ;;
    zapret-*) version="${version#zapret-}" ;;
    byedpi_*) version="${version#byedpi_}" ;;
    byedpi-*) version="${version#byedpi-}" ;;
    esac

    if [ -n "$package_arch" ]; then
        case "$version" in
        *_$package_arch) version="${version%_$package_arch}" ;;
        *-$package_arch) version="${version%-$package_arch}" ;;
        esac
    fi

    printf '%s\n' "$version"
}

updates_select_release_asset_name() {
    local release_json="$1"
    local package_prefix="$2"
    local asset_ext="$3"

    printf '%s' "$release_json" | json_utils_ucode release-asset-name "$package_prefix" "$asset_ext"
}

updates_select_release_asset_url() {
    local release_json="$1"
    local asset_name="$2"

    printf '%s' "$release_json" | json_utils_ucode release-asset-url "$asset_name" | sed -n '1p'
}

updates_resolve_podkop_plus_release() {
    local latest_version="$1"
    local owner repo asset_ext release_json release_tag

    UPDATES_PODKOP_BACKEND_URL=""
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
    release_tag="$(printf '%s' "$release_json" | json_utils_ucode object-get-default tag_name "" 2>/dev/null)"
    [ "$release_tag" = "$latest_version" ] || return 1

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
    local release

    release="$(updates_read_openwrt_release_value "DISTRIB_RELEASE")"
    printf '%s\n' "$release" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'
}

updates_resolve_zapret_release() {
    local release_json candidate_name arch url

    UPDATES_ZAPRET_ARCH=""
    UPDATES_ZAPRET_BUNDLE_URL=""
    UPDATES_ZAPRET_BUNDLE_NAME=""
    UPDATES_ZAPRET_PACKAGE_VERSION=""

    release_json="$(updates_fetch_github_release_json "remittor" "zapret-openwrt")" || return 1

    for arch in $UPDATES_ARCH_CANDIDATES; do
        candidate_name="$(printf '%s' "$release_json" | json_utils_ucode release-asset-name-by-suffix "_${arch}.zip" 2>/dev/null)"
        if [ -n "$candidate_name" ]; then
            UPDATES_ZAPRET_ARCH="$arch"
            UPDATES_ZAPRET_BUNDLE_NAME="$candidate_name"
            break
        fi
    done

    [ -n "$UPDATES_ZAPRET_BUNDLE_NAME" ] || return 1

    url="$(printf '%s' "$release_json" | json_utils_ucode release-asset-url "$UPDATES_ZAPRET_BUNDLE_NAME" 2>/dev/null)"
    [ -n "$url" ] || return 1
    UPDATES_ZAPRET_BUNDLE_URL="$url"
    UPDATES_ZAPRET_PACKAGE_VERSION="$(updates_extract_zapret_bundle_version "$UPDATES_ZAPRET_BUNDLE_NAME")"
    [ -n "$UPDATES_ZAPRET_PACKAGE_VERSION" ] || UPDATES_ZAPRET_PACKAGE_VERSION="$(printf '%s\n' "$UPDATES_ZAPRET_BUNDLE_NAME" | sed 's/\.zip$//')"
}

updates_download_and_extract_zapret_package() {
    local bundle_file inner_package_path

    UPDATES_ZAPRET_PACKAGE_FILE=""
    UPDATES_ZAPRET_PACKAGE_NAME=""
    UPDATES_ZAPRET_PACKAGE_VERSION=""

    bundle_file="$UPDATES_TMP_DIR/$UPDATES_ZAPRET_BUNDLE_NAME"
    updates_download_with_retry "$UPDATES_ZAPRET_BUNDLE_URL" "$bundle_file" "$UPDATES_ZAPRET_BUNDLE_NAME" || return 1

    if updates_is_apk; then
        inner_package_path="$(unzip -l "$bundle_file" | awk '{print $4}' | grep -E '^apk/zapret-.*\.apk$' | sed -n '1p')"
    else
        inner_package_path="$(unzip -l "$bundle_file" | awk '{print $4}' | grep -E "^zapret_.*_${UPDATES_ZAPRET_ARCH}\.ipk$" | sed -n '1p')"
        [ -n "$inner_package_path" ] || inner_package_path="$(unzip -l "$bundle_file" | awk '{print $4}' | grep -E '^zapret_.*\.ipk$' | sed -n '1p')"
    fi

    [ -n "$inner_package_path" ] || return 1

    UPDATES_ZAPRET_PACKAGE_NAME="$(basename "$inner_package_path")"
    UPDATES_ZAPRET_PACKAGE_FILE="$UPDATES_TMP_DIR/$UPDATES_ZAPRET_PACKAGE_NAME"

    unzip -p "$bundle_file" "$inner_package_path" >"$UPDATES_ZAPRET_PACKAGE_FILE" || return 1
    [ -s "$UPDATES_ZAPRET_PACKAGE_FILE" ] || return 1

    [ -n "$UPDATES_ZAPRET_PACKAGE_VERSION" ] || UPDATES_ZAPRET_PACKAGE_VERSION="$(updates_extract_zapret_bundle_version "$UPDATES_ZAPRET_BUNDLE_NAME")"
    [ -n "$UPDATES_ZAPRET_PACKAGE_VERSION" ] || UPDATES_ZAPRET_PACKAGE_VERSION="$(updates_extract_arch_package_version "$UPDATES_ZAPRET_PACKAGE_NAME" "$UPDATES_ZAPRET_ARCH")"
}

updates_resolve_byedpi_release() {
    local response release_series asset_ext resolved

    UPDATES_BYEDPI_ARCH=""
    UPDATES_BYEDPI_PACKAGE_URL=""
    UPDATES_BYEDPI_PACKAGE_NAME=""
    UPDATES_BYEDPI_PACKAGE_VERSION=""

    asset_ext="ipk"
    updates_is_apk && asset_ext="apk"
    release_series="$(updates_get_openwrt_release_series)"

    response="$(updates_fetch_github_releases_json "DPITrickster" "ByeDPI-OpenWrt" 30)" || return 1

    resolved="$(printf '%s' "$response" | json_utils_ucode byedpi-select-asset "$release_series" "$asset_ext" "$UPDATES_ARCH_CANDIDATES" 2>/dev/null)"

    [ -n "$resolved" ] || return 1

    UPDATES_BYEDPI_ARCH="$(printf '%s\n' "$resolved" | cut -f1)"
    UPDATES_BYEDPI_PACKAGE_NAME="$(printf '%s\n' "$resolved" | cut -f2)"
    UPDATES_BYEDPI_PACKAGE_URL="$(printf '%s\n' "$resolved" | cut -f3)"

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
        updates_check_success_compared "zapret" "$current_version" "$UPDATES_ZAPRET_PACKAGE_VERSION" "$normalized_current" "$normalized_latest"
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
        updates_check_success "byedpi" "$current_version" "$UPDATES_BYEDPI_PACKAGE_VERSION"
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
    printf '%s\n' "$1" |
        sed 's/^v//;s/+.*$//;s/[[:space:]].*$//'
}

updates_extract_zapret_bundle_version() {
    local bundle_name="$1"
    local version

    version="$(basename "$bundle_name" | sed -n 's/^zapret_v\([^_][^_]*\)_.*/\1/p')"
    [ -n "$version" ] || version="$(basename "$bundle_name" | sed -n 's/^zapret_\([^_][^_]*\)_.*/\1/p')"

    printf '%s\n' "$version" | sed 's/^v//'
}

updates_normalize_zapret_version() {
    printf '%s\n' "$1" |
        sed 's/^v//;s/-r[0-9][0-9]*$//;s/+.*$//;s/[[:space:]].*$//'
}

updates_resolve_sing_box_extended_arch_suffix() {
    local host_arch distrib_arch

    host_arch="$(uname -m 2>/dev/null || true)"
    distrib_arch="$(updates_read_openwrt_release_value "DISTRIB_ARCH")"

    case "$distrib_arch" in
    *mipsel* | *mipsle*) host_arch="mipsel" ;;
    *mips64el* | *mips64le*) host_arch="mips64el" ;;
    esac

    case "$host_arch" in
    aarch64) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="arm64" ;;
    armv7*) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="armv7" ;;
    armv6*) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="armv6" ;;
    x86_64) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="amd64" ;;
    i386 | i686) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="386" ;;
    mips) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="mips-softfloat" ;;
    mipsel | mipsle) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="mipsle-softfloat" ;;
    mips64) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="mips64" ;;
    mips64el | mips64le) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="mips64le" ;;
    riscv64) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="riscv64" ;;
    s390x) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="s390x" ;;
    *) return 1 ;;
    esac
}

updates_resolve_sing_box_extended_release() {
    local response tag release_json asset_pattern

    UPDATES_SING_BOX_EXTENDED_RELEASE_TAG=""
    UPDATES_SING_BOX_EXTENDED_ASSET_URL=""
    UPDATES_SING_BOX_EXTENDED_ASSET_NAME=""

    updates_resolve_sing_box_extended_arch_suffix || return 1
    response="$(updates_fetch_github_releases_json "shtorm-7" "sing-box-extended" 30)" || return 1

    tag="$(printf '%s' "$response" | json_utils_ucode sing-box-extended-release-tag 2>/dev/null)"

    [ -n "$tag" ] || return 1
    UPDATES_SING_BOX_EXTENDED_RELEASE_TAG="$tag"
    release_json="$(printf '%s' "$response" | json_utils_ucode release-by-tag "$tag" 2>/dev/null)"
    asset_pattern="linux-${UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX}.tar.gz"
    UPDATES_SING_BOX_EXTENDED_ASSET_URL="$(printf '%s' "$release_json" | json_utils_ucode release-asset-url-by-suffix "$asset_pattern" 2>/dev/null)"

    [ -n "$UPDATES_SING_BOX_EXTENDED_ASSET_URL" ] || return 1
    UPDATES_SING_BOX_EXTENDED_ASSET_NAME="$(basename "$UPDATES_SING_BOX_EXTENDED_ASSET_URL")"
}

updates_install_sing_box_extended() {
    local action="$1"
    local current_version latest_version normalized_current normalized_latest archive_file binary_path target_binary extract_error new_version

    updates_init_tmp_dir || updates_fail "sing_box" "$action" "Failed to create temporary directory"
    current_version="$(get_sing_box_version)"
    updates_resolve_sing_box_extended_release || updates_fail "sing_box" "$action" "Failed to resolve sing-box-extended release" "$current_version"
    latest_version="$(updates_normalize_sing_box_version "$UPDATES_SING_BOX_EXTENDED_RELEASE_TAG")"
    normalized_current="$(updates_normalize_sing_box_version "$current_version")"
    normalized_latest="$(updates_normalize_sing_box_version "$latest_version")"

    if [ "$action" = "check_update" ]; then
        is_sing_box_extended "$current_version" || updates_fail "sing_box" "$action" "sing-box-extended is not installed" "$current_version" "$latest_version"
        updates_check_success "sing_box" "$normalized_current" "$normalized_latest"
    fi

    archive_file="$UPDATES_TMP_DIR/$UPDATES_SING_BOX_EXTENDED_ASSET_NAME"
    updates_download_with_retry "$UPDATES_SING_BOX_EXTENDED_ASSET_URL" "$archive_file" "$UPDATES_SING_BOX_EXTENDED_ASSET_NAME" ||
        updates_fail "sing_box" "$action" "Failed to download sing-box-extended" "$current_version" "$latest_version"

    binary_path="$(tar -tzf "$archive_file" 2>/dev/null | grep -E '(^|/)sing-box$' | sed -n '1p')"
    [ -n "$binary_path" ] || updates_fail "sing_box" "$action" "sing-box binary was not found in the downloaded archive" "$current_version" "$latest_version"

    target_binary="/usr/bin/.sing-box.new.$$"
    extract_error="$UPDATES_TMP_DIR/sing-box-extract.err"

    if ! tar -xzf "$archive_file" -O "$binary_path" >"$target_binary" 2>"$extract_error"; then
        while IFS= read -r line; do
            [ -n "$line" ] && updates_log "$line" "error"
        done <"$extract_error"
        rm -f "$target_binary"
        updates_fail "sing_box" "$action" "Failed to extract sing-box-extended" "$current_version" "$latest_version"
    fi

    if [ ! -s "$target_binary" ]; then
        rm -f "$target_binary"
        updates_fail "sing_box" "$action" "sing-box binary was empty after extraction" "$current_version" "$latest_version"
    fi

    if ! chmod 0755 "$target_binary"; then
        rm -f "$target_binary"
        updates_fail "sing_box" "$action" "Failed to prepare sing-box-extended binary" "$current_version" "$latest_version"
    fi

    if ! mv -f "$target_binary" /usr/bin/sing-box; then
        rm -f "$target_binary"
        updates_fail "sing_box" "$action" "Failed to install sing-box-extended" "$current_version" "$latest_version"
    fi

    updates_restart_podkop_after_successful_change
    updates_clear_version_caches
    new_version="$(get_sing_box_version)"
    updates_log "Installed sing-box-extended ${new_version:-unknown}"
    updates_success "sing_box" "$action" "sing-box-extended has been installed" "$new_version" "$latest_version" 1 "latest"
}

updates_install_stable_sing_box() {
    local action="$1"
    local current_version latest_version new_version changed

    current_version="$(updates_get_installed_package_version "sing-box")"
    [ -n "$current_version" ] || current_version="$(get_sing_box_version)"
    latest_version="$(updates_get_available_package_version "sing-box")"
    [ -n "$latest_version" ] || latest_version="$(updates_get_installed_package_version "sing-box")"
    [ -n "$latest_version" ] || updates_fail "sing_box" "$action" "Failed to resolve stable sing-box package version" "$current_version"

    if [ "$action" = "check_update" ]; then
        updates_check_success "sing_box" "$current_version" "$latest_version"
    fi

    updates_log_command "Updating package lists before sing-box installation" updates_pkg_list_update ||
        updates_fail "sing_box" "$action" "Failed to update package lists" "$current_version" "$latest_version"

    latest_version="$(updates_get_available_package_version "sing-box")"
    [ -n "$latest_version" ] || latest_version="$(updates_get_installed_package_version "sing-box")"
    [ -n "$latest_version" ] || updates_fail "sing_box" "$action" "Failed to resolve stable sing-box package version" "$current_version"

    if ! updates_log_command "Installing stable sing-box package" updates_pkg_install_name_downgrade "sing-box"; then
        updates_fail "sing_box" "$action" "Failed to install stable sing-box" "$current_version" "$latest_version"
    fi

    updates_restart_podkop_after_successful_change
    updates_clear_version_caches

    new_version="$(get_sing_box_version)"
    changed=1
    [ "$new_version" = "$current_version" ] && changed=0

    updates_success "sing_box" "$action" "stable sing-box has been installed" "$new_version" "$latest_version" "$changed" "latest"
}

updates_check_podkop_plus() {
    local latest_version compare_result status message now

    latest_version="$(fetch_latest_podkop_version)"
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
        updates_success "podkop" "check_update" "Installed version is newer than release" "$PODKOP_VERSION" "$latest_version" 0 "dev"
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

    updates_success "podkop" "check_update" "$message" "$PODKOP_VERSION" "$latest_version" 0 "$status"
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
    updates_success "podkop" "install" "Podkop Plus has been installed" "$new_version" "$latest_version" 1 "latest"
}

component_action() {
    local component="$1"
    local action="$2"

    trap updates_component_action_cleanup EXIT HUP INT TERM

    updates_acquire_component_lock || updates_fail "${component:-unknown}" "${action:-unknown}" "Another component action is already running"
    updates_capture_podkop_running_state

    case "$component:$action" in
    podkop:check_update)
        updates_check_podkop_plus
        ;;
    podkop:install)
        updates_install_podkop_plus
        ;;
    sing_box:check_update)
        if is_sing_box_extended "$(get_sing_box_version)"; then
            updates_install_sing_box_extended "$action"
        fi
        updates_install_stable_sing_box "$action"
        ;;
    sing_box:install)
        if is_sing_box_extended "$(get_sing_box_version)"; then
            updates_install_sing_box_extended "$action"
        fi
        updates_install_stable_sing_box "$action"
        ;;
    sing_box:install_extended)
        updates_install_sing_box_extended "$action"
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
