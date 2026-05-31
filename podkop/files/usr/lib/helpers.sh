# Check if string is valid IPv4
is_ipv4() {
    local ip="$1"
    local regex="^((25[0-5]|(2[0-4]|1\d|[1-9]|)\d)\.?\b){4}$"
    [[ "$ip" =~ $regex ]]
}

# Check if string is valid IPv4 with CIDR mask
is_ipv4_cidr() {
    local ip="$1"
    local regex="^((25[0-5]|(2[0-4]|1\d|[1-9]|)\d)\.?\b){4}(\/(3[0-2]|2[0-9]|1[0-9]|[0-9]))$"
    [[ "$ip" =~ $regex ]]
}

is_ipv4_ip_or_ipv4_cidr() {
    is_ipv4 "$1" || is_ipv4_cidr "$1"
}

is_domain() {
    local str="$1"
    local regex='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$'

    [[ "$str" =~ $regex ]]
}

is_domain_suffix() {
    local str="$1"
    local normalized="${str#.}"

    is_domain "$normalized"
}

# Checks if the given string looks like a Shadowsocks userinfo
is_shadowsocks_userinfo_format() {
    local str="$1"
    local regex='^[^:]+:[^:]+(:[^:]+)?$'

    [[ "$str" =~ $regex ]]
}

# Compares the current package version with the required minimum
is_min_package_version() {
    local current="$1"
    local required="$2"

    local lowest
    lowest="$(printf '%s\n' "$current" "$required" | sort -V | head -n1)"

    [ "$lowest" = "$required" ]
}

get_apk_installed_package_version() {
    local package_name="$1"
    local version

    version="$(
        apk list --installed --manifest "$package_name" 2>/dev/null |
            awk -v pkg="$package_name" '$1 == pkg { print $2; exit }'
    )"

    if [ -z "$version" ]; then
        version="$(
            apk list --installed --manifest 2>/dev/null |
                awk -v pkg="$package_name" '$1 == pkg { print $2; exit }'
        )"
    fi

    if [ -n "$version" ]; then
        echo "$version"
        return 0
    fi

    apk info -v "$package_name" 2>/dev/null |
        awk -v pkg="$package_name" '
            NR == 1 {
                prefix = pkg "-"
                if (index($0, prefix) == 1) {
                    version = substr($0, length(prefix) + 1)
                    sub(/[[:space:]].*$/, "", version)
                    print version
                }
                exit
            }
        '
}

# Checks if the given file exists
file_exists() {
    local filepath="$1"

    if [[ -f "$filepath" ]]; then
        return 0
    else
        return 1
    fi
}

# Checks if a service script exists in /etc/init.d
service_exists() {
    local service="$1"

    if [ -x "/etc/init.d/$service" ]; then
        return 0
    else
        return 1
    fi
}

runtime_tag_is_reserved() {
    local tag="$1"
    local reserved

    for reserved in \
        "${SB_DNS_SERVER_TAG:-dns-server}" \
        "${SB_FAKEIP_DNS_SERVER_TAG:-fakeip-server}" \
        "${SB_BOOTSTRAP_SERVER_TAG:-bootstrap-dns-server}" \
        "${SB_FAKEIP_DNS_RULE_TAG:-fakeip-dns-rule-tag}" \
        "${SB_FAKEIP_RULESET_DNS_RULE_TAG:-fakeip-ruleset-dns-rule-tag}" \
        "${SB_SERVICE_FAKEIP_DNS_RULE_TAG:-service-fakeip-dns-rule-tag}" \
        "${SB_TPROXY_INBOUND_TAG:-tproxy-in}" \
        "${SB_DNS_INBOUND_TAG:-dns-in}" \
        "${SB_SERVICE_MIXED_INBOUND_TAG:-service-mixed-in}" \
        "${SB_DIRECT_OUTBOUND_TAG:-direct-out}"; do
        [ "$tag" = "$reserved" ] && return 0
    done

    return 1
}

