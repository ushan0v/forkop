#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function read_json_file(path) {
    let data = fs.readfile(path);
    if (data == null)
        return null;

    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : data;
}

function read_stdin_json() {
    let data = read_stdin();
    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function stdin_contains_ci(needle) {
    needle = lc(as_string(needle));
    if (needle == "")
        return false;
    return index(lc(read_stdin()), needle) >= 0;
}

function file_first_line(path) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    let newline = index(data, "\n");
    print(newline >= 0 ? substr(data, 0, newline) : data, "\n");
}

function json_file_field(path, key, fallback) {
    let value = read_json_file(path);
    if (type(value) == "object" && value[key] != null)
        print(as_string(value[key]), "\n");
    else
        print(as_string(fallback), "\n");
}

function object_get_default(key, fallback) {
    let value = read_stdin_json();
    if (type(value) == "object" && value[key] != null)
        print(as_string(value[key]), "\n");
    else
        print(as_string(fallback), "\n");
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function str_contains(haystack, needle) {
    return index(as_string(haystack), as_string(needle)) >= 0;
}

function str_startswith(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
}

function str_endswith(value, suffix) {
    value = as_string(value);
    suffix = as_string(suffix);
    return length(value) >= length(suffix) && substr(value, length(value) - length(suffix)) == suffix;
}

function str_remove_suffix(value, suffix) {
    value = as_string(value);
    suffix = as_string(suffix);
    return str_endswith(value, suffix) ? substr(value, 0, length(value) - length(suffix)) : value;
}

function string_remove_suffix(value, suffix) {
    print(str_remove_suffix(value, suffix), "\n");
}

function path_basename(value) {
    let parts = split(as_string(value), "/");
    return length(parts) > 0 ? as_string(parts[length(parts) - 1]) : "";
}

function str_last_index(value, needle) {
    value = as_string(value);
    needle = as_string(needle);
    if (needle == "")
        return length(value);

    for (let i = length(value) - length(needle); i >= 0; i--)
        if (substr(value, i, length(needle)) == needle)
            return i;

    return -1;
}

function arg_bool(value) {
    return value === true || value == "true" || value == "1" || value == 1;
}

function arg_number(value) {
    value = as_string(value);
    if (value == "" || match(value, /[^0-9-]/))
        return 0;
    return int(value);
}

function file_json_valid(path) {
    return read_json_file(path) != null;
}

function github_response_ok() {
    let response = read_stdin_json();
    if (response == null)
        return false;

    if (type(response) == "object") {
        let message = as_string(response.message || "");
        if (match(message, /API rate limit/) || match(message, /rate limit exceeded/) || message == "Not Found")
            return false;
    }

    return true;
}

function release_by_tag(tag) {
    for (let release in array_or_empty(read_stdin_json())) {
        if (type(release) != "object")
            continue;
        if (release.draft === true || release.prerelease === true)
            continue;
        if (as_string(release.tag_name || "") == tag) {
            write_json(release);
            return;
        }
    }
}

function release_asset_name(prefix, ext) {
    let release = object_or_empty(read_stdin_json());
    for (let asset in array_or_empty(release.assets)) {
        if (type(asset) != "object")
            continue;
        let name = as_string(asset.name || "");
        if ((str_startswith(name, prefix + "_") || str_startswith(name, prefix + "-")) &&
            str_endswith(name, "." + ext)) {
            print(name, "\n");
            return;
        }
    }
}

function release_asset_url(name) {
    let release = object_or_empty(read_stdin_json());
    for (let asset in array_or_empty(release.assets)) {
        if (type(asset) == "object" && as_string(asset.name || "") == name) {
            print(as_string(asset.browser_download_url || ""), "\n");
            return;
        }
    }
}

function release_asset_name_by_suffix(suffix) {
    let release = object_or_empty(read_stdin_json());
    for (let asset in array_or_empty(release.assets)) {
        let name = type(asset) == "object" ? as_string(asset.name || "") : "";
        if (str_endswith(name, suffix)) {
            print(name, "\n");
            return;
        }
    }
}

function release_asset_url_by_suffix_from_release(release, suffix) {
    suffix = as_string(suffix);
    for (let asset in array_or_empty(release.assets)) {
        if (type(asset) != "object")
            continue;
        let name = as_string(asset.name || "");
        if (str_endswith(name, suffix))
            return as_string(asset.browser_download_url || "");
    }

    return "";
}

function release_asset_url_by_suffix(suffix) {
    let release = object_or_empty(read_stdin_json());
    let url = release_asset_url_by_suffix_from_release(release, suffix);
    if (url != "")
        print(url, "\n");
}

function release_metadata_tsv() {
    let release = object_or_empty(read_stdin_json());
    let tag = as_string(release.tag_name || "");

    if (tag == "")
        return;

    print(tag, "\t", as_string(release.html_url || ""), "\n");
}

function openwrt_release_value(path, key) {
    let data = fs.readfile(path);
    if (data == null)
        return;

    let prefix = as_string(key) + "='";
    for (let line in split(as_string(data), "\n")) {
        if (!str_startswith(line, prefix))
            continue;

        let rest = substr(line, length(prefix));
        let quote = str_last_index(rest, "'");
        if (quote >= 0)
            print(substr(rest, 0, quote), "\n");
        return;
    }
}

function openwrt_release_series(path) {
    let data = fs.readfile(path);
    if (data == null)
        return;

    let prefix = "DISTRIB_RELEASE='";
    for (let line in split(as_string(data), "\n")) {
        if (!str_startswith(line, prefix))
            continue;

        let value = substr(line, length(prefix));
        let quote = str_last_index(value, "'");
        if (quote >= 0)
            value = substr(value, 0, quote);

        let matched = match(value, /^([0-9]+\.[0-9]+)/);
        if (matched != null)
            print(matched[1], "\n");
        return;
    }
}

function updates_arch_package_version(package_name, package_arch) {
    let version = str_remove_suffix(str_remove_suffix(package_name, ".ipk"), ".apk");
    let prefixes = ["zapret2_", "zapret2-", "zapret_", "zapret-", "byedpi_", "byedpi-"];

    for (let prefix in prefixes) {
        if (str_startswith(version, prefix)) {
            version = substr(version, length(prefix));
            break;
        }
    }

    package_arch = as_string(package_arch);
    if (package_arch != "") {
        version = str_remove_suffix(version, "_" + package_arch);
        version = str_remove_suffix(version, "-" + package_arch);
    }

    print(version, "\n");
}

function updates_bundle_version(bundle_name, prefixes) {
    let name = path_basename(bundle_name);

    for (let prefix in prefixes) {
        if (!str_startswith(name, prefix))
            continue;

        let rest = substr(name, length(prefix));
        let separator = index(rest, "_");
        if (separator <= 0)
            continue;

        let version = substr(rest, 0, separator);
        if (str_startswith(version, "v"))
            version = substr(version, 1);

        print(version, "\n");
        return;
    }

    print("\n");
}

function updates_zapret_bundle_version(bundle_name) {
    updates_bundle_version(bundle_name, ["zapret_v", "zapret_"]);
}

function updates_zapret2_bundle_version(bundle_name) {
    updates_bundle_version(bundle_name, ["zapret2_v", "zapret2_", "zapret_v", "zapret_"]);
}

function first_version_token(value) {
    value = as_string(value);
    for (let i = 0; i < length(value); i++) {
        let chr = substr(value, i, 1);
        if (chr == " " || chr == "\t" || chr == "\r" || chr == "\n")
            return substr(value, 0, i);
    }

    return value;
}

function strip_plus_metadata(value) {
    value = as_string(value);
    let plus = index(value, "+");
    return plus >= 0 ? substr(value, 0, plus) : value;
}

function strip_revision_suffix(value) {
    let matched = match(as_string(value), /^(.*)-r[0-9]+$/);
    return matched ? matched[1] : as_string(value);
}

function updates_normalize_sing_box_version(value) {
    value = as_string(value);
    if (str_startswith(value, "v"))
        value = substr(value, 1);

    print(first_version_token(strip_plus_metadata(value)), "\n");
}

function updates_normalize_zapret_version(value) {
    value = as_string(value);
    if (str_startswith(value, "v"))
        value = substr(value, 1);

    value = strip_revision_suffix(value);
    value = strip_plus_metadata(value);
    print(first_version_token(value), "\n");
}

function podkop_normalized_release_version(value) {
    value = as_string(value);
    if (str_startswith(value, "v"))
        value = substr(value, 1);

    let revision = match(value, /^(.*)-r([0-9]+)$/);
    if (revision != null)
        value = revision[1] + "-" + revision[2];

    return value;
}

function podkop_release_version_valid(value) {
    value = podkop_normalized_release_version(value);
    return match(value, /^([0-9]+([.][0-9]+)*(-[0-9]+)?|[0-9]+([.][0-9]+){3})$/) != null;
}

function dot_count(value) {
    value = as_string(value);
    let count = 0;
    for (let i = 0; i < length(value); i++)
        if (substr(value, i, 1) == ".")
            count++;
    return count;
}

function podkop_release_version_parts(value) {
    let version = podkop_normalized_release_version(value);
    let release = "0";

    let dash = str_last_index(version, "-");
    if (dash >= 0) {
        release = substr(version, dash + 1);
        version = substr(version, 0, dash);
    }
    else if (dot_count(version) >= 3) {
        let dot = str_last_index(version, ".");
        release = substr(version, dot + 1);
        version = substr(version, 0, dot);
    }

    if (version == "" || match(version, /[^0-9.]/) != null || str_startswith(version, ".") || str_endswith(version, "."))
        return null;
    if (release == "" || match(release, /[^0-9]/) != null)
        return null;

    let parts = split(version, ".");
    let major = as_string(parts[0]);
    let minor = length(parts) > 1 && as_string(parts[1]) != "" ? as_string(parts[1]) : "0";
    let patch = length(parts) > 2 && as_string(parts[2]) != "" ? as_string(parts[2]) : "0";

    if (major == "" || match(major, /[^0-9]/) != null)
        return null;
    if (minor == "" || match(minor, /[^0-9]/) != null)
        return null;
    if (patch == "" || match(patch, /[^0-9]/) != null)
        return null;

    return [int(major), int(minor), int(patch), int(release)];
}

function podkop_release_version_compare(lhs, rhs) {
    let lhs_parts = podkop_release_version_parts(lhs);
    let rhs_parts = podkop_release_version_parts(rhs);
    if (lhs_parts == null || rhs_parts == null)
        return false;

    for (let i = 0; i < length(lhs_parts); i++) {
        if (lhs_parts[i] < rhs_parts[i]) {
            print("-1\n");
            return true;
        }
        if (lhs_parts[i] > rhs_parts[i]) {
            print("1\n");
            return true;
        }
    }

    print("0\n");
    return true;
}

function fourth_whitespace_field(line) {
    let fields = split(trim(as_string(line)), /[ \t]+/);
    return length(fields) >= 4 ? as_string(fields[3]) : "";
}

function updates_zip_inner_package_path(component, arch, ext) {
    component = as_string(component);
    arch = as_string(arch);
    ext = as_string(ext);

    let fallback = "";
    for (let line in split(read_stdin(), "\n")) {
        let path = fourth_whitespace_field(line);
        if (path == "")
            continue;

        if (ext == "apk") {
            if (str_startswith(path, "apk/" + component + "-") && str_endswith(path, ".apk")) {
                print(path, "\n");
                return;
            }
            continue;
        }

        if (ext == "ipk" && str_startswith(path, component + "_") && str_endswith(path, ".ipk")) {
            if (arch != "" && str_endswith(path, "_" + arch + ".ipk")) {
                print(path, "\n");
                return;
            }
            if (fallback == "")
                fallback = path;
        }
    }

    if (fallback != "")
        print(fallback, "\n");
}

function updates_archive_member_path(member_name) {
    member_name = as_string(member_name);

    for (let line in split(read_stdin(), "\n")) {
        let path = trim(as_string(line));
        if (path != "" && path_basename(path) == member_name) {
            print(path, "\n");
            return;
        }
    }
}

function updates_opkg_arch_list() {
    let arches = [];

    for (let line in split(read_stdin(), "\n")) {
        let fields = split(trim(as_string(line)), /[ \t]+/);
        if (length(fields) < 2 || as_string(fields[0]) != "arch")
            continue;

        let name = as_string(fields[1]);
        if (name == "all" || name == "noarch")
            continue;

        push(arches, {
            name,
            priority: int(length(fields) >= 3 ? as_string(fields[2]) : "")
        });
    }

    for (let i = 1; i < length(arches); i++) {
        let item = arches[i];
        let j = i - 1;
        while (j >= 0 && (arches[j].priority < item.priority ||
            (arches[j].priority == item.priority && arches[j].name > item.name))) {
            arches[j + 1] = arches[j];
            j--;
        }
        arches[j + 1] = item;
    }

    for (let arch in arches)
        print(arch.name, "\n");
}

function append_unique(values, value) {
    value = as_string(value);
    if (value == "" || value == "all" || value == "noarch")
        return;

    for (let existing in values)
        if (existing == value)
            return;

    push(values, value);
}

function whitespace_fields(value) {
    value = as_string(value);
    let result = [];
    let start = -1;

    for (let i = 0; i < length(value); i++) {
        let chr = substr(value, i, 1);
        let whitespace = chr == " " || chr == "\t" || chr == "\r" || chr == "\n";

        if (whitespace) {
            if (start >= 0) {
                push(result, substr(value, start, i - start));
                start = -1;
            }
        }
        else if (start < 0) {
            start = i;
        }
    }

    if (start >= 0)
        push(result, substr(value, start));

    return result;
}

function string_has_whitespace_field(value) {
    return length(whitespace_fields(value)) > 0;
}

function file_whitespace_list(path) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    print(join(" ", whitespace_fields(data)), "\n");
}

