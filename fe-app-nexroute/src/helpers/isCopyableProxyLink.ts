const COPYABLE_PROXY_URI_RE =
  /^(vless|vmess|trojan|ss|ssr|hysteria2|hy2|tuic|socks4|socks4a|socks5):\/\//i;

export function isCopyableProxyLink(link?: string) {
  return COPYABLE_PROXY_URI_RE.test((link || '').trim());
}