allocate_runtime_tag() {
    local base="$1"
    local postfix="$2"
    local candidate="$base-$postfix"
    local suffix=1
    local parent

    case "$base" in
    *-[0-9]*)
        parent="${base%-*}"
        if runtime_tag_is_reserved "$parent-$postfix"; then
            candidate="$base-$suffix-$postfix"
            suffix=$((suffix + 1))
        fi
        ;;
    esac
    while runtime_tag_is_reserved "$candidate"; do
        candidate="$base-$suffix-$postfix"
        suffix=$((suffix + 1))
    done

    echo "$candidate"
}

# Returns the inbound tag name by appending the postfix to the given section
get_inbound_tag_by_section() {
    local section="$1"

    allocate_runtime_tag "$section" "in"
}

get_server_inbound_tag_by_section() {
    local section="$1"

    allocate_runtime_tag "server-$section" "in"
}

# Returns the outbound tag name by appending the postfix to the given section
get_outbound_tag_by_section() {
    local section="$1"

    allocate_runtime_tag "$section" "out"
}

# Constructs and returns a domain resolver tag by appending a fixed postfix to the given section
get_domain_resolver_tag() {
    local section="$1"

    allocate_runtime_tag "$section" "domain-resolver"
}

# Converts a comma-separated string into a JSON array string
comma_string_to_json_array() {
    local input="$1"

    if [ -z "$input" ]; then
        echo "[]"
        return
    fi

    local replaced="${input//,/\",\"}"

    echo "[\"$replaced\"]"
}

normalize_port_number() {
    local value="$1"

    value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$value" ] || return 1

    case "$value" in
    *[!0-9]*) return 1 ;;
    esac

    awk -v value="$value" 'BEGIN {
        if (value ~ /^[0-9]+$/) {
            number = value + 0
            if (number >= 1 && number <= 65535) {
                print number
                exit 0
            }
        }
        exit 1
    }'
}

normalize_port_condition_for_nft() {
    local value="$1"
    local start end

    value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$value" ] || return 1

    case "$value" in
    *-*)
        start="${value%%-*}"
        end="${value#*-}"
        [ "$start-$end" = "$value" ] || return 1
        start="$(normalize_port_number "$start")" || return 1
        end="$(normalize_port_number "$end")" || return 1
        [ "$start" -le "$end" ] || return 1

        if [ "$start" = "$end" ]; then
            printf '%s\n' "$start"
        else
            printf '%s-%s\n' "$start" "$end"
        fi
        ;;
    *)
        normalize_port_number "$value"
        ;;
    esac
}

normalize_port_range_for_sing_box() {
    local value="$1"
    local start end

    value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "$value" in
    *-*)
        start="${value%%-*}"
        end="${value#*-}"
        [ "$start-$end" = "$value" ] || return 1
        start="$(normalize_port_number "$start")" || return 1
        end="$(normalize_port_number "$end")" || return 1
        [ "$start" -le "$end" ] || return 1
        printf '%s:%s\n' "$start" "$end"
        ;;
    *)
        return 1
        ;;
    esac
}

is_port_condition() {
    normalize_port_condition_for_nft "$1" > /dev/null 2>&1
}

port_numbers_to_json_array() {
    local input="$1"

    if [ -z "$input" ]; then
        echo "[]"
        return
    fi

    printf '[%s]\n' "$input"
}

# Decodes a URL-encoded string
url_decode() {
    local encoded="$1"
    printf '%b' "$(echo "$encoded" | sed 's/+/ /g; s/%/\\x/g')"
}

# Returns the scheme (protocol) part of a URL
url_get_scheme() {
    local url="$1"
    echo "${url%%://*}"
}

# Extracts the userinfo (username[:password]) part from a URL
url_get_userinfo() {
    local url="$1"
    echo "$url" | sed -n -e 's#^[^:/?]*://##' -e '/@/!d' -e 's/@.*//p'
}

# Extracts the host part from a URL
url_get_host() {
    local url="$1"

    url="${url#*://}"
    url="${url#*@}"
    url="${url%%[/?#]*}"

    echo "${url%%:*}"
}

# Extracts the port number from a URL
url_get_port() {
    local url="$1"

    url="${url#*://}"
    url="${url#*@}"
    url="${url%%[/?#]*}"

    [[ "$url" == *:* ]] && echo "${url#*:}" || echo ""
}

