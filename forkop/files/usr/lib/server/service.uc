let fs = require("fs");
let common = require("core.common");
let core_ip = require("core.ip");
let exec = require("core.exec");
let uci = require("core.uci");
let servers = require("singbox.servers");
let singbox_constants = require("singbox.constants");

const CONFIG_NAME = "forkop";

let paths = {
    firewall_include: "/usr/share/nftables.d/chain-pre/input/forkop-servers.nft",
    firewall_init: "/etc/init.d/firewall"
};

// Issued once, for a hundred years: clients pin or trust a self-signed certificate, and a
// reissued one would break every link and profile handed out.
const CERTIFICATE_MONTHS = 1200;
const FIREWALL_COMMENT = singbox_constants.SERVER_FIREWALL_COMMENT;

let changed = false;

function get(name, key, fallback) {
    let value = uci.get(CONFIG_NAME + "." + name + "." + key);
    return value == "" ? (fallback ?? "") : value;
}

function label(name) {
    return get(name, "label", name);
}

function set_if_empty(name, key, value) {
    if (value != "" && get(name, key) == "" && uci.set(CONFIG_NAME + "." + name + "." + key, value))
        changed = true;
}

function set_value(name, key, value) {
    if (value != "" && get(name, key) != value && uci.set(CONFIG_NAME + "." + name + "." + key, value))
        changed = true;
}

function get_list(name, key) {
    let value = (uci.get_all(CONFIG_NAME, name) ?? {})[key];
    return type(value) == "array" ? value : value == null || value == "" ? [] : [ "" + value ];
}

function set_list(name, key, values) {
    if (join(" ", get_list(name, key)) == join(" ", values))
        return;
    if (length(values) == 0 ? uci.delete(CONFIG_NAME + "." + name + "." + key) : uci.set(CONFIG_NAME + "." + name + "." + key, values))
        changed = true;
}

function section_names(type_name) {
    return uci.sections(CONFIG_NAME, type_name);
}

function file_name(value) {
    return replace(common.as_string(value), /[^A-Za-z0-9_.-]/g, "_");
}

function executable(path) {
    return ((fs.stat(path)?.mode ?? 0) & 0111) != 0;
}

function pem_block(data, label) {
    let begin = "-----BEGIN " + label + "-----";
    let end = "-----END " + label + "-----";
    let lines = null;
    for (let line in split(common.as_string(data), "\n")) {
        line = rtrim(line, "\r");
        if (lines == null && line != begin)
            continue;
        lines ??= [];
        push(lines, line);
        if (line == end)
            return join("\n", lines);
    }
    return "";
}

function pem_sha256(text) {
    let pem = pem_block(text, "CERTIFICATE");
    let der = pem == "" ? null : b64dec(replace(replace(pem, /-----[A-Z ]+-----/g, ""), /[\r\n\t ]/g, ""));
    if (der == null || der == "")
        return "";

    let now = clock();
    let temporary = sprintf("/tmp/forkop-certificate.%d.%d.der", now[0], now[1]);
    if (!common.write_file(temporary, der))
        return "";
    let output = exec.output([ "sha256sum", temporary ]);
    fs.unlink(temporary);
    let fingerprint = split(trim(output ?? ""), " ")[0];
    return match(fingerprint, /^[0-9a-f]{64}$/) ? fingerprint : "";
}

function keypair(subject) {
    let output = exec.output([ "sing-box", "generate", "tls-keypair", subject, "--months", "" + CERTIFICATE_MONTHS ]);
    let key = pem_block(output, "PRIVATE KEY");
    let certificate = pem_block(output, "CERTIFICATE");
    return key == "" || certificate == "" ? null : { key, certificate };
}

// sing-box refuses a name that is not ASCII, and clients check an address only against an IP
// entry, which it never writes.
function certificate_subject(name) {
    for (let value in [ get(name, "tls_server_name"), get(name, "public_host"), get(name, "label") ]) {
        value = trim(value);
        if (match(value, /^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$/) && !core_ip.valid_ip(value))
            return value;
    }
    return name;
}

