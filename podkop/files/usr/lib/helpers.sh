helpers_ucode() {
    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/helpers.uc" "$@"
}

trim_string() {
    helpers_ucode stdin-trim-string
}

# Check if string is valid IPv4
is_ipv4() {
    helpers_ucode valid-ipv4 "$1" >/dev/null 2>&1
}

# Check if string is valid IPv4 with CIDR mask
is_ipv4_cidr() {
    helpers_ucode valid-ipv4-cidr "$1" >/dev/null 2>&1
}

is_ipv4_ip_or_ipv4_cidr() {
    is_ipv4 "$1" || is_ipv4_cidr "$1"
}

is_domain() {
    helpers_ucode valid-domain "$1" >/dev/null 2>&1
}

is_domain_suffix() {
    helpers_ucode valid-domain-suffix "$1" >/dev/null 2>&1
}

# Compares the current package version with the required minimum
is_min_package_version() {
    local current="$1"
    local required="$2"

    helpers_ucode version-at-least "$current" "$required" >/dev/null 2>&1
}

get_apk_installed_package_version() {
    local package_name="$1"
    local version

    version="$(
        apk list --installed --manifest "$package_name" 2>/dev/null |
            updates_ucode updates-apk-manifest-package-version "$package_name"
    )"

    if [ -z "$version" ]; then
        version="$(
            apk list --installed --manifest 2>/dev/null |
                updates_ucode updates-apk-manifest-package-version "$package_name"
        )"
    fi

    if [ -n "$version" ]; then
        echo "$version"
        return 0
    fi

    apk info -v "$package_name" 2>/dev/null |
        updates_ucode updates-apk-info-package-version "$package_name"
}

