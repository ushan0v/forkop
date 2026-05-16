has_enabled_byedpi_rules() {
    local count

    count="$(get_byedpi_rule_count)"
    [ "${count:-0}" -gt 0 ]
}

_count_byedpi_rule_handler() {
    local section="$1"

    rule_is_enabled "$section" || return 0
    [ "$(get_rule_action "$section")" = "byedpi" ] || return 0

    BYEDPI_RULE_COUNT=$((BYEDPI_RULE_COUNT + 1))
}

get_byedpi_rule_count() {
    BYEDPI_RULE_COUNT=0
    config_foreach _count_byedpi_rule_handler "rule"
    echo "$BYEDPI_RULE_COUNT"
}

_find_byedpi_rule_index_handler() {
    local section="$1"
    local target_section="$2"

    rule_is_enabled "$section" || return 0
    [ "$(get_rule_action "$section")" = "byedpi" ] || return 0

    BYEDPI_RULE_INDEX_WALK=$((BYEDPI_RULE_INDEX_WALK + 1))
    if [ "$section" = "$target_section" ]; then
        BYEDPI_RULE_INDEX_RESULT="$BYEDPI_RULE_INDEX_WALK"
    fi
}

get_byedpi_rule_index() {
    local section="$1"

    BYEDPI_RULE_INDEX_WALK=0
    BYEDPI_RULE_INDEX_RESULT=0
    config_foreach _find_byedpi_rule_index_handler "rule" "$section"

    echo "$BYEDPI_RULE_INDEX_RESULT"
}

get_byedpi_rule_port() {
    local index="$1"

    echo $((BYEDPI_PORT_BASE + index - 1))
}

normalize_byedpi_strategy_whitespace() {
    printf '%s' "$1" | tr '\t\r\n' '   ' | tr -s ' ' | sed 's/^ //; s/ $//'
}

get_rule_byedpi_cmd_opts() {
    local section="$1"
    local cmd_opts legacy_cmd_opts

    config_get cmd_opts "$section" "byedpi_cmd_opts"
    if [ -z "$cmd_opts" ]; then
        config_get legacy_cmd_opts "$section" "cmd_opts"
        cmd_opts="$legacy_cmd_opts"
    fi

    if [ -n "$cmd_opts" ]; then
        normalize_byedpi_strategy_whitespace "$cmd_opts"
    else
        normalize_byedpi_strategy_whitespace "$BYEDPI_DEFAULT_CMD_OPTS"
    fi
}

byedpi_package_installed() {
    if command -v apk >/dev/null 2>&1 && apk info -e byedpi >/dev/null 2>&1; then
        return 0
    fi

    if command -v opkg >/dev/null 2>&1 && opkg list-installed 2>/dev/null | grep -Eq '^byedpi[[:space:]-]'; then
        return 0
    fi

    return 1
}

is_byedpi_provider_available() {
    [ -x "$BYEDPI_BIN" ]
}

is_byedpi_installed() {
    is_byedpi_provider_available
}

get_byedpi_package_version() {
    local version=""

    if command -v apk >/dev/null 2>&1 && apk info -e byedpi >/dev/null 2>&1; then
        version="$(apk info -v byedpi 2>/dev/null | awk 'NR == 1 { sub(/^byedpi-/, "", $0); print; exit }')"
    elif command -v opkg >/dev/null 2>&1; then
        version="$(opkg list-installed 2>/dev/null | awk '$1 == "byedpi" { print $3; exit }')"
    fi

    if [ -z "$version" ] && [ -x "$BYEDPI_BIN" ]; then
        version="$("$BYEDPI_BIN" --version 2>/dev/null | awk 'NF { print $1; exit }')"
    fi

    echo "$version"
}

is_byedpi_standalone_service_enabled() {
    [ -x "$BYEDPI_SERVICE_INIT" ] || return 1
    "$BYEDPI_SERVICE_INIT" enabled >/dev/null 2>&1
}