// Its fingerprint is what a Hysteria2 link pins.
function prepare_self_signed_certificate(name, protocol) {
    let section = uci.get_all(CONFIG_NAME, name) ?? {};
    if (servers.effective_security(section, protocol) != "tls" || servers.certificate_source(section, protocol) != "self_signed")
        return;

    if (get(name, "tls_self_signed_certificate") == "" || get(name, "tls_self_signed_key") == "") {
        let pair = keypair(certificate_subject(name));
        if (pair == null)
            die("Failed to issue a TLS certificate for server '" + label(name) + "'");
        set_value(name, "tls_self_signed_certificate", pair.certificate);
        set_value(name, "tls_self_signed_key", pair.key);
        exec.log("info", "Issued a self-signed TLS certificate for server '" + label(name) + "'");
    }
    let fingerprint = pem_sha256(get(name, "tls_self_signed_certificate"));
    if (fingerprint == "")
        die("The self-signed TLS certificate of server '" + label(name) + "' cannot be read");
    set_value(name, "tls_self_signed_sha256", fingerprint);
}

function clients_of(name) {
    return filter(section_names("server_client"), (client) => get(client, "server") == name);
}

// ucode's ?. stops a member access on null, never the call after it.
function random_bytes(count) {
    let random = fs.open("/dev/urandom", "r");
    if (random == null)
        return null;
    let bytes = random.read(count);
    random.close();
    return length(bytes ?? "") == count ? bytes : null;
}

// The key of tls-crypt: 2048 random bits in the text form OpenVPN writes them.
function openvpn_static_key() {
    let bytes = random_bytes(256);
    if (bytes == null)
        return "";
    let lines = [ "-----BEGIN OpenVPN Static key V1-----" ];
    for (let offset = 0; offset < 256; offset += 16) {
        let line = "";
        for (let i = offset; i < offset + 16; i++)
            line += sprintf("%02x", ord(bytes, i));
        push(lines, line);
    }
    push(lines, "-----END OpenVPN Static key V1-----");
    return join("\n", lines);
}

// The server trusts only the fingerprints it issued, each named after the client's section.
function prepare_openvpn(name) {
    if (get(name, "openvpn_certificate") == "" || get(name, "openvpn_key") == "") {
        let pair = keypair(file_name(name));
        if (pair == null)
            die("Failed to issue the OpenVPN certificate of server '" + label(name) + "'");
        set_value(name, "openvpn_certificate", pair.certificate);
        set_value(name, "openvpn_key", pair.key);
        exec.log("info", "Issued the OpenVPN certificate of server '" + label(name) + "'");
    }
    if (get(name, "openvpn_tls_crypt_key") == "") {
        let key = openvpn_static_key();
        if (key == "")
            die("Failed to generate the tls-crypt key of server '" + label(name) + "'");
        set_value(name, "openvpn_tls_crypt_key", key);
    }

    for (let client in clients_of(name)) {
        let client_name = get(client, "name", client);
        if (get(client, "openvpn_certificate") == "" || get(client, "openvpn_key") == "") {
            let pair = keypair(file_name(client));
            if (pair == null)
                die("Failed to issue the OpenVPN certificate of client '" + client_name + "' of server '" + label(name) + "'");
            set_value(client, "openvpn_certificate", pair.certificate);
            set_value(client, "openvpn_key", pair.key);
            exec.log("info", "Issued an OpenVPN certificate for client '" + client_name + "' of server '" + label(name) + "'");
        }
        let fingerprint = pem_sha256(get(client, "openvpn_certificate"));
        if (fingerprint == "")
            die("The OpenVPN certificate of client '" + client_name + "' of server '" + label(name) + "' cannot be read");
        set_value(client, "openvpn_certificate_sha256", fingerprint);
    }
}

