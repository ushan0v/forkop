import { canUseDirectClashApi, getClashWsUrl, onMount } from '../../../helpers';
import { prettyBytes } from '../../../helpers/prettyBytes';
import { showToast } from '../../../helpers/showToast';
import {
  renderPauseIcon24,
  renderPlayIcon24,
  renderSearchIcon24,
  renderXIcon24,
} from '../../../icons';
import { CustomPodkopMethods, PodkopShellMethods } from '../../methods';
import { getOutboundTagBySection } from '../../runtimeTags';
import { getClashApiSecret } from '../../methods/custom/getClashApiSecret';
import { logger, socket, store, StoreType } from '../../services';
import { Podkop } from '../../types';
import {
  getCachedRuntimeUiState,
  refreshRuntimeUiState,
  subscribeRuntimeUiState,
} from '../../services/runtimeUiState.service';
import {
  getServiceAvailability,
  type ServiceAvailability,
} from '../../helpers/serviceAvailability';

type MonitoringTabId = 'active' | 'closed';

type LocalDeviceChoices = Record<string, string>;

interface MonitoringControllerDependencies {
  loadLocalDeviceChoices?: () => Promise<LocalDeviceChoices>;
}

interface ClashConnectionMetadata {
  destinationIP?: string;
  destinationPort?: string | number;
  host?: string;
  network?: string;
  processPath?: string;
  sourceIP?: string;
  sourcePort?: string | number;
  type?: string;
}

interface ClashConnection {
  chains?: string[];
  download?: number;
  id?: string;
  metadata?: ClashConnectionMetadata;
  rule?: string;
  rulePayload?: string;
  start?: string;
  upload?: number;
}

interface ClashConnectionsPayload {
  connections?: ClashConnection[];
}

interface MonitoredConnection extends ClashConnection {
  id: string;
  closedAt?: number;
  lastSeenAt: number;
}

function normalizeConnectionsPayload(value: unknown): ClashConnectionsPayload {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return {};
  }

  return value as ClashConnectionsPayload;
}

const RENDER_INTERVAL_MS = 500;
const CONNECTIONS_RPC_POLL_INTERVAL_MS = 1500;
const CLOSED_CONNECTION_LIMIT = 300;
const ALL_FILTER_VALUE = 'all';

let dependencies: MonitoringControllerDependencies = {};
let monitoringMounted = false;
let monitoringMountId = 0;
let monitoringLifecycleRegistered = false;
let monitoringControllerInitialized = false;
let serviceStateUnsubscribe: (() => void) | null = null;
let renderTimer: ReturnType<typeof setInterval> | null = null;
let connectionsPollTimer: ReturnType<typeof setInterval> | null = null;
let connectionsSocketUrl = '';
let connectionsUpdatesId = 0;
let renderSkippedForSelection = false;
let pendingConnectionsPayload: ClashConnectionsPayload | null = null;
let pollingConnections = false;

let activeTab: MonitoringTabId = 'active';
let selectedDeviceFilter = ALL_FILTER_VALUE;
let searchQuery = '';
let localDeviceChoices: LocalDeviceChoices = {};
let routeDisplayNames: Record<string, string> = {};
let routeSections: Array<{ sectionName: string; displayName: string }> = [];
let serverDisplayNames: Record<string, string> = {};
let lastDeviceFilterSignature = '';
let loading = true;
let failed = false;
let closingAll = false;
let monitoringPaused = false;
let monitoringPausedAt: number | null = null;
let serviceAvailability: ServiceAvailability = 'loading';

const activeConnections = new Map<string, MonitoredConnection>();
const closedConnections = new Map<string, MonitoredConnection>();
const closingConnectionIds = new Set<string>();

function normalizeString(value?: string | number | null): string {
  return value == null ? '' : String(value).trim();
}