function arch_candidate_variants(candidate) {
    let result = [];
    candidate = as_string(candidate);
    if (candidate == "")
        return result;

    append_unique(result, candidate);

    let plus = index(candidate, "+");
    if (plus >= 0)
        append_unique(result, substr(candidate, 0, plus));

    let suffixes = [
        "_musl", "_uclibc", "_glibc",
        "-musl", "-uclibc", "-glibc",
        ".musl", ".uclibc", ".glibc"
    ];

    for (let suffix in suffixes)
        if (str_endswith(candidate, suffix))
            append_unique(result, substr(candidate, 0, length(candidate) - length(suffix)));

    return result;
}

function arch_candidate_bases(arch) {
    let result = [];
    arch = as_string(arch);
    push(result, arch);

    if (str_startswith(arch, "aarch64_"))
        push(result, "aarch64_generic");
    else if (str_startswith(arch, "riscv64_"))
        push(result, "riscv64_generic");
    else if (arch == "arm_cortex-a7_neon-vfpv4") {
        push(result, "arm_cortex-a7_vfpv4");
        push(result, "arm_cortex-a7");
    }
    else if (str_startswith(arch, "arm_cortex-a7_"))
        push(result, "arm_cortex-a7");
    else if (str_startswith(arch, "arm_cortex-a9_"))
        push(result, "arm_cortex-a9");
    else if (arch == "mipsel_24kc_24kf")
        push(result, "mipsel_24kc");

    return result;
}

