import { ValidationResult } from './types';
import { isValidPort, parseHostPort } from './hostPort';

export function validateSocksUrl(url: string): ValidationResult {
  try {
    if (!/^socks(4|4a|5):\/\//.test(url)) {
      return {
        valid: false,
        message: _(
          'Invalid SOCKS URL: must start with socks4://, socks4a://, or socks5://',
        ),
      };
    }

    if (!url || /\s/.test(url)) {
      return {
        valid: false,
        message: _('Invalid SOCKS URL: must not contain spaces'),
      };
    }

    const body = url.replace(/^socks(4|4a|5):\/\//, '');
    const [authAndHost] = body.split('#'); // отбрасываем hash, если есть
    const [credentials, hostPortPart] = authAndHost.includes('@')
      ? authAndHost.split('@')
      : [null, authAndHost];

    if (credentials) {
      const [username, _password] = credentials.split(':');
      if (!username) {
        return {
          valid: false,
          message: _('Invalid SOCKS URL: missing username'),
        };
      }
    }

    if (!hostPortPart) {
      return {
        valid: false,
        message: _('Invalid SOCKS URL: missing host and port'),
      };
    }

    const parsedHostPort = parseHostPort(hostPortPart);
    if (!parsedHostPort) {
      return {
        valid: false,
        message: _('Invalid SOCKS URL: invalid host and port'),
      };
    }
    const { host, port } = parsedHostPort;

    if (!host) {
      return {
        valid: false,
        message: _('Invalid SOCKS URL: missing hostname or IP'),
      };
    }

    if (!port) {
      return { valid: false, message: _('Invalid SOCKS URL: missing port') };
    }

    if (!isValidPort(port)) {
      return {
        valid: false,
        message: _('Invalid SOCKS URL: invalid port number'),
      };
    }
  } catch (_e) {
    return { valid: false, message: _('Invalid SOCKS URL: parsing failed') };
  }

  return { valid: true, message: _('Valid') };
}
