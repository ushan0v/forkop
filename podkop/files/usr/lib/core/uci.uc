#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");

let as_string = common.as_string;

const UCI_STATE_FILE = getenv("PODKOP_UCI_STATE_FILE") || getenv("UCI_STATE") || "";
const UCI_LOG_FILE = getenv("PODKOP_UCI_LOG_FILE") || getenv("UCI_LOG") || "";

let runtime_cursor = false;

function words(value) {
    value = trim(as_string(value));
    return value == "" ? [] : split(value, /[ \t\r\n]+/);
}

function path_parts(path) {
    path = as_string(path);
    let first = index(path, ".");
    if (first < 0)
        return null;

    let package_name = substr(path, 0, first);
    let rest = substr(path, first + 1);
    let second = index(rest, ".");
    if (second < 0)
        return { package: package_name, section: rest, option: "" };

    return {
        package: package_name,
        section: substr(rest, 0, second),
        option: substr(rest, second + 1)
    };
}

function state_lines() {
    let data = fs.readfile(UCI_STATE_FILE);
    if (data == null || data == "")
        return [];
    return split(replace(data, /\r/g, ""), "\n");
}

function state_write_lines(lines) {
    return fs.writefile(UCI_STATE_FILE, join("\n", lines) + "\n") != null;
}

function state_get(path) {
    for (let line in state_lines()) {
        if (line == "")
            continue;
        let equals = index(line, "=");
        let key = equals >= 0 ? substr(line, 0, equals) : line;
        if (key == path)
            return equals >= 0 ? substr(line, equals + 1) : "";
    }
    return "";
}

function state_exists(path) {
    let prefix = as_string(path) + ".";
    for (let line in state_lines()) {
        if (line == "")
            continue;
        let equals = index(line, "=");
        let key = equals >= 0 ? substr(line, 0, equals) : line;
        if (key == path || substr(key, 0, length(prefix)) == prefix)
            return true;
    }
    return false;
}

function state_delete(path) {
    let prefix = as_string(path) + ".";
    let changed = false;
    let lines = [];
    for (let line in state_lines()) {
        if (line == "")
            continue;
        let equals = index(line, "=");
        let key = equals >= 0 ? substr(line, 0, equals) : line;
        if (key == path || substr(key, 0, length(prefix)) == prefix) {
            changed = true;
            continue;
        }
        push(lines, line);
    }
    return !changed || state_write_lines(lines);
}

function state_set(path, value) {
    let lines = [];
    for (let line in state_lines()) {
        if (line == "")
            continue;
        let equals = index(line, "=");
        let key = equals >= 0 ? substr(line, 0, equals) : line;
        if (key != path)
            push(lines, line);
    }
    push(lines, as_string(path) + "=" + as_string(value));
    return state_write_lines(lines);
}

function state_add_list(path, value) {
    let current = state_get(path);
    return state_set(path, current == "" ? value : current + " " + as_string(value));
}

function state_del_list(path, value) {
    let current = state_get(path);
    if (current == "")
        return false;

    let values = [];
    let removed = false;
    for (let item in words(current)) {
        if (item == value) {
            removed = true;
            continue;
        }
        push(values, item);
    }

    if (!removed)
        return false;
    if (length(values) == 0)
        return state_delete(path);
    return state_set(path, join(" ", values));
}

function state_commit(package_name) {
    if (UCI_LOG_FILE == "")
        return true;
    let existing = fs.readfile(UCI_LOG_FILE);
    existing = existing == null ? "" : as_string(existing);
    return fs.writefile(UCI_LOG_FILE, existing + "commit " + as_string(package_name) + "\n") != null;
}

function state_add_section(package_name, type_name) {
    package_name = as_string(package_name);
    type_name = as_string(type_name);

    let index = 1;
    let section = "";
    while (true) {
        section = sprintf("cfg%06x", index);
        if (!state_exists(package_name + "." + section))
            break;
        index++;
    }

    return state_set(package_name + "." + section, type_name) ? section : "";
}

function state_sections(package_name, type_name) {
    let result = [];
    let prefix = as_string(package_name) + ".";
    for (let line in state_lines()) {
        if (line == "")
            continue;
        let equals = index(line, "=");
        if (equals < 0)
            continue;

        let key = substr(line, 0, equals);
        let value = substr(line, equals + 1);
        if (value != type_name || substr(key, 0, length(prefix)) != prefix)
            continue;

        let section = substr(key, length(prefix));
        if (index(section, ".") < 0)
            push(result, section);
    }
    return result;
}

function state_get_all(package_name, section_name) {
    package_name = as_string(package_name);
    section_name = as_string(section_name);

    let result = {};
    let section_type = state_get(package_name + "." + section_name);
    if (section_type != "") {
        result[".name"] = section_name;
        result[".type"] = section_type;
    }

    let prefix = package_name + "." + section_name + ".";
    for (let line in state_lines()) {
        if (line == "")
            continue;
        let equals = index(line, "=");
        if (equals < 0)
            continue;

        let key = substr(line, 0, equals);
        if (substr(key, 0, length(prefix)) != prefix)
            continue;

        let option = substr(key, length(prefix));
        if (option != "")
            result[option] = substr(line, equals + 1);
    }

    return length(keys(result)) > 0 ? result : null;
}

function fixture_enabled() {
    return UCI_STATE_FILE != "";
}

