import { ValidationResult } from './types';
import { isValidHost, isValidPort } from './hostPort';

export function validateUrl(
  url: string,
  protocols = ['http:', 'https:'],
): ValidationResult {
  if (!url.length) {
    return { valid: false, message: _('Invalid URL format') };
  }

  const hasValidProtocol = protocols.some((p) => url.indexOf(p + '//') === 0);

  if (!hasValidProtocol)
    return {
      valid: false,
      message:
        _('URL must use one of the following protocols:') +
        ' ' +
        protocols.join(', '),
    };

  try {
    const parsed = new URL(url);
    const host = parsed.hostname.startsWith('[')
      ? parsed.hostname.slice(1, -1)
      : parsed.hostname;
    if (
      (isValidHost(host) || host === 'localhost') &&
      (!parsed.port || isValidPort(parsed.port))
    ) {
      return { valid: true, message: _('Valid') };
    }
  } catch (_e) {
    return { valid: false, message: _('Invalid URL format') };
  }

  return { valid: false, message: _('Invalid URL format') };
}
