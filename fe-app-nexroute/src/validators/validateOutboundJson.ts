import { ValidationResult } from './types';

const SERVER_OUTBOUND_TYPES = new Set([
  'vless',
  'vmess',
  'trojan',
  'shadowsocks',
  'socks',
  'http',
  'hysteria2',
  'hysteria',
]);

function invalid(message: string): ValidationResult {
  return { valid: false, message };
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function nonEmptyString(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0;
}

function validateServerPort(value: unknown): boolean {
  return (
    typeof value === 'number' &&
    Number.isInteger(value) &&
    value >= 1 &&
    value <= 65535
  );
}

function validateOutbounds(value: unknown): boolean {
  return (
    Array.isArray(value) &&
    value.length > 0 &&
    value.every((item) => nonEmptyString(item))
  );
}

export function validateOutboundJson(
  value: string,
  usedTags: string[] = [],
): ValidationResult {
  const normalized = `${value || ''}`.trim();

  if (!normalized.length) {
    return invalid(_('JSON outbound cannot be empty'));
  }

  let parsed: unknown;

  try {
    parsed = JSON.parse(normalized);
  } catch {
    return { valid: false, message: _('Invalid JSON format') };
  }

  if (!isPlainObject(parsed)) {
    return invalid(_('JSON outbound must be a JSON object'));
  }

  if (!nonEmptyString(parsed.type)) {
    return invalid(_('JSON outbound must contain a non-empty type field'));
  }

  if (!nonEmptyString(parsed.tag)) {
    return invalid(_('JSON outbound must contain a non-empty tag field'));
  }

  const tag = parsed.tag.trim();
  if (usedTags.some((usedTag) => `${usedTag || ''}`.trim() === tag)) {
    return invalid(_('Duplicate JSON outbound tag'));
  }

  const type = parsed.type.trim().toLowerCase();

  if (
    (type === 'selector' || type === 'urltest') &&
    !validateOutbounds(parsed.outbounds)
  ) {
    return invalid(
      _(
        'Selector and URLTest outbounds must contain a non-empty outbounds array',
      ),
    );
  }

  if (SERVER_OUTBOUND_TYPES.has(type)) {
    if (!nonEmptyString(parsed.server)) {
      return invalid(
        _('Server outbound must contain a non-empty server field'),
      );
    }

    if (!validateServerPort(parsed.server_port)) {
      return invalid(
        _('Server outbound must contain a numeric server_port from 1 to 65535'),
      );
    }
  } else if (
    parsed.server_port !== undefined &&
    !validateServerPort(parsed.server_port)
  ) {
    return invalid(_('server_port must be a number from 1 to 65535'));
  }

  if (parsed.outbounds !== undefined && !validateOutbounds(parsed.outbounds)) {
    return invalid(_('outbounds must be a non-empty array of strings'));
  }

  if (parsed.detour !== undefined && !nonEmptyString(parsed.detour)) {
    return invalid(_('detour must be a non-empty string'));
  }

  return { valid: true, message: _('Valid') };
}
