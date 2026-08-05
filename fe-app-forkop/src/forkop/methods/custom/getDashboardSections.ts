import { getConfigSections } from './getConfigSections';
import { ClashAPI, Forkop } from '../../types';
import {
  canUseDirectClashApi,
  getClashHttpUrl,
  getProxyUrlName,
  isCopyableProxyLink,
} from '../../../helpers';
import { getOutboundTagBySection } from '../../runtimeTags';
import { ForkopShellMethods } from '../shell';

interface IGetDashboardSectionsResponse {
  success: boolean;
  data: Forkop.OutboundGroup[];
}

interface IGetDashboardSectionsOptions {
  includeSubscriptionCopyState?: boolean;
}

type ClashProxyEntry = {
  code: string;
  value: ClashAPI.ProxyBase;
};

type DashboardSectionCache = {
  version?: number;
  section?: string;
  links?: Record<string, string>;
  outboundMetadata?: Forkop.GetOutboundMetadata;
  urltestGroups?: Record<string, UrlTestCacheGroup>;
  priorityGroups?: Record<string, PriorityCacheGroup>;
  subscriptionMetadata?:
    | Forkop.SubscriptionMetadata
    | Forkop.SubscriptionMetadata[];
};

type UrlTestCacheGroup = {
  displayName?: string;
  outbounds?: string[];
  url?: string;
  interval?: string;
  tolerance?: string | number;
  idle_timeout?: string;
  interrupt_exist_connections?: boolean;
};

type PriorityCacheLevel = {
  id?: string;
  displayName?: string;
  order?: number;
  direct?: boolean;
  filter_mode?: string;
  detect_server_country?: string;
  outbounds?: string[];
};

type PriorityCacheGroup = {
  id?: string;
  tag?: string;
  section?: string;
  displayName?: string;
  health_url?: string;
  active_check_interval?: string;
  check_timeout?: string;
  recovery_check_interval?: string;
  pick_fastest?: boolean;
  switch_to_faster_same_priority?: boolean;
  fastest_check_interval?: string;
  interrupt_exist_connections?: boolean;
  pin_dashboard?: boolean;
  outbounds?: string[];
  levels?: PriorityCacheLevel[];
};

type PriorityLevelConfig = {
  id: string;
  displayName: string;
  order: number;
  direct: boolean;
  filterMode: string;
  detectServerCountry: string;
  country: string[];
  serverName: string[];
  regex: string[];
  excludeCountries: string[];
  excludeOutbounds: string[];
  excludeRegex: string[];
  outbounds?: string[];
};

type ItemSettingsValue = string | string[] | PriorityLevelConfig[] | undefined;
type ItemSettings = Record<string, ItemSettingsValue>;

type UrlTestConfig = {
  id: string;
  code: string;
  displayName: string;
  settings: ItemSettings;
  pinDashboard: boolean;
  showDetectedCountries: boolean;
};

type PriorityConfig = {
  id: string;
  code: string;
  displayName: string;
  settings: ItemSettings;
  pinDashboard: boolean;
  healthUrl: string;
  activeCheckInterval: string;
  checkTimeout: string;
  recoveryCheckInterval: string;
  pickFastest: boolean;
  switchToFasterSamePriority: boolean;
  fastestCheckInterval: string;
  interruptExistConnections: boolean;
  showDetectedCountries: boolean;
  levels: PriorityLevelConfig[];
};

type ChildType =
  | 'subscription_url'
  | 'section_interface'
  | 'urltest'
  | 'priority_group'
  | 'priority_level';

const DASHBOARD_SECTION_CACHE_DIR = '/var/run/forkop/section-cache';
const CLASH_API_FETCH_TIMEOUT_MS = 5000;

function getDisplayName(section: Forkop.ConfigSection) {
  return section.label || section['.name'];
}

function getSettingsSection(configSections: Forkop.ConfigSection[]) {
  return configSections.find((section) => section['.type'] === 'settings');
}

function getClashApiSecret(configSections: Forkop.ConfigSection[]) {
  return getSettingsSection(configSections)?.yacd_secret_key || '';
}

function canFetchClashApiDirectly() {
  return canUseDirectClashApi() && typeof fetch === 'function';
}

