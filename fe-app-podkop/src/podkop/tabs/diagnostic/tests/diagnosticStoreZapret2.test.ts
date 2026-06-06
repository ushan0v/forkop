import { describe, expect, it } from 'vitest';
import { DIAGNOSTICS_CHECKS } from '../checks/contstants';
import { getDiagnosticsChecks } from '../diagnostic.store';

describe('diagnostic store provider checks', () => {
  it('adds Zapret2 as a separate provider check between Zapret and ByeDPI', () => {
    const checks = getDiagnosticsChecks('Pending', {
      includeZapret: true,
      includeZapret2: true,
      includeByedpi: true,
      includeInbounds: false,
    });

    expect(checks.map((check) => check.code)).toEqual([
      DIAGNOSTICS_CHECKS.DNS,
      DIAGNOSTICS_CHECKS.SINGBOX,
      DIAGNOSTICS_CHECKS.NFT,
      DIAGNOSTICS_CHECKS.ZAPRET,
      DIAGNOSTICS_CHECKS.ZAPRET2,
      DIAGNOSTICS_CHECKS.BYEDPI,
      DIAGNOSTICS_CHECKS.OUTBOUNDS,
      DIAGNOSTICS_CHECKS.FAKEIP,
    ]);
  });

  it('keeps Zapret2 hidden when the provider is not available', () => {
    const checks = getDiagnosticsChecks('Pending', {
      includeZapret: true,
      includeZapret2: false,
      includeByedpi: true,
      includeInbounds: false,
    });

    expect(checks.map((check) => check.code)).not.toContain(
      DIAGNOSTICS_CHECKS.ZAPRET2,
    );
  });

  it('keeps Inbounds hidden until enabled inbounds are confirmed', () => {
    const checks = getDiagnosticsChecks('Pending');

    expect(checks.map((check) => check.code)).not.toContain(
      DIAGNOSTICS_CHECKS.INBOUNDS,
    );
  });

  it('shows Inbounds when enabled inbounds are confirmed', () => {
    const checks = getDiagnosticsChecks('Pending', {
      includeInbounds: true,
    });

    expect(checks.map((check) => check.code)).toContain(
      DIAGNOSTICS_CHECKS.INBOUNDS,
    );
  });
});
