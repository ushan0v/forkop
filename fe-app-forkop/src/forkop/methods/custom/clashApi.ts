import { getConfigSections } from './getConfigSections';
import { ClashAPI, Forkop } from '../../types';
import {
  canUseDirectClashApi,
  getClashApiUrl,
} from '../../../helpers/getClashApiUrl';
import { ForkopShellMethods } from '../shell';
import { DEFAULT_LATENCY_TEST_URL } from '../../../constants';

type ClashConnectionsSnapshot = {
  downloadTotal?: number;
  uploadTotal?: number;
  connections?: unknown[];
};

type DirectClashApiOutcome =
  | { kind: 'response'; status: number; body: string }
  | { kind: 'timeout' }
  | { kind: 'unreachable' };

const CLASH_API_FETCH_TIMEOUT_MS = 5000;
const CLASH_API_MUTATION_TIMEOUT_MS = 15000;
// A ceiling, not a wait: the router answers once the last member is done, and members tested
// least recently go first, so pressing again continues a sweep that ran out.
const GROUP_LATENCY_TIMEOUT_MS = '40000';
// A test already dialing when the budget runs out ends only after its own five seconds, so the
// browser waits one extra test beyond the budget.
const GROUP_LATENCY_SWEEP_OVERSHOOT_MS = 5000;
// After one failed direct attempt requests go to the CLI transport, and a probe beside them
// notices within this interval when the controller is reachable again.
const DIRECT_CLASH_API_PROBE_INTERVAL_MS = 30000;
const DIRECT_CLASH_API_PROBE_TIMEOUT_MS = 2000;
let clashApiConfigSections: Forkop.ConfigSection[] = [];
let clashApiConfigSectionsPromise: Promise<Forkop.ConfigSection[]> | undefined;
let directClashApiSuspended = false;
let directClashApiReachable = false;
let directClashApiProbeAt = 0;
let directClashApiProbe: Promise<void> | undefined;

export function setClashApiConfigSections(sections: Forkop.ConfigSection[]) {
  clashApiConfigSections = sections;
}
function getSettingsSection(configSections: Forkop.ConfigSection[]) {
  return configSections.find((section) => section['.type'] === 'settings');
}

function getClashApiSecret(configSections: Forkop.ConfigSection[]) {
  return getSettingsSection(configSections)?.yacd_secret_key || '';
}

function canReachClashApiFromBrowser() {
  return canUseDirectClashApi() && typeof fetch === 'function';
}

function canFetchClashApiDirectly() {
  return !directClashApiSuspended && canReachClashApiFromBrowser();
}

function suspendDirectClashApi() {
  directClashApiSuspended = true;
  directClashApiReachable = false;
  directClashApiProbeAt = Date.now() + DIRECT_CLASH_API_PROBE_INTERVAL_MS;
}

// Opening a tab is when the core was most likely just started, so the next request probes.
export function resetClashApiTransport() {
  directClashApiProbeAt = 0;
}

function clashApiError(status: number, body: string) {
  // The Clash API reports failures as {"message": "..."}; that text is what the user reads.
  if (body) {
    try {
      const payload = JSON.parse(body);

      if (typeof payload?.message === 'string' && payload.message) {
        return payload.message;
      }
    } catch {
      // Not JSON, so the body is the message.
    }
  }

  return body || `Clash API returned HTTP ${status}`;
}

function parseClashApiPayload<T>(
  status: number,
  body: string,
): Forkop.MethodResponse<T> {
  if (!Number.isInteger(status) || status < 100 || status > 599) {
    return { success: false, error: _('Invalid Clash API response') };
  }

  if (status < 200 || status >= 300) {
    return { success: false, error: clashApiError(status, body), status };
  }

  if (!body) {
    return { success: true, data: undefined as T };
  }

  try {
    return { success: true, data: JSON.parse(body) as T };
  } catch (_error) {
    return { success: false, error: _('Invalid Clash API response') };
  }
}

async function ensureClashApiConfigSections() {
  if (clashApiConfigSections.length) {
    return clashApiConfigSections;
  }

  if (!clashApiConfigSectionsPromise) {
    clashApiConfigSectionsPromise = getConfigSections()
      .then((sections) => {
        clashApiConfigSections = sections;
        return sections;
      })
      .catch(() => [] as Forkop.ConfigSection[])
      .finally(() => {
        clashApiConfigSectionsPromise = undefined;
      });
  }

  return clashApiConfigSectionsPromise;
}

async function fetchClashApiDirectly(
  configSections: Forkop.ConfigSection[],
  path: string,
  init?: RequestInit,
  timeout?: number,
): Promise<DirectClashApiOutcome> {
  const secret = getClashApiSecret(configSections);
  const controller = timeout ? new AbortController() : undefined;
  const timeoutId = timeout
    ? setTimeout(() => controller?.abort(), timeout)
    : undefined;
  const headers: Record<string, string> = {
    ...(init?.headers as Record<string, string> | undefined),
  };

  if (secret) headers.Authorization = `Bearer ${secret}`;

  try {
    const response = await fetch(`${getClashApiUrl()}${path}`, {
      ...init,
      headers,
      signal: controller?.signal,
    });

    return {
      kind: 'response',
      status: response.status,
      body: response.status === 204 ? '' : await response.text(),
    };
  } catch (_error) {
    return { kind: controller?.signal.aborted ? 'timeout' : 'unreachable' };
  } finally {
    if (timeoutId) clearTimeout(timeoutId);
  }
}