async function getClashApiProxies(
  configSections: Forkop.ConfigSection[],
): Promise<Forkop.MethodResponse<ClashAPI.Proxies>> {
  if (canFetchClashApiDirectly()) {
    const secret = getClashApiSecret(configSections);
    const controller = new AbortController();
    const timeoutId = setTimeout(
      () => controller.abort(),
      CLASH_API_FETCH_TIMEOUT_MS,
    );

    try {
      const response = await fetch(`${getClashHttpUrl()}/proxies`, {
        headers: secret ? { Authorization: `Bearer ${secret}` } : undefined,
        signal: controller.signal,
      });

      if (response.ok) {
        return {
          success: true,
          data: (await response.json()) as ClashAPI.Proxies,
        };
      }
    } catch (_error) {
      // Fall back to rpcd below for controllers unavailable from the browser.
    } finally {
      clearTimeout(timeoutId);
    }
  }

  return ForkopShellMethods.getClashApiProxies();
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
  const priorityGroups = childSections(configSections, 'priority_group');
  const priorityLevels = childSections(configSections, 'priority_level');

  return configSections.map((section) => {
    if (section['.type'] !== 'section') {
      return section;
    }

    const next: Forkop.ConfigSection = { ...section };
    const subscriptionUrlItems = ownedChildSections(next, subscriptionUrls);
    const interfaceItems = ownedChildSections(next, interfaces);
    const urltestItems = ownedChildSections(next, urltests);
    const priorityGroupItems = ownedChildSections(next, priorityGroups);

    if (subscriptionUrlItems.length) {
      const settings: Record<string, ItemSettings> = {};
      next.subscription_urls = subscriptionUrlItems
        .map((item) => item.url || '')
        .filter(Boolean);
      subscriptionUrlItems.forEach((item) => {
        if (!item.url) {
          return;
        }
        settings[item.url] = {
          subscription_update_enabled: item.subscription_update_enabled,
          subscription_update_interval: item.subscription_update_interval,
          download_via_proxy_enabled: item.download_via_proxy_enabled,
          download_via_proxy_section: item.download_via_proxy_section,
          auto_user_agent: item.auto_user_agent,
          user_agent: item.user_agent,
          auto_hwid: item.auto_hwid,
          hwid: item.hwid,
          custom_device_headers: item.custom_device_headers,
          device_os: item.device_os,
          ver_os: item.ver_os,
          device_model: item.device_model,
          device_locale: item.device_locale,
          app_version: item.app_version,
          accept_language: item.accept_language,
          show_dashboard_metadata: item.show_dashboard_metadata,
          prefix_nodes: item.prefix_nodes,
          node_prefix: item.node_prefix,
          include_urltest_groups: item.include_urltest_groups,
          hide_urltest_group_outbounds: item.hide_urltest_group_outbounds,
          hide_detour_outbounds: item.hide_detour_outbounds,
        };
      });
      next.subscription_url_settings = compactSettingsMap(settings);
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
          display_name: item.name || item.display_name,
          urltest_check_interval: item.check_interval,
          urltest_tolerance: item.tolerance,
          urltest_testing_url: item.testing_url,
          idle_timeout: item.idle_timeout,
          interrupt_exist_connections: item.interrupt_exist_connections,
          pin_dashboard: item.pin_dashboard,
          urltest_filter_mode: item.filter_mode,
          detect_server_country: item.detect_server_country,
          urltest_include_countries: item.include_countries,
          urltest_include_outbounds: item.include_outbounds,
          urltest_include_regex: item.include_regex,
          urltest_exclude_countries: item.exclude_countries,
          urltest_exclude_outbounds: item.exclude_outbounds,
          urltest_exclude_regex: item.exclude_regex,
        };
      });
      next.urltest_settings = compactSettingsMap(settings);
    }

    if (priorityGroupItems.length) {
      const settings: Record<string, ItemSettings> = {};
      next.priority_groups = priorityGroupItems.map((item) => item['.name']);
      priorityGroupItems.forEach((item) => {
        const groupId = item['.name'];
        const levels = childSectionsByOwner(priorityLevels, 'group', groupId)
          .map(
            (level, index): PriorityLevelConfig => ({
              id: level['.name'],
              displayName: level.name || level['.name'],
              order: Number.parseInt(level.order || `${index}`, 10) || 0,
              direct: level.direct === '1',
              filterMode: level.filter_mode || 'include',
              detectServerCountry: level.detect_server_country || 'flag_emoji',
              country: getListValues(level.country),
              serverName: getListValues(level.server_name),
              regex: getListValues(level.regex),
              excludeCountries: getListValues(level.exclude_countries),
              excludeOutbounds: getListValues(level.exclude_outbounds),
              excludeRegex: getListValues(level.exclude_regex),
            }),
          )
          .sort((left, right) =>
            left.order === right.order
              ? left.id.localeCompare(right.id)
              : left.order - right.order,
          );

        settings[groupId] = {
          name: item.name,
          health_url: item.health_url,
          active_check_interval: item.active_check_interval,
          check_timeout: item.check_timeout,
          recovery_check_interval: item.recovery_check_interval,
          pick_fastest: item.pick_fastest,
          switch_to_faster_same_priority: item.switch_to_faster_same_priority,
          fastest_check_interval: item.fastest_check_interval,
          interrupt_exist_connections: item.interrupt_exist_connections,
          pin_dashboard: item.pin_dashboard,
          levels,
        };
      });
      next.priority_group_settings = compactSettingsMap(settings);
    }

    return next;
  });
}

function getManualProxyLinks(section: Forkop.ConfigSection) {
  return getListValues(section.selector_proxy_links);
}

function getConnectionInterfaces(section: Forkop.ConfigSection) {
  const values = getListValues(section.interfaces);
  return values.length ? values : getListValues(section.interface);
}

function getJsonOutbounds(section: Forkop.ConfigSection) {
  const values = getListValues(section.outbound_jsons);
  return values.length ? values : getListValues(section.outbound_json);
}

function isConnectionAction(action?: string) {
  return Boolean(
    action && ['connection', 'proxy', 'outbound', 'vpn'].includes(action),
  );
}