function updates_arch_candidates(arch_list) {
    let target = "";
    let candidates = [];

    for (let arch in whitespace_fields(arch_list)) {
        arch = as_string(arch);
        if (arch == "" || arch == "all" || arch == "noarch")
            continue;

        if (target == "")
            target = arch;
        for (let base in arch_candidate_bases(arch))
            for (let variant in arch_candidate_variants(base))
                append_unique(candidates, variant);
    }

    if (target == "")
        exit(1);

    print(target, "\t", join(" ", candidates), "\n");
}

function sing_box_extended_arch_suffix(host_arch, distrib_arch) {
    host_arch = as_string(host_arch);
    distrib_arch = as_string(distrib_arch);

    if (str_contains(distrib_arch, "mipsel") || str_contains(distrib_arch, "mipsle"))
        host_arch = "mipsel";
    else if (str_contains(distrib_arch, "mips64el") || str_contains(distrib_arch, "mips64le"))
        host_arch = "mips64el";

    if (host_arch == "aarch64")
        print("arm64\n");
    else if (str_startswith(host_arch, "armv7"))
        print("armv7\n");
    else if (str_startswith(host_arch, "armv6"))
        print("armv6\n");
    else if (host_arch == "x86_64")
        print("amd64\n");
    else if (host_arch == "i386" || host_arch == "i686")
        print("386\n");
    else if (host_arch == "mips")
        print("mips-softfloat\n");
    else if (host_arch == "mipsel" || host_arch == "mipsle")
        print("mipsle-softfloat\n");
    else if (host_arch == "mips64")
        print("mips64\n");
    else if (host_arch == "mips64el" || host_arch == "mips64le")
        print("mips64le\n");
    else if (host_arch == "riscv64")
        print("riscv64\n");
    else if (host_arch == "s390x")
        print("s390x\n");
    else
        exit(1);
}

