# shellcheck shell=ash

subscription_url_decode() {
    case "$1" in
    *%* | *+*) url_decode "$1" ;;
    *) printf '%s\n' "$1" ;;
    esac
}

subscription_url_get_fragment() {
    local url="$1"

    case "$url" in
    *'#'*) subscription_url_decode "${url#*#}" ;;
    *) printf '\n' ;;
    esac
}

subscription_base64_decode_string() {
    local raw="$1"
    local normalized remainder padding

    normalized="$(printf '%s' "$raw" | tr -d '\r\n\t ' | tr '_-' '/+')"
    remainder=$(( ${#normalized} % 4 ))
    padding=""
    case "$remainder" in
    2) padding="==" ;;
    3) padding="=" ;;
    1) return 1 ;;
    esac

    printf '%s' "${normalized}${padding}" | base64 -d 2>/dev/null
}

subscription_try_base64_decode_file() {
    local input="$1"
    local output="$2"
    local compact decoded_tmp

    compact="$(tr -d '\r\n\t ' < "$input")"
    [ -n "$compact" ] || return 1

    decoded_tmp="$(mktemp)" || return 1
    if subscription_base64_decode_string "$compact" > "$decoded_tmp" && [ -s "$decoded_tmp" ]; then
        mv "$decoded_tmp" "$output"
        return 0
    fi

    rm -f "$decoded_tmp"
    return 1
}

subscription_metadata_headers_json() {
    local input="$1"

    [ -s "$input" ] || {
        printf '{}\n'
        return 0
    }

    awk '
    function trim(s) {
        gsub(/^[ \t\r\n]+/, "", s)
        gsub(/[ \t\r\n]+$/, "", s)
        return s
    }
    function allowed(k) {
        return k == "profile-title" ||
            k == "subscription-userinfo" ||
            k == "profile-web-page-url" ||
            k == "support-url" ||
            k == "announce" ||
            k == "announce-url" ||
            k == "subscription-refill-date" ||
            k == "content-disposition"
    }
    function json_escape(s) {
        gsub(/\\/, "\\\\", s)
        gsub(/"/, "\\\"", s)
        gsub(/\t/, "\\t", s)
        gsub(/\r/, "", s)
        return s
    }
    {
        line = trim($0)
        colon = index(line, ":")
        if (colon <= 1) {
            next
        }

        key = tolower(trim(substr(line, 1, colon - 1)))
        value = trim(substr(line, colon + 1))
        if (!allowed(key) || value == "") {
            next
        }

        if (!(key in seen)) {
            order[++count] = key
        }
        seen[key] = 1
        values[key] = value
    }
    END {
        printf "{"
        sep = ""
        for (i = 1; i <= count; i++) {
            key = order[i]
            if (key in values) {
                printf "%s\"%s\":\"%s\"", sep, key, json_escape(values[key])
                sep = ","
            }
        }
        printf "}\n"
    }
    ' "$input"
}

