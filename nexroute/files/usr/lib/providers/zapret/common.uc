#!/usr/bin/env ucode

let constants = require("core.constants");
let validator_module = null;

const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";

function validator() {
    if (validator_module == null)
        validator_module = require("providers.zapret.validator");
    return validator_module;
}

function config(ctx) {
    let runtime_constants = (ctx && ctx.constants) || constants;
    let lib_dir = (ctx && ctx.lib_dir) || LIB_DIR;

    return {
        kind: "zapret",
        action: "zapret",
        binary_name: "nfqws",
        binary: getenv("ZAPRET_NFQWS_BIN") || runtime_constants.ZAPRET_NFQWS_BIN,
        provider_bin: getenv("ZAPRET_PROVIDER_NFQWS_BIN") || runtime_constants.ZAPRET_PROVIDER_NFQWS_BIN,
        provider_files_dir: getenv("ZAPRET_PROVIDER_FILES_DIR") || runtime_constants.ZAPRET_PROVIDER_FILES_DIR,
        provider_ipset_dir: getenv("ZAPRET_PROVIDER_IPSET_DIR") || runtime_constants.ZAPRET_PROVIDER_IPSET_DIR,
        state_dir: getenv("ZAPRET_STATE_DIR") || runtime_constants.ZAPRET_STATE_DIR,
        pid_dir: getenv("ZAPRET_PID_DIR") || runtime_constants.ZAPRET_PID_DIR,
        child_pid_dir: getenv("ZAPRET_CHILD_PID_DIR") || runtime_constants.ZAPRET_CHILD_PID_DIR,
        log_dir: getenv("ZAPRET_LOG_DIR") || runtime_constants.ZAPRET_LOG_DIR,
        route_mark_base: getenv("ZAPRET_ROUTE_MARK_BASE") || runtime_constants.ZAPRET_ROUTE_MARK_BASE,
        queue_base: getenv("ZAPRET_QUEUE_BASE") || runtime_constants.ZAPRET_QUEUE_BASE,
        queue_range_size: getenv("ZAPRET_QUEUE_RANGE_SIZE") || runtime_constants.ZAPRET_QUEUE_RANGE_SIZE,
        respawn_delay: getenv("ZAPRET_NFQWS_RESPAWN_DELAY") || runtime_constants.ZAPRET_NFQWS_RESPAWN_DELAY,
        desync_mark: getenv("ZAPRET_DESYNC_MARK") || runtime_constants.ZAPRET_DESYNC_MARK,
        desync_mark_postnat: getenv("ZAPRET_DESYNC_MARK_POSTNAT") || runtime_constants.ZAPRET_DESYNC_MARK_POSTNAT,
        default_strategy: getenv("ZAPRET_DEFAULT_NFQWS_OPT") || runtime_constants.ZAPRET_DEFAULT_NFQWS_OPT,
        legacy_default_strategy: getenv("ZAPRET_LEGACY_DEFAULT_NFQWS_OPT") || runtime_constants.ZAPRET_LEGACY_DEFAULT_NFQWS_OPT,
        strategy_option: "nfqws_opt",
        validator_kind: "nfqws",
        validator,
        package_name: "zapret",
        runtime_path: lib_dir + "/providers/zapret/runtime.uc",
        check_path: lib_dir + "/providers/zapret/check.uc",
        luci_package: "luci-app-zapret",
        luci_menu: "/usr/share/luci/menu.d/luci-app-zapret.json",
        luci_acl: "/usr/share/rpcd/acl.d/luci-app-zapret.json",
        service_init: "/etc/init.d/zapret",
        config_name: "zapret",
        legacy_runtime_base: getenv("ZAPRET_LEGACY_RUNTIME_BASE_DIR") || runtime_constants.ZAPRET_LEGACY_RUNTIME_BASE_DIR,
        provider_base_dir: runtime_constants.ZAPRET_PROVIDER_BASE_DIR,
        hostlist_dir: getenv("ZAPRET_HOSTLIST_DIR") || runtime_constants.ZAPRET_HOSTLIST_DIR,
        status_label: "zapret",
        check_prefix: "zapret",
        base_args: [ "--dpi-desync-fwmark=" + (getenv("ZAPRET_DESYNC_MARK") || runtime_constants.ZAPRET_DESYNC_MARK) ]
    };
}

return {
    config,
    validator
};
