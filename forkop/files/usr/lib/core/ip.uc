#!/usr/bin/env ucode

function as_string(value) {
    return value == null ? "" : "" + value;
}

function decimal_text(value, strict) {
    value = as_string(value);
    if (value == "" || match(value, /^[0-9]+$/) == null)
        return false;
    return !strict || length(value) == 1 || substr(value, 0, 1) != "0";
}

function valid_ipv4(value, allow_trailing_dot, strict_decimal) {
    value = as_string(value);
    if (allow_trailing_dot && length(value) > 0 && substr(value, length(value) - 1, 1) == ".")
        value = substr(value, 0, length(value) - 1);

    let parts = split(value, ".");
    if (length(parts) != 4)
        return false;

    for (let part in parts) {
        if (!decimal_text(part, strict_decimal))
            return false;

        let octet = int(part);
        if (octet < 0 || octet > 255)
            return false;
    }

    return true;
}

function valid_ipv4_cidr(value, strict_decimal) {
    value = as_string(value);
    let slash = index(value, "/");
    if (slash <= 0 || index(substr(value, slash + 1), "/") >= 0)
        return false;

    let prefix = substr(value, slash + 1);
    if (!decimal_text(prefix, strict_decimal))
        return false;

    let prefix_number = int(prefix);
    return valid_ipv4(substr(value, 0, slash), false, strict_decimal) && prefix_number >= 0 && prefix_number <= 32;
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
            if (i != length(parts) - 1 || !valid_ipv4(part, false, false))
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
    if (!decimal_text(prefix, false))
        return false;

    let prefix_number = int(prefix);
    return valid_ipv6(substr(value, 0, slash)) && prefix_number >= 0 && prefix_number <= 128;
}

function valid_ip(value) {
    return valid_ipv4(value, false, false) || valid_ipv6(value);
}

function valid_ip_cidr(value) {
    return valid_ipv4_cidr(value, false) || valid_ipv6_cidr(value);
}

function valid_ip_or_cidr(value) {
    return valid_ip(value) || valid_ip_cidr(value);
}

function nft_ip_or_cidr(value) {
    return valid_ipv4(value, true, true) || valid_ipv4_cidr(value, true) || valid_ipv6(value) || valid_ipv6_cidr(value);
}

function ip_family(value) {
    return valid_ipv4(value, false, false) || valid_ipv4_cidr(value, false) ? 4 :
        (valid_ipv6(value) || valid_ipv6_cidr(value) ? 6 : 0);
}

function format_ipv6_tproxy_target(address, port) {
    address = as_string(address);
    if (substr(address, 0, 1) == "[" && substr(address, length(address) - 1, 1) == "]")
        return address + ":" + as_string(port);
    return "[" + address + "]:" + as_string(port);
}

return {
    valid_ipv4,
    valid_ipv4_cidr,
    valid_ipv6,
    valid_ipv6_cidr,
    valid_ip,
    valid_ip_cidr,
    valid_ip_or_cidr,
    nft_ip_or_cidr,
    ip_family,
    format_ipv6_tproxy_target
};