function sing_box_extended_asset_url(arch_suffix, prefer_musl, compressed) {
    let release = object_or_empty(read_stdin_json());
    let patterns = [];

    arch_suffix = as_string(arch_suffix);
    if (arch_suffix == "")
        exit(1);

    if (as_string(compressed) == "1")
        push(patterns, "linux-" + arch_suffix + "-compressed.tar.gz");
    else if (as_string(prefer_musl) == "1")
        push(patterns, "linux-" + arch_suffix + "-musl.tar.gz");
    if (as_string(compressed) != "1")
        push(patterns, "linux-" + arch_suffix + ".tar.gz");

    for (let suffix in patterns) {
        let url = release_asset_url_by_suffix_from_release(release, suffix);
        if (url != "") {
            print(url, "\n");
            return;
        }
    }

    exit(1);
}

function updates_opkg_package_installed(package_name) {
    package_name = as_string(package_name);

    for (let line in split(read_stdin(), "\n")) {
        let fields = split(trim(as_string(line)), /[ \t]+/);
        if (length(fields) >= 1 && as_string(fields[0]) == package_name)
            exit(0);
    }

    exit(1);
}

function updates_opkg_package_version(package_name) {
    package_name = as_string(package_name);

    for (let line in split(read_stdin(), "\n")) {
        let fields = split(trim(as_string(line)), /[ \t]+/);
        if (length(fields) >= 3 && as_string(fields[0]) == package_name && as_string(fields[1]) == "-") {
            print(as_string(fields[2]), "\n");
            return;
        }
    }
}