function hasSubscriptionSources(section: Forkop.ConfigSection) {
  return getSubscriptionSourceCount(section) > 0;
}

function getSubscriptionSourceCount(section: Forkop.ConfigSection) {
  return getListValues(section.subscription_urls).length;
}

function shouldSortByLatency(section: Forkop.ConfigSection) {
  return section.sort_by_latency === '1';
}

function hasConfiguredUrlTestList(section: Forkop.ConfigSection) {
  return getListValues(section.urltests).length > 0;
}

function hasConfiguredPriorityList(section: Forkop.ConfigSection) {
  return getListValues(section.priority_groups).length > 0;
}

function getUrlTestIds(section: Forkop.ConfigSection) {
  const values = getListValues(section.urltests);
  return values.length
    ? values
    : section.urltest_enabled === '1'
      ? ['urltest']
      : [];
}

function isUrlTestEnabled(section: Forkop.ConfigSection) {
  return getUrlTestIds(section).length > 0;
}

function shouldUseProxyGroup(section: Forkop.ConfigSection) {
  return (
    getManualProxyLinks(section).length > 0 ||
    hasSubscriptionSources(section) ||
    getConnectionInterfaces(section).length > 0 ||
    getJsonOutbounds(section).length > 0 ||
    isUrlTestEnabled(section) ||
    hasConfiguredPriorityList(section)
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

  if (getJsonOutbounds(section).length > 0) {
    return 'outbound' as const;
  }

  if (getConnectionInterfaces(section).length > 0) {
    return 'interface' as const;
  }

  if (hasConfiguredPriorityList(section)) {
    return 'selector' as const;
  }

  return undefined;
}

function getJsonOutboundDisplayName(section: Forkop.ConfigSection) {
  try {
    const parsedOutbound = JSON.parse(section.outbound_json || '{}');
    return parsedOutbound?.tag ? decodeURIComponent(parsedOutbound.tag) : '';
  } catch (_error) {
    return '';
  }
}

function buildManualLinkByCode(section: Forkop.ConfigSection) {
  const sectionName = section['.name'];

  return new Map(
    getManualProxyLinks(section).map((link, index) => [
      getOutboundTagBySection(`${sectionName}-${index + 1}`),
      link,
    ]),
  );
}

function getProxyEntryByCode(proxies: ClashProxyEntry[]) {
  return new Map(proxies.map((proxy) => [proxy.code, proxy]));
}

function uniqueCodes(codes: string[]) {
  return Array.from(new Set(codes.filter(Boolean)));
}

function isSelectorOutbound(outbound: Forkop.Outbound) {
  return outbound.type?.toLowerCase() === 'selector';
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

function sortOutboundsForDashboard(
  outbounds: Forkop.Outbound[],
  options: {
    pinnedCode?: string;
    pinnedCodes?: string[];
    sortByLatency?: boolean;
  } = {},
) {
  const pinnedCodes = [
    ...(options.pinnedCode ? [options.pinnedCode] : []),
    ...(options.pinnedCodes || []),
  ].filter(Boolean);
  const pinnedRank = new Map(
    pinnedCodes.map((code, index) => [code, index] as const),
  );
  const sortByLatency = options.sortByLatency === true;

  return outbounds
    .map((outbound, index) => ({ outbound, index }))
    .sort((left, right) => {
      const leftPinned = pinnedRank.has(left.outbound.code);
      const rightPinned = pinnedRank.has(right.outbound.code);

      if (leftPinned !== rightPinned) {
        return leftPinned ? -1 : 1;
      }

      if (leftPinned && rightPinned) {
        const rankDiff =
          (pinnedRank.get(left.outbound.code) ?? 0) -
          (pinnedRank.get(right.outbound.code) ?? 0);

        if (rankDiff !== 0) {
          return rankDiff;
        }
      }

      if (sortByLatency) {
        const latencyDiff =
          getLatencySortValue(left.outbound) -
          getLatencySortValue(right.outbound);

        if (latencyDiff !== 0) {
          return latencyDiff;
        }
      }

      return left.index - right.index;
    })
    .map((item) => item.outbound);
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

function isSafeSectionName(sectionName: string) {
  return /^[A-Za-z0-9_-]+$/.test(sectionName);
}

function objectMap(value: unknown): Record<string, string> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return {};
  }

  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .filter(([, item]) => typeof item === 'string')
      .map(([key, item]) => [key, item as string]),
  );
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

function isUrlTestFilteringEnabled(settings: ItemSettings | undefined) {
  return ['exclude', 'include', 'mixed'].includes(
    itemSettingString(settings, 'urltest_filter_mode', 'disabled'),
  );
}

function getUrlTestTag(sectionName: string, id: string) {
  return getOutboundTagBySection(
    id === 'urltest'
      ? `${sectionName}-urltest`
      : `${sectionName}-urltest-${id}`,
  );
}

function getPriorityTag(sectionName: string, id: string) {
  return getOutboundTagBySection(`${sectionName}-priority-${id}`);
}

function getUrlTestDisplayName(
  section: Forkop.ConfigSection,
  id: string,
  settings: ItemSettings | undefined,
) {
  return itemSettingString(
    settings,
    'display_name',
    id === 'urltest' && !hasConfiguredUrlTestList(section) ? _('Fastest') : id,
  );
}

function getUrlTestConfigs(section: Forkop.ConfigSection): UrlTestConfig[] {
  const settingsMap = itemSettingsMap(section.urltest_settings);
  const sectionName = section['.name'];

  return getUrlTestIds(section).map((id) => {
    const settings = settingsMap[id] || {};
    const filteringEnabled = isUrlTestFilteringEnabled(settings);

    return {
      id,
      code: getUrlTestTag(sectionName, id),
      displayName: getUrlTestDisplayName(section, id, settings),
      settings,
      pinDashboard: itemSettingBoolean(settings, 'pin_dashboard', true),
      showDetectedCountries:
        filteringEnabled &&
        itemSettingString(settings, 'detect_server_country', 'flag_emoji') ===
          'country_is',
    };
  });
}

function priorityLevelConfigsFromSettings(
  settings: ItemSettings | undefined,
): PriorityLevelConfig[] {
  const value = settings?.levels;

  if (!Array.isArray(value)) {
    return [];
  }

  return value
    .flatMap((item, index) => {
      if (!item || typeof item !== 'object' || Array.isArray(item)) {
        return [];
      }

      const level = item as Partial<PriorityLevelConfig> &
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
          direct: Boolean(level.direct),
          filterMode: `${level.filterMode || 'include'}` || 'include',
          detectServerCountry:
            `${level.detectServerCountry || 'flag_emoji'}` || 'flag_emoji',
          country: getListValues(level.country as string[] | string),
          serverName: getListValues(level.serverName as string[] | string),
          regex: getListValues(level.regex as string[] | string),
          excludeCountries: getListValues(
            level.excludeCountries as string[] | string,
          ),
          excludeOutbounds: getListValues(
            level.excludeOutbounds as string[] | string,
          ),
          excludeRegex: getListValues(level.excludeRegex as string[] | string),
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

function getPriorityGroupIds(section: Forkop.ConfigSection) {
  return getListValues(section.priority_groups);
}

function getPriorityConfigs(section: Forkop.ConfigSection): PriorityConfig[] {
  const settingsMap = itemSettingsMap(section.priority_group_settings);
  const sectionName = section['.name'];

  return getPriorityGroupIds(section).map((id) => {
    const settings = settingsMap[id] || {};
    const levels = priorityLevelConfigsFromSettings(settings);

    return {
      id,
      code: getPriorityTag(sectionName, id),
      displayName: itemSettingString(settings, 'name', id),
      settings,
      pinDashboard: itemSettingBoolean(settings, 'pin_dashboard', true),
      healthUrl: itemSettingString(
        settings,
        'health_url',
        'https://www.gstatic.com/generate_204',
      ),
      activeCheckInterval: itemSettingString(
        settings,
        'active_check_interval',
        '5s',
      ),
      checkTimeout: itemSettingString(settings, 'check_timeout', '2s'),
      recoveryCheckInterval: itemSettingString(
        settings,
        'recovery_check_interval',
        '15s',
      ),
      pickFastest: itemSettingBoolean(settings, 'pick_fastest', false),
      switchToFasterSamePriority: itemSettingBoolean(
        settings,
        'switch_to_faster_same_priority',
        false,
      ),
      fastestCheckInterval: itemSettingString(
        settings,
        'fastest_check_interval',
        '3m',
      ),
      interruptExistConnections: itemSettingBoolean(
        settings,
        'interrupt_exist_connections',
        true,
      ),
      showDetectedCountries: levels.some(
        (level) => level.detectServerCountry === 'country_is',
      ),
      levels,
    };
  });
}

async function readDashboardSectionCache(
  sectionName: string,
): Promise<DashboardSectionCache | undefined> {
  if (!isSafeSectionName(sectionName)) {
    return undefined;
  }

  try {
    const raw = await fs.read(
      `${DASHBOARD_SECTION_CACHE_DIR}/${sectionName}.json`,
    );
    const parsed = JSON.parse(raw) as DashboardSectionCache;

    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return undefined;
    }

    return parsed;
  } catch (_error) {
    return undefined;
  }
}

function getUrlTestGroups(dashboardCache?: DashboardSectionCache) {
  const groups = dashboardCache?.urltestGroups;

  if (!groups || typeof groups !== 'object' || Array.isArray(groups)) {
    return {};
  }

  return groups;
}

function getPriorityGroups(dashboardCache?: DashboardSectionCache) {
  const groups = dashboardCache?.priorityGroups;

  if (!groups || typeof groups !== 'object' || Array.isArray(groups)) {
    return {};
  }

  return groups;
}

function getOutboundDisplayName(
  code: string,
  entry: ClashProxyEntry | undefined,
  link: string,
  outboundMetadata?: Forkop.GetOutboundMetadata,
  preferMetadata = false,
) {
  const metadataName = outboundMetadata?.names?.[code];

  return (
    (preferMetadata ? metadataName : getProxyUrlName(link)) ||
    (preferMetadata ? getProxyUrlName(link) : metadataName) ||
    entry?.value?.name ||
    code
  );
}

function buildUrlTestInfo({
  code,
  displayName,
  entry,
  groupCache,
  proxyByCode,
  manualLinkByCode,
  cachedProxyLinks,
  outboundMetadata,
  showDetectedCountries,
}: {
  code: string;
  displayName: string;
  entry?: ClashProxyEntry;
  groupCache?: UrlTestCacheGroup;
  proxyByCode: Map<string, ClashProxyEntry>;
  manualLinkByCode: Map<string, string>;
  cachedProxyLinks: Map<string, string>;
  outboundMetadata?: Forkop.GetOutboundMetadata;
  showDetectedCountries: boolean;
}): Forkop.UrlTestInfo {
  const childCodes = uniqueCodes(
    groupCache?.outbounds?.length
      ? groupCache.outbounds
      : entry?.value.all || [],
  );
  const selectedCode = entry?.value.now || '';
  const outbounds = sortUrlTestMembers(
    childCodes.flatMap((childCode) => {
      const childEntry = proxyByCode.get(childCode);
      const link =
        manualLinkByCode.get(childCode) ||
        cachedProxyLinks.get(childCode) ||
        '';
      const canCopyLink = isCopyableProxyLink(link);

      return [
        {
          code: childCode,
          displayName: getOutboundDisplayName(
            childCode,
            childEntry,
            link,
            outboundMetadata,
            cachedProxyLinks.has(childCode),
          ),
          latency: childEntry?.value?.history?.[0]?.delay || 0,
          type: childEntry?.value?.type || '',
          selected: selectedCode === childCode,
          link,
          canCopyLink,
          country: showDetectedCountries
            ? outboundMetadata?.countries?.[childCode]
            : undefined,
        },
      ];
    }),
  );
  const selectedName =
    outbounds.find((outbound) => outbound.code === selectedCode)?.displayName ||
    selectedCode;

  return {
    code,
    displayName: groupCache?.displayName || displayName,
    selectedCode: selectedCode || undefined,
    selectedName: selectedName || undefined,
    url: groupCache?.url,
    interval: groupCache?.interval,
    tolerance: groupCache?.tolerance,
    idleTimeout: groupCache?.idle_timeout || '30m',
    interruptExistConnections: groupCache?.interrupt_exist_connections,
    outbounds,
  };
}

function buildPriorityInfo({
  config,
  entry,
  groupCache,
  proxyByCode,
  manualLinkByCode,
  cachedProxyLinks,
  outboundMetadata,
  showDetectedCountries,
}: {
  config: PriorityConfig;
  entry?: ClashProxyEntry;
  groupCache?: PriorityCacheGroup;
  proxyByCode: Map<string, ClashProxyEntry>;
  manualLinkByCode: Map<string, string>;
  cachedProxyLinks: Map<string, string>;
  outboundMetadata?: Forkop.GetOutboundMetadata;
  showDetectedCountries: boolean;
}): Forkop.PriorityInfo {
  const selectedCode = entry?.value.now || '';
  const cacheLevels = Array.isArray(groupCache?.levels)
    ? groupCache.levels
    : [];
  const configLevelById = new Map(
    config.levels.map((level) => [level.id, level]),
  );
  const levels = (
    cacheLevels.length
      ? cacheLevels.map((level, index): PriorityLevelConfig => {
          const id = `${level.id || ''}`;
          const configLevel = id ? configLevelById.get(id) : undefined;

          return {
            id: id || configLevel?.id || `level-${index + 1}`,
            displayName:
              level.displayName || configLevel?.displayName || `${index + 1}`,
            order:
              typeof level.order === 'number' && Number.isFinite(level.order)
                ? level.order
                : (configLevel?.order ?? index),
            direct: level.direct ?? configLevel?.direct ?? false,
            filterMode:
              level.filter_mode || configLevel?.filterMode || 'include',
            detectServerCountry:
              level.detect_server_country ||
              configLevel?.detectServerCountry ||
              'flag_emoji',
            country: configLevel?.country || [],
            serverName: configLevel?.serverName || [],
            regex: configLevel?.regex || [],
            excludeCountries: configLevel?.excludeCountries || [],
            excludeOutbounds: configLevel?.excludeOutbounds || [],
            excludeRegex: configLevel?.excludeRegex || [],
            outbounds: uniqueCodes(level.outbounds || []),
          };
        })
      : config.levels.map((level) => ({
          ...level,
          outbounds: uniqueCodes(level.outbounds || []),
        }))
  ).sort((left, right) =>
    left.order === right.order
      ? left.id.localeCompare(right.id)
      : left.order - right.order,
  );
  const outbounds = levels.flatMap((level, levelIndex) => {
    const members = uniqueCodes(level.outbounds || []).map((childCode) => {
      const childEntry = proxyByCode.get(childCode);
      const link =
        manualLinkByCode.get(childCode) ||
        cachedProxyLinks.get(childCode) ||
        '';
      const canCopyLink = isCopyableProxyLink(link);

      return {
        code: childCode,
        displayName: getOutboundDisplayName(
          childCode,
          childEntry,
          link,
          outboundMetadata,
          cachedProxyLinks.has(childCode),
        ),
        latency: childEntry?.value?.history?.[0]?.delay || 0,
        type: childEntry?.value?.type || '',
        selected: selectedCode === childCode,
        link,
        canCopyLink,
        country: showDetectedCountries
          ? outboundMetadata?.countries?.[childCode]
          : undefined,
        levelIndex,
        levelName: level.displayName,
        levelId: level.id,
      };
    });

    if (!config.pickFastest) {
      return members;
    }

    return members
      .map((outbound, index) => ({ outbound, index }))
      .sort((left, right) => {
        const latencyDiff =
          getLatencySortValue(left.outbound) -
          getLatencySortValue(right.outbound);

        return latencyDiff !== 0 ? latencyDiff : left.index - right.index;
      })
      .map((item) => item.outbound);
  });
  const selectedName =
    outbounds.find((outbound) => outbound.code === selectedCode)?.displayName ||
    selectedCode;

  return {
    code: config.code,
    displayName: groupCache?.displayName || config.displayName,
    selectedCode: selectedCode || undefined,
    selectedName: selectedName || undefined,
    healthUrl: groupCache?.health_url || config.healthUrl,
    activeCheckInterval:
      groupCache?.active_check_interval || config.activeCheckInterval,
    checkTimeout: groupCache?.check_timeout || config.checkTimeout,
    recoveryCheckInterval:
      groupCache?.recovery_check_interval || config.recoveryCheckInterval,
    pickFastest: groupCache?.pick_fastest ?? config.pickFastest,
    switchToFasterSamePriority:
      groupCache?.switch_to_faster_same_priority ??
      config.switchToFasterSamePriority,
    fastestCheckInterval:
      groupCache?.fastest_check_interval || config.fastestCheckInterval,
    interruptExistConnections:
      groupCache?.interrupt_exist_connections ??
      config.interruptExistConnections,
    outbounds,
  };
}

function buildProxyGroupOutbounds(
  section: Forkop.ConfigSection,
  proxies: ClashProxyEntry[],
  outboundMetadata?: Forkop.GetOutboundMetadata,
  urltestGroups: Record<string, UrlTestCacheGroup> = {},
  priorityGroups: Record<string, PriorityCacheGroup> = {},
  cachedProxyLinks: Map<string, string> = new Map(),
) {
  const sectionName = section['.name'];
  const proxyByCode = getProxyEntryByCode(proxies);
  const selectorTag = getOutboundTagBySection(sectionName);
  const selector = proxyByCode.get(selectorTag);
  const urlTestConfigs = getUrlTestConfigs(section);
  const urlTestConfigByCode = new Map(
    urlTestConfigs.map((config) => [config.code, config]),
  );
  const priorityConfigs = getPriorityConfigs(section);
  const priorityConfigByCode = new Map(
    priorityConfigs.map((config) => [config.code, config]),
  );
  const urlTestEntries = urlTestConfigs.map((config) => ({
    config,
    entry: proxyByCode.get(config.code),
  }));
  const priorityEntries = priorityConfigs.map((config) => ({
    config,
    entry: proxyByCode.get(config.code),
  }));
  const manualLinkByCode = buildManualLinkByCode(section);
  const selectorCodes = selector?.value?.all ?? [];
  const urlTestCodes = urlTestConfigs.map((config) => config.code);
  const priorityCodes = priorityConfigs.map((config) => config.code);
  const showDetectedCountries =
    urlTestConfigs.some((config) => config.showDetectedCountries) ||
    priorityConfigs.some((config) => config.showDetectedCountries);
  const builtInUrltestCode = urlTestCodes[0] || '';
  const fallbackCodes = uniqueCodes([
    ...urlTestCodes,
    ...priorityCodes,
    ...urlTestEntries.flatMap(({ entry }) => entry?.value.all || []),
    ...priorityEntries.flatMap(({ entry }) => entry?.value.all || []),
  ]);
  const groupCodes = uniqueCodes([
    ...(selectorCodes.length ? selectorCodes : fallbackCodes),
    ...urlTestCodes,
    ...priorityCodes,
  ]);

  const outbounds = uniqueCodes(groupCodes).flatMap((code) => {
    const item = proxyByCode.get(code);
    const urlTestConfig = urlTestConfigByCode.get(code);
    const priorityConfig = priorityConfigByCode.get(code);

    if (!item && !urlTestConfig && !priorityConfig) {
      return [];
    }

    const link = manualLinkByCode.get(code) || cachedProxyLinks.get(code) || '';
    const canCopyLink = isCopyableProxyLink(link);
    const displayName =
      priorityConfig?.displayName ||
      urlTestConfig?.displayName ||
      getOutboundDisplayName(
        code,
        item,
        link,
        outboundMetadata,
        cachedProxyLinks.has(code),
      );
    const isRuntimeUrlTest = isUrlTestProxyEntry(item);

    return [
      {
        code,
        displayName,
        latency: item?.value.history?.[0]?.delay || 0,
        type: priorityConfig ? 'Priority' : item?.value.type || 'URLTest',
        selected: selector?.value?.now === code,
        link,
        canCopyLink,
        country: showDetectedCountries
          ? outboundMetadata?.countries?.[code]
          : undefined,
        runtimeAvailable: item ? undefined : false,
        urlTestInfo:
          urlTestConfig || isRuntimeUrlTest
            ? buildUrlTestInfo({
                code,
                displayName,
                entry: item,
                groupCache: urltestGroups[code],
                proxyByCode,
                manualLinkByCode,
                cachedProxyLinks,
                outboundMetadata,
                showDetectedCountries:
                  urlTestConfig?.showDetectedCountries || showDetectedCountries,
              })
            : undefined,
        priorityInfo: priorityConfig
          ? buildPriorityInfo({
              config: priorityConfig,
              entry: item,
              groupCache: priorityGroups[code],
              proxyByCode,
              manualLinkByCode,
              cachedProxyLinks,
              outboundMetadata,
              showDetectedCountries: priorityConfig.showDetectedCountries,
            })
          : undefined,
      },
    ];
  });

  const sortedOutbounds = sortOutboundsForDashboard(outbounds, {
    pinnedCodes: [
      ...urlTestEntries
        .filter(({ config }) => config.pinDashboard)
        .map(({ config }) => config.code),
      ...priorityEntries
        .filter(({ config }) => config.pinDashboard)
        .map(({ config }) => config.code),
    ],
    sortByLatency: shouldSortByLatency(section),
  });
  const latencyTestCodes = sortedOutbounds
    .filter(
      (outbound) =>
        outbound.runtimeAvailable !== false &&
        !isSelectorOutbound(outbound) &&
        !outbound.priorityInfo,
    )
    .map((outbound) => outbound.code);

  return {
    selector,
    latencyTestCode: selector?.code || builtInUrltestCode,
    latencyTestCodes:
      latencyTestCodes.length > 0 ? latencyTestCodes : undefined,
    outbounds: sortedOutbounds,
  };
}

function metadataMatchesCurrentSource(
  sectionName: string,
  sourceCount: number,
  metadata: Forkop.SubscriptionMetadata,
) {
  const legacyMetadata = metadata as Forkop.SubscriptionMetadata & {
    source_index?: number;
    source_section?: string;
  };
  const sourceIndex = metadata.sourceIndex ?? legacyMetadata.source_index;
  const sourceSection =
    metadata.sourceSection || legacyMetadata.source_section || '';
  const hasSourceIndex = typeof sourceIndex === 'number';
  const hasSourceSection = sourceSection !== '';

  if (!hasSourceIndex && !hasSourceSection) {
    return sourceCount <= 1;
  }

  if (sourceCount > 1 && !hasSourceSection) {
    return false;
  }

  if (hasSourceIndex && (sourceIndex < 1 || sourceIndex > sourceCount)) {
    return false;
  }

  if (hasSourceSection) {
    const expectedSourcePrefix = `${sectionName}-subscription-`;

    if (!sourceSection.startsWith(expectedSourcePrefix)) {
      return false;
    }

    const sourceSectionIndex = Number(
      sourceSection.slice(expectedSourcePrefix.length),
    );

    if (
      !Number.isInteger(sourceSectionIndex) ||
      sourceSectionIndex < 1 ||
      sourceSectionIndex > sourceCount
    ) {
      return false;
    }

    if (hasSourceIndex && sourceIndex !== sourceSectionIndex) {
      return false;
    }
  }

  return true;
}

function getSubscriptionMetadataSourceIndex(
  sectionName: string,
  sourceCount: number,
  metadata: Forkop.SubscriptionMetadata,
) {
  const legacyMetadata = metadata as Forkop.SubscriptionMetadata & {
    source_index?: number;
    source_section?: string;
  };
  const sourceIndex = metadata.sourceIndex ?? legacyMetadata.source_index;

  if (typeof sourceIndex === 'number') {
    return sourceIndex;
  }

  const sourceSection =
    metadata.sourceSection || legacyMetadata.source_section || '';
  const expectedSourcePrefix = `${sectionName}-subscription-`;

  if (sourceSection.startsWith(expectedSourcePrefix)) {
    const parsed = Number(sourceSection.slice(expectedSourcePrefix.length));
    return Number.isInteger(parsed) ? parsed : undefined;
  }

  return sourceCount <= 1 ? 1 : undefined;
}

function isSubscriptionMetadataVisible(
  section: Forkop.ConfigSection,
  sourceCount: number,
  metadata: Forkop.SubscriptionMetadata,
) {
  const sourceIndex = getSubscriptionMetadataSourceIndex(
    section['.name'],
    sourceCount,
    metadata,
  );

  if (!sourceIndex || sourceIndex < 1 || sourceIndex > sourceCount) {
    return true;
  }

  const sourceEntry = getListValues(section.subscription_urls)[sourceIndex - 1];
  const settings = itemSettingsMap(section.subscription_url_settings)[
    sourceEntry
  ];

  return settings?.show_dashboard_metadata !== '0';
}

function getSubscriptionMetadata(
  section: Forkop.ConfigSection,
  sourceCount: number,
  dashboardCache?: DashboardSectionCache,
) {
  if (!dashboardCache?.subscriptionMetadata) {
    return undefined;
  }

  const metadataItems = Array.isArray(dashboardCache.subscriptionMetadata)
    ? dashboardCache.subscriptionMetadata
    : [dashboardCache.subscriptionMetadata];
  const visibleMetadataItems = metadataItems.filter(
    (metadata) =>
      metadata &&
      Object.keys(metadata).length > 1 &&
      metadataMatchesCurrentSource(section['.name'], sourceCount, metadata) &&
      isSubscriptionMetadataVisible(section, sourceCount, metadata),
  );

  if (visibleMetadataItems.length > 0) {
    return visibleMetadataItems;
  }

  return undefined;
}

function getOutboundMetadata(dashboardCache?: DashboardSectionCache) {
  const metadata = dashboardCache?.outboundMetadata;

  if (!metadata || typeof metadata !== 'object') {
    return undefined;
  }

  return {
    names: objectMap(metadata.names),
    countries: objectMap(metadata.countries),
  };
}

function getCachedProxyLinks(dashboardCache?: DashboardSectionCache) {
  return new Map(
    Object.entries(objectMap(dashboardCache?.links)).filter(([, link]) =>
      isCopyableProxyLink(link),
    ),
  );
}

export async function getDashboardSections(
  options: IGetDashboardSectionsOptions = {},
): Promise<IGetDashboardSectionsResponse> {
  const includeSubscriptionCopyState =
    options.includeSubscriptionCopyState ?? true;
  const configSections = hydrateConfigSections(await getConfigSections());
  const clashProxies = await getClashApiProxies(configSections);

  if (!clashProxies.success || !clashProxies.data?.proxies) {
    return {
      success: false,
      data: [],
    };
  }

  const proxies = Object.entries(clashProxies.data.proxies).map(
    ([key, value]) => ({
      code: key,
      value,
    }),
  );
  const data = await Promise.all(
    configSections
      .filter(
        (section) =>
          section.enabled !== '0' && isConnectionAction(section.action),
      )
      .map(async (section) => {
        const displayName = getDisplayName(section);
        const sectionName = section['.name'];
        const sectionAction = section.action;
        const proxyConfigType = getSectionProxyConfigType(section);

        if (isConnectionAction(sectionAction) && shouldUseProxyGroup(section)) {
          const subscriptionSourceCount = getSubscriptionSourceCount(section);
          const subscriptionEnabled = subscriptionSourceCount > 0;
          const dashboardCache = await readDashboardSectionCache(sectionName);
          const outboundMetadata = getOutboundMetadata(dashboardCache);
          const subscriptionMetadata = subscriptionEnabled
            ? getSubscriptionMetadata(
                section,
                subscriptionSourceCount,
                dashboardCache,
              )
            : undefined;
          const cachedProxyLinks = includeSubscriptionCopyState
            ? getCachedProxyLinks(dashboardCache)
            : new Map<string, string>();
          const urltestGroups = getUrlTestGroups(dashboardCache);
          const priorityGroups = getPriorityGroups(dashboardCache);
          const { selector, latencyTestCode, latencyTestCodes, outbounds } =
            buildProxyGroupOutbounds(
              section,
              proxies,
              outboundMetadata,
              urltestGroups,
              priorityGroups,
              cachedProxyLinks,
            );

          return {
            withTagSelect: true,
            code: selector?.code || sectionName,
            sectionName,
            displayName,
            action: sectionAction,
            latencyTestCode,
            latencyTestCodes,
            proxyConfigType,
            subscriptionSourceCount,
            subscriptionMetadata,
            outbounds,
          };
        }

        if (sectionAction === 'vpn') {
          const outboundTag = getOutboundTagBySection(sectionName);
          const outbound = proxies.find((proxy) => proxy.code === outboundTag);

          return {
            withTagSelect: false,
            code: outbound?.code || sectionName,
            sectionName,
            displayName,
            action: sectionAction,
            latencyTestTimeout: '10000',
            outbounds: [
              {
                code: outbound?.code || sectionName,
                displayName: section.interface || outbound?.value?.name || '',
                latency: outbound?.value?.history?.[0]?.delay || 0,
                type: outbound?.value?.type || '',
                selected: true,
                canCopyLink: false,
                runtimeAvailable: Boolean(outbound),
              },
            ],
          };
        }

        if (sectionAction === 'outbound') {
          const outboundTag = getOutboundTagBySection(sectionName);
          const outbound = proxies.find((proxy) => proxy.code === outboundTag);

          return {
            withTagSelect: false,
            code: outbound?.code || sectionName,
            sectionName,
            displayName,
            action: sectionAction,
            outbounds: [
              {
                code: outbound?.code || sectionName,
                displayName:
                  getJsonOutboundDisplayName(section) ||
                  outbound?.value?.name ||
                  '',
                latency: outbound?.value?.history?.[0]?.delay || 0,
                type: outbound?.value?.type || '',
                selected: true,
                canCopyLink: false,
              },
            ],
          };
        }

        return {
          withTagSelect: false,
          code: sectionName,
          sectionName,
          displayName,
          action: sectionAction,
          outbounds: [],
        };
      }),
  );

  return {
    success: true,
    data,
  };
}
