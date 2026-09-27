#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function arg_bool(value) {
    return value === true || value == "true" || value == "1" || value == 1;
}

function whitespace_fields(value) {
    value = as_string(value);
    let result = [];

    for (let item in split(trim(value), /[ \t\r\n]+/))
        if (item != "")
            push(result, item);

    return result;
}

function list_has_item(items, needle) {
    needle = as_string(needle);
    if (needle == "")
        return false;

    for (let item in whitespace_fields(items))
        if (item == needle)
            return true;

    return false;
}

function new_urltest_enabled_sections(previous_sections, current_sections, previous_known) {
    if (!arg_bool(previous_known))
        return "";

    let result = [];
    for (let section in whitespace_fields(current_sections))
        if (!list_has_item(previous_sections, section))
            push(result, section);

    return join(" ", result);
}

function emit(name, value) {
    print(name, "\t", as_string(value), "\n");
}

function emit_bool(name, value) {
    emit(name, value ? "1" : "0");
}

function emit_reload_plan(previous, current, context) {
    let changed = {
        service_triggers: current.service_trigger != previous.service_trigger,
        dnsmasq: current.dnsmasq != previous.dnsmasq,
        sing_box: current.sing_box != previous.sing_box,
        nft: current.nft != previous.nft,
        zapret_queue: current.zapret_queue != previous.zapret_queue,
        zapret_runtime: current.zapret_runtime != previous.zapret_runtime,
        zapret2_queue: current.zapret2_queue != previous.zapret2_queue,
        zapret2_runtime: current.zapret2_runtime != previous.zapret2_runtime,
        byedpi_runtime: current.byedpi_runtime != previous.byedpi_runtime,
        list: current.list != previous.list,
        cron: current.cron != previous.cron
    };

    let needs = {
        sing_box_reload: false,
        nft_rebuild: false,
        zapret_restart: false,
        zapret2_restart: false,
        byedpi_restart: false,
        dnsmasq_configure: false,
        dnsmasq_restore: false,
        cron_refresh: false,
        list_update: false
    };

    if (changed.sing_box)
        needs.sing_box_reload = true;

    if (changed.nft)
        needs.nft_rebuild = true;

    if (changed.zapret_queue) {
        needs.zapret_restart = true;
        needs.nft_rebuild = true;
        needs.sing_box_reload = true;
    }

    if (changed.zapret_runtime)
        needs.zapret_restart = true;

    if (changed.zapret2_queue) {
        needs.zapret2_restart = true;
        needs.nft_rebuild = true;
        needs.sing_box_reload = true;
    }

    if (changed.zapret2_runtime)
        needs.zapret2_restart = true;

    if (changed.byedpi_runtime)
        needs.byedpi_restart = true;

    if (changed.dnsmasq) {
        if (!current.dont_touch_dhcp)
            needs.dnsmasq_configure = true;
        else if (context.dnsmasq_managed_state)
            needs.dnsmasq_restore = true;
    }

    if (changed.cron)
        needs.cron_refresh = true;

    if (changed.list && context.has_list_update_sources)
        needs.list_update = true;

    if (needs.nft_rebuild && context.has_nft_list_update_sources)
        needs.list_update = true;

    if (context.runtime_cache_needs_rebuild) {
        changed.sing_box = true;
        needs.sing_box_reload = true;
    }

    if (context.force_runtime_reload &&
        !needs.sing_box_reload &&
        !needs.nft_rebuild &&
        !needs.zapret_restart &&
        !needs.zapret2_restart &&
        !needs.byedpi_restart &&
        !needs.dnsmasq_configure &&
        !needs.dnsmasq_restore)
        needs.sing_box_reload = true;

    let has_work =
        needs.sing_box_reload ||
        needs.nft_rebuild ||
        needs.zapret_restart ||
        needs.zapret2_restart ||
        needs.byedpi_restart ||
        needs.dnsmasq_configure ||
        needs.dnsmasq_restore ||
        needs.cron_refresh ||
        needs.list_update;

    emit("urltest_new_enabled_sections", new_urltest_enabled_sections(
        previous.urltest_sections,
        current.urltest_sections,
        previous.urltest_sections_known
    ));

    emit_bool("changed_service_triggers", changed.service_triggers);
    emit_bool("changed_dnsmasq", changed.dnsmasq);
    emit_bool("changed_sing_box", changed.sing_box);
    emit_bool("changed_nft", changed.nft);
    emit_bool("changed_zapret_queue", changed.zapret_queue);
    emit_bool("changed_zapret_runtime", changed.zapret_runtime);
    emit_bool("changed_zapret2_queue", changed.zapret2_queue);
    emit_bool("changed_zapret2_runtime", changed.zapret2_runtime);
    emit_bool("changed_byedpi_runtime", changed.byedpi_runtime);
    emit_bool("changed_cron", changed.cron);
    emit_bool("changed_list", changed.list);

    emit_bool("needs_sing_box_reload", needs.sing_box_reload);
    emit_bool("needs_nft_rebuild", needs.nft_rebuild);
    emit_bool("needs_zapret_restart", needs.zapret_restart);
    emit_bool("needs_zapret2_restart", needs.zapret2_restart);
    emit_bool("needs_byedpi_restart", needs.byedpi_restart);
    emit_bool("needs_dnsmasq_configure", needs.dnsmasq_configure);
    emit_bool("needs_dnsmasq_restore", needs.dnsmasq_restore);
    emit_bool("needs_cron_refresh", needs.cron_refresh);
    emit_bool("needs_list_update", needs.list_update);
    emit_bool("has_work", has_work);
}

