import type { Forkop } from '../../../types';
import { getMeta } from '../helpers/getMeta';

type DnsCheckState = 'error' | 'success' | 'warning';

export function getDnsCheckPresentation(data: Forkop.DnsCheckResult) {
  const dhcpManagedManually = Boolean(data.dont_touch_dhcp);
  const dhcpCheckOk = dhcpManagedManually || Boolean(data.dhcp_config_status);

  const allGood =
    Boolean(data.dns_on_router) &&
    dhcpCheckOk &&
    Boolean(data.bootstrap_dns_status) &&
    Boolean(data.dns_status);

  const atLeastOneGood =
    Boolean(data.dns_on_router) ||
    dhcpCheckOk ||
    Boolean(data.bootstrap_dns_status) ||
    Boolean(data.dns_status);

  const meta = getMeta({ atLeastOneGood, allGood });
  const state: DnsCheckState =
    dhcpManagedManually && meta.state === 'success' ? 'warning' : meta.state;
  const description =
    dhcpManagedManually && meta.state === 'success'
      ? _('Checks passed with manual DHCP')
      : meta.description;

  const dhcpItemState: DnsCheckState = dhcpManagedManually
    ? 'warning'
    : data.dhcp_config_status
      ? 'success'
      : 'error';
  const dhcpItemKey = dhcpManagedManually
    ? _('DHCP is managed manually')
    : _('DHCP has DNS server');

  return {
    state,
    description,
    dhcpItemState,
    dhcpItemKey,
  };
}