function updates_apk_manifest_package_version(package_name) {
    package_name = as_string(package_name);

    for (let line in split(read_stdin(), "\n")) {
        let fields = split(trim(as_string(line)), /[ \t]+/);
        if (length(fields) >= 2 && as_string(fields[0]) == package_name) {
            print(as_string(fields[1]), "\n");
            return;
        }
    }
}

function updates_apk_info_package_version(package_name) {
    package_name = as_string(package_name);
    let prefix = package_name + "-";
    let first = split(read_stdin(), "\n")[0];
    first = as_string(first);

    if (!str_startswith(first, prefix))
        return;

    let version = substr(first, length(prefix));
    version = replace(version, /[ \t].*$/, "");
    if (version != "")
        print(version, "\n");
}

function updates_apk_policy_version() {
    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (match(line, /^  [^ \t][^ \t]*:/) == null)
            continue;

        let fields = split(trim(line), /[ \t]+/);
        if (length(fields) == 0)
            return;

        print(str_remove_suffix(as_string(fields[0]), ":"), "\n");
        return;
    }
}

function byedpi_asset_matches(name, arch, ext) {
    return (str_startswith(name, "byedpi_") || str_startswith(name, "byedpi-")) &&
        str_endswith(name, "." + ext) &&
        (str_contains(name, "_" + arch + "." + ext) || str_contains(name, "-" + arch + "." + ext));
}

function release_asset_matches_arch(name, prefix, arch, ext) {
    return (str_startswith(name, prefix + "_") || str_startswith(name, prefix + "-")) &&
        str_endswith(name, "." + ext) &&
        (str_contains(name, "_" + arch + "." + ext) || str_contains(name, "-" + arch + "." + ext));
}

