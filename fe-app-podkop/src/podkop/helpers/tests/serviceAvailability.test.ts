import { describe, expect, it } from 'vitest';
import { getServiceAvailability } from '../serviceAvailability';

describe('getServiceAvailability', () => {
  it('does not treat an unresolved service status as stopped', () => {
    expect(
      getServiceAvailability({ loading: true, failed: false, running: false }),
    ).toBe('loading');
  });

  it('distinguishes a stopped service from an unavailable status request', () => {
    expect(
      getServiceAvailability({ loading: false, failed: false, running: 0 }),
    ).toBe('stopped');
    expect(
      getServiceAvailability({ loading: false, failed: true, running: 0 }),
    ).toBe('unavailable');
  });

  it('accepts the numeric running flag returned by the backend', () => {
    expect(
      getServiceAvailability({ loading: false, failed: false, running: 1 }),
    ).toBe('running');
  });
});