# Extracts the path from a URL (without query or fragment; returns "/" if empty)
url_get_path() {
    local url="$1"
    echo "$url" | sed -n -e 's#^[^:/?]*://##' -e 's#^[^/]*##' -e 's#\([^?]*\).*#\1#p'
}

# Extracts the value of a specific query parameter from a URL
url_get_query_param() {
    local url="$1"
    local param="$2"

    local raw
    raw=$(echo "$url" | sed -n "s/.*[?&]$param=\([^&?#]*\).*/\1/p")

    [ -z "$raw" ] && echo "" && return

    echo "$raw"
}

# Extracts and returns the file extension from the given URL
url_get_file_extension() {
    local url="$1"

    local basename="${url##*/}"
    basename="${basename%%[?#]*}"
    case "$basename" in
    *.*) echo "${basename##*.}" | tr '[:upper:]' '[:lower:]' ;;
    *) echo "" ;;
    esac
}

# Remove url fragment (everything after the first '#')
url_strip_fragment() {
    local url="$1"

    echo "${url%%#*}"
}

# Decodes and returns a base64-encoded string
base64_decode() {
    local str="$1"
    local decoded_url

    decoded_url="$(echo "$str" | base64 -d 2> /dev/null)"

    echo "$decoded_url"
}

# Generates a unique 16-character ID based on the current timestamp and a random number
gen_id() {
    printf '%s%s' "$(date +%s)" "$RANDOM" | md5sum | cut -c1-16
}

# Download URL to file
download_to_file() {
    local url="$1"
    local filepath="$2"
    local http_proxy_address="$3"
    local retries="${4:-3}"
    local wait="${5:-2}"

    for attempt in $(seq 1 "$retries"); do
        if [ -n "$http_proxy_address" ]; then
            http_proxy="http://$http_proxy_address" https_proxy="http://$http_proxy_address" wget -O "$filepath" "$url" && break
        else
            wget -O "$filepath" "$url" && break
        fi

        log "Attempt $attempt/$retries to download $url failed" "warn"
        sleep "$wait"
    done
}

get_device_model() {
    local model=""

    if [ -f /tmp/sysinfo/model ]; then
        model="$(cat /tmp/sysinfo/model 2>/dev/null)"
    fi

    echo "${model:-OpenWrt Router}"
}

get_kernel_version() {
    uname -r
}

get_sing_box_version() {
    local version=""

    if command -v sing-box >/dev/null 2>&1; then
        version="$(sing-box version 2>/dev/null | head -1 | awk '{print $NF}')"
    fi

    echo "$version"
}

is_sing_box_extended() {
    local version="${1:-}"

    [ -n "$version" ] || version="$(get_sing_box_version)"

    case "$version" in
    *extended*) return 0 ;;
    esac

    return 1
}

get_subscription_user_agent() {
    local custom_user_agent="${1:-}"

    if [ -n "$custom_user_agent" ]; then
        printf '%s' "$custom_user_agent"
        return 0
    fi

    local sing_box_version

    sing_box_version="$(get_sing_box_version)"
    [ -n "$sing_box_version" ] || sing_box_version="unknown"

    printf 'sing-box/%s' "$sing_box_version"
}

generate_hwid() {
    local mac="" model="" raw_hash=""

    if [ -f /sys/class/net/eth0/address ]; then
        mac="$(cat /sys/class/net/eth0/address 2>/dev/null)"
    elif [ -f /sys/class/net/br-lan/address ]; then
        mac="$(cat /sys/class/net/br-lan/address 2>/dev/null)"
    fi

    model="$(get_device_model)"
    raw_hash="$(printf '%s-%s' "$mac" "$model" | md5sum | cut -c1-16)"

    printf '%s-%s-%s-%s' \
        "$(echo "$raw_hash" | cut -c1-4)" \
        "$(echo "$raw_hash" | cut -c5-8)" \
        "$(echo "$raw_hash" | cut -c9-12)" \
        "$(echo "$raw_hash" | cut -c13-16)"
}