function cursor() {
    if (runtime_cursor !== false)
        return runtime_cursor;

    try {
        runtime_cursor = require("uci").cursor();
    }
    catch (e) {
        runtime_cursor = null;
    }
    return runtime_cursor;
}

function available() {
    return fixture_enabled() || cursor() != null;
}

function load(package_name) {
    if (fixture_enabled())
        return true;

    let c = cursor();
    if (c == null)
        return false;

    try {
        c.load(as_string(package_name));
        return true;
    }
    catch (e) {
        return false;
    }
}

function value_to_string(value) {
    if (value == null)
        return "";
    if (type(value) == "array")
        return join(" ", value);
    return as_string(value);
}

function value_to_list(value) {
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;
    return words(value);
}

function get(path) {
    path = as_string(path);
    if (fixture_enabled())
        return state_get(path);

    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null || parts.option == "")
        return "";
    if (!load(parts.package))
        return "";

    return value_to_string(c.get(parts.package, parts.section, parts.option));
}

function get_all(package_name, section_name) {
    if (fixture_enabled())
        return state_get_all(package_name, section_name);

    let c = cursor();
    if (c == null)
        return null;

    try {
        load(package_name);
        return c.get_all(as_string(package_name), as_string(section_name));
    }
    catch (e) {
        return null;
    }
}

function exists(path) {
    path = as_string(path);
    if (fixture_enabled())
        return state_exists(path);

    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null)
        return false;
    if (!load(parts.package))
        return false;

    if (parts.option == "")
        return c.get_all(parts.package, parts.section) != null;
    return c.get(parts.package, parts.section, parts.option) != null;
}

function delete_path(path) {
    path = as_string(path);
    if (fixture_enabled())
        return state_delete(path);

    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null)
        return false;

    try {
        if (parts.option == "")
            c.delete(parts.package, parts.section);
        else
            c.delete(parts.package, parts.section, parts.option);
        return true;
    }
    catch (e) {
        return false;
    }
}

function set_section(path, type_name) {
    path = as_string(path);
    if (fixture_enabled())
        return state_set(path, type_name);

    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null || parts.option != "")
        return false;

    try {
        c.set(parts.package, parts.section, as_string(type_name));
        return true;
    }
    catch (e) {
        return false;
    }
}

function add(package_name, type_name) {
    if (fixture_enabled())
        return state_add_section(package_name, type_name);

    let c = cursor();
    if (c == null)
        return "";

    try {
        load(package_name);
        let section = c.add(as_string(package_name), as_string(type_name));
        return as_string(section);
    }
    catch (e) {
        return "";
    }
}

function set(path, value) {
    path = as_string(path);
    if (fixture_enabled())
        return state_set(path, value_to_string(value));

    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null || parts.option == "")
        return false;

    try {
        c.set(parts.package, parts.section, parts.option, type(value) == "array" ? value : as_string(value));
        return true;
    }
    catch (e) {
        return false;
    }
}

function add_list(path, value) {
    path = as_string(path);
    if (fixture_enabled())
        return state_add_list(path, value);

    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null || parts.option == "")
        return false;

    try {
        let values = value_to_list(c.get(parts.package, parts.section, parts.option));
        push(values, as_string(value));
        c.set(parts.package, parts.section, parts.option, values);
        return true;
    }
    catch (e) {
        return false;
    }
}

function del_list(path, value) {
    path = as_string(path);
    if (fixture_enabled())
        return state_del_list(path, value);

    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null || parts.option == "")
        return false;

    let values = [];
    let removed = false;
    for (let item in value_to_list(c.get(parts.package, parts.section, parts.option))) {
        if (item == value) {
            removed = true;
            continue;
        }
        push(values, item);
    }

    if (!removed)
        return false;

    try {
        if (length(values) == 0)
            c.delete(parts.package, parts.section, parts.option);
        else
            c.set(parts.package, parts.section, parts.option, values);
        return true;
    }
    catch (e) {
        return false;
    }
}

function commit(package_name) {
    if (fixture_enabled())
        return state_commit(package_name);

    let c = cursor();
    if (c == null)
        return false;

    try {
        return c.commit(package_name) != false;
    }
    catch (e) {
        return false;
    }
}

function section_name(section) {
    if (type(section) == "object")
        return as_string(section[".name"] || "");
    return as_string(section);
}

function sections(package_name, type_name) {
    if (fixture_enabled())
        return state_sections(package_name, type_name);

    let c = cursor();
    if (c == null)
        return [];

    let result = [];
    try {
        load(package_name);
        c.foreach(package_name, as_string(type_name), function(section) {
            let name = section_name(section);
            if (name != "")
                push(result, name);
        });
    }
    catch (e) {
        return [];
    }
    return result;
}

function section_objects(package_name, type_name) {
    if (fixture_enabled()) {
        let result = [];
        for (let name in state_sections(package_name, type_name)) {
            let section = state_get_all(package_name, name);
            if (type(section) == "object")
                push(result, section);
        }
        return result;
    }

    let c = cursor();
    if (c == null)
        return [];

    let result = [];
    try {
        load(package_name);
        c.foreach(package_name, as_string(type_name), function(section) {
            if (type(section) == "object")
                push(result, section);
        });
    }
    catch (e) {
        return [];
    }
    return result;
}

return {
    available,
    load,
    get,
    get_all,
    exists,
    delete: delete_path,
    set_section,
    add,
    set,
    add_list,
    del_list,
    commit,
    sections,
    section_objects
};
