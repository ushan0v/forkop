has_enabled_zapret_rules() {
    local count

    count="$(get_zapret_rule_count)"
    [ "${count:-0}" -gt 0 ]
}

_count_zapret_rule_handler() {
    local section="$1"

    rule_is_enabled "$section" || return 0
    [ "$(get_rule_action "$section")" = "zapret" ] || return 0

    ZAPRET_RULE_COUNT=$((ZAPRET_RULE_COUNT + 1))
}

get_zapret_rule_count() {
    ZAPRET_RULE_COUNT=0
    config_foreach _count_zapret_rule_handler "section"
    echo "$ZAPRET_RULE_COUNT"
}

_find_zapret_rule_index_handler() {
    local section="$1"
    local target_section="$2"

    rule_is_enabled "$section" || return 0
    [ "$(get_rule_action "$section")" = "zapret" ] || return 0

    ZAPRET_RULE_INDEX_WALK=$((ZAPRET_RULE_INDEX_WALK + 1))
    if [ "$section" = "$target_section" ]; then
        ZAPRET_RULE_INDEX_RESULT="$ZAPRET_RULE_INDEX_WALK"
    fi
}

get_zapret_rule_index() {
    local section="$1"

    ZAPRET_RULE_INDEX_WALK=0
    ZAPRET_RULE_INDEX_RESULT=0
    config_foreach _find_zapret_rule_index_handler "section" "$section"

    echo "$ZAPRET_RULE_INDEX_RESULT"
}

format_mark_hex() {
    local mark_value="$1"

    printf '0x%08x\n' "$mark_value"
}

get_zapret_rule_mark_value() {
    local index="$1"

    echo $((ZAPRET_ROUTE_MARK_BASE + index))
}

get_zapret_rule_mark_hex() {
    local index="$1"

    format_mark_hex "$(get_zapret_rule_mark_value "$index")"
}

get_zapret_rule_queue_number() {
    local index="$1"

    echo $((ZAPRET_QUEUE_BASE + index - 1))
}

get_rule_nfqws_opt() {
    local section="$1"
    local nfqws_opt

    config_get nfqws_opt "$section" "nfqws_opt"
    if [ -n "$nfqws_opt" ]; then
        normalize_nfqws_strategy_whitespace "$nfqws_opt"
    else
        normalize_nfqws_strategy_whitespace "$ZAPRET_DEFAULT_NFQWS_OPT"
    fi
}

normalize_nfqws_strategy_whitespace() {
    printf '%s' "$1" | tr '\t\r\n' '   ' | tr -s ' ' | sed 's/^ //; s/ $//'
}

nfqws_option_argument_mode() {
    case "$1" in
    --debug | --comment | --synack-split | --ctrack-disable | --ipcache-hostname | \
        --dup-autottl | --dup-autottl6 | --dup-tcp-flags-set | --dup-tcp-flags-unset | \
        --dup-replace | --orig-autottl | --orig-autottl6 | --orig-tcp-flags-set | \
        --orig-tcp-flags-unset | --dpi-desync-autottl | --dpi-desync-autottl6 | \
        --dpi-desync-tcp-flags-set | --dpi-desync-tcp-flags-unset | \
        --dpi-desync-skip-nosni | --dpi-desync-any-protocol)
        echo "optional"
        ;;
    --dry-run | --version | --daemon | --hostcase | --hostnospace | --domcase | \
        --methodeol | --new | --skip | --bind-fix4 | --bind-fix6)
        echo "none"
        ;;
    --qnum | --pidfile | --user | --uid | --wsize | --wssize | --wssize-cutoff | \
        --wssize-forced-cutoff | --ctrack-timeouts | --ipcache-lifetime | \
        --hostspell | --ip-id | --dpi-desync | --dpi-desync-fwmark | --dup | \
        --dup-ttl | --dup-ttl6 | --dup-fooling | --dup-ts-increment | \
        --dup-badseq-increment | --dup-badack-increment | --dup-ip-id | \
        --dup-start | --dup-cutoff | --orig-ttl | --orig-ttl6 | \
        --orig-mod-start | --orig-mod-cutoff | --dpi-desync-ttl | \
        --dpi-desync-ttl6 | --dpi-desync-fooling | --dpi-desync-repeats | \
        --dpi-desync-split-pos | --dpi-desync-split-http-req | \
        --dpi-desync-split-tls | --dpi-desync-split-seqovl | \
        --dpi-desync-split-seqovl-pattern | --dpi-desync-fakedsplit-pattern | \
        --dpi-desync-fakedsplit-mod | --dpi-desync-hostfakesplit-midhost | \
        --dpi-desync-hostfakesplit-mod | --dpi-desync-ipfrag-pos-tcp | \
        --dpi-desync-ipfrag-pos-udp | --dpi-desync-ts-increment | \
        --dpi-desync-badseq-increment | --dpi-desync-badack-increment | \
        --dpi-desync-fake-tcp-mod | --dpi-desync-fake-http | \
        --dpi-desync-fake-tls | --dpi-desync-fake-tls-mod | \
        --dpi-desync-fake-unknown | --dpi-desync-fake-syndata | \
        --dpi-desync-fake-quic | --dpi-desync-fake-wireguard | \
        --dpi-desync-fake-dht | --dpi-desync-fake-discord | \
        --dpi-desync-fake-stun | --dpi-desync-fake-unknown-udp | \
        --dpi-desync-udplen-increment | --dpi-desync-udplen-pattern | \
        --dpi-desync-cutoff | --dpi-desync-start | --hostlist | \
        --hostlist-domains | --hostlist-exclude | --hostlist-exclude-domains | \
        --hostlist-auto | --hostlist-auto-fail-threshold | \
        --hostlist-auto-fail-time | --hostlist-auto-retrans-threshold | \
        --hostlist-auto-debug | --filter-l3 | --filter-tcp | --filter-udp | \
        --filter-l7 | --ipset | --ipset-ip | --ipset-exclude | \
        --ipset-exclude-ip)
        echo "required"
        ;;
    *)
        echo "unknown"
        ;;
    esac
}

