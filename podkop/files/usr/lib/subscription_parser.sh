# shellcheck shell=ash

subscription_content_has_share_links() {
    grep -Eq '^[[:space:]]*(ss|vmess|vless|trojan|hysteria2|hy2|socks4|socks4a|socks5)://' "$1"
}

subscription_content_is_clash_yaml() {
    grep -Eq '^[[:space:]]*proxies:[[:space:]]*($|#)' "$1"
}

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

subscription_url_get_query_param() {
    local url="$1"
    local param="$2"
    local query pair key value

    case "$url" in
    *\?*) query="${url#*\?}" ;;
    *)
        printf '\n'
        return 0
        ;;
    esac
    query="${query%%#*}"

    while [ -n "$query" ]; do
        case "$query" in
        *'&'*)
            pair="${query%%&*}"
            query="${query#*&}"
            ;;
        *)
            pair="$query"
            query=""
            ;;
        esac

        key="${pair%%=*}"
        [ "$key" = "$param" ] || continue

        value="${pair#*=}"
        [ "$value" != "$pair" ] || value=""
        subscription_url_decode "$value"
        return 0
    done

    printf '\n'
}

subscription_bool_is_true() {
    case "$1" in
    1 | true | TRUE | True | yes | YES | on | ON)
        return 0
        ;;
    esac

    return 1
}

subscription_bool_json() {
    if subscription_bool_is_true "$1"; then
        printf 'true'
    else
        printf 'false'
    fi
}

subscription_normalize_utls_fingerprint() {
    case "$1" in
    "" | chrome | firefox | edge | safari | 360 | ios | android | randomized | randomizedalpn | randomizednoalpn)
        printf '%s' "$1"
        ;;
    *)
        printf 'chrome'
        ;;
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

    printf '%s\n' "$raw_json" | jq -r --arg key "$key" '.[$key] // empty' 2>/dev/null
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

    jq -cn \
        --arg title "$title" \
        --arg webPageUrl "$web_page_url" \
        --arg supportUrl "$support_url" \
        --arg announce "$announce" \
        --arg announceUrl "$announce_url" \
        --arg fileName "$file_name" \
        --argjson hasTraffic "$has_traffic" \
        --argjson upload "$upload_json" \
        --argjson download "$download_json" \
        --argjson used "$used" \
        --argjson total "$total_json" \
        --argjson remaining "$remaining_json" \
        --argjson isUnlimited "$is_unlimited" \
        --argjson expire "$expire_json" \
        --argjson refillDate "$refill_date_json" '
        {
            version: 1
        }
        + (if $title != "" then {title: $title} else {} end)
        + (if $hasTraffic then
            {
                traffic: (
                    {}
                    + (if $upload != null then {upload: $upload} else {} end)
                    + (if $download != null then {download: $download} else {} end)
                    + {used: $used, isUnlimited: $isUnlimited}
                    + (if $total != null and $total > 0 then {total: $total, remaining: $remaining} else {} end)
                )
            }
          else {} end)
        + (if $expire != null and $expire > 0 then {expire: $expire} else {} end)
        + (if $refillDate != null and $refillDate > 0 then {refillDate: $refillDate} else {} end)
        + (if $webPageUrl != "" then {webPageUrl: $webPageUrl} else {} end)
        + (if $supportUrl != "" then {supportUrl: $supportUrl} else {} end)
        + (if $announce != "" then {announce: $announce} else {} end)
        + (if $announceUrl != "" then {announceUrl: $announceUrl} else {} end)
        + (if $fileName != "" then {fileName: $fileName} else {} end)
        | if (keys | length) > 1 then . else empty end
    '
}

subscription_extract_ui_metadata() {
    local headers_file="$1"
    local body_file="$2"
    local output="$3"
    local headers_json body_json raw_json metadata_json

    headers_json="$(subscription_metadata_headers_json "$headers_file")" || headers_json="{}"
    body_json="$(subscription_metadata_body_json "$body_file")" || body_json="{}"

    raw_json="$(jq -cn --argjson body "$body_json" --argjson headers "$headers_json" '$body + $headers')" || {
        rm -f "$output"
        return 1
    }

    metadata_json="$(subscription_normalize_ui_metadata_json "$raw_json")" || metadata_json=""
    if [ -n "$metadata_json" ] && printf '%s\n' "$metadata_json" | jq -e 'type == "object" and (keys | length > 1)' >/dev/null 2>&1; then
        printf '%s\n' "$metadata_json" > "$output"
        return 0
    fi

    rm -f "$output"
    return 1
}

subscription_strip_metadata_preamble_file() {
    local input="$1"
    local tmpfile

    [ -s "$input" ] || return 0

    tmpfile="$(mktemp)" || return 0
    awk '
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
    NR <= 20 {
        line = $0
        sub(/\r$/, "", line)
        gsub(/^[ \t]+|[ \t]+$/, "", line)
        if (line ~ /^(#|\/\/)[ \t]*[A-Za-z0-9][A-Za-z0-9_-]*[ \t]*:/) {
            key = line
            sub(/^(#|\/\/)[ \t]*/, "", key)
            sub(/[ \t]*:.*/, "", key)
            key = tolower(key)
            if (!allowed(key)) {
                print
                next
            }
            next
        }
    }
    {
        print
    }
    ' "$input" > "$tmpfile" && mv "$tmpfile" "$input" || rm -f "$tmpfile"
}

subscription_validate_normalized_file() {
    local output="$1"

    jq -e '
        type == "object" and
        (.outbounds | type == "array") and
        ((.outbounds | length) > 0)
    ' "$output" >/dev/null 2>&1
}

subscription_normalize_sing_box_json_file() {
    local input="$1"
    local output="$2"

    jq -ce '
        def candidate_outbounds:
            if type == "object" and (.outbounds | type == "array") then
                .outbounds
            elif type == "array" then
                .
            elif type == "object" and (.type? | type == "string") then
                [.]
            else
                []
            end;

        {
            version: 1,
            format: "sing-box-json",
            outbounds: (candidate_outbounds | map(select(type == "object")))
        }
    ' "$input" > "$output" 2>/dev/null
}

subscription_parse_v2ray_tls_transport_args() {
    local url="$1"
    local security="$2"
    local default_tls="$3"
    local sni insecure alpn fingerprint public_key short_id transport ws_path ws_host ws_early_data \
        grpc_service_name xhttp_mode tls_enabled

    sni="$(subscription_url_get_query_param "$url" "sni")"
    [ -n "$sni" ] || sni="$(subscription_url_get_query_param "$url" "peer")"
    insecure="$(subscription_url_get_query_param "$url" "allowInsecure")"
    [ -n "$insecure" ] || insecure="$(subscription_url_get_query_param "$url" "insecure")"
    alpn="$(subscription_url_get_query_param "$url" "alpn")"
    fingerprint="$(subscription_url_get_query_param "$url" "fp")"
    fingerprint="$(subscription_normalize_utls_fingerprint "$fingerprint")"
    public_key="$(subscription_url_get_query_param "$url" "pbk")"
    short_id="$(subscription_url_get_query_param "$url" "sid")"
    transport="$(subscription_url_get_query_param "$url" "type")"
    ws_path="$(subscription_url_get_query_param "$url" "path")"
    ws_host="$(subscription_url_get_query_param "$url" "host")"
    ws_early_data="$(subscription_url_get_query_param "$url" "ed")"
    grpc_service_name="$(subscription_url_get_query_param "$url" "serviceName")"
    xhttp_mode="$(subscription_url_get_query_param "$url" "mode")"
    case "$xhttp_mode" in
    auto | packet-up | stream-up | stream-one) ;;
    *) xhttp_mode="auto" ;;
    esac

    if [ "$transport" = "xhttp" ] && [ -z "$alpn" ]; then
        alpn="h2,http/1.1"
    fi

    tls_enabled=false
    case "$security" in
    tls | xtls | reality) tls_enabled=true ;;
    "")
        if [ "$default_tls" = "1" ] || [ -n "$sni$alpn$fingerprint$public_key" ]; then
            tls_enabled=true
        fi
        ;;
    esac

    jq -cn \
        --argjson tls_enabled "$tls_enabled" \
        --arg security "$security" \
        --arg sni "$sni" \
        --arg insecure "$(subscription_bool_json "$insecure")" \
        --arg alpn "$alpn" \
        --arg fingerprint "$fingerprint" \
        --arg public_key "$public_key" \
        --arg short_id "$short_id" \
        --arg transport "$transport" \
        --arg ws_path "$ws_path" \
        --arg ws_host "$ws_host" \
        --arg ws_early_data "$ws_early_data" \
        --arg grpc_service_name "$grpc_service_name" \
        --arg xhttp_mode "$xhttp_mode" '
        {
            tls: (
                if $tls_enabled then
                    {
                        enabled: true
                    }
                    + (if $sni != "" then {server_name: $sni} else {} end)
                    + (if $insecure == "true" then {insecure: true} else {} end)
                    + (if $alpn != "" then {alpn: ($alpn | split(","))} else {} end)
                    + (if $security == "reality" or $public_key != "" then
                        {utls: {enabled: true, fingerprint: (if $fingerprint != "" then $fingerprint else "chrome" end)}}
                    elif $fingerprint != "" then
                        {utls: {enabled: true, fingerprint: $fingerprint}}
                    else {} end)
                    + (if $security == "reality" or $public_key != "" then
                        {reality: ({enabled: true} + (if $public_key != "" then {public_key: $public_key} else {} end) + (if $short_id != "" then {short_id: $short_id} else {} end))}
                    else {} end)
                else
                    null
                end
            ),
            transport: (
                if $transport == "ws" then
                    {
                        type: "ws",
                        path: (if $ws_path != "" then $ws_path else "/" end)
                    }
                    + (if $ws_host != "" then {headers: {Host: $ws_host}} else {} end)
                    + (if $ws_early_data != "" then {max_early_data: ($ws_early_data | tonumber)} else {} end)
                elif $transport == "grpc" then
                    {
                        type: "grpc"
                    }
                    + (if $grpc_service_name != "" then {service_name: $grpc_service_name} else {} end)
                elif $transport == "http" or $transport == "h2" then
                    {
                        type: "http"
                    }
                    + (if $ws_path != "" then {path: $ws_path} else {} end)
                    + (if $ws_host != "" then {host: ($ws_host | split(","))} else {} end)
                elif $transport == "httpupgrade" then
                    {
                        type: "httpupgrade"
                    }
                    + (if $ws_path != "" then {path: $ws_path} else {} end)
                    + (if $ws_host != "" then {host: $ws_host} else {} end)
                elif $transport == "xhttp" then
                    {
                        type: "xhttp",
                        mode: $xhttp_mode,
                        path: (if $ws_path != "" then $ws_path else "/" end),
                        x_padding_bytes: "100-1000",
                        no_grpc_header: false,
                        sc_max_each_post_bytes: 1000000,
                        sc_min_posts_interval_ms: 30
                    }
                    + (if $ws_host != "" then {host: $ws_host} elif $sni != "" then {host: $sni} else {} end)
                else
                    null
                end
            )
        }'
}

