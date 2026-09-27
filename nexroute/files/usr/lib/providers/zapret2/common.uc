#!/usr/bin/env ucode

let constants = require("core.constants");
let validator_module = null;

const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";

function validator() {
    if (validator_module == null)
        validator_module = require("providers.zapret2.validator");
    return validator_module;
}

function config(ctx) {
    let runtime_constants = (ctx && ctx.constants) || constants;
    let lib_dir = (ctx && ctx.lib_dir) || LIB_DIR;
    let desync_mark = getenv("ZAPRET2_DESYNC_MARK") || runtime_constants.ZAPRET2_DESYNC_MARK;
    let provider_lua_dir = getenv("ZAPRET2_PROVIDER_LUA_DIR") || runtime_constants.ZAPRET2_PROVIDER_LUA_DIR;

    return {
        kind: "zapret2",
        action: "zapret2",
        binary_name: "nfqws2",
        binary: getenv("ZAPRET2_NFQWS2_BIN") || runtime_constants.ZAPRET2_NFQWS2_BIN,
        provider_bin: getenv("ZAPRET2_PROVIDER_NFQWS2_BIN") || runtime_constants.ZAPRET2_PROVIDER_NFQWS2_BIN,
        provider_files_dir: getenv("ZAPRET2_PROVIDER_FILES_DIR") || runtime_constants.ZAPRET2_PROVIDER_FILES_DIR,
        provider_ipset_dir: getenv("ZAPRET2_PROVIDER_IPSET_DIR") || runtime_constants.ZAPRET2_PROVIDER_IPSET_DIR,
        provider_lua_dir,
        state_dir: getenv("ZAPRET2_STATE_DIR") || runtime_constants.ZAPRET2_STATE_DIR,
        pid_dir: getenv("ZAPRET2_PID_DIR") || runtime_constants.ZAPRET2_PID_DIR,
        child_pid_dir: getenv("ZAPRET2_CHILD_PID_DIR") || runtime_constants.ZAPRET2_CHILD_PID_DIR,
        log_dir: getenv("ZAPRET2_LOG_DIR") || runtime_constants.ZAPRET2_LOG_DIR,
        route_mark_base: getenv("ZAPRET2_ROUTE_MARK_BASE") || runtime_constants.ZAPRET2_ROUTE_MARK_BASE,
        queue_base: getenv("ZAPRET2_QUEUE_BASE") || runtime_constants.ZAPRET2_QUEUE_BASE,
        queue_range_size: getenv("ZAPRET2_QUEUE_RANGE_SIZE") || runtime_constants.ZAPRET2_QUEUE_RANGE_SIZE,
        respawn_delay: getenv("ZAPRET2_NFQWS2_RESPAWN_DELAY") || runtime_constants.ZAPRET2_NFQWS2_RESPAWN_DELAY,
        desync_mark,
        desync_mark_postnat: getenv("ZAPRET2_DESYNC_MARK_POSTNAT") || runtime_constants.ZAPRET2_DESYNC_MARK_POSTNAT,
        default_strategy: getenv("ZAPRET2_DEFAULT_NFQWS2_OPT") || runtime_constants.ZAPRET2_DEFAULT_NFQWS2_OPT,
        legacy_default_strategy: "",
        strategy_option: "nfqws2_opt",
        validator_kind: "nfqws2",
        validator,
        package_name: "zapret2",
        runtime_path: lib_dir + "/providers/zapret2/runtime.uc",
        check_path: lib_dir + "/providers/zapret2/check.uc",
        luci_package: "luci-app-zapret2",
        luci_menu: "/usr/share/luci/menu.d/luci-app-zapret2.json",
        luci_acl: "/usr/share/rpcd/acl.d/luci-app-zapret2.json",
        service_init: "/etc/init.d/zapret2",
        config_name: "zapret2",
        legacy_runtime_base: "",
        hostlist_dir: "",
        status_label: "zapret2",
        check_prefix: "zapret2",
        base_args: [
            "--fwmark=" + desync_mark,
            "--lua-init=@" + provider_lua_dir + "/zapret-lib.lua",
            "--lua-init=@" + provider_lua_dir + "/zapret-antidpi.lua",
            "--lua-init=@" + provider_lua_dir + "/zapret-auto.lua"
        ]
    };
}

return {
    config,
    validator
};