function reload_plan() {
    let previous = {
        service_trigger: as_string(ARGV[1]),
        dnsmasq: as_string(ARGV[2]),
        sing_box: as_string(ARGV[3]),
        nft: as_string(ARGV[4]),
        zapret_queue: as_string(ARGV[5]),
        zapret_runtime: as_string(ARGV[6]),
        zapret2_queue: as_string(ARGV[7]),
        zapret2_runtime: as_string(ARGV[8]),
        byedpi_runtime: as_string(ARGV[9]),
        list: as_string(ARGV[10]),
        cron: as_string(ARGV[11]),
        urltest_sections_known: arg_bool(ARGV[12]),
        urltest_sections: as_string(ARGV[13])
    };

    let current = {
        service_trigger: as_string(ARGV[14]),
        dnsmasq: as_string(ARGV[15]),
        sing_box: as_string(ARGV[16]),
        nft: as_string(ARGV[17]),
        zapret_queue: as_string(ARGV[18]),
        zapret_runtime: as_string(ARGV[19]),
        zapret2_queue: as_string(ARGV[20]),
        zapret2_runtime: as_string(ARGV[21]),
        byedpi_runtime: as_string(ARGV[22]),
        list: as_string(ARGV[23]),
        cron: as_string(ARGV[24]),
        urltest_sections: as_string(ARGV[25]),
        dont_touch_dhcp: arg_bool(ARGV[26])
    };

    let context = {
        force_runtime_reload: arg_bool(ARGV[27]),
        dnsmasq_managed_state: arg_bool(ARGV[28]),
        has_list_update_sources: arg_bool(ARGV[29]),
        has_nft_list_update_sources: arg_bool(ARGV[30]),
        runtime_cache_needs_rebuild: arg_bool(ARGV[31])
    };

    emit_reload_plan(previous, current, context);
}

function read_state_file(path) {
    let data = fs.readfile(path);
    if (data == null)
        return null;

    let state = {};
    let has = {};

    for (let line in split(data, "\n")) {
        if (line == "")
            continue;

        let equals = index(line, "=");
        let key = equals >= 0 ? substr(line, 0, equals) : line;
        if (key == "")
            continue;

        state[key] = equals >= 0 ? substr(line, equals + 1) : "";
        has[key] = true;
    }

    state.__has = has;
    return state;
}

function plan_state_from_file(path) {
    let state = read_state_file(path);
    if (state == null)
        return null;

    return {
        format: as_string(state.format),
        service_trigger: as_string(state.service_trigger_signature || state.restart_signature),
        dnsmasq: as_string(state.dnsmasq_signature),
        sing_box: as_string(state.sing_box_signature),
        nft: as_string(state.nft_signature),
        zapret_queue: as_string(state.zapret_queue_signature),
        zapret_runtime: as_string(state.zapret_runtime_signature),
        zapret2_queue: as_string(state.zapret2_queue_signature),
        zapret2_runtime: as_string(state.zapret2_runtime_signature),
        byedpi_runtime: as_string(state.byedpi_runtime_signature),
        list: as_string(state.list_signature),
        cron: as_string(state.cron_signature),
        urltest_sections_known: state.__has.urltest_enabled_sections === true,
        urltest_sections: as_string(state.urltest_enabled_sections),
        dont_touch_dhcp: arg_bool(state.dont_touch_dhcp)
    };
}

function plan_state_files() {
    let previous = plan_state_from_file(ARGV[1]);
    let current = plan_state_from_file(ARGV[2]);
    if (previous == null || current == null || previous.format == "" || previous.format != current.format)
        exit(2);

    let context = {
        force_runtime_reload: arg_bool(ARGV[3]),
        dnsmasq_managed_state: arg_bool(ARGV[4]),
        has_list_update_sources: arg_bool(ARGV[5]),
        has_nft_list_update_sources: arg_bool(ARGV[6]),
        runtime_cache_needs_rebuild: arg_bool(ARGV[7])
    };

    emit_reload_plan(previous, current, context);
}

let mode = ARGV[0] || "";

if (mode == "plan")
    reload_plan();
else if (mode == "plan-state-files")
    plan_state_files();
else {
    warn("Usage: service/reload.uc plan ...\n");
    warn("       service/reload.uc plan-state-files <previous-state> <current-state> <force-reload> <dnsmasq-managed-state> <list-update-sources> <nft-list-update-sources> <runtime-cache-needs-rebuild>\n");
    exit(1);
}
