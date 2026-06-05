import { ValidationResult } from './types';

function decodeBase64Json(value: string): unknown {
  const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized.padEnd(
    normalized.length + ((4 - (normalized.length % 4)) % 4),
    '=',
  );
  const binary = atob(padded);
  const decoded = decodeURIComponent(
    Array.from(binary)
      .map((char) => `%${char.charCodeAt(0).toString(16).padStart(2, '0')}`)
      .join(''),
  );

  return JSON.parse(decoded);
}

export function validateVmessUrl(url: string): ValidationResult {
  try {
    if (!url.startsWith('vmess://')) {
      return {
        valid: false,
        message: 'Invalid VMess URL: must start with vmess://',
      };
    }

    if (/\s/.test(url)) {
      return {
        valid: false,
        message: 'Invalid VMess URL: must not contain spaces',
      };
    }

    const body = url.slice('vmess://'.length);
    const [encoded] = body.split('#');
    if (!encoded) {
      return {
        valid: false,
        message: 'Invalid VMess URL: missing encoded config',
      };
    }

    const config = decodeBase64Json(encoded);
    if (!config || typeof config !== 'object') {
      return { valid: false, message: 'Invalid VMess URL: invalid config' };
    }

    const { add, port, id } = config as Record<string, unknown>;
    if (!add || typeof add !== 'string') {
      return { valid: false, message: 'Invalid VMess URL: missing server' };
    }

    const portNum = Number(port);
    if (!Number.isInteger(portNum) || portNum < 1 || portNum > 65535) {
      return {
        valid: false,
        message: 'Invalid VMess URL: invalid port number',
      };
    }

    if (!id || typeof id !== 'string') {
      return { valid: false, message: 'Invalid VMess URL: missing UUID' };
    }

    return { valid: true, message: _('Valid') };
  } catch (_e) {
    return { valid: false, message: _('Invalid VMess URL: parsing failed') };
  }
}
