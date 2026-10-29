import { getConfigSections } from './getConfigSections';
import { ClashAPI, Forkop } from '../../types';
import {
  getClashApiProxies,
  getClashApiProxyProviders,
  setClashApiConfigSections,
} from './clashApi';
import { isCopyableProxyLink } from '../../../helpers/isCopyableProxyLink';
import { DEFAULT_LATENCY_TEST_URL } from '../../../constants';

interface IGetDashboardSectionsResponse {
  success: boolean;
  data: Forkop.OutboundGroup[];
  servers: Forkop.DashboardServer[];
  hasRemoteLists: boolean;
}

type ClashProxyEntry = {
  code: string;
  value: ClashAPI.ProxyBase;
};

type FallbackLevelConfig = {
  id: string;
  displayName: string;
  order: number;
  outbounds?: string[];
};

type ItemSettingsValue = string | string[] | FallbackLevelConfig[] | undefined;
type ItemSettings = Record<string, ItemSettingsValue>;

type UrlTestConfig = {
  id: string;
  code: string;
  displayName: string;
  testingUrl?: string;
  expectedStatus?: string;
  checkInterval?: string;
  tolerance?: number;
  idleTimeout?: string;
  interruptExistConnections?: boolean;
};

type FallbackConfig = {
  id: string;
  sectionName: string;
  code: string;
  displayName: string;
  healthCheckUrl: string;
  healthCheckInterval: string;
  healthCheckTimeout: string;
  attemptTimeout: string;
  expectedStatus: string;
  idleTimeout: string;
  interruptExistConnections: boolean;
  levels: FallbackLevelConfig[];
};

type SubscriptionTagConfig = {
  runtimeTag: string;
  displayTag: string;
  outboundCodes: Set<string>;
};

type ChildType =
  | 'subscription_url'
  | 'section_interface'
  | 'connection_link'
  | 'urltest'
  | 'fallback_group'
  | 'fallback_level'
  | 'tunnel'
  | 'tunnel_peer';

const EXPORTABLE_PROVIDER_PROXY_TYPES = new Set([
  'anytls',
  'http',
  'hysteria',
  'hysteria2',
  'mieru',
  'naive',
  'shadowsocks',
  'socks',
  'trojan',
  'trusttunnel',
  'tuic',
  'vless',
  'vmess',
]);

function getDisplayName(section: Forkop.ConfigSection) {
  return section.label || section['.name'];
}