download_subscription() {
    local url="$1"
    local filepath="$2"
    local http_proxy_address="$3"
    local retries="${4:-3}"
    local wait="${5:-2}"
    local timeout="${6:-10}"
    local headers_filepath="${7:-}"
    local custom_user_agent="${8:-}"
    local tmpfile headers_tmpfile attempt wget_status user_agent

    tmpfile="${filepath}.part.$$"
    headers_tmpfile=""
    user_agent="$(get_subscription_user_agent "$custom_user_agent")"
    [ -n "$headers_filepath" ] && headers_tmpfile="${headers_filepath}.part.$$"
    rm -f "$tmpfile"
    [ -n "$headers_tmpfile" ] && rm -f "$headers_tmpfile"

    for attempt in $(seq 1 "$retries"); do
        if [ -n "$http_proxy_address" ]; then
            if [ -n "$headers_tmpfile" ]; then
                curl -fL -sS \
                    --connect-timeout "$timeout" \
                    --speed-time "$timeout" \
                    --speed-limit 1 \
                    -x "http://$http_proxy_address" \
                    -D "$headers_tmpfile" \
                    -o "$tmpfile" \
                    -H "User-Agent: $user_agent" \
                    -H "X-HWID: $(generate_hwid)" \
                    -H "X-Device-OS: OpenWrt Linux" \
                    -H "X-Device-Model: $(get_device_model)" \
                    -H "X-Ver-OS: $(get_kernel_version)" \
                    -H "Accept-Language: ru-RU,en,*" \
                    -H "X-Device-Locale: EN" \
                    "$url"
            else
                http_proxy="http://$http_proxy_address" https_proxy="http://$http_proxy_address" \
                    wget -T "$timeout" -O "$tmpfile" \
                        --header "User-Agent: $user_agent" \
                        --header "X-HWID: $(generate_hwid)" \
                        --header "X-Device-OS: OpenWrt Linux" \
                        --header "X-Device-Model: $(get_device_model)" \
                        --header "X-Ver-OS: $(get_kernel_version)" \
                        --header "Accept-Language: ru-RU,en,*" \
                        --header "X-Device-Locale: EN" \
                        "$url"
            fi
            wget_status=$?
        else
            if [ -n "$headers_tmpfile" ]; then
                curl -fL -sS \
                    --connect-timeout "$timeout" \
                    --speed-time "$timeout" \
                    --speed-limit 1 \
                    -D "$headers_tmpfile" \
                    -o "$tmpfile" \
                    -H "User-Agent: $user_agent" \
                    -H "X-HWID: $(generate_hwid)" \
                    -H "X-Device-OS: OpenWrt Linux" \
                    -H "X-Device-Model: $(get_device_model)" \
                    -H "X-Ver-OS: $(get_kernel_version)" \
                    -H "Accept-Language: ru-RU,en,*" \
                    -H "X-Device-Locale: EN" \
                    "$url"
            else
                wget -T "$timeout" -O "$tmpfile" \
                    --header "User-Agent: $user_agent" \
                    --header "X-HWID: $(generate_hwid)" \
                    --header "X-Device-OS: OpenWrt Linux" \
                    --header "X-Device-Model: $(get_device_model)" \
                    --header "X-Ver-OS: $(get_kernel_version)" \
                    --header "Accept-Language: ru-RU,en,*" \
                    --header "X-Device-Locale: EN" \
                    "$url"
            fi
            wget_status=$?
        fi

        if [ "$wget_status" -eq 0 ] && [ -s "$tmpfile" ]; then
            mv "$tmpfile" "$filepath"
            if [ -n "$headers_tmpfile" ]; then
                if [ -s "$headers_tmpfile" ]; then
                    mv "$headers_tmpfile" "$headers_filepath"
                else
                    rm -f "$headers_filepath" "$headers_tmpfile"
                fi
            fi
            return 0
        fi

        rm -f "$tmpfile"
        [ -n "$headers_tmpfile" ] && rm -f "$headers_tmpfile"
        log "Attempt $attempt/$retries to download subscription failed" "warn"
        sleep "$wait"
    done

    rm -f "$tmpfile"
    [ -n "$headers_tmpfile" ] && rm -f "$headers_tmpfile"
    return 1
}