function wireguard_keypair() {
    let output = exec.output([ "sing-box", "generate", "wg-keypair" ]) ?? "";
    let private_key = match(output, /(^|\n)PrivateKey:[ \t]*([A-Za-z0-9+\/]{43}=)/);
    let public_key = match(output, /(^|\n)PublicKey:[ \t]*([A-Za-z0-9+\/]{43}=)/);
    return private_key == null || public_key == null ? null : { private_key: private_key[2], public_key: public_key[2] };
}

// A WireGuard pre-shared key: 32 random bytes in base64.
function random_key() {
    let bytes = random_bytes(32);
    return bytes == null ? "" : b64enc(bytes);
}

function address_bytes(value) {
    return iptoarr(split(value, "/")[0]);
}

function plus(bytes, offset) {
    let result = [ ...bytes ];
    for (let i = length(result) - 1; i >= 0 && offset > 0; i--) {
        let sum = result[i] + (offset & 0xff);
        offset = (offset >> 8) + (sum >> 8);
        result[i] = sum & 0xff;
    }
    return result;
}

// An IPv4 pool keeps its broadcast address out; an IPv6 pool is capped to a sane size.
function tunnel_pools(name) {
    let pools = [];
    for (let value in get_list(name, "tunnel_address")) {
        if (!core_ip.valid_ip_cidr(value))
            continue;
        let own = address_bytes(value);
        let bits = int(split(value, "/")[1]);
        let host_bits = length(own) * 8 - bits;
        push(pools, {
            family: length(own) == 4 ? 4 : 6,
            prefix: length(own) == 4 ? 32 : 128,
            network: core_ip.network_bytes(own, bits),
            bits,
            own,
            hosts: length(own) == 4 ? (1 << host_bits) - 2 : (host_bits >= 16 ? 65535 : (1 << host_bits) - 1)
        });
    }
    return pools;
}

function same_bytes(left, right) {
    return join(".", left) == join(".", right);
}

function client_address(pool, current, taken) {
    for (let value in current) {
        let bytes = address_bytes(value);
        if (bytes == null || length(bytes) != length(pool.own) || !same_bytes(core_ip.network_bytes(bytes, pool.bits), pool.network))
            continue;
        let text = arrtoip(bytes);
        if (!same_bytes(bytes, pool.own) && !same_bytes(bytes, pool.network) && !taken[text] &&
            split(value, "/")[1] == "" + pool.prefix &&
            (pool.family == 6 || !same_bytes(bytes, plus(pool.network, pool.hosts + 1))))
            return text;
    }
    for (let i = 1; i <= pool.hosts; i++) {
        let bytes = plus(pool.network, i);
        let text = arrtoip(bytes);
        if (!same_bytes(bytes, pool.own) && !taken[text])
            return text;
    }
    return null;
}

// The server accepts only the keys it issued, so removing a client revokes it.
function prepare_wireguard(name) {
    if (get(name, "wireguard_private_key") == "" || get(name, "wireguard_public_key") == "") {
        let pair = wireguard_keypair();
        if (pair == null)
            die("Failed to issue the WireGuard key of server '" + label(name) + "'");
        set_value(name, "wireguard_private_key", pair.private_key);
        set_value(name, "wireguard_public_key", pair.public_key);
        exec.log("info", "Issued the WireGuard key of server '" + label(name) + "'");
    }

    let pools = tunnel_pools(name);
    let taken = [];
    for (let pool in pools)
        push(taken, {});
    for (let client in clients_of(name)) {
        let client_name = get(client, "name", client);
        if (get(client, "wireguard_private_key") == "" || get(client, "wireguard_public_key") == "") {
            let pair = wireguard_keypair();
            if (pair == null)
                die("Failed to issue the WireGuard key of client '" + client_name + "' of server '" + label(name) + "'");
            set_value(client, "wireguard_private_key", pair.private_key);
            set_value(client, "wireguard_public_key", pair.public_key);
            exec.log("info", "Issued a WireGuard key for client '" + client_name + "' of server '" + label(name) + "'");
        }
        if (get(client, "wireguard_pre_shared_key") == "") {
            let key = random_key();
            if (key == "")
                die("Failed to issue the WireGuard pre-shared key of client '" + client_name + "' of server '" + label(name) + "'");
            set_value(client, "wireguard_pre_shared_key", key);
        }

        let current = get_list(client, "wireguard_address");
        let addresses = [];
        for (let i = 0; i < length(pools); i++) {
            let address = client_address(pools[i], current, taken[i]);
            if (address == null)
                die("Server '" + label(name) + "' has no address left in its tunnel subnet for client '" + client_name + "'");
            taken[i][address] = true;
            push(addresses, address + "/" + pools[i].prefix);
        }
        set_list(client, "wireguard_address", addresses);
    }
}