subscription_parse_vless_link() {
    local link="$1"
    local tag host port uuid flow packet_encoding security extras

    tag="$(subscription_url_get_fragment "$link")"
    link="${link%%#*}"
    host="$(url_get_host "$link")"
    port="$(url_get_port "$link")"
    uuid="$(subscription_url_decode "$(url_get_userinfo "$link")")"
    flow="$(subscription_url_get_query_param "$link" "flow")"
    packet_encoding="$(subscription_url_get_query_param "$link" "packetEncoding")"
    security="$(subscription_url_get_query_param "$link" "security")"
    [ -n "$tag" ] || tag="$host:$port"

    [ -n "$host" ] && [ -n "$port" ] && [ -n "$uuid" ] || return 1

    extras="$(subscription_parse_v2ray_tls_transport_args "$link" "$security" 0)" || return 1

    jq -cn \
        --arg tag "$tag" \
        --arg host "$host" \
        --arg port "$port" \
        --arg uuid "$uuid" \
        --arg flow "$flow" \
        --arg packet_encoding "$packet_encoding" \
        --argjson extras "$extras" '
        {
            type: "vless",
            tag: $tag,
            server: $host,
            server_port: ($port | tonumber),
            uuid: $uuid
        }
        + (if $flow != "" then {flow: $flow} else {} end)
        + (if $packet_encoding != "" then {packet_encoding: $packet_encoding} else {} end)
        + (if $extras.tls != null then {tls: $extras.tls} else {} end)
        + (if $extras.transport != null then {transport: $extras.transport} else {} end)'
}

subscription_parse_trojan_link() {
    local link="$1"
    local tag host port password security extras

    tag="$(subscription_url_get_fragment "$link")"
    link="${link%%#*}"
    host="$(url_get_host "$link")"
    port="$(url_get_port "$link")"
    password="$(subscription_url_decode "$(url_get_userinfo "$link")")"
    security="$(subscription_url_get_query_param "$link" "security")"
    [ -n "$tag" ] || tag="$host:$port"

    [ -n "$host" ] && [ -n "$port" ] && [ -n "$password" ] || return 1

    extras="$(subscription_parse_v2ray_tls_transport_args "$link" "$security" 1)" || return 1

    jq -cn \
        --arg tag "$tag" \
        --arg host "$host" \
        --arg port "$port" \
        --arg password "$password" \
        --argjson extras "$extras" '
        {
            type: "trojan",
            tag: $tag,
            server: $host,
            server_port: ($port | tonumber),
            password: $password
        }
        + (if $extras.tls != null then {tls: $extras.tls} else {} end)
        + (if $extras.transport != null then {transport: $extras.transport} else {} end)'
}

