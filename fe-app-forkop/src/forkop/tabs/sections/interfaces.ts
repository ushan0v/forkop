import {
  childItemInputValue,
  parentSectionIdForItem,
} from '../../cbi/childItems';
import {
  keepUnavailableSectionChoice,
  validateSectionChoice,
} from '../../cbi/choices';
import { required } from '../../cbi/required';
import {
  configureDnsQueryMode,
  configureDnsServerList,
  dnsServerPrefixes,
} from '../../cbi/dnsServers';
import { SettingsDynamicList } from '../../cbi/dynamicList';
import { showChildItemSettingsModal } from '../../cbi/modal';
import { loadOutgoingDevices, OutgoingDevice } from './outgoingDevices';
import {
  refreshLiveChoiceWidgets,
  validateSectionChildName,
} from './outboundNames';
import { refreshDnsDetourSectionOptionValues } from './references';
import { currentOptionValue, optionMapValue } from './subscriptions/model';
import { E } from '../../../helpers/element';

// LuCI's DeviceSelect shows a device this way, its interfaces in parentheses.
function renderNetworkInterfaceChoice(
  choice: OutgoingDevice,
  device: NetworkDevice | undefined,
) {
  const type = device ? device.getType() : 'ethernet';
  const title = device
    ? device.getI18n()
    : '%s: "%s"'.format(_('Absent Interface'), choice.name);
  const networks = choice.networks.length
    ? ' (%s)'.format(choice.networks.join(', '))
    : '';

  return E([
    E('img', {
      title,
      src: L.resource(
        'icons/%s%s.svg'.format(type, device?.isUp() ? '' : '_disabled'),
      ),
    }),
    E('span', { class: 'hide-open' }, [choice.name]),
    E('span', { class: 'hide-close' }, [title + networks]),
  ]);
}

function renderNetworkInterfaceListItem(
  device: NetworkDevice | null,
  fallbackName: string,
) {
  const name = device ? device.getName() : fallbackName;
  const type = device ? device.getType() : 'ethernet';
  const up = device ? device.isUp() : false;

  return E('span', { class: 'fkp-interface-dynlist-label' }, [
    E('img', {
      title: device ? device.getI18n() : _('Network Interface'),
      src: L.resource('icons/%s%s.svg'.format(type, up ? '' : '_disabled')),
    }),
    E('span', {}, [name]),
  ]);
}

function refreshNetworkInterfaceOptionValues(
  option: CBIOption,
  choices: OutgoingDevice[],
) {
  option.keylist = [];
  option.vallist = [];
  option.interfaceDeviceMap = {};

  (option.devices || []).forEach((device) => {
    option.interfaceDeviceMap![device.getName()] = device;
  });
  choices.forEach((choice) => {
    option.value(
      choice.name,
      renderNetworkInterfaceChoice(
        choice,
        option.interfaceDeviceMap![choice.name],
      ),
    );
  });
}

export const InterfaceSettingsDynamicList = SettingsDynamicList.extend({
  load(section_id: string) {
    return network.getDevices().then(
      L.bind(function (this: CBIOption, devices: NetworkDevice[]) {
        this.devices = devices || [];
        return loadOutgoingDevices(this.devices).then(
          L.bind(function (this: CBIOption, choices: OutgoingDevice[]) {
            refreshNetworkInterfaceOptionValues(this, choices);
            return this.super('load', section_id);
          }, this),
        );
      }, this),
    );
  },

  renderListItemLabel(
    section_id: string,
    value: unknown,
    text?: string | null,
  ) {
    const name = childItemInputValue(
      section_id,
      value,
      'section_interface',
      'name',
    );

    return renderNetworkInterfaceListItem(
      this.interfaceDeviceMap ? this.interfaceDeviceMap[name] : null,
      name || `${text ?? ''}`,
    );
  },
});

function interfaceSettingsKeys() {
  return [
    'display_name',
    'domain_resolver_enabled',
    'domain_resolver_dns_server',
    'domain_resolver_dns_fallback_strategy',
    'domain_resolver_dns_detour_enabled',
    'domain_resolver_dns_detour_section',
  ];
}