is_byedpi_standalone_service_running() {
    [ -x "$BYEDPI_SERVICE_INIT" ] || return 1
    "$BYEDPI_SERVICE_INIT" status >/dev/null 2>&1
}

prepare_byedpi_runtime() {
    mkdir -p "$BYEDPI_STATE_DIR" "$BYEDPI_PID_DIR" "$BYEDPI_CHILD_PID_DIR" "$BYEDPI_LOG_DIR"
}

check_byedpi_requirements() {
    has_enabled_byedpi_rules || return 0

    if ! is_byedpi_provider_available; then
        log "ByeDPI provider is not available at $BYEDPI_BIN. Rules with action 'byedpi' will be skipped until the byedpi package is installed." "error"
        return 0
    fi

    if ! prepare_byedpi_runtime; then
        log "Failed to prepare the Podkop Plus ByeDPI state directory in $BYEDPI_STATE_DIR. Aborted." "fatal"
        exit 1
    fi
}

clear_byedpi_validation_state() {
    BYEDPI_VALIDATE_ERROR=""
    BYEDPI_VALIDATE_NEEDLE=""
    BYEDPI_VALIDATE_NEEDLES=""
}

append_byedpi_validation_needle() {
    local needle="$1"

    [ -n "$needle" ] || return 0

    case "
$BYEDPI_VALIDATE_NEEDLES
" in
    *"
$needle
"*)
        return 0
        ;;
    esac

    if [ -n "$BYEDPI_VALIDATE_NEEDLES" ]; then
        BYEDPI_VALIDATE_NEEDLES="${BYEDPI_VALIDATE_NEEDLES}
$needle"
    else
        BYEDPI_VALIDATE_NEEDLES="$needle"
    fi

    [ -n "$BYEDPI_VALIDATE_NEEDLE" ] || BYEDPI_VALIDATE_NEEDLE="$needle"
}

set_byedpi_validation_failure() {
    BYEDPI_VALIDATE_ERROR="$1"
    BYEDPI_VALIDATE_NEEDLE=""
    BYEDPI_VALIDATE_NEEDLES=""
    shift

    while [ "$#" -gt 0 ]; do
        append_byedpi_validation_needle "$1"
        shift
    done

    return 1
}

byedpi_is_allowed_long_value_option() {
    case "$1" in
    --max-conn | --conn-ip | --buf-size | --debug | --def-ttl | --auto | --auto-mode | --cache-ttl | --cache-dump | --timeout | --proto | --hosts | --ipset | --pf | --round | --split | --disorder | --oob | --disoob | --fake | --fake-sni | --ttl | --fake-offset | --fake-data | --fake-tls-mod | --oob-data | --mod-http | --tlsrec | --tlsminor | --udp-fake)
        return 0
        ;;
    esac

    return 1
}

byedpi_is_allowed_long_flag_option() {
    case "$1" in
    --md5sig | --tfo | --drop-sack | --no-domain | --no-udp)
        return 0
        ;;
    esac

    return 1
}

byedpi_is_allowed_short_value_option() {
    case "$1" in
    -c | -I | -b | -x | -g | -A | -L | -u | -y | -T | -K | -H | -j | -V | -R | -s | -d | -o | -q | -f | -n | -t | -O | -l | -Q | -e | -M | -r | -m | -a)
        return 0
        ;;
    esac

    return 1
}

byedpi_is_allowed_short_flag_option() {
    case "$1" in
    -N | -U | -F | -S | -Y)
        return 0
        ;;
    esac

    return 1
}

byedpi_get_short_option_name() {
    local token="$1"
    local short_char

    short_char="${token#-}"
    short_char="${short_char%"${short_char#?}"}"
    printf -- '-%s' "$short_char"
}

byedpi_token_looks_like_option() {
    case "$1" in
    --?*)
        return 0
        ;;
    -[A-Za-z]*)
        return 0
        ;;
    esac

    return 1
}