subscription_parse_socks_link() {
    local link="$1"
    local tag scheme host port userinfo username password version

    tag="$(subscription_url_get_fragment "$link")"
    link="${link%%#*}"
    scheme="$(url_get_scheme "$link")"
    host="$(url_get_host "$link")"
    port="$(url_get_port "$link")"
    userinfo="$(url_get_userinfo "$link")"
    version="${scheme#socks}"
    [ -n "$tag" ] || tag="$host:$port"

    [ -n "$host" ] && [ -n "$port" ] || return 1

    username=""
    password=""
    if [ -n "$userinfo" ]; then
        username="$(subscription_url_decode "${userinfo%%:*}")"
        password="$(subscription_url_decode "${userinfo#*:}")"
        [ "$username" = "$password" ] && password=""
    fi

    jq -cn \
        --arg tag "$tag" \
        --arg host "$host" \
        --arg port "$port" \
        --arg version "$version" \
        --arg username "$username" \
        --arg password "$password" '
        {
            type: "socks",
            tag: $tag,
            server: $host,
            server_port: ($port | tonumber)
        }
        + (if $version != "" then {version: $version} else {} end)
        + (if $username != "" then {username: $username} else {} end)
        + (if $password != "" then {password: $password} else {} end)'
}

subscription_parse_shadowsocks_link() {
    local raw_link="$1"
    local tag link body main authority userinfo hostport decoded method password host port plugin plugin_opts

    tag="$(subscription_url_get_fragment "$raw_link")"
    link="${raw_link%%#*}"
    body="${link#ss://}"
    main="${body%%\?*}"
    authority="$main"

    if printf '%s' "$authority" | grep -q '@'; then
        userinfo="${authority%%@*}"
        hostport="${authority#*@}"
    else
        decoded="$(subscription_base64_decode_string "$authority")" || return 1
        userinfo="${decoded%%@*}"
        hostport="${decoded#*@}"
        [ "$userinfo" != "$decoded" ] || return 1
    fi

    userinfo="$(subscription_url_decode "$userinfo")"
    if ! is_shadowsocks_userinfo_format "$userinfo"; then
        decoded="$(subscription_base64_decode_string "$userinfo")" || return 1
        userinfo="$decoded"
    fi

    method="${userinfo%%:*}"
    password="${userinfo#*:}"
    host="${hostport%%:*}"
    port="${hostport#*:}"
    port="${port%%/*}"
    plugin="$(subscription_url_get_query_param "$link" "plugin")"
    plugin_opts="$(subscription_url_get_query_param "$link" "plugin-opts")"

    [ -n "$tag" ] || tag="$host:$port"
    [ -n "$method" ] && [ -n "$password" ] && [ -n "$host" ] && [ -n "$port" ] || return 1

    jq -cn \
        --arg tag "$tag" \
        --arg host "$host" \
        --arg port "$port" \
        --arg method "$method" \
        --arg password "$password" \
        --arg plugin "$plugin" \
        --arg plugin_opts "$plugin_opts" '
        {
            type: "shadowsocks",
            tag: $tag,
            server: $host,
            server_port: ($port | tonumber),
            method: $method,
            password: $password
        }
        + (if $plugin != "" then {plugin: $plugin} else {} end)
        + (if $plugin_opts != "" then {plugin_opts: $plugin_opts} else {} end)'
}

subscription_parse_hysteria2_link() {
    local link="$1"
    local tag host port userinfo password sni insecure alpn obfs obfs_password up_mbps down_mbps network

    tag="$(subscription_url_get_fragment "$link")"
    link="${link%%#*}"
    host="$(url_get_host "$link")"
    port="$(url_get_port "$link")"
    userinfo="$(subscription_url_decode "$(url_get_userinfo "$link")")"
    password="${userinfo#*:}"
    [ "$password" = "$userinfo" ] && password="$userinfo"
    sni="$(subscription_url_get_query_param "$link" "sni")"
    insecure="$(subscription_url_get_query_param "$link" "insecure")"
    alpn="$(subscription_url_get_query_param "$link" "alpn")"
    obfs="$(subscription_url_get_query_param "$link" "obfs")"
    obfs_password="$(subscription_url_get_query_param "$link" "obfs-password")"
    up_mbps="$(subscription_url_get_query_param "$link" "upmbps")"
    down_mbps="$(subscription_url_get_query_param "$link" "downmbps")"
    network="$(subscription_url_get_query_param "$link" "network")"

    [ -n "$tag" ] || tag="$host:$port"
    [ -n "$host" ] && [ -n "$port" ] && [ -n "$password" ] || return 1

    jq -cn \
        --arg tag "$tag" \
        --arg host "$host" \
        --arg port "$port" \
        --arg password "$password" \
        --arg sni "$sni" \
        --arg insecure "$(subscription_bool_json "$insecure")" \
        --arg alpn "$alpn" \
        --arg obfs "$obfs" \
        --arg obfs_password "$obfs_password" \
        --arg up_mbps "$up_mbps" \
        --arg down_mbps "$down_mbps" \
        --arg network "$network" '
        {
            type: "hysteria2",
            tag: $tag,
            server: $host,
            server_port: ($port | tonumber),
            password: $password,
            tls: (
                {enabled: true}
                + (if $sni != "" then {server_name: $sni} else {} end)
                + (if $insecure == "true" then {insecure: true} else {} end)
                + (if $alpn != "" then {alpn: ($alpn | split(","))} else {} end)
            )
        }
        + (if $network != "" then {network: $network} else {} end)
        + (if $up_mbps != "" then {up_mbps: ($up_mbps | tonumber)} else {} end)
        + (if $down_mbps != "" then {down_mbps: ($down_mbps | tonumber)} else {} end)
        + (if $obfs != "" and $obfs != "none" then {obfs: ({type: $obfs} + (if $obfs_password != "" then {password: $obfs_password} else {} end))} else {} end)'
}

subscription_parse_vmess_jsonl_file() {
    local input="$1"

    jq -ce '
        def s($v): if $v == null then "" else ($v | tostring) end;
        def non_empty($v): s($v) != "";
        def numeric($v): try (s($v) | tonumber) catch null;
        def truthy_tls($v): ($v == true) or ($v == "tls") or ($v == "true");
        def csv($v): if s($v) != "" then (s($v) | split(",")) else null end;
        def utls_fingerprint:
            s(.fp) as $fp
            | if $fp == "" then ""
              elif (["chrome","firefox","edge","safari","360","ios","android","randomized","randomizedalpn","randomizednoalpn"] | index($fp)) != null then $fp
              else "chrome"
              end;
        def ws_transport:
            {
                type: "ws",
                path: (if s(.path) != "" then s(.path) else "/" end)
            }
            + (if s(.host) != "" then {headers: {Host: s(.host)}} else {} end);
        def grpc_transport:
            {
                type: "grpc"
            }
            + (if s(.path) != "" then {service_name: s(.path)} else {} end);
        def http_transport:
            {
                type: "http"
            }
            + (if s(.path) != "" then {path: s(.path)} else {} end)
            + (if s(.host) != "" then {host: (s(.host) | split(","))} else {} end);

        select(type == "object")
        | select(non_empty(.add) and (numeric(.port) != null) and non_empty(.id))
        | {
            type: "vmess",
            tag: (if s(.ps) != "" then s(.ps) else "\(s(.add)):\(s(.port))" end),
            server: s(.add),
            server_port: numeric(.port),
            uuid: s(.id),
            security: (if s(.scy) != "" then s(.scy) else "auto" end)
        }
        + (if numeric(.aid) != null then {alter_id: numeric(.aid)} else {} end)
        + (if truthy_tls(.tls) then
            {
                tls: (
                    {enabled: true}
                    + (if s(.sni) != "" then {server_name: s(.sni)} else {} end)
                    + (if csv(.alpn) != null then {alpn: csv(.alpn)} else {} end)
                    + (if utls_fingerprint != "" then {utls: {enabled: true, fingerprint: utls_fingerprint}} else {} end)
                )
            }
        else {} end)
        + (if s(.net) == "ws" then {transport: ws_transport}
           elif s(.net) == "grpc" then {transport: grpc_transport}
           elif s(.net) == "http" or s(.net) == "h2" then {transport: http_transport}
           else {} end)
    ' "$input" 2>/dev/null
}

subscription_parse_vmess_link() {
    local raw="$1"
    local encoded decoded tmp result status

    encoded="${raw#vmess://}"
    encoded="${encoded%%#*}"
    decoded="$(subscription_base64_decode_string "$encoded")" || return 1
    decoded="$(printf '%s' "$decoded" | tr -d '\r\n')"

    tmp="$(mktemp)" || return 1
    printf '%s\n' "$decoded" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }

    result="$(subscription_parse_vmess_jsonl_file "$tmp")"
    status=$?
    rm -f "$tmp"

    [ "$status" -eq 0 ] || return 1
    [ -n "$result" ] || return 1
    printf '%s\n' "$result" | jq -c --arg share_link "$raw" '. + {share_link: $share_link}' 2>/dev/null
}

subscription_json_string() {
    local value="$1"

    value="$(printf '%s' "$value" | sed 's/\\/\\\\/g;s/"/\\"/g')"
    printf '"%s"' "$value"
}

subscription_is_number() {
    case "$1" in
    "" | *[!0-9]*) return 1 ;;
    esac

    return 0
}

subscription_vless_flow_is_supported() {
    case "$1" in
    "" | xtls-rprx-vision) return 0 ;;
    esac

    return 1
}

subscription_normalize_packet_encoding() {
    case "$1" in
    xudp | packetaddr)
        printf '%s' "$1"
        ;;
    *)
        printf ''
        ;;
    esac
}

