import { validateDomain } from './validateDomain';
import { isValidPort, parseHostPort, unbracketHost } from './hostPort';
import { validateIP } from './validateIp';
import { ValidationResult } from './types';

export function validateDNS(value: string): ValidationResult {
  if (!value) {
    return { valid: false, message: _('DNS server address cannot be empty') };
  }

  const [addressPart, ...pathParts] = value.split('/');
  const parsedHostPort = parseHostPort(addressPart);
  const host = parsedHostPort
    ? parsedHostPort.host
    : unbracketHost(addressPart);
  const domainValue = parsedHostPort
    ? host + (pathParts.length > 0 ? `/${pathParts.join('/')}` : '')
    : value.replace(/:(\d+)(?=\/|$)/, '');

  if (parsedHostPort && !isValidPort(parsedHostPort.port)) {
    return { valid: false, message: _('Invalid DNS server port') };
  }

  if (validateIP(host).valid) {
    return { valid: true, message: _('Valid') };
  }

  if (validateDomain(domainValue).valid) {
    return { valid: true, message: _('Valid') };
  }

  return {
    valid: false,
    message: _(
      'Invalid DNS server format. Examples: 8.8.8.8 or dns.example.com or dns.example.com/nicedns for DoH',
    ),
  };
}
