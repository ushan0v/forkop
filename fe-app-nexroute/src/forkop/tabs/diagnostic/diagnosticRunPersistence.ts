import type { StoreType } from '../../services';
import type { DiagnosticsProviderOptions } from './diagnostic.store';
import { DIAGNOSTICS_CHECKS } from './checks/contstants';

const DIAGNOSTIC_RUN_STORAGE_KEY = 'forkop:diagnostic-run:v1';
const DIAGNOSTIC_RUN_TTL_MS = 30 * 60 * 1000;
const CHECK_STATES = ['loading', 'warning', 'success', 'error', 'skipped'];
const CHECK_ITEM_STATES = ['error', 'warning', 'success'];

export interface PersistedDiagnosticRun {
  nextRunnerIndex: number;
  providerOptions: DiagnosticsProviderOptions;
  diagnosticsChecks: StoreType['diagnosticsChecks'];
  updatedAt: number;
}

function getSessionStorage(): Storage | null {
  if (typeof window === 'undefined') {
    return null;
  }

  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object';
}

function isOptionalBoolean(value: unknown) {
  return value === undefined || typeof value === 'boolean';
}

function isDiagnosticsProviderOptions(
  value: unknown,
): value is DiagnosticsProviderOptions {
  if (!isRecord(value)) {
    return false;
  }

  return (
    isOptionalBoolean(value.includeZapret) &&
    isOptionalBoolean(value.includeZapret2) &&
    isOptionalBoolean(value.includeByedpi) &&
    isOptionalBoolean(value.includeInbounds)
  );
}

function isDiagnosticCheckItem(value: unknown) {
  return (
    isRecord(value) &&
    CHECK_ITEM_STATES.includes(String(value.state)) &&
    typeof value.key === 'string' &&
    typeof value.value === 'string'
  );
}

function isDiagnosticCheck(value: unknown) {
  return (
    isRecord(value) &&
    Number.isFinite(value.order) &&
    Object.values(DIAGNOSTICS_CHECKS).includes(
      value.code as DIAGNOSTICS_CHECKS,
    ) &&
    typeof value.title === 'string' &&
    typeof value.description === 'string' &&
    CHECK_STATES.includes(String(value.state)) &&
    Array.isArray(value.items) &&
    value.items.every(isDiagnosticCheckItem)
  );
}

function isPersistedDiagnosticRun(
  value: unknown,
): value is PersistedDiagnosticRun {
  if (!isRecord(value)) {
    return false;
  }

  return (
    typeof value.nextRunnerIndex === 'number' &&
    Number.isInteger(value.nextRunnerIndex) &&
    value.nextRunnerIndex >= 0 &&
    isDiagnosticsProviderOptions(value.providerOptions) &&
    Array.isArray(value.diagnosticsChecks) &&
    value.diagnosticsChecks.every(isDiagnosticCheck) &&
    Number.isFinite(value.updatedAt)
  );
}

function isExpired(run: PersistedDiagnosticRun, now = Date.now()) {
  return now - run.updatedAt > DIAGNOSTIC_RUN_TTL_MS;
}

export function readPersistedDiagnosticRun(
  storage: Storage | null = getSessionStorage(),
): PersistedDiagnosticRun | null {
  if (!storage) {
    return null;
  }

  try {
    const parsed = JSON.parse(
      storage.getItem(DIAGNOSTIC_RUN_STORAGE_KEY) || 'null',
    );

    if (!isPersistedDiagnosticRun(parsed) || isExpired(parsed)) {
      storage.removeItem(DIAGNOSTIC_RUN_STORAGE_KEY);
      return null;
    }

    return parsed;
  } catch {
    storage.removeItem(DIAGNOSTIC_RUN_STORAGE_KEY);
    return null;
  }
}

export function savePersistedDiagnosticRun(
  run: Omit<PersistedDiagnosticRun, 'updatedAt'>,
  storage: Storage | null = getSessionStorage(),
) {
  if (!storage) {
    return;
  }

  try {
    storage.setItem(
      DIAGNOSTIC_RUN_STORAGE_KEY,
      JSON.stringify({
        ...run,
        updatedAt: Date.now(),
      }),
    );
  } catch {
    // Diagnostics still runs normally; persistence is only for reload recovery.
  }
}

export function clearPersistedDiagnosticRun(
  storage: Storage | null = getSessionStorage(),
) {
  if (!storage) {
    return;
  }

  try {
    storage.removeItem(DIAGNOSTIC_RUN_STORAGE_KEY);
  } catch {
    // Ignore storage failures.
  }
}
