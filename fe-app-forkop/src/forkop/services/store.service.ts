import { Forkop } from '../types';
import { initialDiagnosticStore } from '../tabs/diagnostic/diagnostic.store';

function jsonStableStringify<T, V>(obj: T): string {
  return JSON.stringify(obj, (_, value) => {
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      return Object.keys(value)
        .sort()
        .reduce(
          (acc, key) => {
            acc[key] = value[key];
            return acc;
          },
          {} as Record<string, V>,
        );
    }
    return value;
  });
}

function jsonEqual<A, B>(a: A, b: B): boolean {
  try {
    return jsonStableStringify(a) === jsonStableStringify(b);
  } catch {
    return false;
  }
}

type Listener<T> = (next: T, prev: T, diff: Partial<T>) => void;

// eslint-disable-next-line
export class StoreService<T extends Record<string, any>> {
  private value: T;
  private readonly initial: T;
  private listeners = new Set<Listener<T>>();

  constructor(initial: T) {
    this.value = initial;
    this.initial = structuredClone(initial);
  }

  get(): T {
    return this.value;
  }

  set(next: Partial<T>): void {
    const prev = this.value;
    const diff: Partial<T> = {};

    for (const key in next) {
      if (!jsonEqual(next[key], prev[key])) diff[key] = next[key];
    }

    if (Object.keys(diff).length === 0) {
      return;
    }

    const merged = { ...prev, ...next };
    this.value = merged;
    this.listeners.forEach((cb) => cb(this.value, prev, diff));
  }

  reset<K extends keyof T>(keys?: K[]): void {
    const prev = this.value;
    const next = structuredClone(this.value);

    if (keys && keys.length > 0) {
      keys.forEach((key) => {
        next[key] = structuredClone(this.initial[key]);
      });
    } else {
      Object.assign(next, structuredClone(this.initial));
    }

    if (jsonEqual(prev, next)) return;

    this.value = next;

    const diff: Partial<T> = {};
    for (const key in next) {
      if (!jsonEqual(next[key], prev[key])) diff[key] = next[key];
    }

    this.listeners.forEach((cb) => cb(this.value, prev, diff));
  }

  subscribe(cb: Listener<T>): () => void {
    this.listeners.add(cb);
    cb(this.value, this.value, {});
    return () => this.listeners.delete(cb);
  }

  unsubscribe(cb: Listener<T>): void {
    this.listeners.delete(cb);
  }

  subscribeKey<K extends keyof T>(
    key: K,
    cb: (value: T[K]) => void,
  ): () => void {
    let prev = this.value[key];
    const wrapper: Listener<T> = (val) => {
      if (!jsonEqual(val[key], prev)) {
        prev = val[key];
        cb(val[key]);
      }
    };
    this.listeners.add(wrapper);
    return () => this.listeners.delete(wrapper);
  }
}

export interface IDiagnosticsChecksItem {
  state: 'error' | 'warning' | 'success';
  key: string;
  value: string;
}

export interface IDiagnosticsChecksStoreItem {
  order: number;
  code: string;
  title: string;
  description: string;
  state: 'loading' | 'warning' | 'success' | 'error' | 'skipped';
  items: Array<IDiagnosticsChecksItem>;
}

export interface StoreType {
  tabService: {
    current: string;
    all: string[];
  };
  bandwidthWidget: {
    loading: boolean;
    failed: boolean;
    data: { up: number; down: number };
  };
  trafficTotalWidget: {
    loading: boolean;
    failed: boolean;
    data: { downloadTotal: number; uploadTotal: number };
  };
  connectionsWidget: {
    loading: boolean;
    failed: boolean;
    data: { connections: number };
  };
  // The load needs two readings, so it is null after the first; the start is a moment on this
  // browser's clock.
  coreUsageWidget: {
    loading: boolean;
    failed: boolean;
    data: { cpu: number | null; memory: number; startedAt: number };
  };
  serviceState: {
    loading: boolean;
    failed: boolean;
    data: {
      singbox: number;
      forkopRunning: number;
      forkopEnabled: number;
      forkopBusy: Forkop.ServiceBusy | null;
    };
  };
  sectionsWidget: {
    loading: boolean;
    failed: boolean;
    data: Forkop.OutboundGroup[];
    servers: Forkop.DashboardServer[];
    hasRemoteLists: boolean;
  };
  diagnosticsRunAction: {
    loading: boolean;
    // What the last finished run found, which a report is built from, until
    // the result goes stale.
    finished: { service?: Forkop.ServiceCheckResult } | null;
  };
  diagnosticsChecks: Array<IDiagnosticsChecksStoreItem>;
  diagnosticsActions: {
    restart: { loading: boolean };
    start: { loading: boolean };
    stop: { loading: boolean };
    enable: { loading: boolean };
    disable: { loading: boolean };
    report: { loading: boolean };
  };
  diagnosticsSystemInfo: {
    loading: boolean;
    loaded: boolean;
    capabilitiesLoaded: boolean;
    forkop_version: string;
    luci_app_version: string;
    sing_box_version: string;
    sing_box_variant: string;
    server_inbounds_enabled_count: number;
    sections_enabled_count: number;
    openwrt_version: string;
    device_model: string;
  };
}

const initialStore: StoreType = {
  tabService: {
    current: '',
    all: [],
  },
  bandwidthWidget: {
    loading: true,
    failed: false,
    data: { up: 0, down: 0 },
  },
  trafficTotalWidget: {
    loading: true,
    failed: false,
    data: { downloadTotal: 0, uploadTotal: 0 },
  },
  connectionsWidget: {
    loading: true,
    failed: false,
    data: { connections: 0 },
  },
  coreUsageWidget: {
    loading: true,
    failed: false,
    data: { cpu: null, memory: 0, startedAt: 0 },
  },
  serviceState: {
    loading: true,
    failed: false,
    data: {
      singbox: 0,
      forkopRunning: 0,
      forkopEnabled: 0,
      forkopBusy: null,
    },
  },
  sectionsWidget: {
    loading: true,
    failed: false,
    data: [],
    servers: [],
    hasRemoteLists: false,
  },
  ...initialDiagnosticStore,
};

export const store = new StoreService<StoreType>(initialStore);
