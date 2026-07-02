import { ValidationResult } from './types';

function asciiHostname(hostname: string): string | null {
  if (
    !hostname ||
    /[\s@:/]/.test(hostname) ||
    hostname.startsWith('.') ||
    hostname.endsWith('.')
  ) {
    return null;
  }

  try {
    return new URL(`http://${hostname}`).hostname;
  } catch {
    return null;
  }
}

function validAsciiDomain(hostname: string, requireDot = true): boolean {
  if (!hostname || hostname.length > 253) {
    return false;
  }

  const parts = hostname.split('.');

  if (parts.some((part) => !part || part.length > 63)) {
    return false;
  }

  if (
    parts.some(
      (part) => !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(part),
    )
  ) {
    return false;
  }

  if (!requireDot) {
    return true;
  }

  if (parts.length < 2) {
    return false;
  }

  const tld = parts[parts.length - 1];
  return /^(?:[a-z]{2,}|xn--[a-z0-9-]{2,59})$/.test(tld);
}

export function validateDomain(
  domain: string,
  allowDotTLD = false,
): ValidationResult {
  const normalized = `${domain || ''}`.trim();

  if (allowDotTLD) {
    const dotTld = normalized.startsWith('.') ? normalized.slice(1) : '';
    const ascii = asciiHostname(dotTld);
    if (ascii && !ascii.includes('.') && validAsciiDomain(ascii, false)) {
      return { valid: true, message: _('Valid') };
    }
  }

  const slashIndex = normalized.indexOf('/');
  const hostname =
    slashIndex >= 0 ? normalized.slice(0, slashIndex) : normalized;
  const path = slashIndex >= 0 ? normalized.slice(slashIndex) : '';

  if (path && /\s/.test(path)) {
    return { valid: false, message: _('Invalid domain address') };
  }

  const ascii = asciiHostname(hostname);

  if (!ascii || !validAsciiDomain(ascii)) {
    return { valid: false, message: _('Invalid domain address') };
  }

  return { valid: true, message: _('Valid') };
}