// Account names go on the wire, so they are kept to what the login protocols carry; a name
// that already fits stays as typed.
function login_safe_name(value, fallback) {
    if (match(value, /^[A-Za-z0-9._-]+$/))
        return value;
    let result = replace(replace(value, /[^A-Za-z0-9._-]/g, "-"), /^-+|-+$/g, "");
    return result == "" ? fallback : result;
}

// Normalised, never invented; a client without credentials is the validator's to report.
function prepare_clients(name, protocol) {
    if (length(servers.CLIENT_FIELDS[protocol] ?? []) == 0)
        return;

    for (let client in clients_of(name)) {
        let client_name = trim(get(client, "name"));
        if (servers.LOGIN_NAME_PROTOCOLS[protocol])
            client_name = login_safe_name(client_name, login_safe_name(label(name), file_name(name)));
        else if (client_name == "")
            client_name = label(name);
        set_value(client, "name", client_name);
    }
}

function prepare_server(name) {
    if (get(name, "enabled", "1") == "0")
        return;
    let protocol = get(name, "protocol", "vless");
    if (servers.CLIENT_FIELDS[protocol] == null)
        die("Server '" + label(name) + "' uses unsupported protocol '" + protocol + "'");

    set_if_empty(name, "protocol", protocol);
    set_if_empty(name, "label", name);
    set_if_empty(name, "enabled", "1");
    set_if_empty(name, "routing_mode", "rules");

    if (protocol == "json_inbound")
        return;
    if (protocol == "tailscale") {
        set_if_empty(name, "tailscale_control_url", "https://controlplane.tailscale.com");
        return;
    }

    // A WireGuard endpoint binds every address and takes no listen address.
    if (protocol == "wireguard" || protocol == "amneziawg") {
        prepare_clients(name, protocol);
        prepare_wireguard(name);
        return;
    }

    set_if_empty(name, "listen", "::");
    if (protocol == "openvpn") {
        set_if_empty(name, "openvpn_network", "udp");
        prepare_clients(name, protocol);
        prepare_openvpn(name);
        return;
    }
    if (protocol == "shadowsocks")
        set_if_empty(name, "shadowsocks_method", "2022-blake3-aes-256-gcm");

    prepare_clients(name, protocol);
    prepare_self_signed_certificate(name, protocol);
}

// An empty list cannot be told from one that could not be read.
function remove_orphaned_clients(names) {
    for (let client in section_names("server_client")) {
        let owner = get(client, "server");
        if (owner != "" && index(names, owner) >= 0)
            continue;
        let client_name = get(client, "name", client);
        if (!uci.delete(CONFIG_NAME + "." + client))
            continue;
        changed = true;
        exec.log("info", "Removed client '" + client_name + "' of a server that no longer exists");
    }
}

// Additions only: what removed servers left goes once the configuration is known good, so a
// refused configuration loses nothing.
function prepare() {
    changed = false;
    for (let name in section_names("server"))
        prepare_server(name);
    if (changed)
        uci.commit(CONFIG_NAME);
}

function remove_orphans() {
    changed = false;
    let names = section_names("server");
    if (length(names) == 0)
        return;
    remove_orphaned_clients(names);
    if (changed)
        uci.commit(CONFIG_NAME);
}

