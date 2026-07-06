#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UCODE_LIB="$ROOT_DIR/podkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cat >"$WORK_DIR/uci.uc" <<'UCODE'
let state = {
    dhcp: {
        cfg01411c: {
            ".name": "cfg01411c",
            ".type": "dnsmasq",
            server: [ "1.1.1.1", "8.8.8.8" ],
            noresolv: "0",
            cachesize: "150"
        },
        cfg02422d: {
            ".name": "cfg02422d",
            ".type": "dnsmasq",
            server: [ "9.9.9.9" ],
            noresolv: "0"
        }
    }
};

function package_state(package_name) {
    package_name = "" + package_name;
    if (!state[package_name])
        state[package_name] = {};
    return state[package_name];
}

function cursor() {
    return {
        load: function(_package_name) {
            return true;
        },
        get: function(package_name, section_name, option_name) {
            let section = package_state(package_name)["" + section_name];
            return section ? section["" + option_name] : null;
        },
        get_all: function(package_name, section_name) {
            return package_state(package_name)["" + section_name] || null;
        },
        set: function(package_name, section_name, option_name, value) {
            let sections = package_state(package_name);
            section_name = "" + section_name;
            if (value == null) {
                sections[section_name] = {
                    ".name": section_name,
                    ".type": "" + option_name
                };
                return true;
            }

            if (!sections[section_name])
                sections[section_name] = { ".name": section_name };
            sections[section_name]["" + option_name] = value;
            return true;
        },
        delete: function(package_name, section_name, option_name) {
            let sections = package_state(package_name);
            section_name = "" + section_name;
            if (!sections[section_name])
                return true;
            if (option_name == null) {
                delete sections[section_name];
                return true;
            }
            delete sections[section_name]["" + option_name];
            return true;
        },
        add: function(package_name, type_name) {
            let sections = package_state(package_name);
            let section_name = "cfg100001";
            sections[section_name] = {
                ".name": section_name,
                ".type": "" + type_name
            };
            return section_name;
        },
        foreach: function(package_name, type_name, callback) {
            for (let section_name in package_state(package_name)) {
                let section = package_state(package_name)[section_name];
                if (section && section[".type"] == type_name)
                    callback(section);
            }
        },
        commit: function(_package_name) {
            return true;
        }
    };
}

return { cursor };
UCODE

cat >"$WORK_DIR/check.uc" <<'UCODE'
let uci = require("core.uci");

function fail(message) {
    die(message + "\n");
}

function assert_equal(actual, expected, message) {
    actual = actual == null ? "" : "" + actual;
    expected = expected == null ? "" : "" + expected;
    if (actual != expected)
        fail(message + ": expected '" + expected + "', got '" + actual + "'");
}

function assert_true(value, message) {
    if (!value)
        fail(message);
}

assert_equal(uci.get("dhcp.@dnsmasq[0].server"), "1.1.1.1 8.8.8.8", "anonymous get");
assert_equal(uci.get("dhcp.@dnsmasq[1].server"), "9.9.9.9", "anonymous get second section");

let first = uci.get_all("dhcp", "@dnsmasq[0]");
assert_equal(first[".name"], "cfg01411c", "anonymous get_all section name");

assert_true(uci.set("dhcp.@dnsmasq[0].noresolv", "1"), "anonymous set must succeed");
assert_equal(uci.get("dhcp.cfg01411c.noresolv"), "1", "anonymous set must affect resolved section");

assert_true(uci.delete("dhcp.@dnsmasq[0].server"), "anonymous delete must succeed");
assert_equal(uci.get("dhcp.cfg01411c.server"), "", "anonymous delete must affect resolved section");

assert_true(uci.add_list("dhcp.@dnsmasq[0].server", "127.0.0.42"), "anonymous add_list must succeed");
assert_equal(uci.get("dhcp.cfg01411c.server"), "127.0.0.42", "anonymous add_list must affect resolved section");

assert_true(uci.add_list("dhcp.@dnsmasq[0].server", "1.1.1.1"), "anonymous second add_list must succeed");
assert_equal(uci.get("dhcp.cfg01411c.server"), "127.0.0.42 1.1.1.1", "anonymous add_list must append");

assert_true(uci.del_list("dhcp.@dnsmasq[0].server", "127.0.0.42"), "anonymous del_list must succeed");
assert_equal(uci.get("dhcp.cfg01411c.server"), "1.1.1.1", "anonymous del_list must affect resolved section");

assert_true(uci.delete("dhcp.@dnsmasq[9].server") == false, "missing anonymous section must fail writes");
UCODE

ucode -L "$UCODE_LIB" -L "$WORK_DIR" "$WORK_DIR/check.uc" ||
  fail "core.uci anonymous selector runtime regression"

printf 'core UCI runtime regression checks passed\n'