byedpi_reject_controlled_option() {
    local token="$1"
    local next_token="$2"
    local base_token display

    base_token="${token%%=*}"
    display="$token"

    case "$token" in
    --ip | --ip=* | -i | -i?* | --port | --port=* | -p | -p?*)
        case "$token" in
        --ip | -i | --port | -p)
            if [ -n "$next_token" ] && [ "${next_token#-}" = "$next_token" ]; then
                display="$display $next_token"
            fi
            ;;
        esac
        set_byedpi_validation_failure "ByeDPI listen address and port are assigned by Podkop Plus and must not be set in the strategy: $display" "$base_token"
        return 0
        ;;
    --transparent | -E | -E?*)
        set_byedpi_validation_failure "Transparent proxy mode is incompatible with action=byedpi because Podkop Plus connects to ciadpi through SOCKS." "$base_token"
        return 0
        ;;
    --daemon | -D | -D?*)
        set_byedpi_validation_failure "Podkop Plus manages the ciadpi process lifecycle itself, so daemon mode is not allowed here." "$base_token"
        return 0
        ;;
    --pidfile | --pidfile=* | -w | -w?*)
        set_byedpi_validation_failure "Podkop Plus manages ciadpi pid files itself, so pidfile options are not allowed here." "$base_token"
        return 0
        ;;
    --help | -h | -h?* | --version | -v | -v?*)
        set_byedpi_validation_failure "This field must start a working ciadpi strategy; help/version options exit immediately and are not allowed here." "$base_token"
        return 0
        ;;
    esac

    return 1
}

byedpi_validate_strategy_token() {
    local token="$1"
    local next_token="$2"
    local base value short

    BYEDPI_TOKEN_CONSUME_NEXT=0

    if byedpi_reject_controlled_option "$token" "$next_token"; then
        return 1
    fi

    case "$token" in
    --*=*)
        base="${token%%=*}"
        value="${token#*=}"

        if byedpi_is_allowed_long_value_option "$base"; then
            if [ -z "$value" ]; then
                set_byedpi_validation_failure "ByeDPI option requires a value: $base" "$base"
                return 1
            fi
            return 0
        fi

        if byedpi_is_allowed_long_flag_option "$base"; then
            set_byedpi_validation_failure "ByeDPI option does not accept a value: $base" "$base"
            return 1
        fi

        set_byedpi_validation_failure "Unknown ByeDPI option: $base" "$base"
        return 1
        ;;
    --*)
        base="$token"

        if byedpi_is_allowed_long_value_option "$base"; then
            if [ -z "$next_token" ] || byedpi_token_looks_like_option "$next_token"; then
                set_byedpi_validation_failure "ByeDPI option requires a value: $base" "$base"
                return 1
            fi
            BYEDPI_TOKEN_CONSUME_NEXT=1
            return 0
        fi

        if byedpi_is_allowed_long_flag_option "$base"; then
            return 0
        fi

        set_byedpi_validation_failure "Unknown ByeDPI option: $base" "$base"
        return 1
        ;;
    -*)
        [ "$token" = "-" ] && {
            set_byedpi_validation_failure "Unexpected ByeDPI strategy argument: $token" "$token"
            return 1
        }

        short="$(byedpi_get_short_option_name "$token")"
        value="${token#"$short"}"

        if byedpi_is_allowed_short_value_option "$short"; then
            if [ "$token" = "$short" ]; then
                if [ -z "$next_token" ] || byedpi_token_looks_like_option "$next_token"; then
                    set_byedpi_validation_failure "ByeDPI option requires a value: $short" "$short"
                    return 1
                fi
                BYEDPI_TOKEN_CONSUME_NEXT=1
            elif [ -z "$value" ]; then
                set_byedpi_validation_failure "ByeDPI option requires a value: $short" "$short"
                return 1
            fi
            return 0
        fi

        if byedpi_is_allowed_short_flag_option "$short"; then
            if [ "$token" != "$short" ]; then
                set_byedpi_validation_failure "ByeDPI option does not accept a compact value: $short" "$short"
                return 1
            fi
            return 0
        fi

        set_byedpi_validation_failure "Unknown ByeDPI option: $short" "$short"
        return 1
        ;;
    *)
        set_byedpi_validation_failure "Unexpected ByeDPI strategy argument: $token" "$token"
        return 1
        ;;
    esac
}