clear_nfqws_validation_state() {
    NFQWS_VALIDATE_ERROR=""
    NFQWS_VALIDATE_NEEDLE=""
    NFQWS_VALIDATE_NEEDLES=""
}

append_nfqws_validation_needle() {
    local needle="$1"

    [ -n "$needle" ] || return 0

    case "
$NFQWS_VALIDATE_NEEDLES
" in
    *"
$needle
"*)
        return 0
        ;;
    esac

    if [ -n "$NFQWS_VALIDATE_NEEDLES" ]; then
        NFQWS_VALIDATE_NEEDLES="${NFQWS_VALIDATE_NEEDLES}
$needle"
    else
        NFQWS_VALIDATE_NEEDLES="$needle"
    fi

    [ -n "$NFQWS_VALIDATE_NEEDLE" ] || NFQWS_VALIDATE_NEEDLE="$needle"
}

set_nfqws_validation_failure() {
    NFQWS_VALIDATE_ERROR="$1"
    NFQWS_VALIDATE_NEEDLE=""
    NFQWS_VALIDATE_NEEDLES=""
    shift

    while [ "$#" -gt 0 ]; do
        append_nfqws_validation_needle "$1"
        shift
    done

    return 1
}

get_nfqws_unsupported_token_reason() {
    local token="$1"

    case "$token" in
    "<HOSTLIST>" | "<HOSTLIST_NOAUTO>")
        echo "Podkop Plus does not expand zapret hostlist templates in per-rule strategies because sing-box already selects the resources before NFQUEUE."
        return 0
        ;;
    --hostlist | --hostlist=* | --hostlist-domains | --hostlist-domains=* | \
        --hostlist-exclude | --hostlist-exclude=* | --hostlist-exclude-domains | --hostlist-exclude-domains=* | \
        --hostlist-auto | --hostlist-auto=* | --hostlist-auto-fail-threshold | --hostlist-auto-fail-threshold=* | \
        --hostlist-auto-fail-time | --hostlist-auto-fail-time=* | \
        --hostlist-auto-retrans-threshold | --hostlist-auto-retrans-threshold=* | \
        --hostlist-auto-debug | --hostlist-auto-debug=*)
        echo "Hostname-based selection inside nfqws is incompatible with the Podkop Plus architecture because sing-box already chooses which resources enter action=zapret."
        return 0
        ;;
    --ipset | --ipset=* | --ipset-ip | --ipset-ip=* | --ipset-exclude | --ipset-exclude=* | --ipset-exclude-ip | --ipset-exclude-ip=*)
        echo "IP or CIDR selection inside nfqws is incompatible with the Podkop Plus architecture because sing-box already chooses which resources enter action=zapret."
        return 0
        ;;
    --qnum | --qnum=*)
        echo "The NFQUEUE number is assigned by Podkop Plus per rule and must not be overridden in the strategy."
        return 0
        ;;
    --dpi-desync-fwmark | --dpi-desync-fwmark=*)
        echo "The desync fwmark is managed by Podkop Plus for loop prevention and must not be overridden in the strategy."
        return 0
        ;;
    --daemon)
        echo "Podkop Plus manages the nfqws process lifecycle itself. The strategy must not daemonize nfqws."
        return 0
        ;;
    --dry-run)
        echo "The strategy must launch a working nfqws process. --dry-run exits immediately and is not allowed."
        return 0
        ;;
    --version)
        echo "The strategy must launch a working nfqws process. --version exits immediately and is not allowed."
        return 0
        ;;
    esac

    return 1
}

normalize_nfqws_validation_output() {
    printf '%s\n' "$1" | sed 's/\r$//'
}

extract_nfqws_validation_summary() {
    local output="$1"
    local summary

    summary="$(normalize_nfqws_validation_output "$output" | grep -m1 -E 'unrecognized option:|option requires an argument:|option does not take an argument:|[Ii]nvalid |bad [^ ]|must be |fooling allowed values|incompatible|only one |No such file|not found|cannot |failed to |unable to |should be |Too much splits|out of memory|not supported|value error' | sed 's#^.*/nfqws: ##; s/^nfqws: //')"
    if [ -n "$summary" ]; then
        printf '%s\n' "$summary"
        return 0
    fi

    normalize_nfqws_validation_output "$output" | awk '
        /^github version / { next }
        /^we have [0-9]+ user defined desync profile/ { next }
        /^Running as UID=/ { next }
        /^command line parameters verified$/ { next }
        /^[[:space:]]*$/ { next }
        {
            sub(/^.*\/nfqws:[[:space:]]*/, "", $0)
            sub(/^nfqws:[[:space:]]*/, "", $0)
            print
            exit
        }
    '
}

extract_nfqws_validation_value_hint() {
    local summary="$1"
    local value=""

    case "$summary" in
    *"Invalid port filter :"* | *"Invalid l7 filter :"* | *"invalid debug mode :"* | \
        *"invalid ip_id mode :"* | *"Invalid fakedsplit mod :"* | \
        *"Invalid hostfakesplit mod :"* | *"Invalid tcp mod :"* | \
        *"Invalid tls mod :"* | *"invalid dup ip_id mode :"*)
        value="$(printf '%s\n' "$summary" | sed -n 's/.*:[[:space:]]*\([^[:space:]]\+\).*/\1/p' | head -n 1)"
        ;;
    esac

    printf '%s\n' "$value"
}