function named_release_select_asset(release_prefix, asset_prefix, asset_ext, arch_candidates) {
    let releases = array_or_empty(read_stdin_json());

    for (let release in releases) {
        if (type(release) != "object")
            continue;
        if (release.draft === true)
            continue;

        let release_name = as_string(release.name || "");
        if (!str_startswith(release_name, release_prefix))
            continue;

        for (let arch in split(as_string(arch_candidates), " ")) {
            if (arch == "")
                continue;

            for (let asset in array_or_empty(release.assets)) {
                if (type(asset) != "object")
                    continue;

                let name = as_string(asset.name || "");
                let url = as_string(asset.browser_download_url || "");
                if (url != "" && release_asset_matches_arch(name, asset_prefix, arch, asset_ext)) {
                    print(arch, "\t", name, "\t", url, "\t",
                        as_string(release.html_url || ""), "\t", as_string(release.tag_name || ""), "\n");
                    return;
                }
            }
        }
    }
}

function select_byedpi_asset_from_release(release, asset_ext, arch_candidates) {
    for (let arch in split(as_string(arch_candidates), " ")) {
        if (arch == "")
            continue;
        for (let asset in array_or_empty(release.assets)) {
            if (type(asset) != "object")
                continue;
            let name = as_string(asset.name || "");
            let url = as_string(asset.browser_download_url || "");
            if (url != "" && byedpi_asset_matches(name, arch, asset_ext)) {
                print(arch, "\t", name, "\t", url, "\t", as_string(release.html_url || ""), "\n");
                return true;
            }
        }
    }

    return false;
}

function byedpi_select_asset(series, asset_ext, arch_candidates) {
    let releases = array_or_empty(read_stdin_json());

    for (let pass = 0; pass < 2; pass++) {
        if (pass == 0 && as_string(series) == "")
            continue;

        for (let release in releases) {
            if (type(release) != "object")
                continue;
            if (release.draft === true || release.prerelease === true)
                continue;
            if (pass == 0) {
                let tag = as_string(release.tag_name || "");
                let name = as_string(release.name || "");
                if (!str_contains(tag, series) && !str_contains(name, series))
                    continue;
            }
            if (select_byedpi_asset_from_release(release, asset_ext, arch_candidates))
                return;
        }
    }
}

function sing_box_extended_release_tag() {
    for (let release in array_or_empty(read_stdin_json())) {
        if (type(release) != "object")
            continue;
        if (release.draft === true || release.prerelease === true)
            continue;
        let tag = as_string(release.tag_name || "");
        let lowered = lc(tag);
        if (tag != "" && !str_contains(lowered, "alpha") && !str_contains(lowered, "beta") && !str_contains(lowered, "rc")) {
            print(tag, "\n");
            return;
        }
    }
}

function duration_to_seconds_value(value) {
    let rest = as_string(value);
    if (rest == "")
        return null;

    let total = 0.0;
    let multipliers = {
        ns: 0.000000001,
        us: 0.000001,
        ms: 0.001,
        s: 1,
        m: 60,
        h: 3600,
        d: 86400
    };

    while (rest != "") {
        let matched = match(rest, /^([0-9]+(\.[0-9]+)?)(ns|us|ms|s|m|h|d)/);
        if (!matched)
            return null;

        let token = as_string(matched[0]);
        let amount = matched[1] * 1;
        let unit = matched[3];
        total = total + amount * multipliers[unit];
        rest = substr(rest, length(token));
    }

    if (total <= 0)
        return null;

    return int(total + 0.5);
}

function duration_to_seconds(value) {
    let seconds = duration_to_seconds_value(value);
    if (seconds == null)
        exit(1);

    print(seconds, "\n");
}

function due_check_cron_schedule(value) {
    let seconds = arg_number(value);

    if (seconds <= 60) {
        print("* * * * *\n");
        return;
    }

    if (seconds % 86400 == 0) {
        print("0 0 * * *\n");
        return;
    }

    if (seconds % 3600 == 0) {
        let hours = seconds / 3600;
        if (hours >= 1 && hours <= 23) {
            if (hours == 1)
                print("0 * * * *\n");
            else
                print("0 */", hours, " * * *\n");
            return;
        }
    }

    if (seconds % 60 == 0) {
        let minutes = seconds / 60;
        if (minutes >= 1 && minutes <= 59) {
            if (minutes == 1)
                print("* * * * *\n");
            else
                print("*/", minutes, " * * * *\n");
            return;
        }
    }

    print("* * * * *\n");
}

