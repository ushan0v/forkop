// sing-box refuses an octet or prefix length with a leading zero and nft reads one as octal
// (010.0.0.1 is 8.0.0.1), so such a number is not part of an address here either.

function as_string(value) {
    return value == null ? "" : "" + value;
}

function decimal_text(value) {
    value = as_string(value);
    return match(value, /^(0|[1-9][0-9]*)$/) != null;
}

function valid_ipv4(value) {
    let parts = split(as_string(value), ".");
    if (length(parts) != 4)
        return false;

    for (let part in parts) {
        if (!decimal_text(part))
            return false;

        let octet = int(part);
        if (octet < 0 || octet > 255)
            return false;
    }

    return true;
}

function valid_ipv4_cidr(value) {
    value = as_string(value);
    let slash = index(value, "/");
    if (slash <= 0 || index(substr(value, slash + 1), "/") >= 0)
        return false;

    let prefix = substr(value, slash + 1);
    return decimal_text(prefix) && valid_ipv4(substr(value, 0, slash)) && int(prefix) <= 32;
}

function valid_ipv6_hextet(value) {
    value = as_string(value);
    return value != "" && length(value) <= 4 && match(value, /^[0-9A-Fa-f]+$/) != null;
}

function ipv6_parts_count(parts) {
    let count = 0;

    for (let i = 0; i < length(parts); i++) {
        let part = parts[i];
        if (part == "")
            return -1;

        if (index(part, ".") >= 0) {
            if (i != length(parts) - 1 || !valid_ipv4(part))
                return -1;
            count += 2;
            continue;
        }

        if (!valid_ipv6_hextet(part))
            return -1;
        count++;
    }

    return count;
}

function valid_ipv6(value) {
    value = as_string(value);
    if (value == "" || index(value, "/") >= 0 || index(value, "%") >= 0)
        return false;

    let marker = index(value, "::");
    if (marker >= 0) {
        if (index(substr(value, marker + 2), "::") >= 0)
            return false;

        let left = substr(value, 0, marker);
        let right = substr(value, marker + 2);
        let left_count = left == "" ? 0 : ipv6_parts_count(split(left, ":"));
        let right_count = right == "" ? 0 : ipv6_parts_count(split(right, ":"));

        return left_count >= 0 && right_count >= 0 && left_count + right_count < 8;
    }

    let count = ipv6_parts_count(split(value, ":"));
    return count == 8;
}

function valid_ipv6_cidr(value) {
    value = as_string(value);
    let slash = index(value, "/");
    if (slash <= 0 || index(substr(value, slash + 1), "/") >= 0)
        return false;

    let prefix = substr(value, slash + 1);
    return decimal_text(prefix) && valid_ipv6(substr(value, 0, slash)) && int(prefix) <= 128;
}

function valid_ip(value) {
    return valid_ipv4(value) || valid_ipv6(value);
}

function valid_ip_cidr(value) {
    return valid_ipv4_cidr(value) || valid_ipv6_cidr(value);
}

function valid_ip_or_cidr(value) {
    return valid_ip(value) || valid_ip_cidr(value);
}

// 4 or 6 for an address or a prefix, 0 for anything else.
function ip_family(value) {
    return valid_ipv4(value) || valid_ipv4_cidr(value) ? 4 : (valid_ipv6(value) || valid_ipv6_cidr(value) ? 6 : 0);
}

function network_bytes(bytes, bits) {
    return map(bytes, (byte, i) => {
        let kept = bits - i * 8;
        return kept >= 8 ? byte : kept <= 0 ? 0 : byte & ((0xff << (8 - kept)) & 0xff);
    });
}

function prefix_contains(prefix, address) {
    if (!valid_ip_cidr(prefix) || !valid_ip(address))
        return false;
    let parts = split(prefix, "/");
    let network = iptoarr(parts[0]);
    let bytes = iptoarr(address);
    let bits = int(parts[1]);
    return length(network) == length(bytes) &&
        join(".", network_bytes(network, bits)) == join(".", network_bytes(bytes, bits));
}

function valid_public_ipv4(value) {
    value = as_string(value);
    if (!valid_ipv4(value))
        return false;

    let parts = split(value, ".");
    let a = int(parts[0], 10);
    let b = int(parts[1], 10);

    if (a == 0 || a == 10 || a == 127 || a >= 224)
        return false;
    if (a == 169 && b == 254)
        return false;
    if (a == 192 && (b == 168 || b == 0 || b == 2))
        return false;
    if (a == 198 && (b == 18 || b == 19 || b == 51))
        return false;
    if (a == 203 && b == 0)
        return false;
    if (a == 100 && b >= 64 && b <= 127)
        return false;
    if (a == 172 && b >= 16 && b <= 31)
        return false;

    return true;
}

function valid_public_ipv6(value) {
    value = lc(as_string(value));
    if (!valid_ipv6(value))
        return false;
    if (value == "::" || value == "::1")
        return false;
    if (substr(value, 0, 4) == "fe80" || substr(value, 0, 2) == "ff")
        return false;
    if (substr(value, 0, 2) == "fc" || substr(value, 0, 2) == "fd")
        return false;
    if (index(value, "2001:db8") == 0 || prefix_contains("2001:2::/48", value))
        return false;
    return true;
}

function valid_public_ip(value) {
    return valid_public_ipv4(value) || valid_public_ipv6(value);
}

function format_ipv6_tproxy_target(address, port) {
    address = as_string(address);
    if (substr(address, 0, 1) == "[" && substr(address, length(address) - 1, 1) == "]")
        return address + ":" + as_string(port);
    return "[" + address + "]:" + as_string(port);
}

return {
    valid_ipv4,
    valid_ipv6,
    valid_ip,
    valid_ip_cidr,
    valid_ip_or_cidr,
    valid_public_ip,
    ip_family,
    network_bytes,
    prefix_contains,
    format_ipv6_tproxy_target
};