subscription_metadata_body_json_from_file() {
    local input="$1"

    [ -s "$input" ] || {
        printf '{}\n'
        return 0
    }

    awk '
    function trim(s) {
        gsub(/^[ \t\r\n]+/, "", s)
        gsub(/[ \t\r\n]+$/, "", s)
        return s
    }
    function allowed(k) {
        return k == "profile-title" ||
            k == "subscription-userinfo" ||
            k == "profile-web-page-url" ||
            k == "support-url" ||
            k == "announce" ||
            k == "announce-url" ||
            k == "subscription-refill-date" ||
            k == "content-disposition"
    }
    function json_escape(s) {
        gsub(/\\/, "\\\\", s)
        gsub(/"/, "\\\"", s)
        gsub(/\t/, "\\t", s)
        gsub(/\r/, "", s)
        return s
    }
    NR > 20 {
        exit
    }
    {
        line = trim($0)
        if (line ~ /^#/) {
            sub(/^#[ \t]*/, "", line)
        } else if (line ~ /^\/\//) {
            sub(/^\/\/[ \t]*/, "", line)
        } else {
            next
        }

        colon = index(line, ":")
        if (colon <= 1) {
            next
        }

        key = tolower(trim(substr(line, 1, colon - 1)))
        value = trim(substr(line, colon + 1))
        if (!allowed(key) || value == "") {
            next
        }

        if (!(key in seen)) {
            order[++count] = key
        }
        seen[key] = 1
        values[key] = value
    }
    END {
        printf "{"
        sep = ""
        for (i = 1; i <= count; i++) {
            key = order[i]
            if (key in values) {
                printf "%s\"%s\":\"%s\"", sep, key, json_escape(values[key])
                sep = ","
            }
        }
        printf "}\n"
    }
    ' "$input"
}

subscription_metadata_body_json() {
    local input="$1"
    local raw_json decoded_tmp decoded_json

    raw_json="$(subscription_metadata_body_json_from_file "$input")"
    if [ "$raw_json" != "{}" ]; then
        printf '%s\n' "$raw_json"
        return 0
    fi

    decoded_tmp="$(mktemp)" || {
        printf '{}\n'
        return 0
    }

    if subscription_try_base64_decode_file "$input" "$decoded_tmp"; then
        decoded_json="$(subscription_metadata_body_json_from_file "$decoded_tmp")"
        rm -f "$decoded_tmp"
        printf '%s\n' "$decoded_json"
        return 0
    fi

    rm -f "$decoded_tmp"
    printf '{}\n'
}

subscription_metadata_trim() {
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

subscription_metadata_lower() {
    awk '{ print tolower($0) }'
}

subscription_metadata_clean_text() {
    local value="$1"
    local max="$2"
    local mode="${3:-plain}"
    local prefix cleaned

    if [ "$mode" = "base64" ]; then
        prefix="$(printf '%s' "$value" | cut -c 1-7 | subscription_metadata_lower)"
        if [ "$prefix" = "base64:" ]; then
            value="$(subscription_base64_decode_string "$(printf '%s' "$value" | cut -c 8-)" 2>/dev/null || printf '')"
        fi
    fi

    cleaned="$(
        printf '%s' "$value" |
            tr '\000-\037\177' ' ' |
            sed 's/[[:space:]][[:space:]]*/ /g;s/^[[:space:]]*//;s/[[:space:]]*$//'
    )"

    [ -n "$cleaned" ] || return 1
    if [ "${#cleaned}" -gt "$max" ]; then
        cleaned="$(printf '%s' "$cleaned" | cut -c "1-$max")"
    fi

    printf '%s\n' "$cleaned"
}

subscription_metadata_clean_url() {
    local value cleaned

    value="$1"
    cleaned="$(printf '%s' "$value" | subscription_metadata_trim)"
    [ -n "$cleaned" ] || return 1
    [ "${#cleaned}" -le 2048 ] || return 1

    case "$cleaned" in
    http://* | https://*) ;;
    *) return 1 ;;
    esac

    if printf '%s' "$cleaned" | grep -q '[[:cntrl:][:space:]]'; then
        return 1
    fi

    printf '%s\n' "$cleaned"
}

subscription_metadata_clean_number() {
    local value

    value="$(printf '%s' "$1" | subscription_metadata_trim)"
    case "$value" in
    "" | *[!0-9]*) return 1 ;;
    esac

    printf '%s\n' "$value"
}

subscription_metadata_content_disposition_filename() {
    local value filename

    value="$1"
    case "$value" in
    *filename=\"*)
        filename="${value#*filename=\"}"
        filename="${filename%%\"*}"
        ;;
    *filename=*)
        filename="${value#*filename=}"
        filename="${filename%%;*}"
        filename="${filename#\"}"
        filename="${filename%\"}"
        ;;
    *)
        return 1
        ;;
    esac

    filename="$(subscription_metadata_clean_text "$filename" 120 plain)" || return 1
    filename="$(printf '%s' "$filename" | tr '/\\' '__')"
    [ -n "$filename" ] || return 1
    printf '%s\n' "$filename"
}

subscription_metadata_raw_value() {
    local raw_json="$1"
    local key="$2"

    printf '%s\n' "$raw_json" | subscription_json_utils_ucode object-get "$key" 2>/dev/null
}

subscription_normalize_ui_metadata_json() {
    local raw_json="$1"
    local title web_page_url support_url announce announce_url refill_date file_name
    local userinfo item key value upload download total expire has_traffic used remaining is_unlimited
    local upload_json download_json total_json expire_json refill_date_json remaining_json

    title="$(subscription_metadata_clean_text "$(subscription_metadata_raw_value "$raw_json" "profile-title")" 120 base64 2>/dev/null || true)"
    web_page_url="$(subscription_metadata_clean_url "$(subscription_metadata_raw_value "$raw_json" "profile-web-page-url")" 2>/dev/null || true)"
    support_url="$(subscription_metadata_clean_url "$(subscription_metadata_raw_value "$raw_json" "support-url")" 2>/dev/null || true)"
    announce="$(subscription_metadata_clean_text "$(subscription_metadata_raw_value "$raw_json" "announce")" 500 base64 2>/dev/null || true)"
    announce_url="$(subscription_metadata_clean_url "$(subscription_metadata_raw_value "$raw_json" "announce-url")" 2>/dev/null || true)"
    refill_date="$(subscription_metadata_clean_number "$(subscription_metadata_raw_value "$raw_json" "subscription-refill-date")" 2>/dev/null || true)"
    file_name="$(subscription_metadata_content_disposition_filename "$(subscription_metadata_raw_value "$raw_json" "content-disposition")" 2>/dev/null || true)"

    userinfo="$(subscription_metadata_raw_value "$raw_json" "subscription-userinfo")"
    upload=""
    download=""
    total=""
    expire=""

    while IFS= read -r item || [ -n "$item" ]; do
        item="$(printf '%s' "$item" | subscription_metadata_trim)"
        case "$item" in
        *=*) ;;
        *) continue ;;
        esac

        key="$(printf '%s' "${item%%=*}" | subscription_metadata_trim | subscription_metadata_lower)"
        value="$(subscription_metadata_clean_number "${item#*=}" 2>/dev/null || true)"
        [ -n "$value" ] || continue

        case "$key" in
        upload) upload="$value" ;;
        download) download="$value" ;;
        total) total="$value" ;;
        expire) expire="$value" ;;
        esac
    done <<EOF