function getListValues(value?: string[] | string) {
  if (!value) {
    return [];
  }

  if (Array.isArray(value)) {
    return value.map((item) => normalizeString(item)).filter(Boolean);
  }

  return normalizeString(value)
    .split(/\s+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function getUrlTestIds(section: Podkop.ConfigSection) {
  const values = getListValues(section.urltests);
  return values.length
    ? values
    : section.urltest_enabled === '1'
      ? ['urltest']
      : [];
}

function getUrlTestTag(sectionName: string, id: string) {
  return getOutboundTagBySection(
    id === 'urltest'
      ? `${sectionName}-urltest`
      : `${sectionName}-urltest-${id}`,
  );
}

function formatEndpoint(address?: string, port?: string | number): string {
  const normalizedAddress = normalizeString(address);
  const normalizedPort = normalizeString(port);

  if (!normalizedAddress) {
    return '-';
  }

  if (!normalizedPort) {
    return normalizedAddress;
  }

  if (normalizedPort === '443') {
    return normalizedAddress;
  }

  if (normalizedAddress.includes(':') && !normalizedAddress.startsWith('[')) {
    return `[${normalizedAddress}]:${normalizedPort}`;
  }

  return `${normalizedAddress}:${normalizedPort}`;
}

function getDisplayName(section: Podkop.ConfigSection) {
  return normalizeString(section.label) || section['.name'];
}

function buildRouteDisplayNames(sections: Podkop.ConfigSection[]) {
  const map: Record<string, string> = {
    'bypass-out': 'Bypass',
    'direct-out': 'direct',
  };
  const serverMap: Record<string, string> = {};
  const routeSectionItems: Array<{ sectionName: string; displayName: string }> =
    [];
  const urltestsBySection = new Map<string, string[]>();

  sections
    .filter((section) => section['.type'] === 'urltest')
    .forEach((section) => {
      const owner = normalizeString(section.section);
      const id = normalizeString(section.id) || section['.name'];
      if (!owner || !id) {
        return;
      }

      urltestsBySection.set(owner, [...(urltestsBySection.get(owner) || []), id]);
    });

  sections
    .filter((section) => section['.type'] === 'section')
    .filter((section) => section.enabled !== '0')
    .forEach((section) => {
      const sectionName = section['.name'];
      const displayName = getDisplayName(section);

      if (!sectionName || !displayName) {
        return;
      }

      routeSectionItems.push({ sectionName, displayName });
      map[getOutboundTagBySection(sectionName)] = displayName;
      const urltestIds = urltestsBySection.get(sectionName) || getUrlTestIds(section);
      urltestIds.forEach((id) => {
        map[getUrlTestTag(sectionName, id)] = displayName;
      });
    });

  sections
    .filter((section) => section['.type'] === 'server')
    .filter((section) => section.enabled !== '0')
    .forEach((section) => {
      const sectionName = section['.name'];
      const displayName = getDisplayName(section);

      if (!sectionName || !displayName) {
        return;
      }

      serverMap[`server-${sectionName}-in`] = displayName;
    });

  routeDisplayNames = map;
  serverDisplayNames = serverMap;
  routeSections = routeSectionItems.sort(
    (a, b) => b.sectionName.length - a.sectionName.length,
  );
}

function getRouteDisplayNameByTag(tag: string): string {
  if (!tag) {
    return '';
  }

  if (routeDisplayNames[tag]) {
    return routeDisplayNames[tag];
  }

  const manualSection = routeSections.find(({ sectionName }) => {
    if (!tag.startsWith(`${sectionName}-`) || !tag.endsWith('-out')) {
      return false;
    }

    const middle = tag.slice(sectionName.length + 1, -4);
    return /^\d+(?:-\d+)?$/.test(middle);
  });

  return manualSection?.displayName || '';
}

function getRouteTagFromRule(rule?: string): string {
  const match = normalizeString(rule).match(/=>\s*route\(([^)]+)\)/);
  return normalizeString(match?.[1]).replace(/^['"]|['"]$/g, '');
}

function parseStartedAt(connection: MonitoredConnection): number {
  const startedAt = Date.parse(connection.start || '');
  return Number.isFinite(startedAt) ? startedAt : connection.lastSeenAt;
}

function formatDuration(ms: number): string {
  const totalSeconds = Math.max(0, Math.floor(ms / 1000));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  const pad = (value: number) => String(value).padStart(2, '0');

  if (hours > 0) {
    return `${hours}:${pad(minutes)}:${pad(seconds)}`;
  }

  return `${minutes}:${pad(seconds)}`;
}

function formatConnectionDuration(connection: MonitoredConnection): string {
  const startedAt = parseStartedAt(connection);
  const finishedAt = connection.closedAt || monitoringPausedAt || Date.now();

  return formatDuration(finishedAt - startedAt);
}

function formatBytes(value?: number): string {
  return prettyBytes(Number.isFinite(value) ? Number(value) : 0);
}

function getConnectionSourceIp(connection: ClashConnection): string {
  return normalizeString(connection.metadata?.sourceIP);
}

function getConnectionInboundTag(connection: ClashConnection): string {
  const metadataType = normalizeString(connection.metadata?.type);
  const metadataTypeParts = metadataType.split('/');
  const metadataTag = normalizeString(
    metadataTypeParts.length > 1
      ? metadataTypeParts[metadataTypeParts.length - 1]
      : metadataType,
  );

  if (metadataTag) {
    return metadataTag;
  }

  const ruleInbound = normalizeString(connection.rule).match(
    /(?:^|\s)inbound=([^\s]+)/,
  );

  return normalizeString(ruleInbound?.[1]);
}

function getServerDisplayNameByInboundTag(tag: string): string {
  return normalizeString(serverDisplayNames[tag]);
}

function getDeviceName(ip: string): string {
  return normalizeString(localDeviceChoices[ip]);
}

function getServerSourceNameByIp(ip: string): string {
  if (!ip) {
    return '';
  }

  const connections = [
    ...Array.from(activeConnections.values()),
    ...Array.from(closedConnections.values()),
  ];

  for (const connection of connections) {
    if (getConnectionSourceIp(connection) !== ip) {
      continue;
    }

    const serverName = getServerDisplayNameByInboundTag(
      getConnectionInboundTag(connection),
    );

    if (serverName) {
      return serverName;
    }
  }

  return '';
}

function getDeviceFilterLabel(ip: string): string {
  const serverName = getServerSourceNameByIp(ip);
  if (serverName) {
    return serverName;
  }

  const deviceName = getDeviceName(ip);
  return deviceName || ip;
}

function getSourceCellParts(connection: MonitoredConnection) {
  const ip = getConnectionSourceIp(connection);
  const inboundTag = getConnectionInboundTag(connection);
  const serverName = getServerDisplayNameByInboundTag(inboundTag);

  if (serverName) {
    return {
      primary: serverName,
      ip: '',
      copyValue: serverName,
      searchValue: [serverName, ip, inboundTag].filter(Boolean).join(' '),
    };
  }

  const deviceName = getDeviceName(ip);

  if (deviceName) {
    return {
      primary: deviceName,
      ip: '',
      copyValue: deviceName,
      searchValue: `${deviceName} ${ip}`,
    };
  }

  return {
    primary: ip || '-',
    ip: '',
    copyValue: ip || '-',
    searchValue: ip,
  };
}

function getTargetCellParts(connection: MonitoredConnection): {
  primary: string;
  searchValue: string;
} {
  const metadata = connection.metadata || {};
  const host = normalizeString(metadata.host);
  const destinationIp = normalizeString(metadata.destinationIP);
  const port = metadata.destinationPort;
  const primaryTarget = host || destinationIp;
  const primary = primaryTarget ? formatEndpoint(primaryTarget, port) : '-';

  return {
    primary,
    searchValue: [primary, host, destinationIp].filter(Boolean).join(' '),
  };
}

function getRoute(connection: MonitoredConnection): string {
  const chains = Array.isArray(connection.chains) ? connection.chains : [];
  const routeTag = [...chains].reverse().find(getRouteDisplayNameByTag);
  const fallbackRouteTag = getRouteTagFromRule(connection.rule);
  const route =
    getRouteDisplayNameByTag(routeTag || '') ||
    getRouteDisplayNameByTag(fallbackRouteTag) ||
    normalizeString(routeTag) ||
    normalizeString(fallbackRouteTag);

  return route || '-';
}

function getNetwork(connection: MonitoredConnection): string {
  return normalizeString(connection.metadata?.network).toLowerCase() || '-';
}

function sortConnections(
  connections: MonitoredConnection[],
  tab: MonitoringTabId,
): MonitoredConnection[] {
  return [...connections].sort((a, b) => {
    if (tab === 'closed') {
      return (b.closedAt || 0) - (a.closedAt || 0);
    }

    return parseStartedAt(b) - parseStartedAt(a);
  });
}

function getConnectionsForActiveTab(): MonitoredConnection[] {
  const source =
    activeTab === 'active'
      ? Array.from(activeConnections.values())
      : Array.from(closedConnections.values());

  return sortConnections(source, activeTab);
}

function normalizeSearchValue(value: string): string {
  return value.toLowerCase().replace(/\s+/g, ' ').trim();
}

function getSearchValues(connection: MonitoredConnection): string[] {
  const target = getTargetCellParts(connection);
  const source = getSourceCellParts(connection);

  return [
    connection.id,
    target.primary,
    getNetwork(connection),
    getRoute(connection),
    formatConnectionDuration(connection),
    formatBytes(connection.download),
    formatBytes(connection.upload),
    source.primary,
    source.copyValue,
    source.searchValue,
  ].filter(Boolean);
}

function getVisibleConnections(): MonitoredConnection[] {
  const normalizedSearch = normalizeSearchValue(searchQuery);

  return getConnectionsForActiveTab().filter((connection) => {
    const sourceIp = getConnectionSourceIp(connection);
    if (
      selectedDeviceFilter !== ALL_FILTER_VALUE &&
      sourceIp !== selectedDeviceFilter
    ) {
      return false;
    }

    if (!normalizedSearch) {
      return true;
    }

    return getSearchValues(connection).some((value) =>
      normalizeSearchValue(value).includes(normalizedSearch),
    );
  });
}

function moveConnectionToClosed(connection: MonitoredConnection, now: number) {
  closedConnections.set(connection.id, {
    ...connection,
    closedAt: now,
    lastSeenAt: now,
  });
}

function trimClosedConnections() {
  const sorted = sortConnections(
    Array.from(closedConnections.values()),
    'closed',
  );

  sorted.slice(CLOSED_CONNECTION_LIMIT).forEach((connection) => {
    closedConnections.delete(connection.id);
  });
}

function applyConnectionsPayload(payload: ClashConnectionsPayload) {
  if (monitoringPaused) {
    pendingConnectionsPayload = payload;
    return;
  }

  const mountId = monitoringMountId;
  const now = Date.now();
  const incomingIds = new Set<string>();
  const rawConnections = Array.isArray(payload.connections)
    ? payload.connections
    : [];

  rawConnections.forEach((rawConnection) => {
    const id = normalizeString(rawConnection.id);
    if (!id) {
      return;
    }

    incomingIds.add(id);
    closedConnections.delete(id);
    activeConnections.set(id, {
      ...rawConnection,
      id,
      lastSeenAt: now,
    });
  });

  Array.from(activeConnections.entries()).forEach(([id, connection]) => {
    if (!incomingIds.has(id)) {
      activeConnections.delete(id);
      moveConnectionToClosed(connection, now);
    }
  });

  trimClosedConnections();
  loading = false;
  failed = false;

  if (monitoringMounted && mountId === monitoringMountId) {
    renderControls();
    renderConnections();
  }
}

function setTab(tab: MonitoringTabId) {
  if (activeTab === tab) {
    return;
  }

  activeTab = tab;
  renderControls();
  renderConnections();
}

function getKnownSourceIps(): string[] {
  const ips = new Set<string>();

  activeConnections.forEach((connection) => {
    const ip = getConnectionSourceIp(connection);
    if (ip) {
      ips.add(ip);
    }
  });

  closedConnections.forEach((connection) => {
    const ip = getConnectionSourceIp(connection);
    if (ip) {
      ips.add(ip);
    }
  });

  return Array.from(ips).sort((a, b) => {
    const byLabel = getDeviceFilterLabel(a).localeCompare(
      getDeviceFilterLabel(b),
    );
    return byLabel || a.localeCompare(b);
  });
}

function renderDeviceFilterOptions() {
  const select = document.getElementById(
    'monitoring-device-filter',
  ) as HTMLSelectElement | null;

  if (!select) {
    return;
  }

  const sourceIps = getKnownSourceIps();
  if (
    selectedDeviceFilter !== ALL_FILTER_VALUE &&
    !sourceIps.includes(selectedDeviceFilter)
  ) {
    selectedDeviceFilter = ALL_FILTER_VALUE;
  }

  const signature = [
    selectedDeviceFilter,
    ...sourceIps.map((ip) => `${ip}:${getDeviceFilterLabel(ip)}`),
  ].join('|');
  if (signature === lastDeviceFilterSignature) {
    select.value = selectedDeviceFilter;
    return;
  }

  lastDeviceFilterSignature = signature;

  const options = [
    E('option', { value: ALL_FILTER_VALUE }, _('All')),
    ...sourceIps.map((ip) =>
      E('option', { value: ip }, getDeviceFilterLabel(ip)),
    ),
  ];

  select.replaceChildren(...options);
  select.value = selectedDeviceFilter;
}

function setButtonActive(button: HTMLElement | null, active: boolean) {
  if (!button) {
    return;
  }

  button.classList.toggle('pdk_monitoring-page__tab--active', active);
}

function renderTabButtonContent(label: string, count: number) {
  return [
    E('span', { class: 'pdk_monitoring-page__tab-label' }, label),
    E('span', { class: 'pdk_monitoring-page__tab-badge' }, String(count)),
  ];
}

function renderControls() {
  const activeButton = document.getElementById(
    'monitoring-tab-active',
  ) as HTMLButtonElement | null;
  const closedButton = document.getElementById(
    'monitoring-tab-closed',
  ) as HTMLButtonElement | null;
  const closeAllButton = document.getElementById(
    'monitoring-close-all',
  ) as HTMLButtonElement | null;
  const pauseToggleButton = document.getElementById(
    'monitoring-pause-toggle',
  ) as HTMLButtonElement | null;

  if (activeButton) {
    activeButton.replaceChildren(
      ...renderTabButtonContent(_('Active'), activeConnections.size),
    );
    activeButton.disabled = serviceAvailability === 'stopped';
  }

  if (closedButton) {
    closedButton.replaceChildren(
      ...renderTabButtonContent(_('Closed'), closedConnections.size),
    );
    closedButton.disabled = serviceAvailability === 'stopped';
  }

  setButtonActive(activeButton, activeTab === 'active');
  setButtonActive(closedButton, activeTab === 'closed');

  if (closeAllButton) {
    closeAllButton.replaceChildren(renderXIcon24());
    closeAllButton.disabled =
      serviceAvailability === 'stopped' ||
      activeConnections.size === 0 ||
      closingAll;
  }

  if (pauseToggleButton) {
    const title = monitoringPaused ? _('Resume updates') : _('Pause updates');
    pauseToggleButton.replaceChildren(
      monitoringPaused ? renderPlayIcon24() : renderPauseIcon24(),
    );
    pauseToggleButton.title = title;
    pauseToggleButton.setAttribute('aria-label', title);
    pauseToggleButton.disabled = serviceAvailability === 'stopped';
    pauseToggleButton.classList.toggle(
      'pdk_monitoring-page__icon-button--active',
      monitoringPaused,
    );
  }

  const searchIcon = document.querySelector(
    '.pdk_monitoring-page__search-icon',
  );
  if (searchIcon && searchIcon.childNodes.length === 0) {
    searchIcon.replaceChildren(renderSearchIcon24());
  }

  renderDeviceFilterOptions();

  const select = document.getElementById(
    'monitoring-device-filter',
  ) as HTMLSelectElement | null;
  const searchInput = document.getElementById(
    'monitoring-search',
  ) as HTMLInputElement | null;

  if (select) {
    select.disabled = serviceAvailability === 'stopped';
  }

  if (searchInput) {
    searchInput.disabled = serviceAvailability === 'stopped';
  }
}

function renderValue(value: string, className = '') {
  const text = value || '-';
  const element = E(
    'span',
    {
      class: ['pdk_monitoring-page__value', className]
        .filter(Boolean)
        .join(' '),
      title: text,
    },
    text,
  );

  element.setAttribute('data-copy-value', text);

  return element;
}

function renderSourceValue(source: ReturnType<typeof getSourceCellParts>) {
  const fullText = source.copyValue || source.primary || '-';

  if (!source.ip) {
    const element = E(
      'span',
      {
        class:
          'pdk_monitoring-page__value pdk_monitoring-page__source-value pdk_monitoring-page__source-value--ip-only',
        title: fullText,
      },
      source.primary || '-',
    );

    element.setAttribute('data-copy-value', fullText);

    return element;
  }

  const element = E(
    'span',
    {
      class: 'pdk_monitoring-page__value pdk_monitoring-page__source-value',
      title: fullText,
    },
    [
      E('span', { class: 'pdk_monitoring-page__source-name' }, source.primary),
      E('span', { class: 'pdk_monitoring-page__source-ip' }, source.ip),
    ],
  );

  element.setAttribute('data-copy-value', fullText);

  return element;
}

function renderTableCell(label: string, children: (Node | string)[]) {
  const cell = E('td', {}, children);
  cell.setAttribute('data-label', label);
  return cell;
}

function renderConnectionRow(connection: MonitoredConnection) {
  const target = getTargetCellParts(connection);
  const source = getSourceCellParts(connection);
  const isClosing = closingConnectionIds.has(connection.id);
  const closeButton =
    activeTab === 'active'
      ? E(
          'button',
          {
            class: 'btn cbi-button pdk_monitoring-page__row-action',
            title: _('Close connection'),
            'aria-label': _('Close connection'),
            type: 'button',
            value: connection.id,
            ...(isClosing ? { disabled: true } : {}),
          },
          [renderXIcon24()],
        )
      : E('span', {}, '-');

  return E(
    'tr',
    {
      class: isClosing ? 'pdk_monitoring-page__row--closing' : '',
    },
    [
      renderTableCell(_('Host'), [renderValue(target.primary)]),
      renderTableCell(_('Type'), [
        renderValue(getNetwork(connection), 'pdk_monitoring-page__network'),
      ]),
      renderTableCell(_('Route'), [
        renderValue(getRoute(connection), 'pdk_monitoring-page__route'),
      ]),
      renderTableCell(_('Time'), [
        renderValue(formatConnectionDuration(connection)),
      ]),
      renderTableCell(_('Downloaded'), [
        renderValue(formatBytes(connection.download)),
      ]),
      renderTableCell(_('Uploaded'), [
        renderValue(formatBytes(connection.upload)),
      ]),
      renderTableCell(_('Source'), [renderSourceValue(source)]),
      renderTableCell(_('Close'), [closeButton]),
    ],
  );
}

function renderStateRow(text: string, className = '') {
  return E('tr', { class: 'pdk_monitoring-page__state-row' }, [
    E(
      'td',
      {
        class: 'pdk_monitoring-page__state-cell',
        colSpan: 8,
      },
      [
        E(
          'div',
          {
            class: ['pdk_monitoring-page__state', className]
              .filter(Boolean)
              .join(' '),
          },
          text,
        ),
      ],
    ),
  ]);
}

function renderConnectionsTable(
  connections: MonitoredConnection[],
  state?: { text: string; className?: string },
) {
  const rows = state
    ? [renderStateRow(state.text, state.className)]
    : connections.map(renderConnectionRow);

  return E('div', { class: 'pdk_monitoring-page__table-wrap' }, [
    E(
      'table',
      { class: 'table cbi-section-table pdk_monitoring-page__table' },
      [
        E('thead', {}, [
          E('tr', {}, [
            E('th', {}, _('Host')),
            E('th', {}, _('Type')),
            E('th', {}, _('Route')),
            E('th', {}, _('Time')),
            E('th', {}, `\u2193 ${_('Downloaded')}`),
            E('th', {}, `\u2191 ${_('Uploaded')}`),
            E('th', {}, _('Source')),
            E('th', {}, _('Close')),
          ]),
        ]),
        E('tbody', {}, rows),
      ],
    ),
  ]);
}

function isNodeInsideMonitoring(node: Node | null): boolean {
  const root = document.getElementById('monitoring-status');
  return Boolean(root && node && root.contains(node));
}

function isTextSelectionInsideMonitoring(): boolean {
  const selection = window.getSelection?.();
  if (!selection || selection.isCollapsed) {
    return false;
  }

  return (
    isNodeInsideMonitoring(selection.anchorNode) ||
    isNodeInsideMonitoring(selection.focusNode)
  );
}

function renderConnections(options: { force?: boolean } = {}) {
  const container = document.getElementById('monitoring-connections');
  if (!container) {
    return;
  }

  if (!options.force && isTextSelectionInsideMonitoring()) {
    renderSkippedForSelection = true;
    return;
  }

  renderSkippedForSelection = false;
  const previousScrollLeft = container.scrollLeft;

  if (serviceAvailability === 'stopped') {
    container.replaceChildren(
      renderConnectionsTable([], {
        text: _(
          'Podkop Plus service is stopped. Start the service to display connections.',
        ),
      }),
    );
    return;
  }

  if (loading) {
    container.replaceChildren(
      renderConnectionsTable([], {
        text: _('Loading connections'),
        className: 'pdk_monitoring-page__state--loading',
      }),
    );
    return;
  }

  if (failed) {
    container.replaceChildren(
      renderConnectionsTable([], {
        text: _('Connections are unavailable'),
        className: 'pdk_monitoring-page__state--error',
      }),
    );
    return;
  }

  const visibleConnections = getVisibleConnections();

  if (visibleConnections.length === 0) {
    container.replaceChildren(
      renderConnectionsTable([], {
        text:
          activeTab === 'active'
            ? _('No active connections')
            : _('No closed connections'),
      }),
    );
    return;
  }

  container.replaceChildren(renderConnectionsTable(visibleConnections));
  container.scrollLeft = previousScrollLeft;
}

function flushRenderAfterSelection() {
  if (!renderSkippedForSelection || isTextSelectionInsideMonitoring()) {
    return;
  }

  renderConnections({ force: true });
}

function setMonitoringPaused(paused: boolean) {
  if (monitoringPaused === paused) {
    return;
  }

  monitoringPaused = paused;
  monitoringPausedAt = paused ? Date.now() : null;
  renderSkippedForSelection = false;
  renderControls();

  if (!paused) {
    const payload = pendingConnectionsPayload;
    pendingConnectionsPayload = null;

    if (payload) {
      applyConnectionsPayload(payload);
      return;
    }

    if (connectionsPollTimer) {
      void pollConnectionsSnapshot();
      return;
    }
  }

  renderConnections();
}

function isElementOverflowing(element: HTMLElement): boolean {
  return element.scrollWidth > element.clientWidth + 1;
}

function getMonitoringValueOverflowElements(
  element: HTMLElement,
): HTMLElement[] {
  return [
    element,
    ...Array.from(element.querySelectorAll<HTMLElement>('*')),
  ].filter(isElementOverflowing);
}

function getElementCopyText(element: HTMLElement, fallback: string): string {
  return (
    element.getAttribute('data-copy-value') || element.textContent || fallback
  );
}

function compactMonitoringText(value: string): string {
  return value
    .replace(/\u2026/g, '')
    .trim()
    .replace(/\s+/g, '');
}

function getMonitoringValueTextElements(element: HTMLElement): HTMLElement[] {
  const children = Array.from(element.children).filter(
    (child): child is HTMLElement => child instanceof HTMLElement,
  );

  if (children.length === 0) {
    return [element];
  }

  const textElements = children
    .flatMap(getMonitoringValueTextElements)
    .filter((child) => compactMonitoringText(getElementCopyText(child, '')));

  return textElements.length > 0 ? textElements : [element];
}

function estimateVisibleMonitoringTextLength(
  element: HTMLElement,
  fallbackText: string,
): number {
  const text = compactMonitoringText(getElementCopyText(element, fallbackText));

  if (!text) {
    return 0;
  }

  if (!isElementOverflowing(element)) {
    return text.length;
  }

  return Math.floor(
    (element.clientWidth / Math.max(element.scrollWidth, 1)) * text.length,
  );
}

function getEstimatedVisibleMonitoringTextLength(
  element: HTMLElement,
  fallbackText: string,
): number {
  const textElements = getMonitoringValueTextElements(element);

  if (textElements.length === 1 && textElements[0] === element) {
    return estimateVisibleMonitoringTextLength(element, fallbackText);
  }

  return textElements.reduce(
    (total, textElement) =>
      total + estimateVisibleMonitoringTextLength(textElement, fallbackText),
    0,
  );
}

function isCompactTextSubsequence(needle: string, haystack: string): boolean {
  let haystackIndex = 0;

  for (let needleIndex = 0; needleIndex < needle.length; needleIndex += 1) {
    haystackIndex = haystack.indexOf(needle[needleIndex], haystackIndex);

    if (haystackIndex === -1) {
      return false;
    }

    haystackIndex += 1;
  }

  return true;
}

function getSelectionValueElements(selection: Selection): HTMLElement[] {
  const root = document.getElementById('monitoring-status');
  if (!root) {
    return [];
  }

  return Array.from(
    root.querySelectorAll<HTMLElement>(
      '.pdk_monitoring-page__value[data-copy-value]',
    ),
  ).filter((element) => {
    for (let index = 0; index < selection.rangeCount; index += 1) {
      try {
        if (selection.getRangeAt(index).intersectsNode(element)) {
          return true;
        }
      } catch (_error) {
        return false;
      }
    }

    return false;
  });
}

function shouldCopyFullMonitoringValue(
  element: HTMLElement,
  selectedText: string,
  fullText: string,
): boolean {
  const normalizedSelectedText = selectedText.replace(/\u2026/g, '').trim();
  const normalizedFullText = fullText.trim();
  const compactSelectedText = compactMonitoringText(selectedText);
  const compactFullText = compactMonitoringText(fullText);
  const overflowElements = getMonitoringValueOverflowElements(element);
  const hasCompositeText = getMonitoringValueTextElements(element).length > 1;

  if (!normalizedSelectedText || !normalizedFullText) {
    return false;
  }

  if (normalizedSelectedText === normalizedFullText) {
    return true;
  }

  if (overflowElements.length === 0) {
    return false;
  }

  if (hasCompositeText) {
    const selectedPrefix = compactSelectedText.slice(
      0,
      Math.min(4, compactSelectedText.length),
    );

    if (
      !compactFullText.startsWith(selectedPrefix) ||
      !isCompactTextSubsequence(compactSelectedText, compactFullText)
    ) {
      return false;
    }
  } else if (!compactFullText.startsWith(compactSelectedText)) {
    return false;
  }

  const estimatedVisibleChars = getEstimatedVisibleMonitoringTextLength(
    element,
    normalizedFullText,
  );

  return compactSelectedText.length >= Math.max(4, estimatedVisibleChars - 2);
}

function handleMonitoringValueCopy(event: ClipboardEvent) {
  const selection = window.getSelection?.();
  if (!selection || selection.isCollapsed) {
    return;
  }

  const valueElements = getSelectionValueElements(selection);
  if (valueElements.length !== 1) {
    return;
  }

  const valueElement = valueElements[0];
  const fullText =
    valueElement.getAttribute('data-copy-value') ||
    valueElement.textContent ||
    '';
  const selectedText = selection.toString();

  if (!shouldCopyFullMonitoringValue(valueElement, selectedText, fullText)) {
    return;
  }

  event.clipboardData?.setData('text/plain', fullText);
  event.preventDefault();
}

async function closeConnection(connectionId: string) {
  if (!connectionId || closingConnectionIds.has(connectionId)) {
    return;
  }

  closingConnectionIds.add(connectionId);
  renderConnections();

  try {
    const response =
      await PodkopShellMethods.closeClashApiConnection(connectionId);

    if (!response.success) {
      showToast(_('Failed to close connection'), 'error');
      return;
    }

    const now = Date.now();
    const connection = activeConnections.get(connectionId);
    if (connection) {
      activeConnections.delete(connectionId);
      moveConnectionToClosed(connection, now);
      trimClosedConnections();
      pendingConnectionsPayload = null;
      renderControls();
    }
  } catch (error) {
    logger.error('[MONITORING]', 'closeConnection: failed', error);
    showToast(_('Failed to close connection'), 'error');
  } finally {
    closingConnectionIds.delete(connectionId);
    renderConnections();
  }
}

async function closeAllConnections() {
  if (activeConnections.size === 0 || closingAll) {
    return;
  }

  closingAll = true;
  renderControls();

  try {
    const response = await PodkopShellMethods.closeAllClashApiConnections();

    if (!response.success) {
      showToast(_('Failed to close connections'), 'error');
      return;
    }

    const now = Date.now();
    activeConnections.forEach((connection) => {
      moveConnectionToClosed(connection, now);
    });
    activeConnections.clear();
    pendingConnectionsPayload = null;
    trimClosedConnections();
  } catch (error) {
    logger.error('[MONITORING]', 'closeAllConnections: failed', error);
    showToast(_('Failed to close connections'), 'error');
  } finally {
    closingAll = false;
    renderControls();
    renderConnections();
  }
}

function bindControls() {
  const activeButton = document.getElementById('monitoring-tab-active');
  const closedButton = document.getElementById('monitoring-tab-closed');
  const select = document.getElementById(
    'monitoring-device-filter',
  ) as HTMLSelectElement | null;
  const searchInput = document.getElementById(
    'monitoring-search',
  ) as HTMLInputElement | null;
  const closeAllButton = document.getElementById('monitoring-close-all');
  const pauseToggleButton = document.getElementById('monitoring-pause-toggle');
  const connectionsContainer = document.getElementById(
    'monitoring-connections',
  );

  if (activeButton) {
    activeButton.onclick = () => setTab('active');
  }

  if (closedButton) {
    closedButton.onclick = () => setTab('closed');
  }

  if (closeAllButton) {
    closeAllButton.onclick = () => {
      void closeAllConnections();
    };
  }

  if (pauseToggleButton) {
    pauseToggleButton.onclick = () => {
      setMonitoringPaused(!monitoringPaused);
      pauseToggleButton.blur();
    };
  }

  if (select) {
    select.onchange = () => {
      selectedDeviceFilter = select.value || ALL_FILTER_VALUE;
      renderConnections();
    };
  }

  if (searchInput) {
    searchInput.oninput = () => {
      searchQuery = searchInput.value;
      renderConnections();
    };
  }

  if (connectionsContainer) {
    connectionsContainer.onclick = (event) => {
      const target = event.target as HTMLElement | null;
      const button = target?.closest(
        '.pdk_monitoring-page__row-action',
      ) as HTMLButtonElement | null;

      if (button?.value) {
        void closeConnection(button.value);
      }
    };
  }
}

async function loadLocalDevices() {
  try {
    localDeviceChoices = (await dependencies.loadLocalDeviceChoices?.()) || {};
  } catch (error) {
    logger.warn('[MONITORING]', 'loadLocalDevices: failed', error);
    localDeviceChoices = {};
  } finally {
    renderControls();
    renderConnections();
  }
}

async function loadRouteDisplayNames() {
  try {
    buildRouteDisplayNames(await CustomPodkopMethods.getConfigSections());
  } catch (error) {
    logger.warn('[MONITORING]', 'loadRouteDisplayNames: failed', error);
    buildRouteDisplayNames([]);
  } finally {
    renderControls();
    renderConnections();
  }
}

async function pollConnectionsSnapshot() {
  if (
    pollingConnections ||
    !monitoringMounted ||
    monitoringPaused ||
    serviceAvailability !== 'running'
  ) {
    return;
  }

  const mountId = monitoringMountId;
  pollingConnections = true;

  try {
    const response = await PodkopShellMethods.getClashApiConnections();

    if (
      !monitoringMounted ||
      mountId !== monitoringMountId ||
      serviceAvailability !== 'running'
    ) {
      return;
    }

    if (!response.success) {
      failed = true;
      loading = false;
      renderConnections();
      return;
    }

    applyConnectionsPayload(normalizeConnectionsPayload(response.data));
  } catch (error) {
    if (
      !monitoringMounted ||
      mountId !== monitoringMountId ||
      serviceAvailability !== 'running'
    ) {
      return;
    }

    logger.error('[MONITORING]', 'connections polling failed', error);
    failed = true;
    loading = false;
    renderConnections();
  } finally {
    pollingConnections = false;
  }
}

function startConnectionsPolling() {
  if (connectionsPollTimer) {
    return;
  }

  void pollConnectionsSnapshot();
  connectionsPollTimer = setInterval(() => {
    void pollConnectionsSnapshot();
  }, CONNECTIONS_RPC_POLL_INTERVAL_MS);
}

async function connectToConnectionsSocket(updatesId: number) {
  const mountId = monitoringMountId;
  const clashApiSecret = await getClashApiSecret();

  if (
    !monitoringMounted ||
    mountId !== monitoringMountId ||
    updatesId !== connectionsUpdatesId ||
    serviceAvailability !== 'running'
  ) {
    return;
  }

  connectionsSocketUrl = `${getClashWsUrl()}/connections?token=${clashApiSecret}`;

  socket.subscribe(
    connectionsSocketUrl,
    (msg) => {
      if (
        updatesId !== connectionsUpdatesId ||
        serviceAvailability !== 'running'
      ) {
        return;
      }

      try {
        applyConnectionsPayload(JSON.parse(msg) as ClashConnectionsPayload);
      } catch (error) {
        logger.error('[MONITORING]', 'connections socket parse failed', error);
      }
    },
    (_err) => {
      if (
        !monitoringMounted ||
        mountId !== monitoringMountId ||
        updatesId !== connectionsUpdatesId ||
        serviceAvailability !== 'running'
      ) {
        return;
      }

      failed = true;
      loading = false;
      renderConnections();
    },
  );
}

function startConnectionsUpdates() {
  if (serviceAvailability !== 'running') {
    return;
  }

  if (canUseDirectClashApi()) {
    const updatesId = ++connectionsUpdatesId;
    void connectToConnectionsSocket(updatesId);
    return;
  }

  startConnectionsPolling();
}

function stopConnectionsUpdates() {
  connectionsUpdatesId += 1;

  if (connectionsPollTimer) {
    clearInterval(connectionsPollTimer);
    connectionsPollTimer = null;
  }

  if (connectionsSocketUrl) {
    socket.disconnect(connectionsSocketUrl);
    connectionsSocketUrl = '';
  }
}

function setServiceAvailability(next: ServiceAvailability) {
  if (serviceAvailability === next) {
    return;
  }

  serviceAvailability = next;

  if (next === 'running') {
    loading = true;
    failed = false;
    startConnectionsUpdates();
  } else {
    stopConnectionsUpdates();
    pendingConnectionsPayload = null;

    if (next === 'stopped') {
      loading = false;
      failed = false;
      activeConnections.clear();
      closedConnections.clear();
      closingConnectionIds.clear();
    } else if (next === 'unavailable') {
      loading = false;
      failed = true;
    }
  }

  renderControls();
  renderConnections();
}

function watchServiceState() {
  serviceStateUnsubscribe?.();
  serviceStateUnsubscribe = subscribeRuntimeUiState((uiState) => {
    if (!monitoringMounted) {
      return;
    }

    setServiceAvailability(
      getServiceAvailability({
        loading: false,
        failed: false,
        running: uiState.service.podkop.running,
      }),
    );
  });
}

function resetMonitoringState() {
  activeTab = 'active';
  selectedDeviceFilter = ALL_FILTER_VALUE;
  searchQuery = '';
  lastDeviceFilterSignature = '';
  loading = true;
  failed = false;
  closingAll = false;
  monitoringPaused = false;
  monitoringPausedAt = null;
  serviceAvailability = 'loading';
  pendingConnectionsPayload = null;
  activeConnections.clear();
  closedConnections.clear();
  closingConnectionIds.clear();

  const searchInput = document.getElementById(
    'monitoring-search',
  ) as HTMLInputElement | null;
  if (searchInput) {
    searchInput.value = '';
  }
}

async function onPageMount() {
  onPageUnmount();

  monitoringMounted = true;
  monitoringMountId += 1;
  const mountId = monitoringMountId;

  resetMonitoringState();
  bindControls();
  renderControls();
  renderConnections();
  watchServiceState();

  void loadLocalDevices();
  void loadRouteDisplayNames();

  if (getCachedRuntimeUiState()) {
    void refreshRuntimeUiState({ force: true });
  } else {
    const uiState = await refreshRuntimeUiState({ force: true });

    if (!monitoringMounted || mountId !== monitoringMountId) {
      return;
    }

    if (!uiState && serviceAvailability === 'loading') {
      setServiceAvailability('unavailable');
    }
  }

  document.addEventListener('selectionchange', flushRenderAfterSelection);
  document.addEventListener('copy', handleMonitoringValueCopy);

  renderTimer = setInterval(() => {
    if (monitoringPaused) {
      return;
    }

    renderConnections();
  }, RENDER_INTERVAL_MS);
}

function onPageUnmount() {
  monitoringMounted = false;
  monitoringMountId += 1;

  if (renderTimer) {
    clearInterval(renderTimer);
    renderTimer = null;
  }

  stopConnectionsUpdates();
  serviceStateUnsubscribe?.();
  serviceStateUnsubscribe = null;

  document.removeEventListener('selectionchange', flushRenderAfterSelection);
  document.removeEventListener('copy', handleMonitoringValueCopy);
}

function registerLifecycleListeners() {
  if (monitoringLifecycleRegistered) {
    return;
  }

  monitoringLifecycleRegistered = true;

  store.subscribe(
    (next: StoreType, prev: StoreType, diff: Partial<StoreType>) => {
      if (
        diff.tabService &&
        next.tabService.current !== prev.tabService.current
      ) {
        const isMonitoringVisible = next.tabService.current === 'monitoring';

        if (isMonitoringVisible) {
          return onPageMount();
        }

        if (!isMonitoringVisible) {
          return onPageUnmount();
        }
      }
    },
  );
}

export async function initController(
  controllerDependencies: MonitoringControllerDependencies = {},
): Promise<void> {
  dependencies = {
    ...dependencies,
    ...controllerDependencies,
  };

  if (monitoringControllerInitialized) {
    return;
  }

  monitoringControllerInitialized = true;

  onMount('monitoring-status').then(() => {
    registerLifecycleListeners();

    if (store.get().tabService.current === 'monitoring') {
      onPageMount();
    }
  });
}