check_byedpi_strategy() {
    local raw_opt="$1"
    local old_ifs token next_token

    clear_byedpi_validation_state
    raw_opt="$(normalize_byedpi_strategy_whitespace "$raw_opt")"

    if [ -z "$raw_opt" ]; then
        set_byedpi_validation_failure "ByeDPI strategy cannot be empty."
        return 1
    fi

    set -f
    old_ifs="$IFS"
    IFS=' '
    set -- $raw_opt
    IFS="$old_ifs"

    while [ "$#" -gt 0 ]; do
        token="$1"
        next_token="$2"

        if ! byedpi_validate_strategy_token "$token" "$next_token"; then
            set +f
            return 1
        fi

        if [ "${BYEDPI_TOKEN_CONSUME_NEXT:-0}" -eq 1 ]; then
            shift
        fi

        shift
    done

    set +f
    return 0
}

validate_byedpi_strategy() {
    local raw_opt="$1"
    local context="$2"

    if ! check_byedpi_strategy "$raw_opt"; then
        if [ -n "$context" ]; then
            log "$context: $BYEDPI_VALIDATE_ERROR" "fatal"
        else
            log "$BYEDPI_VALIDATE_ERROR" "fatal"
        fi
        exit 1
    fi
}

validate_byedpi_strategy_json() {
    local raw_opt="$1"

    if check_byedpi_strategy "$raw_opt"; then
        jq -cn '{valid: true, message: "", needle: "", needles: []}'
        return 0
    fi

    printf '%s\n' "$BYEDPI_VALIDATE_NEEDLES" | jq -R . | jq -sc \
        --arg message "$BYEDPI_VALIDATE_ERROR" \
        --arg needle "$BYEDPI_VALIDATE_NEEDLE" \
        '{valid: false, message: $message, needle: $needle, needles: .}'
}

stop_byedpi_pidfile_process() {
    local pidfile="$1"
    local pid

    [ -f "$pidfile" ] || return 0
    pid="$(cat "$pidfile" 2>/dev/null)"
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null || true
}

kill_byedpi_pidfile_process() {
    local pidfile="$1"
    local pid

    [ -f "$pidfile" ] || return 0
    pid="$(cat "$pidfile" 2>/dev/null)"
    [ -n "$pid" ] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    kill -9 "$pid" 2>/dev/null || true
}

