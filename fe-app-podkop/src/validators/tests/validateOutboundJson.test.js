import { describe, expect, it } from 'vitest';
import { validateOutboundJson } from '../validateOutboundJson';

describe('validateOutboundJson', () => {
  it('accepts a direct outbound with type and tag', () => {
    expect(validateOutboundJson('{"type":"direct","tag":"direct"}').valid).toBe(
      true,
    );
  });

  it('accepts a server outbound with server and numeric server_port', () => {
    const result = validateOutboundJson(
      '{"type":"socks","tag":"proxy","server":"127.0.0.1","server_port":1080}',
    );

    expect(result.valid).toBe(true);
  });

  it('accepts a URLTest outbound with referenced outbounds', () => {
    const result = validateOutboundJson(
      '{"type":"urltest","tag":"auto","outbounds":["proxy-1"],"url":"https://www.gstatic.com/generate_204"}',
    );

    expect(result.valid).toBe(true);
  });

  it('rejects empty input', () => {
    const result = validateOutboundJson('');

    expect(result.valid).toBe(false);
    expect(result.message).toBe('JSON outbound cannot be empty');
  });

  it('rejects arrays', () => {
    const result = validateOutboundJson('[{"type":"direct","tag":"direct"}]');

    expect(result.valid).toBe(false);
    expect(result.message).toBe('JSON outbound must be a JSON object');
  });

  it('requires a non-empty type field', () => {
    const result = validateOutboundJson('{"tag":"proxy"}');

    expect(result.valid).toBe(false);
    expect(result.message).toBe(
      'JSON outbound must contain a non-empty type field',
    );
  });

  it('requires a non-empty tag field', () => {
    const result = validateOutboundJson('{"type":"direct"}');

    expect(result.valid).toBe(false);
    expect(result.message).toBe(
      'JSON outbound must contain a non-empty tag field',
    );
  });

  it('rejects a tag already used by another JSON outbound', () => {
    const result = validateOutboundJson('{"type":"direct","tag":"duplicate"}', [
      'first',
      'duplicate',
    ]);

    expect(result.valid).toBe(false);
    expect(result.message).toBe('Duplicate JSON outbound tag');
  });

  it('requires server fields for common server outbound types', () => {
    const result = validateOutboundJson(
      '{"type":"socks","tag":"proxy","server":"127.0.0.1"}',
    );

    expect(result.valid).toBe(false);
    expect(result.message).toBe(
      'Server outbound must contain a numeric server_port from 1 to 65535',
    );
  });

  it('requires group outbounds for selector-like types', () => {
    const result = validateOutboundJson('{"type":"selector","tag":"select"}');

    expect(result.valid).toBe(false);
    expect(result.message).toBe(
      'Selector and URLTest outbounds must contain a non-empty outbounds array',
    );
  });
});