function text_first_chars(value, max_chars) {
    value = as_string(value);
    max_chars = int(max_chars || "0", 10) || 0;
    return max_chars > 0 && length(value) > max_chars ? substr(value, 0, max_chars) : value;
}

function file_last_nonblank_line(path, fallback, max_chars) {
    let data = fs.readfile(path);
    let result = "";

    if (data != null) {
        for (let line in split(as_string(data), "\n"))
            if (match(line, /^[[:space:]]*$/) == null)
                result = line;
    }

    if (result == "")
        result = as_string(fallback);

    print(text_first_chars(result, max_chars), "\n");
}

function file_flat_snippet(path, max_chars) {
    let data = fs.readfile(path);
    if (data == null)
        return;

    print(text_first_chars(replace(as_string(data), /\n/g, " "), max_chars), "\n");
}

function file_tail_json_object(path) {
    let data = fs.readfile(path);
    let result = "";

    if (data != null) {
        for (let line in split(as_string(data), "\n")) {
            let start = index(line, "{");
            if (start >= 0)
                result = substr(line, start);
        }
    }

    if (result != "")
        print(result, "\n");
}

function job_running_is(path, expected) {
    let value = read_json_file(path);
    let running = type(value) == "object" && value.running === true;
    return running == arg_bool(expected);
}

function updates_json_response(success, component, action, message, current_version, latest_version, changed, status, release_url) {
    write_json({
        success: arg_bool(success),
        component: as_string(component),
        action: as_string(action),
        message: as_string(message),
        current_version: as_string(current_version),
        latest_version: as_string(latest_version),
        changed: arg_number(changed),
        status: as_string(status),
        release_url: as_string(release_url)
    });
}

function updates_job_json_response(success, job_id, message) {
    write_json({
        success: arg_bool(success),
        job_id: as_string(job_id),
        message: as_string(message)
    });
}

function updates_running_job_state(component, action, pid, started_at) {
    pid = as_string(pid);
    write_json({
        success: true,
        running: true,
        component: as_string(component),
        action: as_string(action),
        message: "Component action is running",
        pid: pid != "" ? pid : null,
        started_at: arg_number(started_at),
        current_version: "",
        latest_version: "",
        changed: 0,
        status: "",
        exit_code: null
    });
}

function updates_set_running_job_pid(path, pid) {
    let value = object_or_empty(read_json_file(path));
    if (value.running === true)
        value.pid = as_string(pid);
    write_json(value);
}

function updates_mark_stale_job_state(path) {
    let value = object_or_empty(read_json_file(path));
    if (value.running === true) {
        value.success = false;
        value.running = false;
        value.message = "Component action job is stale or the worker process exited unexpectedly";
        value.changed = 0;
        value.status = "";
        value.exit_code = null;
    }
    write_json(value);
}

function updates_finish_job_state(path, exit_code, updated_at) {
    let value = read_json_file(path);
    if (value == null)
        exit(1);

    value.running = false;
    value.exit_code = arg_number(exit_code);
    value.updated_at = arg_number(updated_at);
    write_json(value);
}

function updates_fallback_job_state(component, action, message, exit_code, updated_at) {
    write_json({
        success: false,
        running: false,
        component: as_string(component),
        action: as_string(action),
        message: as_string(message),
        current_version: "",
        latest_version: "",
        changed: 0,
        status: "",
        exit_code: arg_number(exit_code),
        updated_at: arg_number(updated_at)
    });
}

let mode = ARGV[0] || "";

if (mode == "file-json-valid")
    exit(file_json_valid(ARGV[1]) ? 0 : 1);
else if (mode == "file-first-line")
    file_first_line(ARGV[1]);
else if (mode == "json-file-field")
    json_file_field(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "object-get-default")
    object_get_default(ARGV[1], ARGV[2]);
else if (mode == "string-remove-suffix")
    string_remove_suffix(ARGV[1], ARGV[2]);
else if (mode == "github-response-ok")
    exit(github_response_ok() ? 0 : 1);
else if (mode == "release-by-tag")
    release_by_tag(ARGV[1]);