async function fetchClashApiThroughCli<T>(
  method: string,
  path: string,
  body: string,
  summary = false,
): Promise<Forkop.MethodResponse<T>> {
  const response = summary
    ? await ForkopShellMethods.clashSummary()
    : await ForkopShellMethods.clashApi(method, path, body);

  if (!response.success) {
    return response;
  }

  return parseClashApiPayload<T>(
    response.data?.status ?? 0,
    response.data?.body || '',
  );
}

// Any answer proves the controller is reachable, even one refusing the secret.
function probeDirectClashApi() {
  if (directClashApiProbe) {
    return directClashApiProbe;
  }
  if (Date.now() < directClashApiProbeAt) {
    return Promise.resolve();
  }

  directClashApiProbeAt = Date.now() + DIRECT_CLASH_API_PROBE_INTERVAL_MS;
  directClashApiProbe = ensureClashApiConfigSections()
    .then((configSections) =>
      fetchClashApiDirectly(
        configSections,
        '/version',
        undefined,
        DIRECT_CLASH_API_PROBE_TIMEOUT_MS,
      ),
    )
    .then((outcome) => {
      if (outcome.kind === 'response') {
        directClashApiSuspended = false;
        directClashApiReachable = true;
        directClashApiProbeAt = 0;
      } else {
        suspendDirectClashApi();
      }
    })
    .catch(() => undefined)
    .finally(() => {
      directClashApiProbe = undefined;
    });
  return directClashApiProbe;
}

async function requestClashApi<T>(
  path: string,
  init?: RequestInit,
  timeout?: number,
  // Not retried after a timeout: the router keeps working on anything but a plain read, and a
  // second latency sweep would compete with the first for the same ten test slots.
  options?: { keepsRunningAfterTimeout?: boolean; summary?: boolean },
): Promise<Forkop.MethodResponse<T>> {
  const method = (init?.method || 'GET').toUpperCase();
  const body = typeof init?.body === 'string' ? init.body : '';
  const keepsRunning =
    options?.keepsRunningAfterTimeout ||
    (method !== 'GET' && method !== 'HEAD');

  if (keepsRunning && canFetchClashApiDirectly() && !directClashApiReachable) {
    await probeDirectClashApi();
  }

  if (canFetchClashApiDirectly()) {
    const outcome = await fetchClashApiDirectly(
      await ensureClashApiConfigSections(),
      path,
      init,
      timeout,
    );

    if (outcome.kind === 'response') {
      directClashApiSuspended = false;
      directClashApiReachable = true;
      directClashApiProbeAt = 0;
      const response = parseClashApiPayload<T>(outcome.status, outcome.body);
      return options?.summary && response.success
        ? {
            success: true,
            data: summarizeConnections(
              response.data as ClashConnectionsSnapshot,
            ) as T,
          }
        : response;
    }

    // A late answer and no answer spent the same budget before the CLI got its turn.
    suspendDirectClashApi();

    if (keepsRunning) {
      return {
        success: false,
        error:
          outcome.kind === 'timeout'
            ? _('Clash API request timed out after it was sent')
            : _('Clash API response was lost after the request was sent'),
      };
    }
  } else if (canReachClashApiFromBrowser()) {
    void probeDirectClashApi();
  }

  return fetchClashApiThroughCli<T>(method, path, body, options?.summary);
}

function getLatencyTestUrl() {
  return (
    getSettingsSection(clashApiConfigSections)?.latency_test_url ||
    DEFAULT_LATENCY_TEST_URL
  );
}

function latencyRequestTimeout(timeout: string, overshoot = 0) {
  return (
    (Number.parseInt(timeout, 10) || CLASH_API_FETCH_TIMEOUT_MS) +
    overshoot +
    CLASH_API_FETCH_TIMEOUT_MS
  );
}

export async function getClashApiProxyLatency(tag: string, timeout = '5000') {
  await ensureClashApiConfigSections();
  const params = new URLSearchParams({
    url: getLatencyTestUrl(),
    timeout,
  });

  return requestClashApi<Forkop.GetClashApiProxyLatency>(
    `/proxies/${encodeURIComponent(tag)}/delay?${params}`,
    undefined,
    latencyRequestTimeout(timeout),
    { keepsRunningAfterTimeout: true },
  );
}

export async function getClashApiGroupLatency(
  tag: string,
  timeout = GROUP_LATENCY_TIMEOUT_MS,
) {
  await ensureClashApiConfigSections();
  const params = new URLSearchParams({
    url: getLatencyTestUrl(),
    timeout,
  });

  return requestClashApi<Forkop.GetClashApiGroupLatency>(
    `/group/${encodeURIComponent(tag)}/delay?${params}`,
    undefined,
    latencyRequestTimeout(timeout, GROUP_LATENCY_SWEEP_OVERSHOOT_MS),
    { keepsRunningAfterTimeout: true },
  );
}