extract_nfqws_validation_option_hint() {
    local summary="$1"
    local option=""

    option="$(printf '%s\n' "$summary" | grep -oE -- '--[[:alnum:]][[:alnum:]-]*' | head -n 1)"
    if [ -n "$option" ]; then
        printf '%s\n' "$option"
        return 0
    fi

    case "$summary" in
    *"unrecognized option:"*)
        option="$(printf '%s\n' "$summary" | sed -n 's/.*unrecognized option:[[:space:]]*\([^[:space:]]\+\).*/\1/p' | head -n 1)"
        case "$option" in
        "") ;;
        --*) ;;
        -*) option="-$option" ;;
        *) option="--$option" ;;
        esac
        ;;
    *"option requires an argument:"*)
        option="$(printf '%s\n' "$summary" | sed -n 's/.*option requires an argument:[[:space:]]*\([^[:space:]]\+\).*/--\1/p' | head -n 1)"
        ;;
    *"option does not take an argument:"*)
        option="$(printf '%s\n' "$summary" | sed -n 's/.*option does not take an argument:[[:space:]]*\([^[:space:]]\+\).*/--\1/p' | head -n 1)"
        ;;
    *"invalid debug mode :"*)
        option="--debug"
        ;;
    *"hostspell must be exactly 4 chars long"*)
        option="--hostspell"
        ;;
    *"invalid ip_id mode :"*)
        option="--ip-id"
        ;;
    *"invalid dup ip_id mode :"*)
        option="--dup-ip-id"
        ;;
    *"dup-autottl value error"*)
        option="--dup-autottl"
        ;;
    *"dup-autottl6 value error"*)
        option="--dup-autottl6"
        ;;
    *"dpi-desync-autottl value error"*)
        option="--dpi-desync-autottl"
        ;;
    *"dpi-desync-autottl6 value error"*)
        option="--dpi-desync-autottl6"
        ;;
    *"orig-autottl value error"*)
        option="--orig-autottl"
        ;;
    *"orig-autottl6 value error"*)
        option="--orig-autottl6"
        ;;
    *"invalid dpi-desync mode"* | *"invalid desync combo :"*)
        option="--dpi-desync"
        ;;
    *"invalid wssize-cutoff value"*)
        option="--wssize-cutoff"
        ;;
    *"invalid synack-split value"*)
        option="--synack-split"
        ;;
    *"invalid ctrack-timeouts value"*)
        option="--ctrack-timeouts"
        ;;
    *"invalid ipcache-lifetime value"*)
        option="--ipcache-lifetime"
        ;;
    *"dpi-desync-repeats must be within "*)
        option="--dpi-desync-repeats"
        ;;
    *"dup-repeats must be within "*)
        option="--dup"
        ;;
    *"invalid desync-cutoff value"*)
        option="--dpi-desync-cutoff"
        ;;
    *"invalid desync-start value"*)
        option="--dpi-desync-start"
        ;;
    *"Invalid fakedsplit mod :"*)
        option="--dpi-desync-fakedsplit-mod"
        ;;
    *"Invalid hostfakesplit mod :"*)
        option="--dpi-desync-hostfakesplit-mod"
        ;;
    *"Invalid tcp mod :"*)
        option="--dpi-desync-fake-tcp-mod"
        ;;
    *"Invalid tls mod :"*)
        option="--dpi-desync-fake-tls-mod"
        ;;
    *"Invalid argument for dpi-desync-split-http-req"*)
        option="--dpi-desync-split-http-req"
        ;;
    *"Invalid argument for dpi-desync-split-tls"*)
        option="--dpi-desync-split-tls"
        ;;
    *"Invalid argument for dpi-desync-split-seqovl"*)
        option="--dpi-desync-split-seqovl"
        ;;
    *"Invalid argument for dpi-desync-hostfakesplit-midhost"*)
        option="--dpi-desync-hostfakesplit-midhost"
        ;;
    *"dpi-desync-ipfrag-pos-tcp must be within "* | *"dpi-desync-ipfrag-pos-tcp must be multiple of 8"*)
        option="--dpi-desync-ipfrag-pos-tcp"
        ;;
    *"dpi-desync-ipfrag-pos-udp must be within "* | *"dpi-desync-ipfrag-pos-udp must be multiple of 8"*)
        option="--dpi-desync-ipfrag-pos-udp"
        ;;
    *"dpi-desync-ts-increment should be "*)
        option="--dpi-desync-ts-increment"
        ;;
    *"dpi-desync-badseq-increment should be "*)
        option="--dpi-desync-badseq-increment"
        ;;
    *"dpi-desync-badack-increment should be "*)
        option="--dpi-desync-badack-increment"
        ;;
    *"dup-ts-increment should be "*)
        option="--dup-ts-increment"
        ;;
    *"dup-badseq-increment should be "*)
        option="--dup-badseq-increment"
        ;;
    *"dup-badack-increment should be "*)
        option="--dup-badack-increment"
        ;;
    *"bad value for --filter-l3"*)
        option="--filter-l3"
        ;;
    *"auto hostlist fail time is not valid"*)
        option="--hostlist-auto-fail-time"
        ;;
    *"auto hostlist fail threshold must be within 1..20"*)
        option="--hostlist-auto-fail-threshold"
        ;;
    *"auto hostlist fail threshold must be within 2..10"*)
        option="--hostlist-auto-retrans-threshold"
        ;;
    *"dpi-desync-udplen-increment must be integer within "*)
        option="--dpi-desync-udplen-increment"
        ;;
    esac

    printf '%s\n' "$option"
}

collect_nfqws_validation_needles() {
    local summary="$1"
    local option value

    option="$(extract_nfqws_validation_option_hint "$summary")"
    value="$(extract_nfqws_validation_value_hint "$summary")"

    [ -n "$option" ] && printf '%s\n' "$option"
    [ -n "$value" ] && printf '%s\n' "$value"
}