subscription_json_csv_array() {
    local csv="$1"
    local output item first

    output="["
    first=1
    while [ -n "$csv" ]; do
        case "$csv" in
        *,*)
            item="${csv%%,*}"
            csv="${csv#*,}"
            ;;
        *)
            item="$csv"
            csv=""
            ;;
        esac

        [ -n "$item" ] || continue
        if [ "$first" -eq 1 ]; then
            first=0
        else
            output="$output,"
        fi
        output="$output$(subscription_json_string "$item")"
    done

    output="$output]"
    printf '%s' "$output"
}

subscription_v2ray_tls_member() {
    local url="$1"
    local security="$2"
    local default_tls="$3"
    local sni insecure alpn fingerprint public_key short_id transport tls_enabled json reality

    sni="$(subscription_url_get_query_param "$url" "sni")"
    [ -n "$sni" ] || sni="$(subscription_url_get_query_param "$url" "peer")"
    insecure="$(subscription_url_get_query_param "$url" "allowInsecure")"
    [ -n "$insecure" ] || insecure="$(subscription_url_get_query_param "$url" "insecure")"
    alpn="$(subscription_url_get_query_param "$url" "alpn")"
    transport="$(subscription_url_get_query_param "$url" "type")"
    if [ "$transport" = "xhttp" ] && [ -z "$alpn" ]; then
        alpn="h2,http/1.1"
    fi
    fingerprint="$(subscription_url_get_query_param "$url" "fp")"
    fingerprint="$(subscription_normalize_utls_fingerprint "$fingerprint")"
    public_key="$(subscription_url_get_query_param "$url" "pbk")"
    short_id="$(subscription_url_get_query_param "$url" "sid")"

    if [ "$security" = "reality" ] && [ -z "$public_key" ]; then
        return 1
    fi
    if { [ "$security" = "reality" ] || [ -n "$public_key" ]; } && [ -z "$fingerprint" ]; then
        fingerprint="chrome"
    fi

    tls_enabled=0
    case "$security" in
    tls | xtls | reality) tls_enabled=1 ;;
    "")
        if [ "$default_tls" = "1" ] || [ -n "$sni$alpn$fingerprint$public_key" ]; then
            tls_enabled=1
        fi
        ;;
    esac

    [ "$tls_enabled" -eq 1 ] || return 0

    json=',"tls":{"enabled":true'
    [ -n "$sni" ] && json="$json,\"server_name\":$(subscription_json_string "$sni")"
    subscription_bool_is_true "$insecure" && json="$json,\"insecure\":true"
    [ -n "$alpn" ] && json="$json,\"alpn\":$(subscription_json_csv_array "$alpn")"
    [ -n "$fingerprint" ] && json="$json,\"utls\":{\"enabled\":true,\"fingerprint\":$(subscription_json_string "$fingerprint")}"
    if [ "$security" = "reality" ] || [ -n "$public_key" ]; then
        reality='{"enabled":true'
        [ -n "$public_key" ] && reality="$reality,\"public_key\":$(subscription_json_string "$public_key")"
        [ -n "$short_id" ] && reality="$reality,\"short_id\":$(subscription_json_string "$short_id")"
        json="$json,\"reality\":$reality}"
    fi

    printf '%s}' "$json"
}

subscription_v2ray_transport_member() {
    local url="$1"
    local transport ws_path ws_host ws_early_data grpc_service_name xhttp_mode sni json

    transport="$(subscription_url_get_query_param "$url" "type")"
    ws_path="$(subscription_url_get_query_param "$url" "path")"
    ws_host="$(subscription_url_get_query_param "$url" "host")"
    ws_early_data="$(subscription_url_get_query_param "$url" "ed")"
    grpc_service_name="$(subscription_url_get_query_param "$url" "serviceName")"
    xhttp_mode="$(subscription_url_get_query_param "$url" "mode")"
    sni="$(subscription_url_get_query_param "$url" "sni")"
    case "$xhttp_mode" in
    auto | packet-up | stream-up | stream-one) ;;
    *) xhttp_mode="auto" ;;
    esac

    case "$transport" in
    ws)
        [ -n "$ws_path" ] || ws_path="/"
        json=',"transport":{"type":"ws"'
        json="$json,\"path\":$(subscription_json_string "$ws_path")"
        [ -n "$ws_host" ] && json="$json,\"headers\":{\"Host\":$(subscription_json_string "$ws_host")}"
        if [ -n "$ws_early_data" ] && subscription_is_number "$ws_early_data"; then
            json="$json,\"max_early_data\":$ws_early_data"
        fi
        printf '%s}' "$json"
        ;;
    grpc)
        json=',"transport":{"type":"grpc"'
        [ -n "$grpc_service_name" ] && json="$json,\"service_name\":$(subscription_json_string "$grpc_service_name")"
        printf '%s}' "$json"
        ;;
    http | h2)
        json=',"transport":{"type":"http"'
        [ -n "$ws_path" ] && json="$json,\"path\":$(subscription_json_string "$ws_path")"
        [ -n "$ws_host" ] && json="$json,\"host\":$(subscription_json_csv_array "$ws_host")"
        printf '%s}' "$json"
        ;;
    httpupgrade)
        json=',"transport":{"type":"httpupgrade"'
        [ -n "$ws_path" ] && json="$json,\"path\":$(subscription_json_string "$ws_path")"
        [ -n "$ws_host" ] && json="$json,\"host\":$(subscription_json_string "$ws_host")"
        printf '%s}' "$json"
        ;;
    xhttp)
        [ -n "$ws_path" ] || ws_path="/"
        [ -n "$ws_host" ] || ws_host="$sni"
        json=',"transport":{"type":"xhttp"'
        json="$json,\"mode\":$(subscription_json_string "$xhttp_mode")"
        json="$json,\"path\":$(subscription_json_string "$ws_path")"
        json="$json,\"x_padding_bytes\":\"100-1000\""
        json="$json,\"no_grpc_header\":false"
        json="$json,\"sc_max_each_post_bytes\":1000000"
        json="$json,\"sc_min_posts_interval_ms\":30"
        [ -n "$ws_host" ] && json="$json,\"host\":$(subscription_json_string "$ws_host")"
        printf '%s}' "$json"
        ;;
    esac
}

subscription_parse_vless_link() {
    local link="$1"
    local raw_link tag host port uuid flow packet_encoding security tls_member transport_member json

    raw_link="$link"
    tag="$(subscription_url_get_fragment "$link")"
    link="${link%%#*}"
    host="$(url_get_host "$link")"
    port="$(url_get_port "$link")"
    uuid="$(subscription_url_decode "$(url_get_userinfo "$link")")"
    flow="$(subscription_url_get_query_param "$link" "flow")"
    packet_encoding="$(subscription_url_get_query_param "$link" "packetEncoding")"
    packet_encoding="$(subscription_normalize_packet_encoding "$packet_encoding")"
    security="$(subscription_url_get_query_param "$link" "security")"
    [ -n "$tag" ] || tag="$host:$port"

    [ -n "$host" ] && [ -n "$port" ] && [ -n "$uuid" ] || return 1
    subscription_is_number "$port" || return 1
    subscription_vless_flow_is_supported "$flow" || return 1

    json="{\"type\":\"vless\",\"tag\":$(subscription_json_string "$tag"),\"share_link\":$(subscription_json_string "$raw_link"),\"server\":$(subscription_json_string "$host"),\"server_port\":$port,\"uuid\":$(subscription_json_string "$uuid")"
    [ -n "$flow" ] && json="$json,\"flow\":$(subscription_json_string "$flow")"
    [ -n "$packet_encoding" ] && json="$json,\"packet_encoding\":$(subscription_json_string "$packet_encoding")"
    tls_member="$(subscription_v2ray_tls_member "$link" "$security" 0)" || return 1
    transport_member="$(subscription_v2ray_transport_member "$link")" || return 1
    json="$json$tls_member"
    json="$json$transport_member"
    printf '%s}\n' "$json"
}