export function setClashApiGroupProxy(group: string, proxy: string) {
  return requestClashApi<undefined>(
    `/proxies/${encodeURIComponent(group)}`,
    {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: proxy }),
    },
    CLASH_API_MUTATION_TIMEOUT_MS,
  );
}

// Both address families are asked at once, so a family that never answers holds the reply for
// the whole timeout.
const EXIT_LOOKUP_TIMEOUT_MS = '5000';

export function getClashApiProxyExit(tag: string) {
  return requestClashApi<Forkop.GetClashApiProxyExit>(
    `/proxies/${encodeURIComponent(tag)}/exit?timeout=${EXIT_LOOKUP_TIMEOUT_MS}`,
    undefined,
    latencyRequestTimeout(EXIT_LOOKUP_TIMEOUT_MS),
    { keepsRunningAfterTimeout: true },
  );
}

export function getClashApiProxyLink(tag: string) {
  return requestClashApi<Forkop.GetClashApiProxyLink>(
    `/proxies/${encodeURIComponent(tag)}/link`,
    undefined,
    CLASH_API_FETCH_TIMEOUT_MS,
  );
}

export async function updateClashApiProxyProviders(providerTags: string[]) {
  const responses = await Promise.all(
    providerTags.map((tag) =>
      requestClashApi<undefined>(
        `/providers/proxies/${encodeURIComponent(tag)}`,
        { method: 'PUT' },
        CLASH_API_MUTATION_TIMEOUT_MS,
      ),
    ),
  );

  return (
    responses.find((response) => !response.success) || {
      success: true as const,
      data: undefined,
    }
  );
}

// Refreshing rule sets downloads files, so it takes the router-side transport's ceiling.
const CLASH_API_RULE_SET_UPDATE_TIMEOUT_MS = 60000;

// Refreshes every remote rule set the runtime holds, including sections the dashboard hides.
export function updateClashApiRuleProviders() {
  return requestClashApi<undefined>(
    '/providers/rules',
    { method: 'PUT' },
    CLASH_API_RULE_SET_UPDATE_TIMEOUT_MS,
  );
}

export function getClashApiProxies() {
  return requestClashApi<ClashAPI.Proxies>(
    '/proxies',
    undefined,
    CLASH_API_FETCH_TIMEOUT_MS,
  );
}

export function getClashApiTailscale() {
  return requestClashApi<ClashAPI.Tailscale>(
    '/tailscale',
    undefined,
    CLASH_API_FETCH_TIMEOUT_MS,
  );
}

const TAILSCALE_PING_TIMEOUT_MS = '5000';

export function pingClashApiTailscalePeer(tag: string, address: string) {
  const params = new URLSearchParams({
    address,
    timeout: TAILSCALE_PING_TIMEOUT_MS,
  });

  return requestClashApi<ClashAPI.TailscalePong>(
    `/tailscale/${encodeURIComponent(tag)}/ping?${params}`,
    undefined,
    latencyRequestTimeout(TAILSCALE_PING_TIMEOUT_MS),
    { keepsRunningAfterTimeout: true },
  );
}

export function getClashApiProxyProviders() {
  return requestClashApi<ClashAPI.ProxyProviders>(
    '/providers/proxies',
    undefined,
    CLASH_API_FETCH_TIMEOUT_MS,
  );
}

export function getClashApiConnections() {
  return requestClashApi<unknown>(
    '/connections',
    undefined,
    CLASH_API_FETCH_TIMEOUT_MS,
  );
}

function summarizeConnections(
  snapshot: ClashConnectionsSnapshot | undefined,
): Forkop.ClashConnectionsSummary {
  return {
    downloadTotal: snapshot?.downloadTotal || 0,
    uploadTotal: snapshot?.uploadTotal || 0,
    connections: snapshot?.connections?.length || 0,
  };
}

// The full snapshot through ubus could exceed rpcd's limit of about 256 KB, so without a direct
// path the router is asked for the three numbers.
export async function getClashApiConnectionsSummary(): Promise<
  Forkop.MethodResponse<Forkop.ClashConnectionsSummary>
> {
  return requestClashApi<Forkop.ClashConnectionsSummary>(
    '/connections',
    undefined,
    CLASH_API_FETCH_TIMEOUT_MS,
    { summary: true },
  );
}

export function closeClashApiConnection(connectionId: string) {
  return requestClashApi<undefined>(
    `/connections/${encodeURIComponent(connectionId)}`,
    { method: 'DELETE' },
    CLASH_API_MUTATION_TIMEOUT_MS,
  );
}

export function closeAllClashApiConnections() {
  return requestClashApi<undefined>(
    '/connections',
    { method: 'DELETE' },
    CLASH_API_MUTATION_TIMEOUT_MS,
  );
}

export function startClashApiBandwidthTest(tag: string) {
  return requestClashApi<ClashAPI.BandwidthStatus>(
    `/proxies/${encodeURIComponent(tag)}/bandwidth`,
    { method: 'POST' },
    CLASH_API_MUTATION_TIMEOUT_MS,
  );
}
