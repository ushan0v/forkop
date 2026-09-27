function sing_box_standard_ports_listening(netstat, dns_address, tproxy_port, tproxy6_address) {
    netstat = netstat == null ? "" : "" + netstat;
    dns_address = dns_address == null ? "127.0.0.42" : "" + dns_address;
    tproxy_port = tproxy_port == null ? "1602" : "" + tproxy_port;
    tproxy6_address = tproxy6_address == null ? "::1" : "" + tproxy6_address;

    let dns_ok = index(netstat, dns_address + ":53") >= 0;
    let tproxy_suffix = ":" + tproxy_port;
    let tproxy4_ok = index(netstat, "0.0.0.0" + tproxy_suffix) >= 0 ||
        index(netstat, "127.0.0.1" + tproxy_suffix) >= 0;
    let tproxy6_ok = index(netstat, tproxy6_address + tproxy_suffix) >= 0 ||
        index(netstat, "[" + tproxy6_address + "]" + tproxy_suffix) >= 0 ||
        index(netstat, "0:0:0:0:0:0:0:1" + tproxy_suffix) >= 0 ||
        index(netstat, ":::" + tproxy_port) >= 0;
    return dns_ok && tproxy4_ok && tproxy6_ok;
}

return { sing_box_standard_ports_listening };
