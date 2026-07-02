#!/usr/bin/env ucode

const PUNYCODE_BASE = 36;
const PUNYCODE_TMIN = 1;
const PUNYCODE_TMAX = 26;
const PUNYCODE_SKEW = 38;
const PUNYCODE_DAMP = 700;
const PUNYCODE_INITIAL_BIAS = 72;
const PUNYCODE_INITIAL_N = 128;
const PUNYCODE_DELIMITER = "-";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function ascii_lower(value) {
    let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    let lower = "abcdefghijklmnopqrstuvwxyz";
    return replace(as_string(value), /[A-Z]/g, function(ch) {
        return substr(lower, index(upper, ch), 1);
    });
}

function byte_at(value, offset) {
    return ord(substr(value, offset, 1));
}

function valid_continuation(value, offset) {
    if (offset >= length(value))
        return -1;

    let byte = byte_at(value, offset);
    return (byte & 0xc0) == 0x80 ? byte : -1;
}

function unicode_lower_codepoint(cp) {
    if (cp >= 0x41 && cp <= 0x5a)
        return cp + 0x20;

    if (cp >= 0xc0 && cp <= 0xd6)
        return cp + 0x20;
    if (cp >= 0xd8 && cp <= 0xde)
        return cp + 0x20;

    if (cp == 0x401)
        return 0x451;
    if (cp >= 0x410 && cp <= 0x42f)
        return cp + 0x20;

    if (cp >= 0x391 && cp <= 0x3a1)
        return cp + 0x20;
    if (cp >= 0x3a3 && cp <= 0x3ab)
        return cp + 0x20;

    return cp;
}

function utf8_next_codepoint(value, offset) {
    let b1 = byte_at(value, offset);
    if (b1 < 0x80)
        return { cp: unicode_lower_codepoint(b1), next: offset + 1 };

    if (b1 >= 0xc2 && b1 <= 0xdf) {
        let b2 = valid_continuation(value, offset + 1);
        if (b2 < 0)
            return null;
        return {
            cp: unicode_lower_codepoint(((b1 & 0x1f) << 6) | (b2 & 0x3f)),
            next: offset + 2
        };
    }

    if (b1 >= 0xe0 && b1 <= 0xef) {
        let b2 = valid_continuation(value, offset + 1);
        let b3 = valid_continuation(value, offset + 2);
        if (b2 < 0 || b3 < 0)
            return null;

        let cp = ((b1 & 0x0f) << 12) | ((b2 & 0x3f) << 6) | (b3 & 0x3f);
        if (cp < 0x800 || (cp >= 0xd800 && cp <= 0xdfff))
            return null;

        return { cp: unicode_lower_codepoint(cp), next: offset + 3 };
    }

    if (b1 >= 0xf0 && b1 <= 0xf4) {
        let b2 = valid_continuation(value, offset + 1);
        let b3 = valid_continuation(value, offset + 2);
        let b4 = valid_continuation(value, offset + 3);
        if (b2 < 0 || b3 < 0 || b4 < 0)
            return null;

        let cp = ((b1 & 0x07) << 18) | ((b2 & 0x3f) << 12) | ((b3 & 0x3f) << 6) | (b4 & 0x3f);
        if (cp < 0x10000 || cp > 0x10ffff)
            return null;

        return { cp: unicode_lower_codepoint(cp), next: offset + 4 };
    }

    return null;
}

function utf8_codepoints(value) {
    value = as_string(value);
    let result = [];

    for (let i = 0; i < length(value); ) {
        let next = utf8_next_codepoint(value, i);
        if (next == null)
            return null;

        push(result, next.cp);
        i = next.next;
    }

    return result;
}

function ascii_label_char(cp) {
    return (cp >= 0x30 && cp <= 0x39) ||
        (cp >= 0x61 && cp <= 0x7a) ||
        cp == 0x2d;
}

function valid_ascii_label(value) {
    value = ascii_lower(value);
    return length(value) >= 1 &&
        length(value) <= 63 &&
        match(value, /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/) != null;
}

function codepoints_to_ascii_label(codepoints) {
    let result = "";
    for (let cp in codepoints) {
        if (!ascii_label_char(cp))
            return null;
        result += chr(cp);
    }
    return valid_ascii_label(result) ? result : null;
}

function punycode_digit(value) {
    return chr(value < 26 ? 0x61 + value : 0x30 + value - 26);
}

function punycode_adapt(delta, numpoints, first_time) {
    delta = first_time ? int(delta / PUNYCODE_DAMP) : int(delta / 2);
    delta += int(delta / numpoints);

    let k = 0;
    while (delta > int(((PUNYCODE_BASE - PUNYCODE_TMIN) * PUNYCODE_TMAX) / 2)) {
        delta = int(delta / (PUNYCODE_BASE - PUNYCODE_TMIN));
        k += PUNYCODE_BASE;
    }

    return k + int(((PUNYCODE_BASE - PUNYCODE_TMIN + 1) * delta) / (delta + PUNYCODE_SKEW));
}