subscription_parse_trojan_link() {
    local link="$1"
    local raw_link tag host port password security tls_member transport_member json

    raw_link="$link"
    tag="$(subscription_url_get_fragment "$link")"
    link="${link%%#*}"
    host="$(url_get_host "$link")"
    port="$(url_get_port "$link")"
    password="$(subscription_url_decode "$(url_get_userinfo "$link")")"
    security="$(subscription_url_get_query_param "$link" "security")"
    [ -n "$tag" ] || tag="$host:$port"

    [ -n "$host" ] && [ -n "$port" ] && [ -n "$password" ] || return 1
    subscription_is_number "$port" || return 1

    json="{\"type\":\"trojan\",\"tag\":$(subscription_json_string "$tag"),\"share_link\":$(subscription_json_string "$raw_link"),\"server\":$(subscription_json_string "$host"),\"server_port\":$port,\"password\":$(subscription_json_string "$password")"
    tls_member="$(subscription_v2ray_tls_member "$link" "$security" 1)" || return 1
    transport_member="$(subscription_v2ray_transport_member "$link")" || return 1
    json="$json$tls_member"
    json="$json$transport_member"
    printf '%s}\n' "$json"
}

subscription_parse_socks_link() {
    local link="$1"
    local raw_link tag scheme host port userinfo username password version json

    raw_link="$link"
    tag="$(subscription_url_get_fragment "$link")"
    link="${link%%#*}"
    scheme="$(url_get_scheme "$link")"
    host="$(url_get_host "$link")"
    port="$(url_get_port "$link")"
    userinfo="$(url_get_userinfo "$link")"
    version="${scheme#socks}"
    [ -n "$tag" ] || tag="$host:$port"

    [ -n "$host" ] && [ -n "$port" ] || return 1
    subscription_is_number "$port" || return 1

    username=""
    password=""
    if [ -n "$userinfo" ]; then
        username="$(subscription_url_decode "${userinfo%%:*}")"
        password="$(subscription_url_decode "${userinfo#*:}")"
        [ "$username" = "$password" ] && password=""
    fi

    json="{\"type\":\"socks\",\"tag\":$(subscription_json_string "$tag"),\"share_link\":$(subscription_json_string "$raw_link"),\"server\":$(subscription_json_string "$host"),\"server_port\":$port"
    [ -n "$version" ] && json="$json,\"version\":$(subscription_json_string "$version")"
    [ -n "$username" ] && json="$json,\"username\":$(subscription_json_string "$username")"
    [ -n "$password" ] && json="$json,\"password\":$(subscription_json_string "$password")"
    printf '%s}\n' "$json"
}

subscription_parse_shadowsocks_link() {
    local raw_link="$1"
    local tag link body main authority userinfo hostport decoded method password host port plugin plugin_opts json

    tag="$(subscription_url_get_fragment "$raw_link")"
    link="${raw_link%%#*}"
    body="${link#ss://}"
    main="${body%%\?*}"
    authority="$main"

    if printf '%s' "$authority" | grep -q '@'; then
        userinfo="${authority%%@*}"
        hostport="${authority#*@}"
    else
        decoded="$(subscription_base64_decode_string "$authority")" || return 1
        userinfo="${decoded%%@*}"
        hostport="${decoded#*@}"
        [ "$userinfo" != "$decoded" ] || return 1
    fi

    userinfo="$(subscription_url_decode "$userinfo")"
    if ! is_shadowsocks_userinfo_format "$userinfo"; then
        decoded="$(subscription_base64_decode_string "$userinfo")" || return 1
        userinfo="$decoded"
    fi

    method="${userinfo%%:*}"
    password="${userinfo#*:}"
    host="${hostport%%:*}"
    port="${hostport#*:}"
    port="${port%%/*}"
    plugin="$(subscription_url_get_query_param "$link" "plugin")"
    plugin_opts="$(subscription_url_get_query_param "$link" "plugin-opts")"

    [ -n "$tag" ] || tag="$host:$port"
    [ -n "$method" ] && [ -n "$password" ] && [ -n "$host" ] && [ -n "$port" ] || return 1
    subscription_is_number "$port" || return 1
    [ "$method" = "ss" ] && return 1

    json="{\"type\":\"shadowsocks\",\"tag\":$(subscription_json_string "$tag"),\"share_link\":$(subscription_json_string "$raw_link"),\"server\":$(subscription_json_string "$host"),\"server_port\":$port,\"method\":$(subscription_json_string "$method"),\"password\":$(subscription_json_string "$password")"
    [ -n "$plugin" ] && json="$json,\"plugin\":$(subscription_json_string "$plugin")"
    [ -n "$plugin_opts" ] && json="$json,\"plugin_opts\":$(subscription_json_string "$plugin_opts")"
    printf '%s}\n' "$json"
}

subscription_parse_hysteria2_link() {
    local link="$1"
    local raw_link tag host port userinfo password sni insecure alpn obfs obfs_password up_mbps down_mbps network json tls obfs_json

    raw_link="$link"
    tag="$(subscription_url_get_fragment "$link")"
    link="${link%%#*}"
    host="$(url_get_host "$link")"
    port="$(url_get_port "$link")"
    userinfo="$(subscription_url_decode "$(url_get_userinfo "$link")")"
    password="${userinfo#*:}"
    [ "$password" = "$userinfo" ] && password="$userinfo"
    sni="$(subscription_url_get_query_param "$link" "sni")"
    insecure="$(subscription_url_get_query_param "$link" "insecure")"
    alpn="$(subscription_url_get_query_param "$link" "alpn")"
    obfs="$(subscription_url_get_query_param "$link" "obfs")"
    obfs_password="$(subscription_url_get_query_param "$link" "obfs-password")"
    up_mbps="$(subscription_url_get_query_param "$link" "upmbps")"
    down_mbps="$(subscription_url_get_query_param "$link" "downmbps")"
    network="$(subscription_url_get_query_param "$link" "network")"

    [ -n "$tag" ] || tag="$host:$port"
    [ -n "$host" ] && [ -n "$port" ] && [ -n "$password" ] || return 1
    subscription_is_number "$port" || return 1

    tls='{"enabled":true'
    [ -n "$sni" ] && tls="$tls,\"server_name\":$(subscription_json_string "$sni")"
    subscription_bool_is_true "$insecure" && tls="$tls,\"insecure\":true"
    [ -n "$alpn" ] && tls="$tls,\"alpn\":$(subscription_json_csv_array "$alpn")"
    tls="$tls}"

    json="{\"type\":\"hysteria2\",\"tag\":$(subscription_json_string "$tag"),\"share_link\":$(subscription_json_string "$raw_link"),\"server\":$(subscription_json_string "$host"),\"server_port\":$port,\"password\":$(subscription_json_string "$password"),\"tls\":$tls"
    [ -n "$network" ] && json="$json,\"network\":$(subscription_json_string "$network")"
    [ -n "$up_mbps" ] && subscription_is_number "$up_mbps" && json="$json,\"up_mbps\":$up_mbps"
    [ -n "$down_mbps" ] && subscription_is_number "$down_mbps" && json="$json,\"down_mbps\":$down_mbps"
    if [ -n "$obfs" ] && [ "$obfs" != "none" ]; then
        obfs_json="{\"type\":$(subscription_json_string "$obfs")"
        [ -n "$obfs_password" ] && obfs_json="$obfs_json,\"password\":$(subscription_json_string "$obfs_password")"
        json="$json,\"obfs\":$obfs_json}"
    fi
    printf '%s}\n' "$json"
}

subscription_parse_share_link() {
    local line="$1"

    case "$line" in
    vless://*) subscription_parse_vless_link "$line" ;;
    trojan://*) subscription_parse_trojan_link "$line" ;;
    ss://*) subscription_parse_shadowsocks_link "$line" ;;
    vmess://*) subscription_parse_vmess_link "$line" ;;
    hysteria2://* | hy2://*) subscription_parse_hysteria2_link "$line" ;;
    socks4://* | socks4a://* | socks5://*) subscription_parse_socks_link "$line" ;;
    *) return 1 ;;
    esac
}

