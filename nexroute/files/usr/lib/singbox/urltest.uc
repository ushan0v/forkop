#!/usr/bin/env ucode

let common = require("core.common");

let as_string = common.as_string;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;

function contains(values, needle) {
    for (let value in values) {
        if (value == needle)
            return true;
    }
    return false;
}

function regex_matches(value, pattern) {
    pattern = as_string(pattern);
    if (pattern == "")
        return false;

    try {
        return match(as_string(value), regexp(pattern)) != null;
    }
    catch (e) {
        return false;
    }
}

function normalized_country_list(values) {
    let result = [];
    for (let value in array_or_empty(values)) {
        value = uc(as_string(value));
        if (length(value) == 2)
            push(result, value);
    }
    return result;
}

function byte_at(value, index) {
    return ord(substr(value, index, 1));
}

function regional_indicator_letter(value, index) {
    if (index + 3 >= length(value))
        return "";

    if (byte_at(value, index) != 240 ||
        byte_at(value, index + 1) != 159 ||
        byte_at(value, index + 2) != 135)
        return "";

    let letter = byte_at(value, index + 3) - 166;
    if (letter < 0 || letter > 25)
        return "";

    return chr(65 + letter);
}

function country_from_flag_emoji(value) {
    value = as_string(value);

    for (let i = 0; i + 7 < length(value); i++) {
        let first = regional_indicator_letter(value, i);
        if (first == "")
            continue;

        let second = regional_indicator_letter(value, i + 4);
        if (second != "")
            return first + second;
    }

    return "";
}

function countries_from_flag_names(names) {
    names = object_or_empty(names);
    let result = {};

    for (let tag, name in names) {
        let country = country_from_flag_emoji(name);
        if (country != "")
            result[tag] = country;
    }

    return result;
}

function regex_matching_tag_array(tags, names, regexes) {
    tags = array_or_empty(tags);
    names = object_or_empty(names);
    regexes = array_or_empty(regexes);
    let result = [];

    for (let tag in tags) {
        let name = names[tag];
        name = name == null || as_string(name) == "" ? tag : as_string(name);

        for (let pattern in regexes) {
            if (regex_matches(name, pattern)) {
                push(result, tag);
                break;
            }
        }
    }

    return result;
}

function filter_array(mode, tags, names, countries, name_filter, regex_tags, country_filter) {
    tags = array_or_empty(tags);
    names = object_or_empty(names);
    countries = object_or_empty(countries);
    name_filter = array_or_empty(name_filter);
    regex_tags = array_or_empty(regex_tags);
    country_filter = array_or_empty(country_filter);
    let result = [];

    for (let tag in tags) {
        let name = as_string(names[tag] || tag);
        let country = uc(as_string(countries[tag] || ""));
        let matched = contains(name_filter, name) ||
            contains(name_filter, tag) ||
            (country != "" && contains(country_filter, country)) ||
            contains(regex_tags, tag);

        if ((mode == "include" && matched) || (mode == "exclude" && !matched))
            push(result, tag);
    }

    return result;
}

function filter_mode(mode, tags, names, countries, include_names, include_regexes, include_countries, exclude_names, exclude_regexes, exclude_countries) {
    include_countries = normalized_country_list(include_countries);
    exclude_countries = normalized_country_list(exclude_countries);

    let include_regex_tags = regex_matching_tag_array(tags, names, include_regexes);
    let exclude_regex_tags = regex_matching_tag_array(tags, names, exclude_regexes);

    if (mode == "include")
        return filter_array("include", tags, names, countries, include_names, include_regex_tags, include_countries);
    if (mode == "exclude")
        return filter_array("exclude", tags, names, countries, exclude_names, exclude_regex_tags, exclude_countries);
    if (mode == "mixed") {
        let included = filter_array("include", tags, names, countries, include_names, include_regex_tags, include_countries);
        return filter_array("exclude", included, names, countries, exclude_names, exclude_regex_tags, exclude_countries);
    }
    return array_or_empty(tags);
}

return {
    normalized_country_list,
    countries_from_flag_names,
    regex_matching_tag_array,
    filter_array,
    filter_mode
};