run_nfqws_dry_run_validation() {
    local raw_opt="$1"
    local old_ifs output_file output summary needles rc

    if ! is_zapret_provider_available; then
        return 0
    fi

    raw_opt="$(expand_zapret_nfqws_opt "$raw_opt")"
    raw_opt="$(normalize_nfqws_strategy_whitespace "$raw_opt")"
    [ -n "$raw_opt" ] || return 0

    output_file="$(mktemp)"

    set -f
    old_ifs="$IFS"
    IFS=' '
    set -- $raw_opt
    IFS="$old_ifs"

    "$ZAPRET_NFQWS_BIN" --dry-run --qnum="$ZAPRET_QUEUE_BASE" --dpi-desync-fwmark="$ZAPRET_DESYNC_MARK" "$@" >"$output_file" 2>&1
    rc=$?
    output="$(cat "$output_file")"
    rm -f "$output_file"
    set +f

    [ "$rc" -eq 0 ] && return 0

    summary="$(extract_nfqws_validation_summary "$output")"
    [ -n "$summary" ] || summary="nfqws rejected the strategy during syntax validation."

    needles="$(collect_nfqws_validation_needles "$summary")"
    if [ -n "$needles" ]; then
        # shellcheck disable=SC2086
        set_nfqws_validation_failure "nfqws syntax check failed: $summary" $needles
    else
        set_nfqws_validation_failure "nfqws syntax check failed: $summary"
    fi
}

check_nfqws_strategy() {
    local raw_opt="$1"
    local old_ifs token base_token mode reason display next_token token_count=0

    clear_nfqws_validation_state
    raw_opt="$(normalize_nfqws_strategy_whitespace "$raw_opt")"

    if [ "$raw_opt" = "$ZAPRET_LEGACY_DEFAULT_NFQWS_OPT" ]; then
        return 0
    fi

    set -f
    old_ifs="$IFS"
    IFS=' '
    set -- $raw_opt
    IFS="$old_ifs"

    while [ "$#" -gt 0 ]; do
        token="$1"
        next_token="$2"
        base_token="${token%%=*}"

        if [ "$token_count" -eq 0 ]; then
            case "$token" in
            @* | \$*)
                set_nfqws_validation_failure \
                    "Unsupported NFQWS token '$token': External nfqws config files bypass Podkop Plus validation and queue management." \
                    "$token"
                return 1
                ;;
            esac
        fi

        if reason="$(get_nfqws_unsupported_token_reason "$token")"; then
            display="$token"
            mode="$(nfqws_option_argument_mode "$base_token")"
            if [ "$base_token" = "$token" ] && [ "$mode" = "required" ] && [ "$#" -gt 1 ] && [ "${next_token#--}" = "$next_token" ]; then
                display="$display $next_token"
                set_nfqws_validation_failure "Unsupported NFQWS token '$display': $reason" "$base_token" "$next_token"
                return 1
            fi

            set_nfqws_validation_failure "Unsupported NFQWS token '$display': $reason" "$base_token"
            return 1
        fi

        case "$token" in
        --*)
            mode="$(nfqws_option_argument_mode "$base_token")"
            case "$mode" in
            unknown)
                set_nfqws_validation_failure \
                    "Unknown NFQWS flag '$token'." \
                    "$base_token"
                return 1
                ;;
            none)
                if [ "$base_token" != "$token" ]; then
                    set_nfqws_validation_failure \
                        "NFQWS flag '$base_token' does not accept a value." \
                        "$base_token"
                    return 1
                fi
                shift
                token_count=$((token_count + 1))
                ;;
            optional)
                if [ "$base_token" = "$token" ] && [ "$#" -gt 1 ] && [ "${next_token#--}" = "$next_token" ]; then
                    set_nfqws_validation_failure \
                        "Optional value for '$base_token' must be attached as '$base_token=value'. Separate tokens are ignored by nfqws here." \
                        "$base_token" "$next_token"
                    return 1
                fi
                shift
                token_count=$((token_count + 1))
                ;;
            required)
                if [ "$base_token" != "$token" ]; then
                    shift
                    token_count=$((token_count + 1))
                    continue
                fi

                if [ "$#" -lt 2 ] || [ "${next_token#--}" != "$next_token" ]; then
                    set_nfqws_validation_failure \
                        "NFQWS option '$base_token' requires a value." \
                        "$base_token"
                    return 1
                fi

                shift 2
                token_count=$((token_count + 2))
                ;;
            esac
            ;;
        *)
            set_nfqws_validation_failure \
                "Unexpected standalone NFQWS token '$token'. Use explicit flags such as --name or --name=value." \
                "$token"
            return 1
            ;;
        esac
    done

    set +f

    run_nfqws_dry_run_validation "$raw_opt"
}

validate_nfqws_strategy() {
    local raw_opt="$1"
    local context="$2"

    if ! check_nfqws_strategy "$raw_opt"; then
        log "$context uses invalid NFQWS strategy: $NFQWS_VALIDATE_ERROR Aborted." "fatal"
        exit 1
    fi
}

validate_rule_nfqws_opt() {
    local section="$1"
    local raw_opt

    raw_opt="$(get_rule_nfqws_opt "$section")"
    validate_nfqws_strategy "$raw_opt" "Zapret rule '$section'"
}

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[\/&]/\\&/g'
}

prepare_zapret_runtime() {
    mkdir -p "$ZAPRET_STATE_DIR" "$ZAPRET_PID_DIR" "$ZAPRET_CHILD_PID_DIR" "$ZAPRET_LOG_DIR"
}

is_zapret_provider_available() {
    [ -x "$ZAPRET_PROVIDER_NFQWS_BIN" ]
}

is_zapret_installed() {
    is_zapret_provider_available
}

zapret_package_installed() {
    if command -v apk >/dev/null 2>&1 && apk info -e zapret >/dev/null 2>&1; then
        return 0
    fi

    if command -v opkg >/dev/null 2>&1 && opkg list-installed 2>/dev/null | grep -Eq '^zapret[[:space:]-]'; then
        return 0
    fi

    return 1
}

