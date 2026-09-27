#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let subscription_share_link = require("subscription.share_link");

let as_string = common.as_string;
let read_json_file = common.read_json_file;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;
let object_key_count = common.object_key_count;

const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || "/tmp/sing-box/subscriptions";
const FORKOP_RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const FORKOP_SECTION_CACHE_DIR = getenv("FORKOP_SECTION_CACHE_DIR") || FORKOP_RUNTIME_STATE_DIR + "/section-cache";
const FORKOP_SUBSCRIPTION_METADATA_DIR = getenv("FORKOP_SUBSCRIPTION_METADATA_DIR") || FORKOP_RUNTIME_STATE_DIR + "/subscription-metadata";
const FORKOP_RUNTIME_CACHE_FORMAT = int(getenv("FORKOP_RUNTIME_CACHE_FORMAT") || "8");
const FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR = getenv("FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR") || "/etc/forkop/subscription-cache";

let section_cache_dir = FORKOP_SECTION_CACHE_DIR;

function set_section_cache_dir(path) {
    path = as_string(path);
    if (path != "")
        section_cache_dir = path;
}

function source_id(section_name, index) {
    return section_name + "-subscription-" + index;
}

function section_cache_path(section_name) {
    return section_cache_dir + "/" + section_name + ".json";
}

function legacy_metadata_path(section_name) {
    return FORKOP_SUBSCRIPTION_METADATA_DIR + "/" + section_name + ".json";
}

function persistent_source_path(source_section, suffix) {
    return FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR + "/" + source_section + suffix;
}

function persistent_metadata_path(source_section) {
    return persistent_source_path(source_section, ".metadata.json");
}

function trim_string(value) {
    return replace(as_string(value), /^[ \t\r\n]+|[ \t\r\n]+$/g, "");
}

function parse_source_entry(entry) {
    entry = trim_string(entry);
    let delimiter = " | ";
    let delimiter_index = index(entry, delimiter);
    if (delimiter_index < 0)
        return { url: entry, user_agent: "" };

    return {
        url: trim_string(substr(entry, 0, delimiter_index)),
        user_agent: trim_string(substr(entry, delimiter_index + length(delimiter)))
    };
}

function file_first_line(path) {
    let data = fs.readfile(path);
    if (data == null)
        return "";

    let newline = index(data, "\n");
    return newline >= 0 ? substr(data, 0, newline) : data;
}

function valid_metadata_object(value) {
    return type(value) == "object" && object_key_count(value) > 1;
}

function metadata_items_from_value(value) {
    let result = [];
    if (type(value) == "array") {
        for (let item in value)
            if (valid_metadata_object(item))
                push(result, item);
    }
    else if (valid_metadata_object(value)) {
        push(result, value);
    }
    return result;
}

function metadata_source_index(item) {
    if (type(item) != "object")
        return null;

    let value = item.sourceIndex != null ? item.sourceIndex : item.source_index;
    if (value == null || value == "")
        return null;

    return int(value, 10);
}

function metadata_source_section(item) {
    if (type(item) != "object")
        return "";

    return as_string(item.sourceSection != null ? item.sourceSection : item.source_section);
}

function metadata_items_have_source_markers(items) {
    for (let item in items) {
        if (metadata_source_index(item) != null || metadata_source_section(item) != "")
            return true;
    }
    return false;
}

function metadata_matches_source(item, source_index, source_section, has_source_markers) {
    if (!has_source_markers)
        return false;

    let item_section = metadata_source_section(item);
    let item_index = metadata_source_index(item);

    if (item_section != "")
        return item_section == source_section;

    return item_index == source_index;
}

function persistent_source_matches_entry(source_section, source_entry) {
    if (source_entry == null || source_entry == "")
        return true;

    let parsed = parse_source_entry(source_entry);
    let cached_url = file_first_line(persistent_source_path(source_section, ".url"));
    let cached_user_agent = file_first_line(persistent_source_path(source_section, ".user_agent"));

    if (cached_url != parsed.url)
        return false;
    if (parsed.user_agent != "" && cached_user_agent != parsed.user_agent)
        return false;
    return cached_user_agent != "";
}

function read_persistent_source_metadata(source_section, source_entry) {
    if (!persistent_source_matches_entry(source_section, source_entry))
        return [];
    return metadata_items_from_value(read_json_file(persistent_metadata_path(source_section)));
}

function read_section_metadata(section_name, source_section, source_index) {
    let cache = object_or_empty(read_json_file(section_cache_path(section_name)));
    let metadata = metadata_items_from_value(cache.subscriptionMetadata);
    if (length(metadata) == 0)
        metadata = metadata_items_from_value(read_json_file(legacy_metadata_path(section_name)));
    if (length(metadata) == 0) {
        cache = object_or_empty(read_json_file(section_cache_path(source_section)));
        metadata = metadata_items_from_value(cache.subscriptionMetadata);
    }
    if (length(metadata) == 0)
        metadata = metadata_items_from_value(read_json_file(legacy_metadata_path(source_section)));

    let selected = [];
    let has_source_markers = metadata_items_have_source_markers(metadata);
    if (has_source_markers) {
        for (let item in metadata) {
            if (metadata_matches_source(item, source_index, source_section, true))
                push(selected, item);
        }
    }
    else if (source_index > 0 && source_index <= length(metadata)) {
        push(selected, metadata[source_index - 1]);
    }

    return selected;
}

