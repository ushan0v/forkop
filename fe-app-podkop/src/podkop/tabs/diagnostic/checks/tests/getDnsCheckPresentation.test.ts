import { describe, expect, it } from 'vitest';
import { getDnsCheckPresentation } from '../getDnsCheckPresentation';

const baseDnsResult = {
  dns_type: 'udp' as const,
  dns_server: '77.88.8.8',
  dns_status: 1 as const,
  dns_on_router: 1 as const,
  bootstrap_dns_server: '77.88.8.8',
  bootstrap_dns_status: 1 as const,
  dhcp_config_status: 0 as const,
  dont_touch_dhcp: 0 as const,
};

describe('getDnsCheckPresentation', () => {
  it('keeps manual DHCP mode as a warning instead of a DNS failure', () => {
    expect(
      getDnsCheckPresentation({
        ...baseDnsResult,
        dont_touch_dhcp: 1,
      }),
    ).toMatchObject({
      state: 'warning',
      description: 'Checks passed with manual DHCP',
      dhcpItemState: 'warning',
      dhcpItemKey: 'DHCP is managed manually',
    });
  });

  it('keeps a mismatched managed DHCP config as an error item', () => {
    expect(getDnsCheckPresentation(baseDnsResult)).toMatchObject({
      state: 'warning',
      description: 'Issues detected',
      dhcpItemState: 'error',
      dhcpItemKey: 'DHCP has DNS server',
    });
  });
});