else if (mode == "release-asset-name")
    release_asset_name(ARGV[1], ARGV[2]);
else if (mode == "release-asset-url")
    release_asset_url(ARGV[1]);
else if (mode == "release-asset-name-by-suffix")
    release_asset_name_by_suffix(ARGV[1]);
else if (mode == "release-asset-url-by-suffix")
    release_asset_url_by_suffix(ARGV[1]);
else if (mode == "release-metadata-tsv")
    release_metadata_tsv();
else if (mode == "openwrt-release-value")
    openwrt_release_value(ARGV[1], ARGV[2]);
else if (mode == "openwrt-release-series")
    openwrt_release_series(ARGV[1]);
else if (mode == "stdin-contains-ci")
    exit(stdin_contains_ci(ARGV[1]) ? 0 : 1);
else if (mode == "updates-arch-package-version")
    updates_arch_package_version(ARGV[1], ARGV[2]);
else if (mode == "updates-zapret-bundle-version")
    updates_zapret_bundle_version(ARGV[1]);
else if (mode == "updates-zapret2-bundle-version")
    updates_zapret2_bundle_version(ARGV[1]);
else if (mode == "updates-normalize-sing-box-version")
    updates_normalize_sing_box_version(ARGV[1]);
else if (mode == "updates-normalize-zapret-version")
    updates_normalize_zapret_version(ARGV[1]);
else if (mode == "podkop-release-version-valid")
    exit(podkop_release_version_valid(ARGV[1]) ? 0 : 1);
else if (mode == "podkop-release-version-compare")
    exit(podkop_release_version_compare(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "updates-zip-inner-package-path")
    updates_zip_inner_package_path(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "updates-archive-member-path")
    updates_archive_member_path(ARGV[1]);
else if (mode == "updates-opkg-arch-list")
    updates_opkg_arch_list();
else if (mode == "updates-arch-candidates")
    updates_arch_candidates(ARGV[1]);
else if (mode == "string-has-whitespace-field")
    exit(string_has_whitespace_field(ARGV[1]) ? 0 : 1);
else if (mode == "file-whitespace-list")
    file_whitespace_list(ARGV[1]);
else if (mode == "sing-box-extended-arch-suffix")
    sing_box_extended_arch_suffix(ARGV[1], ARGV[2]);
else if (mode == "sing-box-extended-asset-url")
    sing_box_extended_asset_url(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "updates-opkg-package-installed")
    updates_opkg_package_installed(ARGV[1]);
else if (mode == "updates-opkg-package-version")
    updates_opkg_package_version(ARGV[1]);
else if (mode == "updates-apk-manifest-package-version")
    updates_apk_manifest_package_version(ARGV[1]);
else if (mode == "updates-apk-info-package-version")
    updates_apk_info_package_version(ARGV[1]);
else if (mode == "updates-apk-policy-version")
    updates_apk_policy_version();
else if (mode == "named-release-select-asset")
    named_release_select_asset(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "byedpi-select-asset")
    byedpi_select_asset(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "sing-box-extended-release-tag")
    sing_box_extended_release_tag();
else if (mode == "duration-to-seconds")
    duration_to_seconds(ARGV[1]);
else if (mode == "due-check-cron-schedule")
    due_check_cron_schedule(ARGV[1]);
else if (mode == "file-last-nonblank-line")
    file_last_nonblank_line(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "file-flat-snippet")
    file_flat_snippet(ARGV[1], ARGV[2]);
else if (mode == "file-tail-json-object")
    file_tail_json_object(ARGV[1]);
else if (mode == "job-running-is")
    exit(job_running_is(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "updates-json-response")
    updates_json_response(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9]);
else if (mode == "updates-job-json-response")
    updates_job_json_response(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "updates-running-job-state")
    updates_running_job_state(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "updates-set-running-job-pid")
    updates_set_running_job_pid(ARGV[1], ARGV[2]);
else if (mode == "updates-mark-stale-job-state")
    updates_mark_stale_job_state(ARGV[1]);
else if (mode == "updates-finish-job-state")
    updates_finish_job_state(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "updates-fallback-job-state")
    updates_fallback_job_state(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]);
else {
    warn("Usage: updater.uc <operation> ...\n");
    exit(1);
}