function read_source_metadata(section_name, source_section, source_index, source_entry) {
    let metadata = read_section_metadata(section_name, source_section, source_index);
    if (length(metadata) == 0)
        metadata = read_persistent_source_metadata(source_section, source_entry);

    let result = [];
    for (let item in metadata) {
        item.sourceIndex = source_index;
        item.sourceSection = source_section;
        push(result, item);
    }
    return result;
}

function merge_source_metadata(state, section_name, source_section, source_index, source_entry) {
    if (type(state) != "object")
        return;
    for (let item in read_source_metadata(section_name, source_section, source_index, source_entry))
        push(state.subscriptionMetadata, item);
}

function remember_outbound_metadata(state, tag_name, display_name, outbound) {
    if (type(state) != "object")
        return;
    state.outboundMetadata.names[tag_name] = display_name;
    let protocol = lc(as_string(outbound.type || ""));
    if (protocol != "")
        state.outboundMetadata.protocols[tag_name] = protocol;

    let transport = lc(as_string(object_or_empty(outbound.transport).type || ""));
    if (transport == "" || transport == "raw")
        transport = "tcp";
    else if (transport == "h2")
        transport = "http";
    state.outboundMetadata.transports[tag_name] = transport;

    let tls = type(outbound.tls) == "object" ? outbound.tls : null;
    let security = "none";
    if (tls != null && tls.enabled !== false) {
        let reality = type(tls.reality) == "object" ? tls.reality : null;
        security = reality != null && reality.enabled !== false ? "reality" : "tls";
    }
    state.outboundMetadata.securities[tag_name] = security;

    let server = as_string(outbound.server || "");
    if (server != "")
        state.servers[tag_name] = server;
}

function remember_source_outbound(state, tag_name, display_name, outbound, source_link) {
    if (type(state) != "object")
        return;
    remember_outbound_metadata(state, tag_name, display_name, outbound);
    let outbound_type = as_string(outbound.type || "");
    if (outbound_type != "selector" && outbound_type != "urltest") {
        if (subscription_share_link.is_copyable_link(source_link))
            state.links[tag_name] = source_link;
    }
}

function remember_urltest_group(state, tag_name, display_name, outbound) {
    if (type(state) != "object" || as_string(outbound.type || "") != "urltest")
        return;

    let group = {
        displayName: as_string(display_name) != "" ? as_string(display_name) : tag_name,
        outbounds: array_or_empty(outbound.outbounds)
    };

    for (let key in [ "url", "interval", "tolerance", "idle_timeout", "interrupt_exist_connections" ]) {
        if (outbound[key] != null)
            group[key] = outbound[key];
    }

    state.urltestGroups[tag_name] = group;
}

function remember_urltest_group_config(state, tag_name, input_group) {
    if (type(state) != "object")
        return;

    input_group = object_or_empty(input_group);
    let output_group = {
        displayName: as_string(input_group.displayName || "") != "" ? as_string(input_group.displayName) : tag_name,
        outbounds: array_or_empty(input_group.outbounds)
    };

    for (let key in [ "url", "interval", "tolerance", "idle_timeout", "interrupt_exist_connections" ]) {
        if (input_group[key] != null)
            output_group[key] = input_group[key];
    }

    state.urltestGroups[tag_name] = output_group;
}

function remember_priority_group(state, tag_name, group) {
    if (type(state) != "object")
        return;

    state.priorityGroups[tag_name] = object_or_empty(group);
}

function source_hwid_path(source_section) {
    return TMP_SUBSCRIPTION_FOLDER + "/" + source_section + ".hwid";
}

function hwid_matches_config(configured_hwid, cached_hwid) {
    configured_hwid = as_string(configured_hwid);
    cached_hwid = as_string(cached_hwid);

    if (configured_hwid != "")
        return cached_hwid == configured_hwid;
    return true;
}

function source_cache_is_current(source_section, source_entry, expected_user_agent, expected_hwid) {
    let parsed = parse_source_entry(source_entry);
    let cached_url = file_first_line(TMP_SUBSCRIPTION_FOLDER + "/" + source_section + ".url");
    let cached_user_agent = file_first_line(TMP_SUBSCRIPTION_FOLDER + "/" + source_section + ".user_agent");
    let cached_hwid = file_first_line(source_hwid_path(source_section));
    let configured_user_agent = as_string(expected_user_agent || "");
    if (configured_user_agent != "")
        parsed.user_agent = configured_user_agent;

    if (cached_url != parsed.url)
        return false;

    if (parsed.user_agent != "" && cached_user_agent != parsed.user_agent)
        return false;

    if (!hwid_matches_config(expected_hwid, cached_hwid))
        return false;

    return true;
}

function source_json_path(source_section) {
    return TMP_SUBSCRIPTION_FOLDER + "/" + source_section + ".json";
}

function read_source_outbounds(source_section) {
    let subscription = object_or_empty(read_json_file(source_json_path(source_section)));
    return array_or_empty(subscription.outbounds);
}

function new_section_state(section_name) {
    return {
        version: FORKOP_RUNTIME_CACHE_FORMAT,
        section: section_name,
        links: {},
        outboundMetadata: {
            names: {},
            countries: {},
            protocols: {},
            transports: {},
            securities: {}
        },
        servers: {},
        urltestCandidateTags: [],
        urltestGroups: {},
        priorityGroups: {},
        subscriptionMetadata: []
    };
}

return {
    set_section_cache_dir,
    source_id,
    section_cache_path,
    merge_source_metadata,
    remember_outbound_metadata,
    remember_source_outbound,
    remember_urltest_group,
    remember_urltest_group_config,
    remember_priority_group,
    source_cache_is_current,
    read_source_outbounds,
    new_section_state
};