function getListValues(value?: string[] | string) {
  if (!value) {
    return [];
  }

  if (Array.isArray(value)) {
    return value.map((item) => `${item}`.trim()).filter(Boolean);
  }

  return `${value}`
    .split(/\s+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function childSections(
  configSections: Forkop.ConfigSection[],
  type: ChildType,
) {
  return configSections.filter((section) => section['.type'] === type);
}

function ownedChildSections(
  parent: Forkop.ConfigSection,
  children: Forkop.ConfigSection[],
) {
  return children.filter(
    (section): section is Forkop.ConfigSection =>
      section.section === parent['.name'],
  );
}

function childSectionsByOwner(
  children: Forkop.ConfigSection[],
  ownerKey: keyof Forkop.ConfigSection,
  ownerValue: string,
) {
  return children.filter((section) => section[ownerKey] === ownerValue);
}

function compactSettingsMap(settings: Record<string, ItemSettings>) {
  return Object.keys(settings).length ? JSON.stringify(settings) : undefined;
}

function hydrateConfigSections(configSections: Forkop.ConfigSection[]) {
  const subscriptionUrls = childSections(configSections, 'subscription_url');
  const interfaces = childSections(configSections, 'section_interface');
  const urltests = childSections(configSections, 'urltest');
  const fallbackGroups = childSections(configSections, 'fallback_group');
  const fallbackLevels = childSections(configSections, 'fallback_level');
  const tunnels = childSections(configSections, 'tunnel');
  const links = childSections(configSections, 'connection_link');

  return configSections.map((section) => {
    if (section['.type'] !== 'section') {
      return section;
    }

    const next: Forkop.ConfigSection = { ...section };
    const subscriptionUrlItems = ownedChildSections(next, subscriptionUrls);
    const interfaceItems = ownedChildSections(next, interfaces);
    const urltestItems = ownedChildSections(next, urltests);
    const fallbackGroupItems = ownedChildSections(next, fallbackGroups);
    const tunnelItems = ownedChildSections(next, tunnels);
    const linkItems = ownedChildSections(next, links).sort(
      (left, right) => Number(left.order || 0) - Number(right.order || 0),
    );

    if (linkItems.length) {
      next.connection_links = linkItems.map((item) => ({
        name: `${item.name || ''}`,
        uri: `${item.uri || ''}`,
      }));
    }

    // In configuration order, the order of the providers; two may fetch the same address.
    const subscriptions = subscriptionUrlItems
      .filter((item) => item.url)
      .map((item) => ({
        tag: `${item.tag || ''}`,
        show_dashboard_metadata: item.show_dashboard_metadata,
      }));
    if (subscriptions.length) {
      next.subscriptions = subscriptions;
    }

    if (interfaceItems.length) {
      next.interfaces = interfaceItems
        .map((item) => item.name || '')
        .filter(Boolean);
    }

    if (urltestItems.length) {
      const settings: Record<string, ItemSettings> = {};
      next.urltests = urltestItems.map((item) => item['.name']);
      urltestItems.forEach((item) => {
        settings[item['.name']] = {
          display_name: item.name,
          urltest_check_interval: item.check_interval,
          urltest_tolerance: item.tolerance,
          urltest_testing_url: item.testing_url,
          expected_status: item.expected_status,
          idle_timeout: item.idle_timeout,
          interrupt_exist_connections: item.interrupt_exist_connections,
          urltest_server_filter_mode: item.server_filter_mode,
          urltest_include_outbounds: item.include_outbounds,
          urltest_include_regex: item.include_regex,
          urltest_exclude_outbounds: item.exclude_outbounds,
          urltest_exclude_regex: item.exclude_regex,
        };
      });
      next.urltest_settings = compactSettingsMap(settings);
    }

    if (fallbackGroupItems.length) {
      const settings: Record<string, ItemSettings> = {};
      next.fallback_groups = fallbackGroupItems.map((item) => item['.name']);
      fallbackGroupItems.forEach((item) => {
        const groupId = item['.name'];
        const levels = childSectionsByOwner(fallbackLevels, 'group', groupId)
          .map(
            (level, index): FallbackLevelConfig => ({
              id: level['.name'],
              displayName: level.name || level['.name'],
              order: Number.parseInt(level.order || `${index}`, 10) || 0,
            }),
          )
          .sort((left, right) =>
            left.order === right.order
              ? left.id.localeCompare(right.id)
              : left.order - right.order,
          );

        settings[groupId] = {
          name: item.name,
          health_check_url: item.health_check_url,
          health_check_interval: item.health_check_interval,
          health_check_timeout: item.health_check_timeout,
          attempt_timeout: item.attempt_timeout,
          expected_status: item.expected_status,
          idle_timeout: item.idle_timeout,
          interrupt_exist_connections: item.interrupt_exist_connections,
          levels,
        };
      });
      next.fallback_group_settings = compactSettingsMap(settings);
    }

    if (tunnelItems.length) {
      next.tunnels = tunnelItems.map((item) => item['.name']);
    }

    return next;
  });
}

function getManualProxyLinks(section: Forkop.ConfigSection) {
  return section.connection_links || [];
}

function getConnectionInterfaces(section: Forkop.ConfigSection) {
  return getListValues(section.interfaces);
}

function getConnectionTunnels(section: Forkop.ConfigSection) {
  return getListValues(section.tunnels);
}

function getJsonOutbounds(section: Forkop.ConfigSection) {
  return getListValues(section.outbound_jsons);
}

function isConnectionAction(action?: string) {
  return action === 'connection';
}

// A rule set named by a path is read from the router's disk, so only URLs and built-in lists count.
function hasRemoteLists(section: Forkop.ConfigSection) {
  return (
    section['.type'] === 'section' &&
    section.enabled !== '0' &&
    (getListValues(section.community_lists).length > 0 ||
      [
        ...getListValues(section.rule_set),
        ...getListValues(section.rule_set_with_subnets),
      ].some((reference) => !reference.startsWith('/')))
  );
}

function hasSubscriptionSources(section: Forkop.ConfigSection) {
  return getSubscriptionSourceCount(section) > 0;
}

function getSubscriptionSourceCount(section: Forkop.ConfigSection) {
  return (section.subscriptions || []).length;
}

function hasConfiguredFallbackList(section: Forkop.ConfigSection) {
  return getListValues(section.fallback_groups).length > 0;
}

function getUrlTestIds(section: Forkop.ConfigSection) {
  return getListValues(section.urltests);
}

function isUrlTestEnabled(section: Forkop.ConfigSection) {
  return getUrlTestIds(section).length > 0;
}

// The sources the generator counts before it gives a section a selector; groups draw their
// members from these, so they cannot stand in for them.
function shouldUseProxyGroup(section: Forkop.ConfigSection) {
  return (
    getManualProxyLinks(section).length > 0 ||
    hasSubscriptionSources(section) ||
    getConnectionInterfaces(section).length > 0 ||
    getConnectionTunnels(section).length > 0 ||
    getJsonOutbounds(section).length > 0
  );
}

function getSectionProxyConfigType(section: Forkop.ConfigSection) {
  if (hasSubscriptionSources(section)) {
    return 'subscription' as const;
  }

  if (isUrlTestEnabled(section) && shouldUseProxyGroup(section)) {
    return 'urltest' as const;
  }

  if (getManualProxyLinks(section).length > 0) {
    return 'selector' as const;
  }

  if (getConnectionTunnels(section).length > 0) {
    return 'selector' as const;
  }

  if (getJsonOutbounds(section).length > 0) {
    return 'outbound' as const;
  }

  if (getConnectionInterfaces(section).length > 0) {
    return 'interface' as const;
  }

  if (hasConfiguredFallbackList(section)) {
    return 'selector' as const;
  }

  return undefined;
}

function buildManualLinkByCode(
  section: Forkop.ConfigSection,
  selectorCodes: string[],
) {
  const available = new Set(selectorCodes);
  const sectionPrefix = `${getDisplayName(section)}/`;

  return new Map(
    getManualProxyLinks(section).flatMap(({ name, uri }) => {
      const code = `${sectionPrefix}${name}`;
      return available.has(code) && isCopyableProxyLink(uri)
        ? [[code, uri] as const]
        : [];
    }),
  );
}

function canExportProviderProxyLink(
  code: string,
  type: string,
  providerTags: string[],
) {
  return (
    EXPORTABLE_PROVIDER_PROXY_TYPES.has(type.toLowerCase()) &&
    providerTags.some((tag) => code.startsWith(`${tag}/`))
  );
}

function getProxyEntryByCode(proxies: ClashProxyEntry[]) {
  return new Map(proxies.map((proxy) => [proxy.code, proxy]));
}

function uniqueCodes(codes: string[]) {
  return Array.from(new Set(codes.filter(Boolean)));
}

function isUrlTestProxyEntry(entry?: ClashProxyEntry) {
  return entry?.value?.type?.toLowerCase() === 'urltest';
}

function getLatencySortValue(outbound: { latency: number }) {
  const latency = Number(outbound.latency);

  return Number.isFinite(latency) && latency > 0
    ? latency
    : Number.POSITIVE_INFINITY;
}

function sortUrlTestMembers(outbounds: Forkop.UrlTestMember[]) {
  return outbounds
    .map((outbound, index) => ({ outbound, index }))
    .sort((left, right) => {
      if (left.outbound.selected !== right.outbound.selected) {
        return left.outbound.selected ? -1 : 1;
      }

      const latencyDiff =
        getLatencySortValue(left.outbound) -
        getLatencySortValue(right.outbound);

      if (latencyDiff !== 0) {
        return latencyDiff;
      }

      return left.index - right.index;
    })
    .map((item) => item.outbound);
}

function itemSettingsMap(value?: string): Record<string, ItemSettings> {
  if (!value) {
    return {};
  }

  try {
    const parsed = JSON.parse(value) as unknown;

    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return {};
    }

    return Object.fromEntries(
      Object.entries(parsed as Record<string, unknown>).filter(
        ([, item]) => item && typeof item === 'object' && !Array.isArray(item),
      ),
    ) as Record<string, ItemSettings>;
  } catch (_error) {
    return {};
  }
}

function itemSettingString(
  settings: ItemSettings | undefined,
  key: string,
  fallback = '',
) {
  const value = settings?.[key];
  return typeof value === 'string' ? value : fallback;
}

function itemSettingBoolean(
  settings: ItemSettings | undefined,
  key: string,
  fallback: boolean,
) {
  const value = settings?.[key];
  if (value === undefined || value === null || value === '') {
    return fallback;
  }

  return value === '1' || value === 'true';
}

function itemSettingNumber(
  settings: ItemSettings | undefined,
  key: string,
  fallback: number,
) {
  const raw = settings?.[key];
  if (raw === undefined || raw === null || raw === '' || Array.isArray(raw)) {
    return fallback;
  }
  const value = Number(raw);
  return Number.isFinite(value) ? value : fallback;
}

function getChildTag(section: Forkop.ConfigSection, displayName: string) {
  return `${getDisplayName(section)}/${displayName}`;
}

function getUrlTestDisplayName(id: string, settings: ItemSettings | undefined) {
  return itemSettingString(settings, 'display_name', id);
}

// What an unset group option means; config/connections.uc gives the generated configuration the
// same values, and tests/fixtures/page_contract.json holds both.
export const URLTEST_DEFAULTS = {
  testing_url: DEFAULT_LATENCY_TEST_URL,
  expected_status: '*',
  check_interval: '3m',
  tolerance: 50,
  // Not written when unset; this is what sing-box then applies.
  idle_timeout: '30m',
  interrupt_exist_connections: false,
};

export const FALLBACK_DEFAULTS = {
  health_check_url: DEFAULT_LATENCY_TEST_URL,
  health_check_interval: '5m',
  health_check_timeout: '5s',
  attempt_timeout: '5s',
  expected_status: '*',
  idle_timeout: '5m',
  interrupt_exist_connections: false,
};

function getUrlTestConfigs(section: Forkop.ConfigSection): UrlTestConfig[] {
  const settingsMap = itemSettingsMap(section.urltest_settings);

  return getUrlTestIds(section).map((id) => {
    const settings = settingsMap[id] || {};
    const displayName = getUrlTestDisplayName(id, settings);

    return {
      id,
      code: getChildTag(section, displayName),
      displayName,
      testingUrl: itemSettingString(
        settings,
        'urltest_testing_url',
        URLTEST_DEFAULTS.testing_url,
      ),
      expectedStatus: itemSettingString(
        settings,
        'expected_status',
        URLTEST_DEFAULTS.expected_status,
      ),
      checkInterval: itemSettingString(
        settings,
        'urltest_check_interval',
        URLTEST_DEFAULTS.check_interval,
      ),
      tolerance: itemSettingNumber(
        settings,
        'urltest_tolerance',
        URLTEST_DEFAULTS.tolerance,
      ),
      idleTimeout: itemSettingString(
        settings,
        'idle_timeout',
        URLTEST_DEFAULTS.idle_timeout,
      ),
      interruptExistConnections: itemSettingBoolean(
        settings,
        'interrupt_exist_connections',
        URLTEST_DEFAULTS.interrupt_exist_connections,
      ),
    };
  });
}

function fallbackLevelConfigsFromSettings(
  settings: ItemSettings | undefined,
): FallbackLevelConfig[] {
  const value = settings?.levels;

  if (!Array.isArray(value)) {
    return [];
  }

  return value
    .flatMap((item, index) => {
      if (!item || typeof item !== 'object' || Array.isArray(item)) {
        return [];
      }

      const level = item as Partial<FallbackLevelConfig> &
        Record<string, unknown>;
      const id = `${level.id || ''}`.trim();

      if (!id) {
        return [];
      }

      return [
        {
          id,
          displayName: `${level.displayName || id}`,
          order:
            typeof level.order === 'number' && Number.isFinite(level.order)
              ? level.order
              : index,
          outbounds: getListValues(level.outbounds as string[] | string),
        },
      ];
    })
    .sort((left, right) =>
      left.order === right.order
        ? left.id.localeCompare(right.id)
        : left.order - right.order,
    );
}

function getFallbackGroupIds(section: Forkop.ConfigSection) {
  return getListValues(section.fallback_groups);
}

function getFallbackConfigs(section: Forkop.ConfigSection): FallbackConfig[] {
  const settingsMap = itemSettingsMap(section.fallback_group_settings);
  const sectionName = section['.name'];

  return getFallbackGroupIds(section).map((id) => {
    const settings = settingsMap[id] || {};
    const levels = fallbackLevelConfigsFromSettings(settings);
    const displayName = itemSettingString(settings, 'name', id);

    return {
      id,
      sectionName,
      code: getChildTag(section, displayName),
      displayName,
      healthCheckUrl: itemSettingString(
        settings,
        'health_check_url',
        FALLBACK_DEFAULTS.health_check_url,
      ),
      healthCheckInterval: itemSettingString(
        settings,
        'health_check_interval',
        FALLBACK_DEFAULTS.health_check_interval,
      ),
      healthCheckTimeout: itemSettingString(
        settings,
        'health_check_timeout',
        FALLBACK_DEFAULTS.health_check_timeout,
      ),
      attemptTimeout: itemSettingString(
        settings,
        'attempt_timeout',
        FALLBACK_DEFAULTS.attempt_timeout,
      ),
      expectedStatus: itemSettingString(
        settings,
        'expected_status',
        FALLBACK_DEFAULTS.expected_status,
      ),
      idleTimeout: itemSettingString(
        settings,
        'idle_timeout',
        FALLBACK_DEFAULTS.idle_timeout,
      ),
      interruptExistConnections: itemSettingBoolean(
        settings,
        'interrupt_exist_connections',
        FALLBACK_DEFAULTS.interrupt_exist_connections,
      ),
      levels,
    };
  });
}

function getOutboundPresentation(
  code: string,
  sectionDisplayName: string,
  subscriptionTags: SubscriptionTagConfig[],
) {
  const sectionPrefix = `${sectionDisplayName}/`;
  const relativeCode = code.startsWith(sectionPrefix)
    ? code.slice(sectionPrefix.length)
    : code;
  const subscription = subscriptionTags.find((item) =>
    item.outboundCodes.has(code),
  );

  return {
    displayName: subscription
      ? code.slice(subscription.runtimeTag.length + 1)
      : relativeCode,
    subscriptionTag: subscription?.displayTag,
  };
}

function getOutboundDisplayType(entry: ClashProxyEntry | undefined) {
  return entry?.value?.type || '';
}

function buildUrlTestInfo({
  config,
  entry,
  proxyByCode,
  sectionDisplayName,
  subscriptionTags,
}: {
  config: UrlTestConfig;
  entry?: ClashProxyEntry;
  proxyByCode: Map<string, ClashProxyEntry>;
  sectionDisplayName: string;
  subscriptionTags: SubscriptionTagConfig[];
}): Forkop.UrlTestInfo {
  const childCodes = uniqueCodes(entry?.value.all || []);
  const selectedCode = entry?.value.now || '';
  const outbounds = sortUrlTestMembers(
    childCodes.flatMap((childCode) => {
      const childEntry = proxyByCode.get(childCode);
      const presentation = getOutboundPresentation(
        childCode,
        sectionDisplayName,
        subscriptionTags,
      );

      return [
        {
          code: childCode,
          ...presentation,
          latency: childEntry?.value?.history?.[0]?.delay || 0,
          type: getOutboundDisplayType(childEntry),
          selected: selectedCode === childCode,
        },
      ];
    }),
  );
  const selectedName =
    outbounds.find((outbound) => outbound.code === selectedCode)?.displayName ||
    selectedCode;

  return {
    code: config.code,
    displayName: config.displayName,
    selectedCode: selectedCode || undefined,
    selectedName: selectedName || undefined,
    url: entry?.value.url || config.testingUrl,
    expectedStatus: config.expectedStatus || '*',
    interval: entry?.value.interval || config.checkInterval,
    tolerance: config.tolerance,
    idleTimeout: entry?.value.idle_timeout || config.idleTimeout || '30m',
    interruptExistConnections: config.interruptExistConnections,
    outbounds,
  };
}

function buildFallbackInfo({
  config,
  entry,
  proxyByCode,
  sectionDisplayName,
  subscriptionTags,
}: {
  config: FallbackConfig;
  entry?: ClashProxyEntry;
  proxyByCode: Map<string, ClashProxyEntry>;
  sectionDisplayName: string;
  subscriptionTags: SubscriptionTagConfig[];
}): Forkop.FallbackInfo {
  const selectedCode = entry?.value.now || '';
  const pinnedCode = entry?.value.fixed || '';
  const configuredLevels = config.levels;
  const runtimeGroups = Array.isArray(entry?.value.groups)
    ? entry.value.groups
    : [];
  // The Clash API names no levels, and both sides order them alike, so names come by position.
  const levels = runtimeGroups
    .map((runtimeGroup, index): FallbackLevelConfig => {
      const metadata = configuredLevels[index];
      return {
        id: metadata?.id || `level-${index + 1}`,
        displayName: metadata?.displayName || `${index + 1}`,
        order:
          typeof metadata?.order === 'number' && Number.isFinite(metadata.order)
            ? metadata.order
            : index,
        outbounds: uniqueCodes(runtimeGroup.outbounds || []),
      };
    })
    .sort((left, right) =>
      left.order === right.order
        ? left.id.localeCompare(right.id)
        : left.order - right.order,
    );
  const outbounds = levels.flatMap((level, levelIndex) => {
    const members = uniqueCodes(level.outbounds || []).map((childCode) => {
      const childEntry = proxyByCode.get(childCode);
      const presentation = getOutboundPresentation(
        childCode,
        sectionDisplayName,
        subscriptionTags,
      );

      return {
        code: childCode,
        ...presentation,
        latency: childEntry?.value?.history?.[0]?.delay || 0,
        type: getOutboundDisplayType(childEntry),
        selected: selectedCode === childCode,
        pinned: pinnedCode === childCode,
        levelIndex,
        levelName: level.displayName,
        levelId: level.id,
      };
    });

    return members;
  });
  const selectedName =
    outbounds.find((outbound) => outbound.code === selectedCode)?.displayName ||
    selectedCode;

  return {
    code: config.code,
    displayName: config.displayName,
    selectedCode: selectedCode || undefined,
    selectedName: selectedName || undefined,
    healthCheckUrl: config.healthCheckUrl,
    healthCheckInterval: config.healthCheckInterval,
    healthCheckTimeout: config.healthCheckTimeout,
    attemptTimeout: config.attemptTimeout,
    expectedStatus: config.expectedStatus,
    idleTimeout: config.idleTimeout,
    interruptExistConnections: config.interruptExistConnections,
    outbounds,
  };
}

function buildProxyGroupOutbounds(
  section: Forkop.ConfigSection,
  proxies: ClashProxyEntry[],
  subscriptionTags: SubscriptionTagConfig[],
) {
  const sectionDisplayName = getDisplayName(section);
  const exportableProviderTags = subscriptionTags.map(
    (item) => item.runtimeTag,
  );
  const proxyByCode = getProxyEntryByCode(proxies);
  const selector = proxyByCode.get(sectionDisplayName);
  const selectorCodes = selector?.value?.all ?? [];
  // Only groups the Clash API reports reach the dashboard.
  const urlTestConfigByCode = new Map(
    getUrlTestConfigs(section).map((config) => [config.code, config]),
  );
  const fallbackConfigByCode = new Map(
    getFallbackConfigs(section).map((config) => [config.code, config]),
  );
  const manualLinkByCode = buildManualLinkByCode(section, selectorCodes);

  const outbounds = uniqueCodes(selectorCodes).flatMap((code) => {
    const item = proxyByCode.get(code);
    const urlTestConfig = urlTestConfigByCode.get(code);
    const fallbackConfig = fallbackConfigByCode.get(code);

    if (!item) {
      return [];
    }

    const link = manualLinkByCode.get(code) || '';
    const canCopyLink =
      isCopyableProxyLink(link) ||
      canExportProviderProxyLink(
        code,
        item.value?.type || '',
        exportableProviderTags,
      );
    const presentation = getOutboundPresentation(
      code,
      sectionDisplayName,
      subscriptionTags,
    );
    const displayName =
      fallbackConfig?.displayName ||
      urlTestConfig?.displayName ||
      presentation.displayName;
    const isRuntimeUrlTest = isUrlTestProxyEntry(item);
    const effectiveUrlTestConfig =
      urlTestConfig ||
      (isRuntimeUrlTest
        ? {
            id: code,
            code,
            displayName,
          }
        : undefined);
    const urlTestInfo = effectiveUrlTestConfig
      ? buildUrlTestInfo({
          config: effectiveUrlTestConfig,
          entry: item,
          proxyByCode,
          sectionDisplayName,
          subscriptionTags,
        })
      : undefined;
    const fallbackInfo = fallbackConfig
      ? buildFallbackInfo({
          config: fallbackConfig,
          entry: item,
          proxyByCode,
          sectionDisplayName,
          subscriptionTags,
        })
      : undefined;
    const groupInfo = urlTestInfo || fallbackInfo;
    const selectedGroupMember = groupInfo?.outbounds.find(
      (member) => member.selected,
    );

    return [
      {
        code,
        displayName,
        subscriptionTag:
          fallbackConfig || urlTestConfig
            ? undefined
            : presentation.subscriptionTag,
        latency:
          selectedGroupMember?.latency || item.value.history?.[0]?.delay || 0,
        type: fallbackConfig
          ? 'Fallback'
          : getOutboundDisplayType(item) || 'URLTest',
        selected: selector?.value?.now === code,
        link,
        canCopyLink,
        urlTestInfo,
        fallbackInfo,
      },
    ];
  });

  return {
    selector,
    outbounds,
  };
}

function isSubscriptionMetadataVisible(
  section: Forkop.ConfigSection,
  sourceIndex: number,
) {
  return (
    (section.subscriptions || [])[sourceIndex - 1]?.show_dashboard_metadata !==
    '0'
  );
}

function getSectionSubscriptionTags(
  section: Forkop.ConfigSection,
  providers: Record<string, ClashAPI.ProxyProvider>,
) {
  const sectionDisplayName = getDisplayName(section);

  return (section.subscriptions || []).map((subscription) => {
    const displayTag = subscription.tag.trim();
    const runtimeTag = `${sectionDisplayName}/${displayTag}`;
    return {
      runtimeTag,
      displayTag,
      outboundCodes: new Set(
        (providers[runtimeTag]?.proxies || []).map((proxy) => proxy.name),
      ),
    };
  });
}

function providerNumber(
  value: ClashAPI.ProxyProvider['subscriptionInfo'],
  lower: 'upload' | 'download' | 'total' | 'expire',
) {
  const upper = `${lower[0].toUpperCase()}${lower.slice(1)}` as
    | 'Upload'
    | 'Download'
    | 'Total'
    | 'Expire';
  const number = Number(value?.[lower] ?? value?.[upper] ?? 0);
  return Number.isFinite(number) ? number : 0;
}

// Go writes up to nine fractional digits where the format every browser parses has three, and a
// provider never downloaded as its zero time, 0001-01-01.
function providerUpdatedAt(provider: ClashAPI.ProxyProvider) {
  const milliseconds = Date.parse(
    (provider.updatedAt || '').replace(/(\.\d{3})\d+/, '$1'),
  );
  return milliseconds > 0 ? milliseconds / 1000 : undefined;
}

function providerSubscriptionMetadata(
  provider: ClashAPI.ProxyProvider,
  sourceIndex: number,
  subscriptionTag: string,
): Forkop.SubscriptionMetadata | undefined {
  const metadata = provider.subscriptionMetadata || {};
  const upload = providerNumber(provider.subscriptionInfo, 'upload');
  const download = providerNumber(provider.subscriptionInfo, 'download');
  const total = providerNumber(provider.subscriptionInfo, 'total');
  const expire = providerNumber(provider.subscriptionInfo, 'expire');
  const used = upload + download;
  const updatedAt = providerUpdatedAt(provider);

  if (
    !upload &&
    !download &&
    !total &&
    !expire &&
    !Object.keys(metadata).length
  ) {
    return undefined;
  }

  return {
    ...metadata,
    sourceIndex,
    sourceSection: provider.name,
    ...(subscriptionTag ? { subscriptionTag } : {}),
    ...(upload || download || total
      ? {
          traffic: {
            upload,
            download,
            used,
            total,
            remaining: total > 0 ? Math.max(total - used, 0) : undefined,
            isUnlimited: total <= 0,
          },
        }
      : {}),
    ...(expire ? { expire } : {}),
    ...(updatedAt ? { updatedAt } : {}),
  };
}

function getSubscriptionMetadata(
  section: Forkop.ConfigSection,
  sourceCount: number,
  subscriptionTags: SubscriptionTagConfig[],
  providers: Record<string, ClashAPI.ProxyProvider>,
) {
  const items = subscriptionTags.slice(0, sourceCount).flatMap((tag, index) => {
    const sourceIndex = index + 1;
    const provider = providers[tag.runtimeTag];
    if (
      !provider ||
      (provider.subscriptionInfo === undefined &&
        provider.subscriptionMetadata === undefined)
    ) {
      return [];
    }
    const metadata = providerSubscriptionMetadata(
      provider,
      sourceIndex,
      tag.displayTag,
    );
    return metadata && isSubscriptionMetadataVisible(section, sourceIndex)
      ? [metadata]
      : [];
  });

  return items.length ? items : undefined;
}

// The core is given only enabled servers; it reports an OpenVPN client by its certificate, named
// after the client's section, and a WireGuard client by no user at all, only by its addresses.
function getDashboardServers(
  configSections: Forkop.ConfigSection[],
): Forkop.DashboardServer[] {
  return configSections
    .filter(
      (section) => section['.type'] === 'server' && section.enabled === '1',
    )
    .map((server) => {
      const protocol = server.protocol || '';
      const byAddress = protocol === 'wireguard' || protocol === 'amneziawg';
      const clients = configSections
        .filter(
          (section) =>
            section['.type'] === 'server_client' &&
            section.server === server['.name'],
        )
        .map((client) => {
          const name = client.name?.trim() || client['.name'];
          return {
            sectionName: client['.name'],
            name,
            users: byAddress
              ? []
              : [protocol === 'openvpn' ? client['.name'] : name],
            addresses: byAddress
              ? getListValues(client.wireguard_address)
                  .map((address) => address.split('/')[0].trim())
                  .filter(Boolean)
              : [],
          };
        });

      return {
        sectionName: server['.name'],
        tag: getDisplayName(server),
        protocol,
        port: server.listen_port || '',
        clients,
      };
    });
}

export async function getDashboardSections(): Promise<IGetDashboardSectionsResponse> {
  const configSections = hydrateConfigSections(await getConfigSections());
  setClashApiConfigSections(configSections);
  const hasSubscriptions = configSections.some(hasSubscriptionSources);
  const remoteLists = configSections.some(hasRemoteLists);
  const servers = getDashboardServers(configSections);
  const [clashProxies, clashProviders] = await Promise.all([
    getClashApiProxies(),
    hasSubscriptions
      ? getClashApiProxyProviders()
      : Promise.resolve({
          success: true as const,
          data: { providers: {} },
        }),
  ]);

  if (!clashProxies.success || !clashProxies.data?.proxies) {
    return {
      success: false,
      data: [],
      servers,
      hasRemoteLists: remoteLists,
    };
  }

  const proxies = Object.entries(clashProxies.data.proxies).map(
    ([key, value]) => ({
      code: key,
      value,
    }),
  );
  const providers = clashProviders.success
    ? clashProviders.data?.providers || {}
    : {};
  const activeSections = configSections.filter(
    (section) => section.enabled !== '0' && isConnectionAction(section.action),
  );
  const data = activeSections.map((section) => {
    const displayName = getDisplayName(section);
    const sectionName = section['.name'];
    const sectionAction = section.action;
    const proxyConfigType = getSectionProxyConfigType(section);

    if (isConnectionAction(sectionAction) && shouldUseProxyGroup(section)) {
      const subscriptionSourceCount = getSubscriptionSourceCount(section);
      const subscriptionEnabled = subscriptionSourceCount > 0;
      const subscriptionTags = getSectionSubscriptionTags(section, providers);
      const subscriptionMetadata = subscriptionEnabled
        ? getSubscriptionMetadata(
            section,
            subscriptionSourceCount,
            subscriptionTags,
            providers,
          )
        : undefined;
      const { selector, outbounds } = buildProxyGroupOutbounds(
        section,
        proxies,
        subscriptionTags,
      );

      return {
        withTagSelect: true,
        code: selector?.code || displayName,
        sectionName,
        displayName,
        action: sectionAction,
        proxyConfigType,
        subscriptionSourceCount,
        subscriptionProviderTags: subscriptionTags.map(
          (item) => item.runtimeTag,
        ),
        subscriptionMetadata,
        outbounds,
      };
    }

    return {
      withTagSelect: false,
      code: displayName,
      sectionName,
      displayName,
      action: sectionAction,
      outbounds: [],
    };
  });

  return {
    success: true,
    data,
    servers,
    hasRemoteLists: remoteLists,
  };
}