// Options hidden behind the Domain Resolver flag mean the same by their absence, so none is seeded.
export function defaultInterfaceSettings(displayName: string = '') {
  return {
    display_name: displayName,
    domain_resolver_enabled: '0',
  };
}

function addInterfaceItemOptions(
  itemSection: CBISection,
  options: Partial<ChildItemDialogContext> = {},
) {
  const parentSectionForItem =
    typeof options.parentSectionId === 'function'
      ? options.parentSectionId
      : parentSectionIdForItem;

  let o = itemSection.option(form.Value, 'display_name', _('Interface name'));
  o.validate = required(function (itemId, value) {
    return validateSectionChildName(
      parentSectionForItem(itemId),
      'interface',
      value,
      typeof options.itemValue === 'function'
        ? `${options.itemValue() || ''}`.trim()
        : '',
    );
  });

  o = itemSection.option(
    form.Flag,
    'domain_resolver_enabled',
    _('Domain Resolver'),
    _('Enable built-in DNS resolver for domains handled by this section'),
  );
  o.default = '0';
  o.rmempty = false;

  const dnsServerOption = itemSection.option(
    form.DynamicList,
    'domain_resolver_dns_server',
    _('DNS Server'),
    _(
      'Several servers give automatic failover. The protocol is set by a prefix: %s',
    ).format(dnsServerPrefixes()),
  );
  // No address is proposed: a default public resolver would be a DNS choice made for the user.
  dnsServerOption.depends('domain_resolver_enabled', '1');
  configureDnsServerList(dnsServerOption, {
    appliesTo: (option, itemId) =>
      currentOptionValue(option, itemId, 'domain_resolver_enabled') === '1',
  });

  const dnsQueryModeOption = itemSection.option(
    form.ListValue,
    'domain_resolver_dns_fallback_strategy',
    _('DNS Query Mode'),
    _(
      'Parallel asks every server at once and is faster. Sequential asks them in turn until the first answer',
    ),
  );
  configureDnsQueryMode(dnsQueryModeOption, 'domain_resolver_dns_server', {
    alsoDependsOn: { domain_resolver_enabled: '1' },
  });

  o = itemSection.option(
    form.Flag,
    'domain_resolver_dns_detour_enabled',
    _('DNS through section'),
    _(
      "Route the resolver's DNS requests through a section instead of this network interface",
    ),
  );
  o.depends('domain_resolver_enabled', '1');
  o.default = '0';
  o.rmempty = false;

  o = itemSection.option(
    form.ListValue,
    'domain_resolver_dns_detour_section',
    _('DNS requests through'),
  );
  o.depends({
    domain_resolver_enabled: '1',
    domain_resolver_dns_detour_enabled: '1',
  });
  o.rmempty = false;
  o.load = function (itemId: string) {
    refreshDnsDetourSectionOptionValues(this, parentSectionForItem(itemId));
    const value = optionMapValue(
      this,
      itemId,
      'domain_resolver_dns_detour_section',
    );
    keepUnavailableSectionChoice(this, value);
    return value;
  };
  o.validate = function (itemId: string, value: unknown) {
    if (
      currentOptionValue(this, itemId, 'domain_resolver_enabled') !== '1' ||
      currentOptionValue(this, itemId, 'domain_resolver_dns_detour_enabled') !==
        '1'
    ) {
      return true;
    }
    return validateSectionChoice(this, value, parentSectionForItem(itemId));
  };
}

export function showInterfaceSettingsModal(
  _section_id: string,
  itemValue: unknown,
  option: CBIOption,
) {
  option.sharedPendingSettingsKey = 'interfaces';
  return showChildItemSettingsModal(_section_id, itemValue, option, {
    typeName: 'section_interface',
    valueOption: 'name',
    keys: interfaceSettingsKeys(),
    defaults: (inputValue: string) => defaultInterfaceSettings(inputValue),
    addOptions: addInterfaceItemOptions,
    title: (name: string) =>
      name
        ? _('Network interface: %s').format(name)
        : _('Network interface settings'),
    afterSave: () => refreshLiveChoiceWidgets(_section_id),
  });
}