# Checks if the given file exists
file_exists() {
    local filepath="$1"

    if [ -f "$filepath" ]; then
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

list_has_item() {
    local list="$1"
    local needle="$2"
    helpers_ucode whitespace-list-contains "$list" "$needle" >/dev/null 2>&1
}

allocate_runtime_tag() {
    local base="$1"
    local postfix="$2"

    helpers_ucode allocate-runtime-tag \
        "$base" \
        "$postfix" \
        "${SB_DNS_SERVER_TAG:-dns-server}" \
        "${SB_FAKEIP_DNS_SERVER_TAG:-fakeip-server}" \
        "${SB_BOOTSTRAP_SERVER_TAG:-bootstrap-dns-server}" \
        "${SB_FAKEIP_DNS_RULE_TAG:-fakeip-dns-rule-tag}" \
        "${SB_FAKEIP_RULESET_DNS_RULE_TAG:-fakeip-ruleset-dns-rule-tag}" \
        "${SB_SERVICE_FAKEIP_DNS_RULE_TAG:-service-fakeip-dns-rule-tag}" \
        "${SB_TPROXY_INBOUND_TAG:-tproxy-in}" \
        "${SB_DNS_INBOUND_TAG:-dns-in}" \
        "${SB_SERVICE_MIXED_INBOUND_TAG:-service-mixed-in}" \
        "${SB_DIRECT_OUTBOUND_TAG:-direct-out}"
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

get_tailscale_dns_server_tag_by_section() {
    local section="$1"

    allocate_runtime_tag "server-$section" "tailscale-dns"
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

config_list_to_json() {
    local section="$1"
    local option="$2"
    local value

    CONFIG_LIST_VALUES_SEEN=0
    {
        config_list_foreach "$section" "$option" config_list_print_value
        if [ "$CONFIG_LIST_VALUES_SEEN" -eq 0 ]; then
            config_get value "$section" "$option"
            if [ -n "$value" ]; then
                printf '%s\n' "$value"
            fi
        fi
    } | helpers_ucode stdin-lines-to-json-array
}

config_list_print_value() {
    local value="$1"

    CONFIG_LIST_VALUES_SEEN=1
    printf '%s\n' "$value"
}

# Returns the scheme (protocol) part of a URL
url_get_scheme() {
    helpers_ucode url-get-scheme "$1"
}

# Extracts the userinfo (username[:password]) part from a URL
url_get_userinfo() {
    helpers_ucode url-get-userinfo "$1"
}

# Extracts the host part from a URL
url_get_host() {
    helpers_ucode url-get-host "$1"
}

# Extracts the port number from a URL
url_get_port() {
    helpers_ucode url-get-port "$1"
}

# Extracts the path from a URL (without query or fragment; returns "/" if empty)
url_get_path() {
    helpers_ucode url-get-path "$1"
}

# Extracts the value of a specific query parameter from a URL
url_get_query_param() {
    helpers_ucode url-get-query-param "$1" "$2"
}

# Extracts and returns the file extension from the given URL
url_get_file_extension() {
    helpers_ucode url-file-extension "$1"
}

# Remove url fragment (everything after the first '#')
url_strip_fragment() {
    helpers_ucode url-strip-fragment "$1"
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
    printf '%s%s' "$(date +%s)" "$RANDOM" | md5sum | helpers_ucode md5sum-hex-prefix 16
}

# Download URL to file
download_to_file() {
    local url="$1"
    local filepath="$2"
    local http_proxy_address="$3"
    local retries="${4:-3}"
    local wait="${5:-2}"

    attempt=1
    while [ "$attempt" -le "$retries" ]; do
        if [ -n "$http_proxy_address" ]; then
            http_proxy="http://$http_proxy_address" https_proxy="http://$http_proxy_address" wget -O "$filepath" "$url" && break
        else
            wget -O "$filepath" "$url" && break
        fi

        log "Attempt $attempt/$retries to download $url failed" "warn"
        sleep "$wait"
        attempt=$((attempt + 1))
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
        version="$(sing-box version 2>/dev/null | helpers_ucode stdin-first-line-last-field)"
    fi

    echo "$version"
}

sing_box_version_output() {
    command -v sing-box >/dev/null 2>&1 || return 1
    sing-box version 2>/dev/null
}

sing_box_has_build_tag() {
    local tag="$1"

    [ -n "$tag" ] || return 1
    sing_box_version_output | grep -Eq "(^|[,:[:space:]])${tag}([,[:space:]]|$)"
}

is_sing_box_extended() {
    local version="${1:-}"

    [ -n "$version" ] || version="$(get_sing_box_version)"
    helpers_ucode sing-box-version-is-extended "$version" >/dev/null 2>&1
}

is_sing_box_tiny_package_installed() {
    if command -v apk >/dev/null 2>&1; then
        apk info -e sing-box-tiny >/dev/null 2>&1
        return $?
    fi

    opkg_package_is_installed sing-box-tiny
}

is_sing_box_full_package_installed() {
    if command -v apk >/dev/null 2>&1; then
        apk info -e sing-box >/dev/null 2>&1
        return $?
    fi

    opkg_package_is_installed sing-box
}

is_sing_box_compressed_marker_set() {
    [ -r "${SB_VARIANT_STATE_FILE:-/etc/podkop-plus/sing-box-variant}" ] || return 1
    [ "$(cat "${SB_VARIANT_STATE_FILE:-/etc/podkop-plus/sing-box-variant}" 2>/dev/null)" = "extended-compressed" ]
}

is_sing_box_tiny_marker_set() {
    [ -r "${SB_VARIANT_STATE_FILE:-/etc/podkop-plus/sing-box-variant}" ] || return 1
    [ "$(cat "${SB_VARIANT_STATE_FILE:-/etc/podkop-plus/sing-box-variant}" 2>/dev/null)" = "tiny" ]
}

is_sing_box_tiny() {
    is_sing_box_extended && return 1
    is_sing_box_tiny_package_installed && return 0
    is_sing_box_tiny_marker_set || return 1
    sing_box_supports_tailscale && return 1
    return 0
}

sing_box_supports_tailscale() {
    is_sing_box_extended && return 0
    sing_box_has_build_tag with_tailscale
}

get_sing_box_variant() {
    if ! command -v sing-box >/dev/null 2>&1; then
        printf '%s\n' "not-installed"
        return 0
    fi

    if is_sing_box_extended; then
        if is_sing_box_compressed_marker_set; then
            printf '%s\n' "extended-compressed"
        else
            printf '%s\n' "extended"
        fi
        return 0
    fi

    if is_sing_box_tiny; then
        printf '%s\n' "tiny"
        return 0
    fi

    printf '%s\n' "stable"
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

normalize_strategy_whitespace() {
    helpers_ucode normalize-strategy-whitespace "$1"
}

generate_hwid() {
    local mac="" model=""

    if [ -f /sys/class/net/eth0/address ]; then
        mac="$(cat /sys/class/net/eth0/address 2>/dev/null)"
    elif [ -f /sys/class/net/br-lan/address ]; then
        mac="$(cat /sys/class/net/br-lan/address 2>/dev/null)"
    fi

    model="$(get_device_model)"
    printf '%s-%s' "$mac" "$model" | md5sum | helpers_ucode md5sum-hwid
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

    attempt=1
    while [ "$attempt" -le "$retries" ]; do
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
        attempt=$((attempt + 1))
    done

    rm -f "$tmpfile"
    [ -n "$headers_tmpfile" ] && rm -f "$headers_tmpfile"
    return 1
}

updates_ucode() {
    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/updater.uc" "$@"
}

opkg_package_is_installed() {
    local package_name="$1"

    command -v opkg >/dev/null 2>&1 || return 1
    opkg list-installed 2>/dev/null | updates_ucode updates-opkg-package-installed "$package_name"
}

get_opkg_installed_package_version() {
    local package_name="$1"

    command -v opkg >/dev/null 2>&1 || return 0
    opkg list-installed 2>/dev/null | updates_ucode updates-opkg-package-version "$package_name"
}

validate_subscription_file() {
    local filepath="$1"

    [ -s "$filepath" ] || return 1

    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/subscription_parser.uc" validate-subscription "$filepath" >/dev/null 2>&1
}

provider_status_ucode() {
    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/provider_status.uc" "$@"
}

# Converts Windows-style line endings (CRLF) to Unix-style (LF)
convert_crlf_to_lf() {
    local filepath="$1"

    if helpers_ucode file-has-cr "$filepath" >/dev/null 2>&1; then
        log "File '$filepath' contains CRLF line endings. Converting to LF..." "debug"
        helpers_ucode file-remove-cr "$filepath" >/dev/null 2>&1
    fi
}