subscription_normalize_uri_list_file() {
    local input="$1"
    local output="$2"
    local lines_tmp jsonl vmess_jsonl vmess_links vmess_outbounds line index added skipped vmess_total vmess_added decoded encoded

    lines_tmp="$(mktemp)" || return 1
    sed 's/\r//g;s/^[[:space:]]*//;s/[[:space:]]*$//' "$input" > "$lines_tmp" || {
        rm -f "$lines_tmp"
        return 1
    }

    jsonl="$(mktemp)" || {
        rm -f "$lines_tmp"
        return 1
    }
    vmess_jsonl="$(mktemp)" || {
        rm -f "$lines_tmp" "$jsonl"
        return 1
    }
    vmess_links="$(mktemp)" || {
        rm -f "$lines_tmp" "$jsonl" "$vmess_jsonl"
        return 1
    }
    index=1
    added=0
    skipped=0
    vmess_total=0

    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        case "$line" in \#*) continue ;; esac

        case "$line" in
        vmess://*)
            encoded="${line#vmess://}"
            encoded="${encoded%%#*}"
            if decoded="$(subscription_base64_decode_string "$encoded")"; then
                decoded="$(printf '%s' "$decoded" | tr -d '\r\n')"
                case "$decoded" in
                \{*\})
                    printf '%s\n' "$decoded" >> "$vmess_jsonl"
                    printf '%s\n' "$line" >> "$vmess_links"
                    vmess_total=$((vmess_total + 1))
                    index=$((index + 1))
                    continue
                    ;;
                esac
            fi
            ;;
        esac

        if subscription_parse_share_link "$line" >> "$jsonl"; then
            added=$((added + 1))
        else
            skipped=$((skipped + 1))
        fi
        index=$((index + 1))
    done < "$lines_tmp"

    if [ "$vmess_total" -gt 0 ]; then
        vmess_outbounds="$(mktemp)" || {
            rm -f "$lines_tmp" "$jsonl" "$vmess_jsonl" "$vmess_links"
            return 1
        }

        if subscription_parse_vmess_jsonl_file "$vmess_jsonl" > "$vmess_outbounds"; then
            vmess_added="$(wc -l < "$vmess_outbounds" | tr -d ' ')"
            if [ "${vmess_added:-0}" -gt 0 ]; then
                while IFS= read -r line && IFS= read -r encoded <&3; do
                    printf '%s\n' "$line" | jq -c --arg share_link "$encoded" '. + {share_link: $share_link}' 2>/dev/null >> "$jsonl"
                done < "$vmess_outbounds" 3< "$vmess_links"
                added=$((added + vmess_added))
            fi
            skipped=$((skipped + vmess_total - ${vmess_added:-0}))
        else
            while IFS= read -r line || [ -n "$line" ]; do
                if subscription_parse_share_link "$line" >> "$jsonl"; then
                    added=$((added + 1))
                else
                    skipped=$((skipped + 1))
                fi
            done < "$vmess_links"
        fi
        rm -f "$vmess_outbounds"
    fi

    if [ "$added" -eq 0 ]; then
        rm -f "$lines_tmp" "$jsonl" "$vmess_jsonl" "$vmess_links"
        return 1
    fi

    if [ "$skipped" -gt 0 ]; then
        log "Skipped $skipped invalid or unsupported subscription links" "warn"
    fi

    jq -s --argjson skipped "$skipped" '{
        version: 1,
        format: "uri-list",
        skipped: $skipped,
        outbounds: .
    }' "$jsonl" > "$output"
    rm -f "$lines_tmp" "$jsonl" "$vmess_jsonl" "$vmess_links"
}

subscription_clash_yaml_records() {
    local input="$1"

    awk '
    function trim(s) {
        gsub(/^[ \t\r\n]+/, "", s)
        gsub(/[ \t\r\n]+$/, "", s)
        return s
    }
    function json_escape(s) {
        gsub(/\\/, "\\\\", s)
        gsub(/"/, "\\\"", s)
        gsub(/\t/, "\\t", s)
        gsub(/\r/, "", s)
        return s
    }
    function clean_scalar(s) {
        s = trim(s)
        if ((substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"") ||
            (substr(s, 1, 1) == "'"'"'" && substr(s, length(s), 1) == "'"'"'")) {
            s = substr(s, 2, length(s) - 2)
        }
        return s
    }
    function clear_fields(    k) {
        for (k in fields) {
            delete fields[k]
        }
        field_count = 0
        ctx = ""
        ctx_indent = -1
    }
    function set_field(k, v) {
        k = clean_scalar(k)
        v = clean_scalar(v)
        if (k == "") {
            return
        }
        if (!(k in fields)) {
            keys[++field_count] = k
        }
        fields[k] = v
    }
    function emit_record(    i,k,sep) {
        if (field_count <= 0) {
            return
        }
        printf "{"
        sep = ""
        for (i = 1; i <= field_count; i++) {
            k = keys[i]
            if (k in fields) {
                printf "%s\"%s\":\"%s\"", sep, json_escape(k), json_escape(fields[k])
                sep = ","
            }
        }
        printf "}\n"
        clear_fields()
    }
    function parse_pair(part, prefix,    i,c,depth,quote,esc,colon,key,value) {
        part = trim(part)
        depth = 0
        quote = ""
        esc = 0
        colon = 0
        for (i = 1; i <= length(part); i++) {
            c = substr(part, i, 1)
            if (quote != "") {
                if (esc) {
                    esc = 0
                } else if (c == "\\") {
                    esc = 1
                } else if (c == quote) {
                    quote = ""
                }
                continue
            }
            if (c == "\"" || c == "'"'"'") {
                quote = c
                continue
            }
            if (c == "{" || c == "[") {
                depth++
            } else if (c == "}" || c == "]") {
                depth--
            } else if (c == ":" && depth == 0) {
                colon = i
                break
            }
        }
        if (colon <= 0) {
            return
        }
        key = clean_scalar(substr(part, 1, colon - 1))
        value = trim(substr(part, colon + 1))
        if (substr(value, 1, 1) == "{" && substr(value, length(value), 1) == "}") {
            parse_map(value, prefix key ".")
        } else {
            set_field(prefix key, value)
        }
    }
    function parse_map(s, prefix,    i,c,depth,quote,esc,start,part) {
        s = trim(s)
        if (substr(s, 1, 1) == "{") {
            s = substr(s, 2)
        }
        if (substr(s, length(s), 1) == "}") {
            s = substr(s, 1, length(s) - 1)
        }
        depth = 0
        quote = ""
        esc = 0
        start = 1
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (quote != "") {
                if (esc) {
                    esc = 0
                } else if (c == "\\") {
                    esc = 1
                } else if (c == quote) {
                    quote = ""
                }
                continue
            }
            if (c == "\"" || c == "'"'"'") {
                quote = c
                continue
            }
            if (c == "{" || c == "[") {
                depth++
            } else if (c == "}" || c == "]") {
                depth--
            } else if (c == "," && depth == 0) {
                part = substr(s, start, i - start)
                parse_pair(part, prefix)
                start = i + 1
            }
        }
        part = substr(s, start)
        parse_pair(part, prefix)
    }
    function leading_indent(s,    i,c) {
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (c != " " && c != "\t") {
                return i - 1
            }
        }
        return length(s)
    }
    function parse_block_line(line,    indent,t,key,value,colon,fullkey) {
        indent = leading_indent(line)
        t = trim(line)
        if (t == "") {
            return
        }
        colon = index(t, ":")
        if (colon <= 0) {
            return
        }
        key = clean_scalar(substr(t, 1, colon - 1))
        value = trim(substr(t, colon + 1))

        if (ctx != "" && indent <= ctx_indent) {
            ctx = ""
            ctx_indent = -1
        }

        if (value == "") {
            if (key == "ws-opts" || key == "grpc-opts" || key == "reality-opts" || key == "obfs-opts" || key == "headers") {
                if (ctx != "" && indent > ctx_indent) {
                    ctx = ctx "." key
                } else {
                    ctx = key
                }
                ctx_indent = indent
            }
            return
        }

        fullkey = key
        if (ctx != "" && indent > ctx_indent) {
            fullkey = ctx "." key
        }
        set_field(fullkey, value)
    }
    BEGIN {
        in_proxies = 0
        clear_fields()
    }
    /^[^ \t]/ {
        if (in_proxies && $0 !~ /^proxies:[ \t]*($|#)/ && $0 !~ /^-[ \t]*/) {
            emit_record()
            in_proxies = 0
        }
    }
    /^[ \t]*proxies:[ \t]*($|#)/ {
        emit_record()
        in_proxies = 1
        next
    }
    {
        if (!in_proxies) {
            next
        }
        line = $0
        if (line ~ /^[ \t]*-[ \t]*\{/) {
            emit_record()
            clear_fields()
            sub(/^[ \t]*-[ \t]*/, "", line)
            parse_map(line, "")
            emit_record()
            next
        }
        if (line ~ /^[ \t]*-[ \t]*/) {
            emit_record()
            clear_fields()
            sub(/^[ \t]*-[ \t]*/, "", line)
            if (trim(line) != "") {
                parse_block_line(line)
            }
            next
        }
        if (field_count > 0) {
            parse_block_line(line)
        }
    }
    END {
        emit_record()
    }
    ' "$input"
}

subscription_clash_value() {
    local record="$1"
    local key="$2"
    local rest value

    case "$record" in
    *\"$key\":\"*)
        rest="${record#*\"$key\":\"}"
        value="${rest%%\"*}"
        value="$(printf '%s' "$value" | sed 's/\\"/"/g;s/\\\\/\\/g')"
        printf '%s\n' "$value"
        ;;
    *)
        printf '\n'
        ;;
    esac
}