luci_app_zapret_installed() {
    if command -v apk >/dev/null 2>&1 && apk info -e luci-app-zapret >/dev/null 2>&1; then
        return 0
    fi

    if command -v opkg >/dev/null 2>&1 && opkg list-installed 2>/dev/null | grep -Eq '^luci-app-zapret[[:space:]-]'; then
        return 0
    fi

    [ -f /usr/share/luci/menu.d/luci-app-zapret.json ] ||
        [ -f /usr/share/rpcd/acl.d/luci-app-zapret.json ]
}

zapret_legacy_runtime_path_present() {
    uci -q show "$PODKOP_CONFIG_NAME" 2>/dev/null | grep -Fq "$ZAPRET_LEGACY_RUNTIME_BASE_DIR" && return 0
    [ -d "$ZAPRET_LEGACY_RUNTIME_BASE_DIR" ]
}

rewrite_legacy_zapret_runtime_paths() {
    local provider_path legacy_path

    provider_path="$(escape_sed_replacement "$ZAPRET_PROVIDER_BASE_DIR")"
    legacy_path="$(escape_sed_replacement "$ZAPRET_LEGACY_RUNTIME_BASE_DIR")"

    printf '%s' "$1" | sed "s#${legacy_path}#${provider_path}#g"
}

expand_zapret_nfqws_opt() {
    rewrite_legacy_zapret_runtime_paths "$1"
}

check_zapret_requirements() {
    cleanup_legacy_zapret_runtime
    has_enabled_zapret_rules || return 0

    if ! is_zapret_provider_available; then
        log "Zapret provider is not available at $ZAPRET_PROVIDER_NFQWS_BIN. Rules with action 'zapret' will be skipped until the zapret provider is installed." "error"
        return 0
    fi

    if ! prepare_zapret_runtime; then
        log "Failed to prepare the Podkop Plus zapret state directory in $ZAPRET_STATE_DIR. Aborted." "fatal"
        exit 1
    fi
}

get_zapret_package_version() {
    local version=""

    if command -v apk >/dev/null 2>&1 && apk info -e zapret >/dev/null 2>&1; then
        version="$(get_apk_installed_package_version "zapret")"
    elif command -v opkg >/dev/null 2>&1; then
        version="$(opkg list-installed 2>/dev/null | awk '$1 == "zapret" { print $3; exit }')"
    fi

    if [ -z "$version" ] && [ -x "$ZAPRET_PROVIDER_NFQWS_BIN" ]; then
        version="$("$ZAPRET_PROVIDER_NFQWS_BIN" --version 2>/dev/null | sed -n '1s/^.*version[[:space:]]*//p' | awk '{ print $1; exit }')"
    fi

    echo "$version"
}

is_zapret_standalone_service_enabled() {
    [ -x /etc/init.d/zapret ] || return 1
    /etc/init.d/zapret enabled >/dev/null 2>&1
}

is_zapret_standalone_service_running() {
    [ -x /etc/init.d/zapret ] || return 1
    /etc/init.d/zapret status >/dev/null 2>&1
}

zapret_standalone_uci_config_present() {
    [ -f /etc/config/zapret ] || return 1
    uci -q get zapret.config >/dev/null 2>&1
}

stop_legacy_zapret_runtime_processes() {
    local pid

    ps w 2>/dev/null | grep -F "$ZAPRET_LEGACY_RUNTIME_BASE_DIR/nfq/nfqws" | grep -v grep | awk '{ print $1 }' | while read -r pid; do
        [ -n "$pid" ] || continue
        kill "$pid" 2>/dev/null || true
    done
}

cleanup_legacy_zapret_runtime() {
    stop_legacy_zapret_runtime_processes
    rm -rf "$ZAPRET_LEGACY_RUNTIME_BASE_DIR"
}

