import {
  configureDnsQueryMode,
  configureDnsServerList,
  dnsServerPrefixes,
  offerPublicResolvers,
} from '../../../cbi/dnsServers';
import {
  configureDownloadSectionOption,
  configureDownloadViaProxyFlag,
} from '../sectionChoices';
import { createStaticHostsOption } from '../staticHosts';
import { validateRequiredSingBoxDuration } from '../../../../validators/validateSingBoxDuration';
import { required } from '../../../cbi/required';
import { wholeNumberField } from '../../../../validators/fields';

export function addDnsOptions(section: CBISection) {
  const dnsOption = section.option(
    form.DynamicList,
    'dns_server',
    _('DNS Server'),
    _(
      'Several servers give automatic failover. The protocol is set by a prefix: %s',
    ).format(dnsServerPrefixes()),
  );
  dnsOption.default = ['77.88.8.8'];
  offerPublicResolvers(dnsOption);
  configureDnsServerList(dnsOption);

  let o = section.option(
    form.ListValue,
    'dns_main_fallback_strategy',
    _('Main DNS Query Mode'),
    _(
      'Parallel asks every server at once and is faster. Sequential asks them in turn until the first answer',
    ),
  );
  configureDnsQueryMode(o, 'dns_server');

  const bootstrapOption = section.option(
    form.DynamicList,
    'bootstrap_dns_server',
    _('Bootstrap DNS Servers'),
    _(
      'Resolve the addresses of the main DNS servers and proxies. Several servers give automatic failover. The protocol is set by a prefix: %s',
    ).format(dnsServerPrefixes()),
  );
  bootstrapOption.default = ['77.88.8.8'];
  offerPublicResolvers(bootstrapOption, { bootstrap: true });
  configureDnsServerList(bootstrapOption, { ipOnly: true });

  o = section.option(
    form.ListValue,
    'dns_bootstrap_fallback_strategy',
    _('Bootstrap DNS Query Mode'),
    _(
      'Parallel asks every server at once and is faster. Sequential asks them in turn until the first answer',
    ),
  );
  configureDnsQueryMode(o, 'bootstrap_dns_server');

  o = section.option(
    form.Value,
    'dns_rewrite_ttl',
    _('DNS Rewrite TTL'),
    _('How long DNS records are cached, in seconds'),
  );
  o.default = '60';
  o.validate = required(wholeNumberField(0));

  o = section.option(
    form.ListValue,
    'dns_strategy',
    _('DNS Strategy'),
    _('Preferred IP address type for domains'),
  );
  o.value('prefer_ipv4', _('Prefer IPv4'));
  o.value('ipv4_only', _('IPv4 only'));
  o.value('prefer_ipv6', _('Prefer IPv6'));
  o.value('ipv6_only', _('IPv6 only'));
  o.default = 'prefer_ipv4';
  o.rmempty = false;

  o = section.option(
    form.Flag,
    'dns_detour_enabled',
    _('DNS through section'),
    _('Route main DNS requests through a section'),
  );
  configureDownloadViaProxyFlag(o, 'dns_detour_section');

  o = section.option(
    form.ListValue,
    'dns_detour_section',
    _('DNS requests through'),
  );
  o.depends('dns_detour_enabled', '1');
  configureDownloadSectionOption(o, 'dns_detour_section');

  createStaticHostsOption(section);

  o = section.option(
    form.Flag,
    'intercept_client_dns',
    _('Intercept client DNS'),
    _(
      'Redirect client TCP and UDP DNS on port 53 to Forkop. Disable to let your own resolver receive the original client addresses.',
    ),
  );
  o.default = '1';
  o.rmempty = false;

  o = section.option(
    form.Value,
    'dns_timeout',
    _('DNS timeout'),
    _('Maximum time to wait for a DNS response'),
  );
  o.default = '10s';
  o.validate = (_sectionId: string, value: unknown) =>
    validateRequiredSingBoxDuration(value);

  o = section.option(
    form.ListValue,
    'unmatched_dns_mode',
    _('DNS outside the rules'),
    _('Who resolves domains no rule matched'),
  );
  o.value('forkop', 'Forkop');
  o.value('router', _('Router'));
  o.default = 'forkop';
  o.rmempty = false;
}