function firewall_ports() {
    let ports = { tcp: [], udp: [] };
    for (let name in section_names("server")) {
        let protocol = get(name, "protocol", "vless");
        if (servers.CLIENT_FIELDS[protocol] == null || protocol == "tailscale" || protocol == "json_inbound")
            continue;
        if (get(name, "enabled", "1") == "0" || get(name, "open_firewall", "1") == "0")
            continue;

        let port = get(name, "listen_port");
        if (!match(port, /^[0-9]+$/) || int(port) < 1 || int(port) > 65535)
            continue;

        for (let proto in servers.listen_transports(uci.get_all(CONFIG_NAME, name) ?? {}))
            if (ports[proto] != null && index(ports[proto], port) < 0)
                push(ports[proto], port);
    }
    return ports;
}

// fw4 prepends this to its input chain and silently drops an include with a single-quoted comment.
function firewall_include_text() {
    let ports = firewall_ports();
    let rules = [];
    for (let proto in [ "tcp", "udp" ])
        if (length(ports[proto]) > 0)
            push(rules, "meta l4proto " + proto + " th dport { " + join(", ", ports[proto]) +
                " } counter accept comment \"" + FIREWALL_COMMENT + "\"");
    if (length(rules) == 0)
        return "";
    return "# Written by Forkop from the VPN server tab. Do not edit: it is rewritten on\n" +
        "# every apply. fw4 prepends this file to its own input chain.\n" + join("\n", rules) + "\n";
}

// fw4 reads the include only while it builds its ruleset.
function firewall_rules_loaded() {
    let chain = exec.output([ "nft", "list", "chain", "inet", "fw4", "input" ]);
    return chain != null && index(chain, FIREWALL_COMMENT) >= 0;
}

function reload_firewall() {
    // A firewall that is not loaded reads the file the next time it starts.
    if (!executable(paths.firewall_init) || !exec.ok([ "nft", "list", "chain", "inet", "fw4", "input" ]))
        return;
    if (!exec.ok([ paths.firewall_init, "reload" ]))
        exec.log("warn", "Failed to reload the firewall; the server ports stay as they were until it is reloaded");
}

// Reloaded whenever the loaded chain disagrees with the file, so a failed or foreign reload
// is corrected too.
function sync_firewall(clear) {
    let wanted = clear ? "" : firewall_include_text();
    let current = fs.readfile(paths.firewall_include) ?? "";
    let file_changed = current != wanted;

    if (file_changed) {
        if (wanted == "")
            fs.unlink(paths.firewall_include);
        else if (!common.write_file_atomic(paths.firewall_include, wanted)) {
            exec.log("warn", "Failed to write the firewall rules of the server ports to " + paths.firewall_include);
            return;
        }
    }

    if (file_changed || (wanted == "") == firewall_rules_loaded())
        reload_firewall();
}

function reality_keypair() {
    let output = exec.output([ "sing-box", "generate", "reality-keypair" ]) ?? "";
    let private_key = match(output, /(^|\n)PrivateKey:[ \t]*([^\r\n]+)/);
    let public_key = match(output, /(^|\n)PublicKey:[ \t]*([^\r\n]+)/);
    if (private_key == null || public_key == null)
        die("Failed to generate Reality key pair");
    return { private_key: private_key[2], public_key: public_key[2] };
}

// X25519 or ML-KEM-768; the core prints the private key the server's setting takes.
function vless_encryption_keypair(kind) {
    if (kind != "x25519" && kind != "mlkem768")
        die("Unknown VLESS Encryption key type '" + kind + "': x25519 or mlkem768 is expected");
    let output = exec.output([ "sing-box", "generate", "vless-encryption-keypair", kind ]) ?? "";
    let private_key = match(output, /(^|\n)PrivateKey:[ \t]*([A-Za-z0-9_-]+)/);
    let public_key = match(output, /(^|\n)PublicKey:[ \t]*([A-Za-z0-9_-]+)/);
    if (private_key == null || public_key == null)
        die("Failed to generate VLESS Encryption key pair");
    return { private_key: private_key[2], public_key: public_key[2] };
}

return { paths, prepare, remove_orphans, sync_firewall, reality_keypair, vless_encryption_keypair };