stop_byedpi_runtime() {
    local pidfile

    if [ -d "$BYEDPI_PID_DIR" ]; then
        for pidfile in "$BYEDPI_PID_DIR"/*.pid; do
            stop_byedpi_pidfile_process "$pidfile"
        done
    fi

    if [ -d "$BYEDPI_CHILD_PID_DIR" ]; then
        for pidfile in "$BYEDPI_CHILD_PID_DIR"/*.pid; do
            stop_byedpi_pidfile_process "$pidfile"
        done
    fi

    sleep 1

    if [ -d "$BYEDPI_PID_DIR" ]; then
        for pidfile in "$BYEDPI_PID_DIR"/*.pid; do
            kill_byedpi_pidfile_process "$pidfile"
        done
    fi

    if [ -d "$BYEDPI_CHILD_PID_DIR" ]; then
        for pidfile in "$BYEDPI_CHILD_PID_DIR"/*.pid; do
            kill_byedpi_pidfile_process "$pidfile"
        done
    fi

    rm -rf "$BYEDPI_PID_DIR" "$BYEDPI_CHILD_PID_DIR" "$BYEDPI_LOG_DIR"
}

run_byedpi_supervisor() {
    local section="$1"
    local port="$2"
    local raw_opt="$3"
    local child_pidfile="$4"
    local child_pid="" old_ifs rc

    trap 'rm -f "$child_pidfile"; [ -n "$child_pid" ] && kill "$child_pid" 2>/dev/null; [ -n "$child_pid" ] && wait "$child_pid" 2>/dev/null; exit 0' TERM INT

    while :; do
        if [ ! -x "$BYEDPI_BIN" ]; then
            printf '%s Provider %s is not executable; retrying in %s seconds\n' \
                "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$BYEDPI_BIN" "$BYEDPI_RESPAWN_DELAY"
            sleep "$BYEDPI_RESPAWN_DELAY" &
            child_pid="$!"
            wait "$child_pid"
            child_pid=""
            continue
        fi

        ulimit -n "$BYEDPI_OPEN_FILES_LIMIT" >/dev/null 2>&1 || true

        set -f
        old_ifs="$IFS"
        IFS=' '
        set -- $raw_opt
        IFS="$old_ifs"

        "$BYEDPI_BIN" --ip "$BYEDPI_LISTEN_ADDRESS" --port "$port" "$@" &
        child_pid="$!"
        echo "$child_pid" > "$child_pidfile"
        wait "$child_pid"
        rc="$?"
        rm -f "$child_pidfile"
        child_pid=""
        set +f

        printf '%s ciadpi for rule %s exited with code %s; respawning in %s seconds\n' \
            "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$section" "$rc" "$BYEDPI_RESPAWN_DELAY"
        sleep "$BYEDPI_RESPAWN_DELAY" &
        child_pid="$!"
        wait "$child_pid"
        child_pid=""
    done
}

_start_byedpi_runtime_handler() {
    local section="$1"
    local index port raw_opt pidfile child_pidfile logfile pid child_pid

    rule_is_enabled "$section" || return 0
    [ "$(get_rule_action "$section")" = "byedpi" ] || return 0

    index="$(get_byedpi_rule_index "$section")"
    if [ "${index:-0}" -le 0 ]; then
        log "Unable to resolve ByeDPI index for rule '$section'. Aborted." "fatal"
        exit 1
    fi

    port="$(get_byedpi_rule_port "$index")"
    raw_opt="$(get_rule_byedpi_cmd_opts "$section")"
    validate_byedpi_strategy "$raw_opt" "Invalid ByeDPI strategy for rule '$section'"

    pidfile="$BYEDPI_PID_DIR/$section.pid"
    child_pidfile="$BYEDPI_CHILD_PID_DIR/$section.pid"
    logfile="$BYEDPI_LOG_DIR/$section.log"

    log "Starting ciadpi for rule '$section' on $BYEDPI_LISTEN_ADDRESS:$port"
    (close_inherited_service_lock_fd; run_byedpi_supervisor "$section" "$port" "$raw_opt" "$child_pidfile") >>"$logfile" 2>&1 &
    pid="$!"
    echo "$pid" > "$pidfile"
    sleep 1

    if ! kill -0 "$pid" 2>/dev/null; then
        log "ciadpi failed to start for rule '$section'. Check $logfile. Aborted." "fatal"
        exit 1
    fi

    child_pid="$(cat "$child_pidfile" 2>/dev/null)"
    if [ -z "$child_pid" ] || ! kill -0 "$child_pid" 2>/dev/null; then
        log "ciadpi supervisor started for rule '$section', but ciadpi is not running yet. Check $logfile." "warn"
    fi
}

start_byedpi_runtime() {
    stop_byedpi_runtime

    has_enabled_byedpi_rules || return 0
    is_byedpi_provider_available || return 0

    if is_byedpi_standalone_service_enabled; then
        log "Standalone byedpi service is enabled. Podkop Plus manages ciadpi itself for action 'byedpi'; disable standalone byedpi autostart to avoid boot-time port conflicts." "warn"
    fi

    if is_byedpi_standalone_service_running; then
        log "Stopping standalone byedpi service before starting Podkop-managed ciadpi runtime"
        "$BYEDPI_SERVICE_INIT" stop >/dev/null 2>&1 || true
        sleep 1
        if is_byedpi_standalone_service_running; then
            log "Standalone byedpi service is still running and may conflict with Podkop-managed ciadpi runtime. Aborted." "fatal"
            exit 1
        fi
    fi

    check_byedpi_requirements
    mkdir -p "$BYEDPI_PID_DIR" "$BYEDPI_CHILD_PID_DIR" "$BYEDPI_LOG_DIR"
    config_foreach _start_byedpi_runtime_handler "rule"
}

get_byedpi_runtime_process_count() {
    local count=0 pidfile pid

    [ -d "$BYEDPI_CHILD_PID_DIR" ] || {
        echo 0
        return 0
    }

    for pidfile in "$BYEDPI_CHILD_PID_DIR"/*.pid; do
        [ -f "$pidfile" ] || continue
        pid="$(cat "$pidfile" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            count=$((count + 1))
        else
            rm -f "$pidfile"
        fi
    done

    echo "$count"
}

get_byedpi_supervisor_process_count() {
    local count=0 pidfile pid

    [ -d "$BYEDPI_PID_DIR" ] || {
        echo 0
        return 0
    }

    for pidfile in "$BYEDPI_PID_DIR"/*.pid; do
        [ -f "$pidfile" ] || continue
        pid="$(cat "$pidfile" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            count=$((count + 1))
        else
            rm -f "$pidfile"
        fi
    done

    echo "$count"
}

get_byedpi_restart_count() {
    local count=0 logfile lines

    [ -d "$BYEDPI_LOG_DIR" ] || {
        echo 0
        return 0
    }

    for logfile in "$BYEDPI_LOG_DIR"/*.log; do
        [ -f "$logfile" ] || continue
        lines="$(grep -c 'ciadpi for rule .* exited with code' "$logfile" 2>/dev/null || true)"
        count=$((count + ${lines:-0}))
    done

    echo "$count"
}

byedpi_rule_outbound_present() {
    local section="$1"
    local port="$2"
    local outbound_tag

    [ -f "$BYEDPI_SINGBOX_CONFIG_PATH" ] || return 1

    outbound_tag="$(get_outbound_tag_by_section "$section")"

    jq -e \
        --arg tag "$outbound_tag" \
        --arg address "$BYEDPI_LISTEN_ADDRESS" \
        --argjson port "$port" \
        '.outbounds[]? |
            select(.type == "socks" and .tag == $tag and .server == $address and (.server_port // empty) == $port)' \
        "$BYEDPI_SINGBOX_CONFIG_PATH" >/dev/null 2>&1
}

byedpi_rule_route_rule_present() {
    local section="$1"
    local outbound_tag

    [ -f "$BYEDPI_SINGBOX_CONFIG_PATH" ] || return 1

    outbound_tag="$(get_outbound_tag_by_section "$section")"

    jq -e \
        --arg inbound "$SB_TPROXY_INBOUND_TAG" \
        --arg outbound "$outbound_tag" \
        '.route.rules[]? |
            select(.action == "route" and .inbound == $inbound and .outbound == $outbound)' \
        "$BYEDPI_SINGBOX_CONFIG_PATH" >/dev/null 2>&1
}

_collect_byedpi_runtime_status_handler() {
    local section="$1"
    local index port

    rule_is_enabled "$section" || return 0
    [ "$(get_rule_action "$section")" = "byedpi" ] || return 0

    BYEDPI_RUNTIME_RULES_CONFIGURED=1
    index="$(get_byedpi_rule_index "$section")"
    port="$(get_byedpi_rule_port "$index")"

    if ! byedpi_rule_outbound_present "$section" "$port"; then
        BYEDPI_RUNTIME_OUTBOUNDS_CONFIGURED=0
    fi

    if ! byedpi_rule_route_rule_present "$section"; then
        BYEDPI_RUNTIME_ROUTES_CONFIGURED=0
    fi
}

collect_byedpi_runtime_status() {
    local sing_box_config_path

    BYEDPI_RUNTIME_RULES_CONFIGURED=0
    BYEDPI_RUNTIME_OUTBOUNDS_CONFIGURED=1
    BYEDPI_RUNTIME_ROUTES_CONFIGURED=1

    config_get sing_box_config_path "settings" "config_path"
    BYEDPI_SINGBOX_CONFIG_PATH="$sing_box_config_path"
    config_foreach _collect_byedpi_runtime_status_handler "rule"

    if [ "$BYEDPI_RUNTIME_RULES_CONFIGURED" -eq 0 ]; then
        BYEDPI_RUNTIME_OUTBOUNDS_CONFIGURED=0
        BYEDPI_RUNTIME_ROUTES_CONFIGURED=0
    fi
}

get_byedpi_status_json() {
    local installed=0 package_installed=0 provider_available=0 configured=0 ready=0 conflict=0
    local standalone_service_enabled=0 standalone_service_running=0 enabled_rule_count expected_process_count running_process_count
    local supervisor_process_count restart_count runtime_unstable=0 version status_message outbounds_configured=0 routes_configured=0

    enabled_rule_count="$(get_byedpi_rule_count)"
    expected_process_count="${enabled_rule_count:-0}"
    running_process_count="$(get_byedpi_runtime_process_count)"
    supervisor_process_count="$(get_byedpi_supervisor_process_count)"
    restart_count="$(get_byedpi_restart_count)"
    version="not installed"
    status_message=""

    if [ "${enabled_rule_count:-0}" -gt 0 ]; then
        configured=1
    fi

    if byedpi_package_installed; then
        package_installed=1
        version="$(get_byedpi_package_version)"
        [ -n "$version" ] || version="unknown"
    fi

    if is_byedpi_provider_available; then
        provider_available=1
        installed=1
        if [ "$package_installed" -eq 0 ]; then
            version="$(get_byedpi_package_version)"
            [ -n "$version" ] || version="unknown"
        fi
    fi

    if is_byedpi_standalone_service_enabled; then
        standalone_service_enabled=1
    fi

    if is_byedpi_standalone_service_running; then
        standalone_service_running=1
    fi

    collect_byedpi_runtime_status
    outbounds_configured="${BYEDPI_RUNTIME_OUTBOUNDS_CONFIGURED:-0}"
    routes_configured="${BYEDPI_RUNTIME_ROUTES_CONFIGURED:-0}"

    if [ "${running_process_count:-0}" -gt "${expected_process_count:-0}" ]; then
        conflict=1
    fi

    if [ "$configured" -eq 1 ] && [ "${restart_count:-0}" -gt 0 ]; then
        runtime_unstable=1
    fi

    if [ "$configured" -eq 1 ] &&
        [ "$provider_available" -eq 1 ] &&
        [ "$standalone_service_running" -eq 0 ] &&
        [ "$conflict" -eq 0 ] &&
        [ "$runtime_unstable" -eq 0 ] &&
        [ "$outbounds_configured" -eq 1 ] &&
        [ "$routes_configured" -eq 1 ] &&
        [ "${expected_process_count:-0}" -gt 0 ] &&
        [ "${running_process_count:-0}" -eq "${expected_process_count:-0}" ]; then
        ready=1
    fi

    if [ "$configured" -eq 1 ] && [ "$provider_available" -eq 0 ]; then
        status_message="action=byedpi is configured, but ciadpi is not available at $BYEDPI_BIN"
    elif [ "$configured" -eq 1 ] && [ "$standalone_service_running" -eq 1 ]; then
        status_message="standalone byedpi service is active together with podkop action=byedpi; port conflicts are possible"
        conflict=1
    elif [ "$configured" -eq 1 ] && [ "$standalone_service_enabled" -eq 1 ]; then
        status_message="standalone byedpi service autostart is enabled; disable it to avoid boot-time port conflicts with podkop action=byedpi"
    elif [ "${running_process_count:-0}" -gt "${expected_process_count:-0}" ] ||
        [ "${supervisor_process_count:-0}" -gt "${expected_process_count:-0}" ]; then
        status_message="unexpected podkop-managed ciadpi processes are running without matching action=byedpi rules"
    elif [ "$configured" -eq 1 ] && [ "$runtime_unstable" -eq 1 ]; then
        status_message="podkop-managed ciadpi has restarted after exiting; the ByeDPI strategy or traffic load may be unstable"
    elif [ "$configured" -eq 1 ] && [ "$ready" -eq 0 ]; then
        status_message="action=byedpi is configured, but the podkop-managed ciadpi runtime is not ready"
    elif [ "$configured" -eq 0 ] && [ "$provider_available" -eq 0 ] && [ "$package_installed" -eq 1 ]; then
        status_message="byedpi package is installed, but ciadpi is not available at $BYEDPI_BIN"
    elif [ "$configured" -eq 0 ] && [ "$provider_available" -eq 0 ]; then
        status_message="byedpi package is not installed; action=byedpi is unavailable"
    else
        status_message="byedpi provider status is normal"
    fi

    jq -cn \
        --arg version "$version" \
        --arg provider_path "$BYEDPI_BIN" \
        --arg listen_address "$BYEDPI_LISTEN_ADDRESS" \
        --arg status_message "$status_message" \
        --argjson installed "$installed" \
        --argjson package_installed "$package_installed" \
        --argjson provider_available "$provider_available" \
        --argjson configured "$configured" \
        --argjson enabled_rule_count "${enabled_rule_count:-0}" \
        --argjson expected_process_count "${expected_process_count:-0}" \
        --argjson running_process_count "${running_process_count:-0}" \
        --argjson supervisor_process_count "${supervisor_process_count:-0}" \
        --argjson restart_count "${restart_count:-0}" \
        --argjson runtime_unstable "$runtime_unstable" \
        --argjson standalone_service_enabled "$standalone_service_enabled" \
        --argjson standalone_service_running "$standalone_service_running" \
        --argjson port_base "$BYEDPI_PORT_BASE" \
        --argjson outbounds_configured "$outbounds_configured" \
        --argjson routes_configured "$routes_configured" \
        --argjson ready "$ready" \
        --argjson conflict "$conflict" \
        '{
            installed: $installed,
            package_installed: $package_installed,
            provider_available: $provider_available,
            provider_path: $provider_path,
            version: $version,
            configured: $configured,
            enabled_rule_count: $enabled_rule_count,
            expected_process_count: $expected_process_count,
            running_process_count: $running_process_count,
            supervisor_process_count: $supervisor_process_count,
            restart_count: $restart_count,
            runtime_unstable: $runtime_unstable,
            standalone_service_enabled: $standalone_service_enabled,
            standalone_service_running: $standalone_service_running,
            listen_address: $listen_address,
            port_base: $port_base,
            outbounds_configured: $outbounds_configured,
            routes_configured: $routes_configured,
            ready: $ready,
            conflict: $conflict,
            status_message: $status_message
        }'
}

check_byedpi_runtime_json() {
    local installed=0 package_installed=0

    if is_byedpi_provider_available; then
        installed=1
    fi

    if byedpi_package_installed; then
        package_installed=1
    fi

    jq -cn \
        --argjson byedpi_installed "$installed" \
        --argjson byedpi_package_installed "$package_installed" \
        --arg byedpi_provider_path "$BYEDPI_BIN" \
        '{
            byedpi_installed: $byedpi_installed,
            byedpi_package_installed: $byedpi_package_installed,
            byedpi_provider_path: $byedpi_provider_path
        }'
}