get_zapret_nfqws_process_count() {
    local count=0 pidfile pid

    [ -d "$ZAPRET_CHILD_PID_DIR" ] || {
        echo 0
        return 0
    }

    for pidfile in "$ZAPRET_CHILD_PID_DIR"/*.pid; do
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

get_zapret_supervisor_process_count() {
    local count=0 pidfile pid

    [ -d "$ZAPRET_PID_DIR" ] || {
        echo 0
        return 0
    }

    for pidfile in "$ZAPRET_PID_DIR"/*.pid; do
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

get_zapret_queue_range_end() {
    echo $((ZAPRET_QUEUE_BASE + ZAPRET_QUEUE_RANGE_SIZE - 1))
}

zapret_external_queue_overlap_present() {
    local range_end

    range_end="$(get_zapret_queue_range_end)"
    nft list ruleset 2>/dev/null | awk \
        -v own_table="$NFT_TABLE_NAME" \
        -v range_start="$ZAPRET_QUEUE_BASE" \
        -v range_end="$range_end" '
        function token_queue_overlap(token, first, last, parts) {
            gsub(/[{},;]/, "", token)
            if (token !~ /^[0-9]+(-[0-9]+)?$/) {
                return 0
            }

            split(token, parts, "-")
            first = parts[1] + 0
            last = (parts[2] == "" ? first : parts[2] + 0)

            return first <= range_end && last >= range_start
        }
        $1 == "table" {
            in_own_table = ($2 == "inet" && $3 == own_table)
        }
        !in_own_table {
            for (i = 1; i <= NF; i++) {
                if ($i != "queue") {
                    continue
                }

                for (j = i + 1; j <= NF; j++) {
                    if (($j == "num" || $j == "to") && token_queue_overlap($(j + 1))) {
                        found = 1
                    } else if (token_queue_overlap($j)) {
                        found = 1
                    }
                }
            }
        }
        END { exit(found ? 0 : 1) }
    '
}

zapret_standalone_conflict_present() {
    has_enabled_zapret_rules || return 1
    is_zapret_standalone_service_running
}

zapret_rule_outbound_present() {
    local section="$1"
    local routing_mark="$2"
    local outbound_tag

    [ -f "$ZAPRET_SINGBOX_CONFIG_PATH" ] || return 1

    outbound_tag="$(get_outbound_tag_by_section "$section")"

    jq -e \
        --arg tag "$outbound_tag" \
        --argjson routing_mark "$routing_mark" \
        '.outbounds[]? |
            select(.type == "direct" and .tag == $tag and (.routing_mark // empty) == $routing_mark)' \
        "$ZAPRET_SINGBOX_CONFIG_PATH" >/dev/null 2>&1
}

zapret_rule_route_rule_present() {
    local section="$1"
    local outbound_tag

    [ -f "$ZAPRET_SINGBOX_CONFIG_PATH" ] || return 1

    outbound_tag="$(get_outbound_tag_by_section "$section")"

    jq -e \
        --arg inbound "$SB_TPROXY_INBOUND_TAG" \
        --arg outbound "$outbound_tag" \
        '.route.rules[]? |
            select(.action == "route" and .inbound == $inbound and .outbound == $outbound)' \
        "$ZAPRET_SINGBOX_CONFIG_PATH" >/dev/null 2>&1
}

_collect_zapret_runtime_status_handler() {
    local section="$1"
    local index mark_value

    rule_is_enabled "$section" || return 0
    [ "$(get_rule_action "$section")" = "zapret" ] || return 0

    ZAPRET_RUNTIME_RULES_CONFIGURED=1
    index="$(get_zapret_rule_index "$section")"
    mark_value="$(get_zapret_rule_mark_value "$index")"

    if ! zapret_rule_outbound_present "$section" "$mark_value"; then
        ZAPRET_RUNTIME_OUTBOUNDS_CONFIGURED=0
    fi

    if ! zapret_rule_route_rule_present "$section"; then
        ZAPRET_RUNTIME_ROUTES_CONFIGURED=0
    fi
}

collect_zapret_runtime_status() {
    local sing_box_config_path

    ZAPRET_RUNTIME_RULES_CONFIGURED=0
    ZAPRET_RUNTIME_OUTBOUNDS_CONFIGURED=1
    ZAPRET_RUNTIME_ROUTES_CONFIGURED=1

    config_get sing_box_config_path "settings" "config_path"
    ZAPRET_SINGBOX_CONFIG_PATH="$sing_box_config_path"
    config_foreach _collect_zapret_runtime_status_handler "section"

    if [ "$ZAPRET_RUNTIME_RULES_CONFIGURED" -eq 0 ]; then
        ZAPRET_RUNTIME_OUTBOUNDS_CONFIGURED=0
        ZAPRET_RUNTIME_ROUTES_CONFIGURED=0
    fi
}

get_zapret_status_json() {
    local installed=0 package_installed=0 provider_available=0 files_available=0 ipset_available=0 configured=0
    local standalone_service_enabled=0 standalone_service_running=0 standalone_config_present=0 ready=0 conflict=0
    local queue_overlap=0 standalone_conflict=0 legacy_runtime_present=0 luci_app_installed=0
    local enabled_rule_count expected_process_count running_process_count supervisor_process_count version queue_range_end status_message
    local outbounds_configured=0 routes_configured=0

    enabled_rule_count="$(get_zapret_rule_count)"
    expected_process_count="${enabled_rule_count:-0}"
    running_process_count="$(get_zapret_nfqws_process_count)"
    supervisor_process_count="$(get_zapret_supervisor_process_count)"
    queue_range_end="$(get_zapret_queue_range_end)"
    version="not installed"
    status_message=""

    if [ "${enabled_rule_count:-0}" -gt 0 ]; then
        configured=1
    fi

    if zapret_package_installed; then
        package_installed=1
        version="$(get_zapret_package_version)"
        [ -n "$version" ] || version="unknown"
    fi

    if [ -d "$ZAPRET_PROVIDER_FILES_DIR" ]; then
        files_available=1
    fi

    if [ -d "$ZAPRET_PROVIDER_IPSET_DIR" ]; then
        ipset_available=1
    fi

    if is_zapret_provider_available; then
        provider_available=1
        installed=1
        if [ "$package_installed" -eq 0 ]; then
            version="$(get_zapret_package_version)"
            [ -n "$version" ] || version="unknown"
        fi
    fi

    if is_zapret_standalone_service_enabled; then
        standalone_service_enabled=1
    fi

    if is_zapret_standalone_service_running; then
        standalone_service_running=1
    fi

    if zapret_standalone_uci_config_present; then
        standalone_config_present=1
    fi

    if zapret_external_queue_overlap_present; then
        queue_overlap=1
    fi

    if zapret_standalone_conflict_present; then
        standalone_conflict=1
    fi

    if zapret_legacy_runtime_path_present; then
        legacy_runtime_present=1
    fi

    if luci_app_zapret_installed; then
        luci_app_installed=1
    fi

    collect_zapret_runtime_status
    outbounds_configured="${ZAPRET_RUNTIME_OUTBOUNDS_CONFIGURED:-0}"
    routes_configured="${ZAPRET_RUNTIME_ROUTES_CONFIGURED:-0}"

    if [ "${running_process_count:-0}" -gt "${expected_process_count:-0}" ] ||
        [ "$queue_overlap" -eq 1 ] ||
        [ "$legacy_runtime_present" -eq 1 ]; then
        conflict=1
    fi

    if [ "$configured" -eq 1 ] &&
        [ "$provider_available" -eq 1 ] &&
        [ "$conflict" -eq 0 ] &&
        [ "$outbounds_configured" -eq 1 ] &&
        [ "$routes_configured" -eq 1 ] &&
        [ "${expected_process_count:-0}" -gt 0 ] &&
        [ "${running_process_count:-0}" -eq "${expected_process_count:-0}" ]; then
        ready=1
    fi

    if [ "$configured" -eq 1 ] && [ "$provider_available" -eq 0 ]; then
        status_message="action=zapret is configured, but zapret provider is not available at $ZAPRET_PROVIDER_NFQWS_BIN"
    elif [ "$queue_overlap" -eq 1 ]; then
        status_message="external NFQUEUE rules overlap with the Podkop Plus zapret range $ZAPRET_QUEUE_BASE-$queue_range_end"
    elif [ "$legacy_runtime_present" -eq 1 ]; then
        status_message="legacy zapret runtime paths are still present and should be migrated"
    elif [ "${running_process_count:-0}" -gt "${expected_process_count:-0}" ] ||
        [ "${supervisor_process_count:-0}" -gt "${expected_process_count:-0}" ]; then
        status_message="unexpected Podkop Plus-managed nfqws processes are running without matching action=zapret rules"
    elif [ "$configured" -eq 1 ] && [ "$ready" -eq 0 ]; then
        status_message="action=zapret is configured, but the Podkop Plus-managed nfqws runtime is not ready"
    elif [ "$standalone_conflict" -eq 1 ]; then
        status_message="standalone zapret is active together with Podkop Plus action=zapret; queues are separate, but packet-level policy overlap is possible"
    elif [ "$configured" -eq 0 ] && [ "$provider_available" -eq 0 ] && [ "$package_installed" -eq 1 ]; then
        status_message="zapret package is installed, but the provider binary is not available at $ZAPRET_PROVIDER_NFQWS_BIN"
    elif [ "$configured" -eq 0 ] && [ "$provider_available" -eq 0 ]; then
        status_message="zapret provider is not installed; action=zapret is unavailable"
    else
        status_message="zapret provider status is normal"
    fi

    jq -cn \
        --arg version "$version" \
        --arg provider_path "$ZAPRET_PROVIDER_NFQWS_BIN" \
        --arg status_message "$status_message" \
        --argjson installed "$installed" \
        --argjson package_installed "$package_installed" \
        --argjson provider_available "$provider_available" \
        --argjson files_available "$files_available" \
        --argjson ipset_available "$ipset_available" \
        --argjson configured "$configured" \
        --argjson enabled_rule_count "${enabled_rule_count:-0}" \
        --argjson expected_process_count "${expected_process_count:-0}" \
        --argjson running_process_count "${running_process_count:-0}" \
        --argjson supervisor_process_count "${supervisor_process_count:-0}" \
        --argjson standalone_service_enabled "$standalone_service_enabled" \
        --argjson standalone_service_running "$standalone_service_running" \
        --argjson standalone_config_present "$standalone_config_present" \
        --argjson standalone_conflict "$standalone_conflict" \
        --argjson luci_app_installed "$luci_app_installed" \
        --argjson queue_base "$ZAPRET_QUEUE_BASE" \
        --argjson queue_range_end "$queue_range_end" \
        --argjson queue_overlap "$queue_overlap" \
        --argjson legacy_runtime_present "$legacy_runtime_present" \
        --argjson ready "$ready" \
        --argjson conflict "$conflict" \
        '{
            installed: $installed,
            package_installed: $package_installed,
            provider_available: $provider_available,
            provider_path: $provider_path,
            files_available: $files_available,
            ipset_available: $ipset_available,
            version: $version,
            configured: $configured,
            enabled_rule_count: $enabled_rule_count,
            expected_process_count: $expected_process_count,
            running_process_count: $running_process_count,
            supervisor_process_count: $supervisor_process_count,
            standalone_service_enabled: $standalone_service_enabled,
            standalone_service_running: $standalone_service_running,
            standalone_config_present: $standalone_config_present,
            standalone_conflict: $standalone_conflict,
            luci_app_installed: $luci_app_installed,
            queue_base: $queue_base,
            queue_range_end: $queue_range_end,
            queue_overlap: $queue_overlap,
            legacy_runtime_present: $legacy_runtime_present,
            ready: $ready,
            conflict: $conflict,
            status_message: $status_message
        }'
}

check_zapret_runtime_json() {
    local installed=0 package_installed=0

    if is_zapret_provider_available; then
        installed=1
    fi

    if zapret_package_installed; then
        package_installed=1
    fi

    jq -cn \
        --argjson zapret_installed "$installed" \
        --argjson zapret_package_installed "$package_installed" \
        --arg zapret_provider_path "$ZAPRET_PROVIDER_NFQWS_BIN" \
        '{
            zapret_installed: $zapret_installed,
            zapret_package_installed: $zapret_package_installed,
            zapret_provider_path: $zapret_provider_path
        }'
}

_create_zapret_nft_rule_handler() {
    local section="$1"
    local index mark_hex queue_number

    rule_is_enabled "$section" || return 0
    [ "$(get_rule_action "$section")" = "zapret" ] || return 0

    index="$(get_zapret_rule_index "$section")"
    mark_hex="$(get_zapret_rule_mark_hex "$index")"
    queue_number="$(get_zapret_rule_queue_number "$index")"

    nft add rule inet "$NFT_TABLE_NAME" mangle_output meta mark "$mark_hex" meta l4proto tcp \
        counter queue num "$queue_number" bypass
    nft add rule inet "$NFT_TABLE_NAME" mangle_output meta mark "$mark_hex" meta l4proto udp \
        counter queue num "$queue_number" bypass
}

create_zapret_nft_rules() {
    has_enabled_zapret_rules || return 0
    is_zapret_installed || return 0

    nft add rule inet "$NFT_TABLE_NAME" mangle_output meta mark \& "$ZAPRET_DESYNC_MARK" == "$ZAPRET_DESYNC_MARK" return
    nft add rule inet "$NFT_TABLE_NAME" mangle_output meta mark \& "$ZAPRET_DESYNC_MARK_POSTNAT" == "$ZAPRET_DESYNC_MARK_POSTNAT" return
    config_foreach _create_zapret_nft_rule_handler "section"
}

stop_zapret_pidfile_process() {
    local pidfile="$1"
    local pid

    [ -f "$pidfile" ] || return 0
    pid="$(cat "$pidfile" 2>/dev/null)"
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null || true
}

kill_zapret_pidfile_process() {
    local pidfile="$1"
    local pid

    [ -f "$pidfile" ] || return 0
    pid="$(cat "$pidfile" 2>/dev/null)"
    [ -n "$pid" ] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    kill -9 "$pid" 2>/dev/null || true
}

stop_zapret_runtime() {
    local pidfile

    if [ -d "$ZAPRET_PID_DIR" ]; then
        for pidfile in "$ZAPRET_PID_DIR"/*.pid; do
            stop_zapret_pidfile_process "$pidfile"
        done
    fi

    if [ -d "$ZAPRET_CHILD_PID_DIR" ]; then
        for pidfile in "$ZAPRET_CHILD_PID_DIR"/*.pid; do
            stop_zapret_pidfile_process "$pidfile"
        done
    fi

    sleep 1

    if [ -d "$ZAPRET_PID_DIR" ]; then
        for pidfile in "$ZAPRET_PID_DIR"/*.pid; do
            kill_zapret_pidfile_process "$pidfile"
        done
    fi

    if [ -d "$ZAPRET_CHILD_PID_DIR" ]; then
        for pidfile in "$ZAPRET_CHILD_PID_DIR"/*.pid; do
            kill_zapret_pidfile_process "$pidfile"
        done
    fi

    rm -rf "$ZAPRET_PID_DIR" "$ZAPRET_CHILD_PID_DIR" "$ZAPRET_LOG_DIR" "$ZAPRET_HOSTLIST_DIR" "$ZAPRET_LEGACY_RUNTIME_BASE_DIR"
}

run_zapret_nfqws_supervisor() {
    local section="$1"
    local queue_number="$2"
    local expanded_opt="$3"
    local child_pidfile="$4"
    local child_pid="" old_ifs rc

    trap 'rm -f "$child_pidfile"; [ -n "$child_pid" ] && kill "$child_pid" 2>/dev/null; [ -n "$child_pid" ] && wait "$child_pid" 2>/dev/null; exit 0' TERM INT

    while :; do
        if [ ! -x "$ZAPRET_NFQWS_BIN" ]; then
            printf '%s Provider %s is not executable; retrying in %s seconds\n' \
                "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$ZAPRET_NFQWS_BIN" "$ZAPRET_NFQWS_RESPAWN_DELAY"
            sleep "$ZAPRET_NFQWS_RESPAWN_DELAY" &
            child_pid="$!"
            wait "$child_pid"
            child_pid=""
            continue
        fi

        set -f
        old_ifs="$IFS"
        IFS=' '
        set -- $expanded_opt
        IFS="$old_ifs"

        "$ZAPRET_NFQWS_BIN" --qnum="$queue_number" --dpi-desync-fwmark="$ZAPRET_DESYNC_MARK" "$@" &
        child_pid="$!"
        echo "$child_pid" > "$child_pidfile"
        wait "$child_pid"
        rc="$?"
        rm -f "$child_pidfile"
        child_pid=""
        set +f

        printf '%s nfqws for rule %s exited with code %s; respawning in %s seconds\n' \
            "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$section" "$rc" "$ZAPRET_NFQWS_RESPAWN_DELAY"
        sleep "$ZAPRET_NFQWS_RESPAWN_DELAY" &
        child_pid="$!"
        wait "$child_pid"
        child_pid=""
    done
}

_start_zapret_runtime_handler() {
    local section="$1"
    local index queue_number mark_hex raw_opt expanded_opt pidfile child_pidfile logfile pid child_pid

    rule_is_enabled "$section" || return 0
    [ "$(get_rule_action "$section")" = "zapret" ] || return 0

    index="$(get_zapret_rule_index "$section")"
    queue_number="$(get_zapret_rule_queue_number "$index")"
    mark_hex="$(get_zapret_rule_mark_hex "$index")"
    raw_opt="$(get_rule_nfqws_opt "$section")"
    expanded_opt="$(expand_zapret_nfqws_opt "$raw_opt" "$section")"
    pidfile="$ZAPRET_PID_DIR/$section.pid"
    child_pidfile="$ZAPRET_CHILD_PID_DIR/$section.pid"
    logfile="$ZAPRET_LOG_DIR/$section.log"

    log "Starting nfqws for rule '$section' on queue $queue_number with mark $mark_hex"
    (close_inherited_service_lock_fd; run_zapret_nfqws_supervisor "$section" "$queue_number" "$expanded_opt" "$child_pidfile") >>"$logfile" 2>&1 &
    pid="$!"
    echo "$pid" > "$pidfile"
    sleep 1

    if ! kill -0 "$pid" 2>/dev/null; then
        log "nfqws failed to start for rule '$section'. Check $logfile. Aborted." "fatal"
        exit 1
    fi

    child_pid="$(cat "$child_pidfile" 2>/dev/null)"
    if [ -z "$child_pid" ] || ! kill -0 "$child_pid" 2>/dev/null; then
        log "nfqws supervisor started for rule '$section', but nfqws is not running yet. Check $logfile." "warn"
    fi
}

start_zapret_runtime() {
    stop_zapret_runtime

    has_enabled_zapret_rules || return 0
    is_zapret_provider_available || return 0

    check_zapret_requirements
    mkdir -p "$ZAPRET_PID_DIR" "$ZAPRET_CHILD_PID_DIR" "$ZAPRET_LOG_DIR"
    config_foreach _start_zapret_runtime_handler "section"
}
