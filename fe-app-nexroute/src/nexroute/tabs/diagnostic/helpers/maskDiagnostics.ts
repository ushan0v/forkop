const MASKED_VALUE = 'MASKED';

const SING_BOX_MASKED_KEYS = new Set([
  'auth_key',
  'control_url',
  'exit_node',
  'hostname',
  'listen',
  'listen_port',
  'username',
  'uuid',
  'server',
  'server_name',
  'secret',
  'password',
  'private_key',
  'public_key',
  'short_id',
  'fingerprint',
  'server_port',
  'server_ports',
  'advertise_routes',
  'domain',
  'domain_suffix',
  'domain_keyword',
  'domain_regex',
  'ip_cidr',
  'source_ip_cidr',
]);

const FORKOP_MASK_AFTER_TOKEN = [
  'option proxy_string',
  'option hwid',
  'option subscription_url',
  'list subscription_urls',
  'list urltest_proxy_links',
  'list selector_proxy_links',
  'list server_users',
  'option server_uuid',
  'option server_username',
  'option server_password',
  'option mtproto_secret',
  'option hysteria2_obfs_password',
  'option reality_private_key',
  'option reality_public_key',
  'option reality_short_id',
  'list reality_short_id',
  'option yacd_secret_key',
];

const FORKOP_MASK_AFTER_TOKEN_SPACE = [
  'option outbound_json',
  'list domain',
  'list domain_suffix',
  'list domain_keyword',
  'list domain_regex',
  'list ip_cidr',
  'list source_ip_cidr',
  'list fully_routed_ips',
  'option dns_server',
  'option bootstrap_dns_server',
  'list dns_server',
  'list bootstrap_dns_server',
  'option listen',
  'option listen_port',
  'option public_host',
  'option mtproto_faketls',
  'option mtproto_domain_fronting_ip',
  'option tls_server_name',
  'option reality_handshake_server',
  'option reality_handshake_server_port',
  'option transport_host',
  'list transport_hosts',
  'option tailscale_auth_key',
  'option tailscale_control_url',
  'option tailscale_hostname',
  'list tailscale_advertise_routes',
  'option tailscale_ephemeral',
  'option tailscale_exit_node',
  'option tailscale_exit_node_allow_lan_access',
  'option mixed_proxy_username',
  'option mixed_proxy_password',
  'option ipaddr',
  'option netmask',
  'option gateway',
  'option username',
  'option password',
  'option private_key',
  'option url',
];

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function isSpaceChar(value: string) {
  return value === ' ' || value === '\t' || value === '\r' || value === '\n';
}

function maskAfterToken(line: string, token: string) {
  const position = line.indexOf(token);

  return position < 0
    ? line
    : `${line.slice(0, position)}${token} '${MASKED_VALUE}'`;
}

function maskAfterTokenSpace(line: string, token: string) {
  const position = line.indexOf(token);

  if (position < 0) {
    return line;
  }

  const spacePosition = position + token.length;

  if (
    spacePosition >= line.length ||
    !isSpaceChar(line.slice(spacePosition, spacePosition + 1))
  ) {
    return line;
  }

  return `${line.slice(0, spacePosition + 1)}'${MASKED_VALUE}'`;
}

function maskOptionPath(line: string, token: string) {
  const position = line.indexOf(token);

  if (position < 0) {
    return line;
  }

  const slashOffset = line.slice(position + token.length).indexOf('/');

  if (slashOffset < 0) {
    return line;
  }

  const slash = slashOffset + position + token.length;
  const quoteOffset = line.slice(slash + 1).indexOf("'");

  if (quoteOffset < 0) {
    return line;
  }

  const quote = quoteOffset + slash + 1;

  return `${line.slice(0, slash)}/MASKED'${line.slice(quote + 1)}`;
}

function maskGlobalCheckLine(line: string) {
  let maskedLine = line;

  for (const token of FORKOP_MASK_AFTER_TOKEN) {
    maskedLine = maskAfterToken(maskedLine, token);
  }

  for (const token of FORKOP_MASK_AFTER_TOKEN_SPACE) {
    maskedLine = maskAfterTokenSpace(maskedLine, token);
  }

  maskedLine = maskOptionPath(maskedLine, "option dns_server '");
  maskedLine = maskOptionPath(maskedLine, "list dns_server '");
  return maskedLine;
}

function maskMultilineContinuation(line: string) {
  const leadingSpace = line.match(/^\s*/)?.[0] ?? '';
  const hasClosingQuote = line.includes("'");

  return `${leadingSpace}${MASKED_VALUE}${hasClosingQuote ? "'" : ''}`;
}

export function maskSingBoxConfigValue(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map((item) => maskSingBoxConfigValue(item));
  }

  if (isRecord(value)) {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [
        key,
        SING_BOX_MASKED_KEYS.has(key)
          ? MASKED_VALUE
          : maskSingBoxConfigValue(item),
      ]),
    );
  }

  return value;
}

export function stringifySingBoxConfig(value: unknown) {
  return typeof value === 'string' ? value : JSON.stringify(value, null, 2);
}

export function formatMaskedSingBoxConfig(value: unknown) {
  if (typeof value === 'string') {
    try {
      return JSON.stringify(maskSingBoxConfigValue(JSON.parse(value)), null, 2);
    } catch (_error) {
      return value;
    }
  }

  return JSON.stringify(maskSingBoxConfigValue(value), null, 2);
}

export function maskGlobalCheckText(text: string = '') {
  let inMaskedMultiline = false;

  return `${text}`
    .split('\n')
    .map((line) => {
      if (inMaskedMultiline) {
        if (line.includes("'")) {
          inMaskedMultiline = false;
        }

        return maskMultilineContinuation(line);
      }

      const maskedLine = maskGlobalCheckLine(line);

      if (line.includes('option outbound_json')) {
        const firstQuote = line.indexOf("'");

        if (firstQuote >= 0 && line.slice(firstQuote + 1).indexOf("'") < 0) {
          inMaskedMultiline = true;
        }
      }

      return maskedLine;
    })
    .join('\n');
}