$(printf '%s' "$userinfo" | tr ';' '\n')
EOF

    has_traffic=false
    [ -n "$upload$download$total$expire" ] && has_traffic=true

    upload_json="${upload:-null}"
    download_json="${download:-null}"
    total_json="${total:-null}"
    expire_json="${expire:-null}"
    refill_date_json="${refill_date:-null}"

    used=$(( ${upload:-0} + ${download:-0} ))
    remaining_json="null"
    is_unlimited=true
    if [ -n "$total" ] && [ "$total" -gt 0 ]; then
        is_unlimited=false
        remaining=$((total - used))
        [ "$remaining" -lt 0 ] && remaining=0
        remaining_json="$remaining"
    fi

    subscription_json_utils_ucode subscription-ui-metadata \
        "$title" \
        "$web_page_url" \
        "$support_url" \
        "$announce" \
        "$announce_url" \
        "$file_name" \
        "$has_traffic" \
        "$upload_json" \
        "$download_json" \
        "$used" \
        "$total_json" \
        "$remaining_json" \
        "$is_unlimited" \
        "$expire_json" \
        "$refill_date_json"
}

subscription_extract_ui_metadata() {
    local headers_file="$1"
    local body_file="$2"
    local output="$3"
    local headers_json body_json raw_json metadata_json headers_tmp body_tmp status

    headers_json="$(subscription_metadata_headers_json "$headers_file")" || headers_json="{}"
    body_json="$(subscription_metadata_body_json "$body_file")" || body_json="{}"

    body_tmp="$(mktemp)" || {
        rm -f "$output"
        return 1
    }
    headers_tmp="$(mktemp)" || {
        rm -f "$body_tmp" "$output"
        return 1
    }
    printf '%s' "$body_json" > "$body_tmp" || {
        rm -f "$body_tmp" "$headers_tmp" "$output"
        return 1
    }
    printf '%s' "$headers_json" > "$headers_tmp" || {
        rm -f "$body_tmp" "$headers_tmp" "$output"
        return 1
    }

    raw_json="$(subscription_json_utils_ucode objects-merge "$body_tmp" "$headers_tmp" 2>/dev/null)"
    status=$?
    rm -f "$body_tmp" "$headers_tmp"
    if [ "$status" -ne 0 ] || [ -z "$raw_json" ]; then
        rm -f "$output"
        return 1
    fi

    metadata_json="$(subscription_normalize_ui_metadata_json "$raw_json")" || metadata_json=""
    if [ -n "$metadata_json" ]; then
        printf '%s\n' "$metadata_json" > "$output"
        return 0
    fi

    rm -f "$output"
    return 1
}

subscription_parser_ucode() {
    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/subscription_parser.uc" "$@"
}

subscription_json_utils_ucode() {
    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/json_utils.uc" "$@"
}

subscription_validate_normalized_file() {
    local output="$1"

    subscription_json_utils_ucode validate-subscription "$output" >/dev/null 2>&1
}

subscription_log_normalized_skipped() {
    local output="$1"
    local skipped format message

    skipped="$(subscription_json_utils_ucode json-file-field "$output" "skipped" "0" 2>/dev/null)"
    case "$skipped" in
    '' | *[!0-9]*) skipped=0 ;;
    esac
    [ "$skipped" -gt 0 ] || return 0

    format="$(subscription_json_utils_ucode json-file-field "$output" "format" "" 2>/dev/null)"
    case "$format" in
    clash-yaml)
        message="Skipped $skipped invalid or unsupported Clash proxy entries"
        ;;
    *)
        message="Skipped $skipped invalid or unsupported subscription links"
        ;;
    esac
    log "$message" "warn"
}

subscription_normalize_content_file() {
    local input="$1"
    local output="$2"

    if subscription_parser_ucode normalize-content "$input" "$output"; then
        subscription_log_normalized_skipped "$output"
        subscription_validate_normalized_file "$output"
        return $?
    fi

    return 1
}

subscription_runtime_outbounds_equal() {
    local left="$1"
    local right="$2"

    subscription_parser_ucode runtime-outbounds-equal "$left" "$right" >/dev/null 2>&1
}

normalize_subscription_file() {
    local input="$1"
    local output="$2"
    local section="$3"
    local tmp_output

    tmp_output="$(mktemp)" || return 1
    if ! subscription_normalize_content_file "$input" "$tmp_output"; then
        log "Subscription for rule '$section' has no supported proxy entries" "error"
        rm -f "$tmp_output"
        return 1
    fi

    mv "$tmp_output" "$output"
}