subscription_clash_bool() {
    local value="$1"

    subscription_bool_is_true "$value"
}

subscription_parse_clash_record() {
    local record="$1"
    local type name server port tls skip_verify sni network ws_path ws_host grpc_service_name \
        reality_public_key reality_short_id alpn fingerprint password uuid cipher alter_id flow packet_encoding \
        obfs obfs_password username

    type="$(subscription_clash_value "$record" "type" | tr '[:upper:]' '[:lower:]')"
    name="$(subscription_clash_value "$record" "name")"
    server="$(subscription_clash_value "$record" "server")"
    port="$(subscription_clash_value "$record" "port")"
    tls="$(subscription_clash_value "$record" "tls")"
    skip_verify="$(subscription_clash_value "$record" "skip-cert-verify")"
    sni="$(subscription_clash_value "$record" "sni")"
    [ -n "$sni" ] || sni="$(subscription_clash_value "$record" "servername")"
    network="$(subscription_clash_value "$record" "network" | tr '[:upper:]' '[:lower:]')"
    ws_path="$(subscription_clash_value "$record" "ws-opts.path")"
    ws_host="$(subscription_clash_value "$record" "ws-opts.headers.Host")"
    grpc_service_name="$(subscription_clash_value "$record" "grpc-opts.grpc-service-name")"
    reality_public_key="$(subscription_clash_value "$record" "reality-opts.public-key")"
    reality_short_id="$(subscription_clash_value "$record" "reality-opts.short-id")"
    alpn="$(subscription_clash_value "$record" "alpn" | sed 's/^\[//;s/\]$//;s/[[:space:]]//g')"
    fingerprint="$(subscription_clash_value "$record" "client-fingerprint")"
    [ -n "$fingerprint" ] || fingerprint="$(subscription_clash_value "$record" "fingerprint")"
    fingerprint="$(subscription_normalize_utls_fingerprint "$fingerprint")"
    [ -n "$name" ] || name="$server:$port"

    [ -n "$type" ] && [ -n "$server" ] && [ -n "$port" ] || return 1

    case "$type" in
    ss | shadowsocks)
        cipher="$(subscription_clash_value "$record" "cipher")"
        password="$(subscription_clash_value "$record" "password")"
        [ -n "$cipher" ] && [ -n "$password" ] || return 1
        [ "$cipher" = "ss" ] && return 1
        jq -cn --arg tag "$name" --arg server "$server" --arg port "$port" --arg method "$cipher" --arg password "$password" '
            {type:"shadowsocks", tag:$tag, server:$server, server_port:($port|tonumber), method:$method, password:$password}'
        ;;
    vmess)
        uuid="$(subscription_clash_value "$record" "uuid")"
        alter_id="$(subscription_clash_value "$record" "alterId")"
        [ -n "$alter_id" ] || alter_id="$(subscription_clash_value "$record" "alter-id")"
        cipher="$(subscription_clash_value "$record" "cipher")"
        [ -n "$cipher" ] || cipher="auto"
        [ -n "$uuid" ] || return 1
        jq -cn \
            --arg type "vmess" --arg tag "$name" --arg server "$server" --arg port "$port" \
            --arg uuid "$uuid" --arg alter_id "$alter_id" --arg security "$cipher" \
            --arg tls "$(subscription_bool_json "$tls")" \
            --arg skip_verify "$(subscription_bool_json "$skip_verify")" \
            --arg sni "$sni" --arg alpn "$alpn" --arg fingerprint "$fingerprint" \
            --arg network "$network" --arg ws_path "$ws_path" --arg ws_host "$ws_host" --arg grpc_service_name "$grpc_service_name" '
            {
                type:$type, tag:$tag, server:$server, server_port:($port|tonumber), uuid:$uuid, security:$security
            }
            + (if $alter_id != "" then {alter_id:($alter_id|tonumber)} else {} end)
            + (if $tls == "true" or $sni != "" or $fingerprint != "" then
                {tls: ({enabled:true}
                    + (if $sni != "" then {server_name:$sni} else {} end)
                    + (if $skip_verify == "true" then {insecure:true} else {} end)
                    + (if $alpn != "" then {alpn:($alpn|split(","))} else {} end)
                    + (if $fingerprint != "" then {utls:{enabled:true,fingerprint:$fingerprint}} else {} end))}
            else {} end)
            + (if $network == "ws" then {transport:({type:"ws", path:(if $ws_path != "" then $ws_path else "/" end)} + (if $ws_host != "" then {headers:{Host:$ws_host}} else {} end))}
               elif $network == "grpc" then {transport:({type:"grpc"} + (if $grpc_service_name != "" then {service_name:$grpc_service_name} else {} end))}
               else {} end)'
        ;;
    vless)
        uuid="$(subscription_clash_value "$record" "uuid")"
        flow="$(subscription_clash_value "$record" "flow")"
        packet_encoding="$(subscription_clash_value "$record" "packet-encoding")"
        [ -n "$packet_encoding" ] || packet_encoding="$(subscription_clash_value "$record" "packetEncoding")"
        packet_encoding="$(subscription_normalize_packet_encoding "$packet_encoding")"
        [ -n "$uuid" ] || return 1
        subscription_vless_flow_is_supported "$flow" || return 1
        jq -cn \
            --arg tag "$name" --arg server "$server" --arg port "$port" --arg uuid "$uuid" \
            --arg flow "$flow" --arg packet_encoding "$packet_encoding" \
            --arg tls "$(subscription_bool_json "$tls")" \
            --arg skip_verify "$(subscription_bool_json "$skip_verify")" \
            --arg sni "$sni" --arg alpn "$alpn" --arg fingerprint "$fingerprint" \
            --arg reality_public_key "$reality_public_key" --arg reality_short_id "$reality_short_id" \
            --arg network "$network" --arg ws_path "$ws_path" --arg ws_host "$ws_host" --arg grpc_service_name "$grpc_service_name" '
            {
                type:"vless", tag:$tag, server:$server, server_port:($port|tonumber), uuid:$uuid
            }
            + (if $flow != "" then {flow:$flow} else {} end)
            + (if $packet_encoding != "" then {packet_encoding:$packet_encoding} else {} end)
            + (if $tls == "true" or $sni != "" or $fingerprint != "" or $reality_public_key != "" then
                {tls: ({enabled:true}
                    + (if $sni != "" then {server_name:$sni} else {} end)
                    + (if $skip_verify == "true" then {insecure:true} else {} end)
                    + (if $alpn != "" then {alpn:($alpn|split(","))} else {} end)
                    + (if $reality_public_key != "" then
                        {utls:{enabled:true,fingerprint:(if $fingerprint != "" then $fingerprint else "chrome" end)}}
                    elif $fingerprint != "" then
                        {utls:{enabled:true,fingerprint:$fingerprint}}
                    else {} end)
                    + (if $reality_public_key != "" then {reality:({enabled:true, public_key:$reality_public_key} + (if $reality_short_id != "" then {short_id:$reality_short_id} else {} end))} else {} end))}
            else {} end)
            + (if $network == "ws" then {transport:({type:"ws", path:(if $ws_path != "" then $ws_path else "/" end)} + (if $ws_host != "" then {headers:{Host:$ws_host}} else {} end))}
               elif $network == "grpc" then {transport:({type:"grpc"} + (if $grpc_service_name != "" then {service_name:$grpc_service_name} else {} end))}
               else {} end)'
        ;;
    trojan)
        password="$(subscription_clash_value "$record" "password")"
        [ -n "$password" ] || return 1
        jq -cn \
            --arg tag "$name" --arg server "$server" --arg port "$port" --arg password "$password" \
            --arg tls "$(subscription_bool_json "$tls")" \
            --arg skip_verify "$(subscription_bool_json "$skip_verify")" \
            --arg sni "$sni" --arg alpn "$alpn" --arg fingerprint "$fingerprint" \
            --arg reality_public_key "$reality_public_key" --arg reality_short_id "$reality_short_id" \
            --arg network "$network" --arg ws_path "$ws_path" --arg ws_host "$ws_host" --arg grpc_service_name "$grpc_service_name" '
            {
                type:"trojan", tag:$tag, server:$server, server_port:($port|tonumber), password:$password
            }
            + {tls: ({enabled:true}
                + (if $sni != "" then {server_name:$sni} else {} end)
                + (if $skip_verify == "true" then {insecure:true} else {} end)
                + (if $alpn != "" then {alpn:($alpn|split(","))} else {} end)
                + (if $reality_public_key != "" then
                    {utls:{enabled:true,fingerprint:(if $fingerprint != "" then $fingerprint else "chrome" end)}}
                elif $fingerprint != "" then
                    {utls:{enabled:true,fingerprint:$fingerprint}}
                else {} end)
                + (if $reality_public_key != "" then {reality:({enabled:true, public_key:$reality_public_key} + (if $reality_short_id != "" then {short_id:$reality_short_id} else {} end))} else {} end))}
            + (if $network == "ws" then {transport:({type:"ws", path:(if $ws_path != "" then $ws_path else "/" end)} + (if $ws_host != "" then {headers:{Host:$ws_host}} else {} end))}
               elif $network == "grpc" then {transport:({type:"grpc"} + (if $grpc_service_name != "" then {service_name:$grpc_service_name} else {} end))}
               else {} end)'
        ;;
    hysteria2 | hy2)
        password="$(subscription_clash_value "$record" "password")"
        obfs="$(subscription_clash_value "$record" "obfs")"
        obfs_password="$(subscription_clash_value "$record" "obfs-password")"
        [ -n "$obfs_password" ] || obfs_password="$(subscription_clash_value "$record" "obfs-opts.password")"
        [ -n "$password" ] || return 1
        jq -cn \
            --arg tag "$name" --arg server "$server" --arg port "$port" --arg password "$password" \
            --arg skip_verify "$(subscription_bool_json "$skip_verify")" \
            --arg sni "$sni" --arg alpn "$alpn" --arg obfs "$obfs" --arg obfs_password "$obfs_password" '
            {
                type:"hysteria2", tag:$tag, server:$server, server_port:($port|tonumber), password:$password,
                tls: ({enabled:true}
                    + (if $sni != "" then {server_name:$sni} else {} end)
                    + (if $skip_verify == "true" then {insecure:true} else {} end)
                    + (if $alpn != "" then {alpn:($alpn|split(","))} else {} end))
            }
            + (if $obfs != "" and $obfs != "none" then {obfs:({type:$obfs} + (if $obfs_password != "" then {password:$obfs_password} else {} end))} else {} end)'
        ;;
    socks5 | socks)
        username="$(subscription_clash_value "$record" "username")"
        password="$(subscription_clash_value "$record" "password")"
        jq -cn --arg tag "$name" --arg server "$server" --arg port "$port" --arg username "$username" --arg password "$password" '
            {type:"socks", tag:$tag, server:$server, server_port:($port|tonumber), version:"5"}
            + (if $username != "" then {username:$username} else {} end)
            + (if $password != "" then {password:$password} else {} end)'
        ;;
    *)
        return 1
        ;;
    esac
}

