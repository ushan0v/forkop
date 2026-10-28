import { renderChildItemLabel } from '../../cbi/listItems';
import { FORKOP_UCI_PACKAGE, RESERVED_RUNTIME_TAGS } from '../../../constants';
import { validateOutboundJson } from '../../../validators/validateOutboundJson';
import { message } from '../../../validators/messages';
import {
  childItemInputValue,
  isExistingChildItem,
  nextSectionId,
  orderChildItemsByPosition,
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
import {
  GRID_KIND_COLUMN_WIDTH,
  GRID_SWITCH_COLUMN_WIDTH,
} from '../../cbi/grid';
import {
  ButtonAddSettingsDynamicList,
  SettingsDynamicList,
} from '../../cbi/dynamicList';
import {
  getRuleActionDisplayMarkup,
  getRuleActionDisplayValue,
  getRuleConfiguredAction,
  getRuleResolvedAction,
  populateActionOptionValues,
} from './actions';
import {
  DESTINATION_CONDITION_PLACEHOLDER,
  DOMAIN_CONDITION_PLACEHOLDER,
  addDestinationField,
  addDynamicConditionField,
  addLocalDeviceSubnetDynamicField,
  analyzeDestinationText,
  analyzeDnsDestinationText,
  makeDeviceOptionsExclusive,
  validatePortCondition,
} from './conditions';
import { RULE_SET_ITEM_SETTINGS_KEY } from './constants';
import { connectionUriDescription } from './coreSupport';
import {
  fallbackGroupChildDefaults,
  removeFallbackLevels,
  showFallbackGroupSettingsModal,
  validateFallbackGroupItemsBeforeSave,
} from './fallback';
import {
  InterfaceSettingsDynamicList,
  defaultInterfaceSettings,
  showInterfaceSettingsModal,
} from './interfaces';
import {
  connectionLinkListItemLabel,
  nextLinkName,
  showConnectionLinkSettingsModal,
  validateConnectionLink,
} from './links';
import {
  outboundJsonDisplayTag,
  outboundJsonListItemLabel,
  showOutboundJsonSettingsModal,
  validateOutboundJsonItemsBeforeSave,
} from './outboundJson';
import {
  outboundNameSourceOptions,
  refreshLiveChoiceWidgets,
} from './outboundNames';
import {
  dependsOnRoutingAction,
  dependsOnRuleConditions,
  refreshDnsDetourSectionOptionValues,
} from './references';
import {
  getBuiltInRulesetReferences,
  getCustomRulesetReferences,
  loadRulesetValues,
  refuseHeldBuiltinLists,
  showRuleSetSettingsModal,
  validateCustomRulesetReference,
  writeBuiltInRulesetReferences,
  writeCustomRulesetReferences,
  writeDnsRulesetReferences,
} from './ruleSets';
import {
  cleanupRemoteSubscriptionUrlSettings,
  defaultSubscriptionHeaderLines,
  defaultSubscriptionUrlSettings,
  isRemoteSubscriptionSource,
  nextSubscriptionTag,
  subscriptionListItemLabel,
  validateSubscriptionUrlEntry,
} from './subscriptions/model';
import { showSubscriptionUrlSettingsModal } from './subscriptions/options';
import {
  canAddTunnel,
  showTunnelSettingsModal,
  tunnelKindsDescription,
} from './tunnels/dialog';
import { normalizeDynamicListItems } from '../../cbi/listValues';
import { removeTunnelPeers, tunnelListItemLabel } from './tunnels/model';
import {
  validateTunnelItem,
  validateTunnelItemsBeforeSave,
} from './tunnels/validate';
import {
  showUrlTestSettingsModal,
  urlTestChildDefaults,
  validateUrlTestItemsBeforeSave,
} from './urltest';

export function createSectionContent(section: CBISection) {
  let o: CBIOption;

  section.tab('settings', _('Route'));
  section.tab('conditions', _('Conditions'));

  o = section.taboption('settings', form.Flag, 'enabled', _('Enable'));
  o.default = '1';
  o.rmempty = false;
  o.editable = true;
  o.width = GRID_SWITCH_COLUMN_WIDTH;

  o = section.taboption(
    'settings',
    form.DummyValue,
    '_action_display',
    _('Action'),
  );
  o.modalonly = false;
  o.rawhtml = true;
  o.cfgvalue = function (section_id: string) {
    return getRuleActionDisplayMarkup(section_id);
  };
  o.textvalue = function (section_id: string) {
    return getRuleActionDisplayValue(section_id);
  };
  o.width = GRID_KIND_COLUMN_WIDTH;

  o = section.taboption('settings', form.Value, 'label', _('Section name'));
  o.modalonly = true;
  o.load = function (section_id: string) {
    return uci.get(FORKOP_UCI_PACKAGE, section_id, 'label') || section_id;
  };
  o.validate = required(function (section_id, value) {
    const normalized = value.trim();
    if (normalized.includes('/')) return message.slashInName();
    if (RESERVED_RUNTIME_TAGS.has(normalized)) return message.reservedName();
    return [
      ...(uci.sections(FORKOP_UCI_PACKAGE, 'section') || []),
      ...(uci.sections(FORKOP_UCI_PACKAGE, 'server') || []),
    ].some(
      (item) =>
        item['.name'] !== section_id &&
        `${item.label || item['.name'] || ''}`.trim() === normalized,
    )
      ? message.nameTaken()
      : true;
  });

  o = section.taboption(
    'settings',
    form.ListValue,
    'action',
    _('Action'),
    _("What to do when this section's conditions match"),
  );
  populateActionOptionValues(o);
  o.default = 'connection';
  o.rmempty = false;
  o.modalonly = true;
  o.cfgvalue = function (section_id: string) {
    return getRuleConfiguredAction(section_id);
  };
  o.load = function (section_id: string) {
    const value = this.cfgvalue(section_id);
    populateActionOptionValues(this, value);
    return value;
  };

  const dnsServerOption = section.taboption(
    'settings',
    form.DynamicList,
    'dns_server',
    _('DNS Server'),
    _(
      'Resolves domains that match the section conditions. Several servers give automatic failover. The protocol is set by a prefix: %s',
    ).format(dnsServerPrefixes()),
  );
  dnsServerOption.depends('action', 'dns');
  dnsServerOption.retain = true;
  dnsServerOption.modalonly = true;
  configureDnsServerList(dnsServerOption);

  const dnsQueryModeOption = section.taboption(
    'settings',
    form.ListValue,
    'dns_fallback_strategy',
    _('DNS Query Mode'),
    _(
      'Parallel asks every server at once and is faster. Sequential asks them in turn until the first answer',
    ),
  );
  dnsQueryModeOption.modalonly = true;
  configureDnsQueryMode(dnsQueryModeOption, 'dns_server', {
    alsoDependsOn: { action: 'dns' },
  });

  o = section.taboption(
    'settings',
    form.Flag,
    'dns_detour_enabled',
    _('DNS through section'),
    _('Route DNS requests through a section'),
  );
  o.depends('action', 'dns');
  o.default = '0';
  o.rmempty = false;
  o.modalonly = true;

  o = section.taboption(
    'settings',
    form.ListValue,
    'dns_detour_section',
    _('DNS requests through'),
  );
  o.depends({ action: 'dns', dns_detour_enabled: '1' });
  o.rmempty = false;
  o.modalonly = true;
  o.load = function (section_id: string) {
    refreshDnsDetourSectionOptionValues(this, section_id);
    const value =
      uci.get(FORKOP_UCI_PACKAGE, section_id, 'dns_detour_section') || '';
    keepUnavailableSectionChoice(this, value);
    return value;
  };
  o.validate = function (section_id: string, value: unknown) {
    return validateSectionChoice(this, value, section_id);
  };

  // Named rather than held in `o`, for the same reason as the subscriptions below.
  const links = section.taboption(
    'settings',
    SettingsDynamicList,
    'connection_link',
    _('Connection URI'),
    connectionUriDescription(),
  );
  links.depends('action', 'connection');
  links.rmempty = true;
  links.modalonly = true;
  links.childType = 'connection_link';
  links.entriesAreSections = true;
  links.childValueOption = 'uri';
  links.createId = () => nextSectionId('connection_link');
  links.childDefaults = {
    name: (value: unknown, sectionId: string) =>
      nextLinkName(sectionId, links, `${value ?? ''}`),
  };
  links.renderItemSettingsModal = showConnectionLinkSettingsModal;
  links.hasItemSettings = function (section_id: string, value: unknown) {
    return isExistingChildItem(
      section_id,
      `${value || ''}`.trim(),
      'connection_link',
    );
  };
  links.renderListItemLabel = function (section_id: string, value: string) {
    return connectionLinkListItemLabel(section_id, value);
  };
  links.validate = function (section_id: string, value: string) {
    return validateConnectionLink(
      childItemInputValue(section_id, value, 'connection_link', 'uri'),
    );
  };
  links.onListChange = refreshLiveChoiceWidgets;
  links.afterMaterializeChildItems = orderChildItemsByPosition;
  links.liveDynamicListNodes = new Map();
  const renderLinks = links.renderWidget;
  links.renderWidget = function (
    section_id: string,
    option_index: string,
    cfgvalue: unknown,
  ) {
    const node = renderLinks.call(
      this,
      section_id,
      option_index,
      cfgvalue,
    ) as HTMLElement;
    this.liveDynamicListNodes!.set(section_id, node);
    return node;
  };
  outboundNameSourceOptions.set('connection_link', links);

  // Named rather than held in `o`, which every option here is assigned to in turn: the callbacks
  // below would otherwise close over the variable and reach the last option declared.
  const subscriptions = section.taboption(
    'settings',
    SettingsDynamicList,
    'subscription_url',
    _('Subscription'),
    _('Subscription URL or local path'),
  );
  subscriptions.depends('action', 'connection');
  subscriptions.rmempty = true;
  subscriptions.modalonly = true;
  subscriptions.childType = 'subscription_url';
  subscriptions.entriesAreSections = true;
  subscriptions.childValueOption = 'url';
  subscriptions.createId = () => nextSectionId('subscription_url');
  subscriptions.childDefaults = Object.assign(
    defaultSubscriptionUrlSettings([], '', false),
    {
      subscription_update_enabled: (value: unknown) =>
        isRemoteSubscriptionSource(value) ? '1' : null,
      subscription_update_interval: (value: unknown) =>
        isRemoteSubscriptionSource(value) ? '1h' : null,
      download_via_proxy_enabled: (value: unknown) =>
        isRemoteSubscriptionSource(value) ? '0' : null,
      header: (value: unknown) =>
        isRemoteSubscriptionSource(value)
          ? defaultSubscriptionHeaderLines.slice()
          : null,
      show_dashboard_metadata: (value: unknown) =>
        isRemoteSubscriptionSource(value) ? '1' : null,
      tag: (_value: unknown, sectionId: string) =>
        nextSubscriptionTag(sectionId, subscriptions),
    },
  );
  subscriptions.renderItemSettingsModal = showSubscriptionUrlSettingsModal;
  subscriptions.hasItemSettings = function (
    section_id: string,
    value: unknown,
  ) {
    return isExistingChildItem(
      section_id,
      `${value || ''}`.trim(),
      'subscription_url',
    );
  };
  subscriptions.afterMaterializeChildItems = function (
    _section_id: string,
    itemIds: string[],
  ) {
    itemIds.forEach((itemId: string) => {
      const source = childItemInputValue(
        _section_id,
        itemId,
        'subscription_url',
        'url',
      );
      if (!isRemoteSubscriptionSource(source)) {
        cleanupRemoteSubscriptionUrlSettings(itemId);
      }
    });
  };
  subscriptions.renderListItemLabel = function (
    section_id: string,
    itemId: string,
  ) {
    return subscriptionListItemLabel(section_id, itemId);
  };
  subscriptions.validate = function (section_id: string, value: string) {
    return validateSubscriptionUrlEntry(
      section_id,
      childItemInputValue(section_id, value, 'subscription_url', 'url'),
    );
  };
  subscriptions.onListChange = refreshLiveChoiceWidgets;
  outboundNameSourceOptions.set('subscription_url', subscriptions);

  o = section.taboption(
    'settings',
    InterfaceSettingsDynamicList,
    'interfaces',
    _('Network Interface'),
    _('An OpenWrt uplink or tunnel interface'),
  );
  o.depends('action', 'connection');
  o.rmempty = true;
  o.modalonly = true;
  o.placeholder = _('Select an interface');
  // The name rule of LuCI's netdevname, said in the page's words.
  o.validate = function (_section_id: string, value: string) {
    return !value || /^[^\s:/%]{1,15}$/.test(value)
      ? true
      : _('Invalid interface name');
  };
  o.childType = 'section_interface';
  o.childValueOption = 'name';
  o.createId = () => nextSectionId('section_interface');
  o.sharedPendingSettingsKey = 'interfaces';
  o.childDefaults = Object.assign(defaultInterfaceSettings(), {
    display_name: (interfaceName: string) => interfaceName,
  });
  o.renderItemSettingsModal = showInterfaceSettingsModal;
  o.hasItemSettings = function (section_id: string, value: unknown) {
    const normalized = `${value || ''}`.trim();
    if (isExistingChildItem(section_id, normalized, 'section_interface')) {
      return true;
    }

    return this.validate(section_id, normalized) === true;
  };
  o.onListChange = refreshLiveChoiceWidgets;
  outboundNameSourceOptions.set('interfaces', o);

  o = section.taboption(
    'settings',
    ButtonAddSettingsDynamicList,
    'tunnels',
    _('Tunnel'),
    tunnelKindsDescription(),
  );
  o.depends('action', 'connection');
  // A core that builds no tunnel leaves the list only to remove saved ones. LuCI deletes the
  // sections of a list it hides on save, so the list hides only once it is empty.
  const dependsOnAction = o.checkDepends;
  o.checkDepends = function (section_id: string) {
    return (
      dependsOnAction.call(this, section_id) &&
      (canAddTunnel() ||
        normalizeDynamicListItems(
          this.formvalue(section_id) ?? this.cfgvalue(section_id),
        ).length > 0)
    );
  };
  o.addable = canAddTunnel;
  o.rmempty = true;
  o.modalonly = true;
  o.addButtonLabel = _('+ Add tunnel');
  o.childType = 'tunnel';
  o.entriesAreSections = true;
  o.ownerOption = 'section';
  o.removeNestedChildItems = removeTunnelPeers;
  o.childValueOption = undefined;
  o.createId = () => nextSectionId('tunnel');
  o.renderItemSettingsModal = showTunnelSettingsModal;
  o.renderListItemLabel = function (section_id: string, value: unknown) {
    return tunnelListItemLabel(section_id, `${value ?? ''}`);
  };
  o.validateItemsOnSave = validateTunnelItemsBeforeSave;
  o.validate = function (section_id: string, value: unknown) {
    const tunnelId = `${value || ''}`.trim();
    return tunnelId ? validateTunnelItem(section_id, tunnelId) : true;
  };
  o.onListChange = refreshLiveChoiceWidgets;
  o.afterMaterializeChildItems = orderChildItemsByPosition;
  outboundNameSourceOptions.set('tunnels', o);

  o = section.taboption(
    'settings',
    ButtonAddSettingsDynamicList,
    'outbound_jsons',
    _('JSON outbound'),
    _('A custom sing-box outbound object'),
  );
  o.depends('action', 'connection');
  o.rmempty = true;
  o.modalonly = true;
  // Kept when the action changes: hand-written outbound objects cannot be typed again.
  o.retain = true;
  o.addButtonLabel = _('+ Add JSON outbound');
  o.renderItemSettingsModal = showOutboundJsonSettingsModal;
  o.renderListItemLabel = function (_section_id: string, value: unknown) {
    return outboundJsonListItemLabel(value);
  };
  o.validateItemsOnSave = validateOutboundJsonItemsBeforeSave;
  o.validate = function (_section_id: string, value: string) {
    if (!value || value.length === 0) {
      return true;
    }

    const validation = validateOutboundJson(value);
    return validation === true
      ? true
      : message.item(outboundJsonDisplayTag(value), validation);
  };
  o.onListChange = refreshLiveChoiceWidgets;
  outboundNameSourceOptions.set('outbound_jsons', o);

  o = section.taboption(
    'settings',
    ButtonAddSettingsDynamicList,
    'urltest',
    _('URLTest'),
    _('Selects the node with the lowest latency'),
  );
  o.depends('action', 'connection');
  o.rmempty = true;
  o.modalonly = true;
  o.addButtonLabel = _('+ Add URLTest');
  o.childType = 'urltest';
  o.childValueOption = 'name';
  o.createId = () => nextSectionId('urltest');
  o.childDefaults = urlTestChildDefaults();
  outboundNameSourceOptions.set('urltest', o);
  o.renderItemSettingsModal = showUrlTestSettingsModal;
  o.validateItemsOnSave = function (section_id: string, values: unknown) {
    return validateUrlTestItemsBeforeSave(section_id, values, this);
  };
  o.renderListItemLabel = function (section_id: string, itemId: string) {
    return renderChildItemLabel(this, section_id, itemId);
  };
  o.onListChange = refreshLiveChoiceWidgets;

  o = section.taboption(
    'settings',
    ButtonAddSettingsDynamicList,
    'fallback_group',
    _('Fallback'),
    _('Selects the first available node by priority'),
  );
  o.depends('action', 'connection');
  o.rmempty = true;
  o.modalonly = true;
  o.addButtonLabel = _('+ Add fallback');
  o.childType = 'fallback_group';
  o.entriesAreSections = true;
  o.removeNestedChildItems = removeFallbackLevels;
  o.childValueOption = 'name';
  o.childDefaults = fallbackGroupChildDefaults();
  outboundNameSourceOptions.set('fallback_group', o);
  o.createId = () => nextSectionId('fallback_group');
  o.renderItemSettingsModal = showFallbackGroupSettingsModal;
  o.validateItemsOnSave = validateFallbackGroupItemsBeforeSave;
  o.renderListItemLabel = function (section_id: string, itemId: string) {
    return renderChildItemLabel(this, section_id, itemId);
  };
  o.onListChange = refreshLiveChoiceWidgets;

  const destinationOption = addDestinationField(
    section,
    'destinations',
    _('Domains and IPs'),
    DESTINATION_CONDITION_PLACEHOLDER,
    analyzeDestinationText,
    _('Match destination domains and addresses'),
  );
  dependsOnRoutingAction(destinationOption);

  const dnsDestinationOption = addDestinationField(
    section,
    '_dns_destinations',
    _('Domains'),
    DOMAIN_CONDITION_PLACEHOLDER,
    analyzeDnsDestinationText,
    _('Match the domains of DNS queries'),
  );
  dnsDestinationOption.depends('action', 'dns');

  const builtInRulesetOption = section.taboption(
    'conditions',
    form.DynamicList,
    'community_lists',
    _('Built-in lists'),
    _('Ready-made lists of domains and subnets from %s').format(
      '<a href="https://github.com/ushan0v/forkop-lists" target="_blank">forkop-lists</a>',
    ),
  );
  builtInRulesetOption.modalonly = true;
  builtInRulesetOption.placeholder = _('Service list');
  builtInRulesetOption.load = function (section_id: string) {
    loadRulesetValues(this);
    return getBuiltInRulesetReferences(section_id);
  };
  builtInRulesetOption.renderWidget = function (
    section_id: string,
    option_index: string,
    cfgvalue: unknown,
  ) {
    const node = form.DynamicList.prototype.renderWidget.call(
      this,
      section_id,
      option_index,
      cfgvalue,
    );
    refuseHeldBuiltinLists(node);
    return node;
  };
  builtInRulesetOption.write = function (section_id: string, values: unknown) {
    writeBuiltInRulesetReferences(section_id, values);
  };
  builtInRulesetOption.remove = function (section_id: string) {
    uci.unset(FORKOP_UCI_PACKAGE, section_id, 'community_lists');
  };

  const dnsRuleSetOption = section.taboption(
    'conditions',
    form.DynamicList,
    '_dns_rule_set',
    _('Rule sets'),
    _('A URL or local path. The format is detected automatically'),
  );
  dnsRuleSetOption.depends('action', 'dns');
  dnsRuleSetOption.modalonly = true;
  // Both rule set fields edit one list and this one shows only for a DNS rule; without retain LuCI
  // would call its remove() under every other action and clear the list and its settings.
  dnsRuleSetOption.retain = true;
  dnsRuleSetOption.load = function (section_id: string) {
    return getCustomRulesetReferences(section_id);
  };
  dnsRuleSetOption.write = function (section_id: string, value: unknown) {
    writeDnsRulesetReferences(section_id, value);
  };
  dnsRuleSetOption.remove = function (section_id: string) {
    writeDnsRulesetReferences(section_id, []);
  };
  dnsRuleSetOption.validate = function (_section_id: string, value: string) {
    return validateCustomRulesetReference(value);
  };

  const ruleSetOption = section.taboption(
    'conditions',
    SettingsDynamicList,
    'rule_set',
    _('Rule sets'),
    _('A URL or local path. The format is detected automatically'),
  );
  dependsOnRoutingAction(ruleSetOption);
  ruleSetOption.modalonly = true;
  ruleSetOption.retain = true;
  ruleSetOption.renderItemSettingsModal = showRuleSetSettingsModal;
  ruleSetOption.hasItemSettings = function (section_id: string) {
    return getRuleResolvedAction(section_id) !== 'dns';
  };
  ruleSetOption.load = function (section_id: string) {
    return getCustomRulesetReferences(section_id);
  };
  ruleSetOption.write = function (section_id: string, value: unknown) {
    writeCustomRulesetReferences(section_id, value);
  };
  ruleSetOption.remove = function (section_id: string) {
    uci.unset(FORKOP_UCI_PACKAGE, section_id, 'rule_set');
    uci.unset(FORKOP_UCI_PACKAGE, section_id, 'rule_set_with_subnets');
    uci.unset(FORKOP_UCI_PACKAGE, section_id, RULE_SET_ITEM_SETTINGS_KEY);
  };
  ruleSetOption.validate = function (_section_id: string, value: string) {
    return validateCustomRulesetReference(value);
  };

  const portsOption = addDynamicConditionField(section, {
    key: 'ports',
    label: _('Ports'),
    description: _(
      "Narrows the section's conditions to these ports. Without conditions, takes all traffic to them",
    ),
    dynamicValidate: validatePortCondition,
  });
  dependsOnRoutingAction(portsOption);

  const sourceIpOption = addLocalDeviceSubnetDynamicField(section, {
    key: 'source_ip_cidr',
    label: _('Only for devices'),
    description: _(
      "The section's other conditions apply only to these devices",
    ),
  });
  dependsOnRuleConditions(sourceIpOption);

  const fullyRoutedOption = addLocalDeviceSubnetDynamicField(section, {
    key: 'fully_routed_ips',
    label: _('All device traffic'),
    description: _('All traffic from the device is forced through the section'),
  });
  dependsOnRoutingAction(fullyRoutedOption);
  fullyRoutedOption.depends('action', 'dns');
  makeDeviceOptionsExclusive(sourceIpOption, fullyRoutedOption);
}