function punycode_encode(codepoints) {
    let output = "";
    let basic_count = 0;

    for (let cp in codepoints) {
        if (cp < 0x80) {
            if (!ascii_label_char(cp))
                return null;
            output += chr(cp);
            basic_count++;
        }
    }

    let handled = basic_count;
    if (basic_count > 0 && basic_count < length(codepoints))
        output += PUNYCODE_DELIMITER;

    let n = PUNYCODE_INITIAL_N;
    let delta = 0;
    let bias = PUNYCODE_INITIAL_BIAS;

    while (handled < length(codepoints)) {
        let m = 0x10ffff;
        for (let cp in codepoints)
            if (cp >= n && cp < m)
                m = cp;

        delta += (m - n) * (handled + 1);
        n = m;

        for (let cp in codepoints) {
            if (cp < n) {
                delta++;
                continue;
            }
            if (cp != n)
                continue;

            let q = delta;
            for (let k = PUNYCODE_BASE; ; k += PUNYCODE_BASE) {
                let t = k <= bias
                    ? PUNYCODE_TMIN
                    : (k >= bias + PUNYCODE_TMAX ? PUNYCODE_TMAX : k - bias);
                if (q < t)
                    break;

                output += punycode_digit(t + ((q - t) % (PUNYCODE_BASE - t)));
                q = int((q - t) / (PUNYCODE_BASE - t));
            }

            output += punycode_digit(q);
            bias = punycode_adapt(delta, handled + 1, handled == basic_count);
            delta = 0;
            handled++;
        }

        delta++;
        n++;
    }

    return "xn--" + output;
}

function label_to_ascii(value) {
    value = as_string(value);
    if (value == "")
        return null;

    let codepoints = utf8_codepoints(value);
    if (codepoints == null)
        return null;

    let ascii = codepoints_to_ascii_label(codepoints);
    if (ascii != null)
        return ascii;

    let encoded = punycode_encode(codepoints);
    return encoded != null && valid_ascii_label(encoded) ? encoded : null;
}

function domain_to_ascii(value, allow_leading_dot) {
    value = trim(as_string(value));
    if (value == "")
        return null;

    let leading_dot = false;
    if (allow_leading_dot && substr(value, 0, 1) == ".") {
        leading_dot = true;
        value = substr(value, 1);
    }

    if (value == "" || substr(value, length(value) - 1, 1) == ".")
        return null;

    let labels = split(value, ".");
    let result = [];
    for (let label in labels) {
        let normalized = label_to_ascii(label);
        if (normalized == null)
            return null;
        push(result, normalized);
    }

    let domain = join(".", result);
    if (length(domain) > 253)
        return null;

    return leading_dot ? "." + domain : domain;
}

function suffix_to_ascii(value) {
    return domain_to_ascii(value, true);
}

function keyword_to_ascii(value) {
    value = trim(as_string(value));
    if (value == "" || match(value, /[,[:space:]]/) != null)
        return null;

    let has_non_ascii = false;
    for (let i = 0; i < length(value); i++) {
        if (byte_at(value, i) >= 0x80) {
            has_non_ascii = true;
            break;
        }
    }

    if (!has_non_ascii)
        return value;

    return domain_to_ascii(value, false);
}

function regex_to_ascii(value) {
    value = as_string(value);
    if (match(value, /[,[:space:]]/) != null)
        return null;

    let result = "";
    let label = "";
    let label_has_non_ascii = false;
    let escaped = false;
    let in_class = false;

    function flush_label() {
        if (label == "")
            return true;

        let normalized = label_has_non_ascii ? label_to_ascii(label) : label;
        if (normalized == null)
            return false;

        result += normalized;
        label = "";
        label_has_non_ascii = false;
        return true;
    }

    for (let i = 0; i < length(value); ) {
        let next = utf8_next_codepoint(value, i);
        if (next == null)
            return null;

        let raw = substr(value, i, next.next - i);
        let cp = next.cp;

        if (escaped) {
            if (!flush_label())
                return null;
            result += raw;
            escaped = false;
        }
        else if (cp == 0x5c) {
            if (!flush_label())
                return null;
            result += raw;
            escaped = true;
        }
        else if (in_class) {
            result += raw;
            if (cp == 0x5d)
                in_class = false;
        }
        else if (cp == 0x5b) {
            if (!flush_label())
                return null;
            result += raw;
            in_class = true;
        }
        else if (ascii_label_char(cp) || cp >= 0x80) {
            label += raw;
            if (cp >= 0x80)
                label_has_non_ascii = true;
        }
        else {
            if (!flush_label())
                return null;
            result += raw;
        }

        i = next.next;
    }

    return flush_label() ? result : null;
}

function valid_suffix(value) {
    return suffix_to_ascii(value) != null;
}

return {
    ascii_lower,
    label_to_ascii,
    suffix_to_ascii,
    keyword_to_ascii,
    regex_to_ascii,
    valid_suffix
};
