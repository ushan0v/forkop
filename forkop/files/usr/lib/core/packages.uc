#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function command_success(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function command_output(args) {
    let pipe = fs.popen(command_from_args(args), "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";
    return as_string(data);
}

function command_exists(name) {
    return command_success([ "command", "-v", name ]);
}

function apk_installed(package_name) {
    return command_exists("apk") && command_success([ "apk", "info", "-e", as_string(package_name) ]);
}

function opkg_installed(package_name) {
    package_name = as_string(package_name);
    if (!command_exists("opkg"))
        return false;

    let prefix = package_name + " - ";
    for (let line in split(command_output([ "opkg", "list-installed" ]), "\n")) {
        line = trim(as_string(line));
        if (substr(line, 0, length(prefix)) == prefix)
            return true;
    }
    return false;
}

function installed(package_name) {
    return apk_installed(package_name) || opkg_installed(package_name);
}

function apk_manifest_version(package_name, output) {
    package_name = as_string(package_name);
    let found = false;

    for (let line in split(as_string(output), "\n")) {
        line = trim(as_string(line));
        if (substr(line, 0, 2) == "P:")
            found = substr(line, 2) == package_name;
        else if (found && substr(line, 0, 2) == "V:")
            return substr(line, 2);
    }
    return "";
}

function apk_info_version(package_name, output) {
    package_name = as_string(package_name);
    let prefix = package_name + "-";

    for (let line in split(as_string(output), "\n")) {
        line = trim(as_string(line));
        if (line == "")
            continue;
        return substr(line, 0, length(prefix)) == prefix ? substr(line, length(prefix)) : line;
    }
    return "";
}

function apk_version(package_name) {
    package_name = as_string(package_name);
    if (!apk_installed(package_name))
        return "";

    let version = apk_manifest_version(package_name, command_output([ "apk", "list", "--installed", "--manifest", package_name ]));
    if (version != "")
        return version;

    version = apk_manifest_version(package_name, command_output([ "apk", "list", "--installed", "--manifest" ]));
    if (version != "")
        return version;

    return apk_info_version(package_name, command_output([ "apk", "info", "-v", package_name ]));
}

function apk_available_version(package_name) {
    package_name = as_string(package_name);
    if (!command_exists("apk"))
        return "";
    return apk_manifest_version(
        package_name,
        command_output([ "apk", "list", "--available", "--manifest", package_name ])
    );
}

function opkg_version(package_name) {
    package_name = as_string(package_name);
    if (!command_exists("opkg"))
        return "";

    let prefix = package_name + " - ";
    for (let line in split(command_output([ "opkg", "list-installed" ]), "\n")) {
        line = trim(as_string(line));
        if (substr(line, 0, length(prefix)) == prefix)
            return substr(line, length(prefix));
    }
    return "";
}

function version(package_name) {
    let value = apk_version(package_name);
    return value != "" ? value : opkg_version(package_name);
}

let mode = ARGV[0] || "";

if (mode == "installed")
    exit(installed(ARGV[1]) ? 0 : 1);
else if (mode == "apk-installed")
    exit(apk_installed(ARGV[1]) ? 0 : 1);
else if (mode == "opkg-installed")
    exit(opkg_installed(ARGV[1]) ? 0 : 1);
else if (mode == "version")
    print(version(ARGV[1]), "\n");
else if (mode == "apk-version")
    print(apk_version(ARGV[1]), "\n");
else if (mode == "apk-available-version")
    print(apk_available_version(ARGV[1]), "\n");
else if (mode == "opkg-version")
    print(opkg_version(ARGV[1]), "\n");
else {
    warn("Usage: core/packages.uc <installed|apk-installed|opkg-installed|version|apk-version|apk-available-version|opkg-version> <package>\n");
    exit(1);
}