subscription_normalize_clash_yaml_file() {
    local input="$1"
    local output="$2"
    local records jsonl record added skipped

    records="$(mktemp)" || return 1
    jsonl="$(mktemp)" || {
        rm -f "$records"
        return 1
    }

    subscription_clash_yaml_records "$input" > "$records"

    added=0
    skipped=0
    while IFS= read -r record || [ -n "$record" ]; do
        [ -n "$record" ] || continue
        if subscription_parse_clash_record "$record" >> "$jsonl"; then
            added=$((added + 1))
        else
            skipped=$((skipped + 1))
            log "Skip unsupported or invalid Clash proxy entry" "warn"
        fi
    done < "$records"

    rm -f "$records"

    if [ "$added" -eq 0 ]; then
        rm -f "$jsonl"
        return 1
    fi

    jq -s --argjson skipped "$skipped" '{
        version: 1,
        format: "clash-yaml",
        skipped: $skipped,
        outbounds: .
    }' "$jsonl" > "$output"
    rm -f "$jsonl"
}

subscription_normalize_content_file() {
    local input="$1"
    local output="$2"
    local depth="${3:-0}"
    local decoded_tmp

    convert_crlf_to_lf "$input"
    subscription_strip_metadata_preamble_file "$input"

    if jq -e . "$input" >/dev/null 2>&1; then
        subscription_normalize_sing_box_json_file "$input" "$output" || return 1
        subscription_validate_normalized_file "$output"
        return $?
    fi

    if subscription_content_is_clash_yaml "$input"; then
        subscription_normalize_clash_yaml_file "$input" "$output" || return 1
        subscription_validate_normalized_file "$output"
        return $?
    fi

    if subscription_content_has_share_links "$input"; then
        subscription_normalize_uri_list_file "$input" "$output" || return 1
        subscription_validate_normalized_file "$output"
        return $?
    fi

    if [ "$depth" -lt 1 ]; then
        decoded_tmp="$(mktemp)" || return 1
        if subscription_try_base64_decode_file "$input" "$decoded_tmp"; then
            if subscription_normalize_content_file "$decoded_tmp" "$output" $((depth + 1)); then
                rm -f "$decoded_tmp"
                return 0
            fi
        fi
        rm -f "$decoded_tmp"
    fi

    return 1
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