json_utils_ucode() {
    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/json_utils.uc" "$@"
}

validate_subscription_file() {
    local filepath="$1"

    [ -s "$filepath" ] || return 1

    json_utils_ucode validate-subscription "$filepath" >/dev/null 2>&1
}

provider_status_ucode() {
    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/provider_status.uc" "$@"
}

# Converts Windows-style line endings (CRLF) to Unix-style (LF)
convert_crlf_to_lf() {
    local filepath="$1"

    if grep -q $'\r' "$filepath"; then
        log "File '$filepath' contains CRLF line endings. Converting to LF..." "debug"
        local tmpfile
        tmpfile=$(mktemp)
        tr -d '\r' < "$filepath" > "$tmpfile" && mv "$tmpfile" "$filepath" || rm -f "$tmpfile"
    fi
}

#######################################
# Parses a whitespace-separated string, validates items as either domains
# or IPv4 addresses/subnets, and returns a comma-separated string of valid items.
# Arguments:
#   $1 - Input string (space-separated list of items)
#   $2 - Type of validation ("domains" or "subnets")
# Outputs:
#   Comma-separated string of valid domains or subnets
#######################################
parse_domain_or_subnet_string_to_commas_string() {
    local string="$1"
    local type="$2"

    tmpfile=$(mktemp)
    printf "%s\n" "$string" | sed -e 's/[[:space:]]*\/\/.*$//' -e 's/[[:space:]]*#.*$//' | tr ', ' '\n' | grep -v '^$' > "$tmpfile"

    result="$(parse_domain_or_subnet_file_to_comma_string "$tmpfile" "$type")"
    rm -f "$tmpfile"

    echo "$result"
}

#######################################
# Parses a file line by line, validates entries as either domains or subnets,
# and returns a single comma-separated string of valid items.
# Arguments:
#   $1 - Path to the input file
#   $2 - Type of validation ("domains" or "subnets")
# Outputs:
#   Comma-separated string of valid domains or subnets
#######################################
parse_domain_or_subnet_file_to_comma_string() {
    local filepath="$1"
    local type="$2"

    local result
    while IFS= read -r line; do
        line=$(printf "%s\n" "$line" | sed -e 's/[[:space:]]*\/\/.*$//' -e 's/[[:space:]]*#.*$//')
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        [ -z "$line" ] && continue

        case "$type" in
        domains)
            if ! is_domain_suffix "$line"; then
                log "'$line' is not a valid domain" "debug"
                continue
            fi
            ;;
        subnets)
            if ! is_ipv4 "$line" && ! is_ipv4_cidr "$line"; then
                log "'$line' is not IPv4 or IPv4 CIDR" "debug"
                continue
            fi
            ;;
        *)
            log "Unknown type: $type" "error"
            return 1
            ;;
        esac

        if [ -z "$result" ]; then
            result="$line"
        else
            result="$result,$line"
        fi
    done < "$filepath"

    echo "$result"
}

#######################################
# Splits a plain list file into separate domain and subnet files.
# Invalid items are skipped.
# Arguments:
#   $1 - Path to the input file
#   $2 - Output file for domains
#   $3 - Output file for IPv4 / IPv4 CIDR entries
#######################################
split_domain_or_subnet_file() {
    local filepath="$1"
    local domains_output="$2"
    local subnets_output="$3"
    local line

    : > "$domains_output"
    : > "$subnets_output"

    while IFS= read -r line; do
        line=$(printf "%s\n" "$line" | sed -e 's/[[:space:]]*\/\/.*$//' -e 's/[[:space:]]*#.*$//')
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        [ -z "$line" ] && continue

        if is_domain_suffix "$line"; then
            printf '%s\n' "$line" >> "$domains_output"
            continue
        fi

        if is_ipv4_ip_or_ipv4_cidr "$line"; then
            printf '%s\n' "$line" >> "$subnets_output"
            continue
        fi

        log "'$line' is neither a valid domain nor IPv4 / IPv4 CIDR" "debug"
    done < "$filepath"
}
