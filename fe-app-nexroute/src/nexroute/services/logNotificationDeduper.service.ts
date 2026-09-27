const LOG_NOTIFICATION_STORAGE_KEY = 'forkop:shown-log-error-notifications:v1';
const MAX_STORED_LOG_NOTIFICATIONS = 500;

export type ForkopLogNotification =
  | { kind: 'error'; line: string }
  | {
      kind: 'component-update';
      line: string;
      component: string;
      version: string;
    };

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

function readStoredKeys(storage: Storage | null): string[] {
  if (!storage) {
    return [];
  }

  try {
    const parsed = JSON.parse(
      storage.getItem(LOG_NOTIFICATION_STORAGE_KEY) || '[]',
    );

    return Array.isArray(parsed)
      ? parsed.filter((item): item is string => typeof item === 'string')
      : [];
  } catch {
    return [];
  }
}

function writeStoredKeys(storage: Storage | null, keys: string[]) {
  if (!storage) {
    return;
  }

  try {
    storage.setItem(
      LOG_NOTIFICATION_STORAGE_KEY,
      JSON.stringify(keys.slice(-MAX_STORED_LOG_NOTIFICATIONS)),
    );
  } catch {
    // Notifications are still deduped in-memory when sessionStorage is blocked.
  }
}

export function isErrorLogLine(line: string) {
  const lower = line.toLowerCase();
  return (
    lower.includes('[error]') ||
    lower.includes('[fatal]') ||
    (lower.includes('sing-box') &&
      lower.includes('rule-set') &&
      /\b(error|fatal)\b/.test(lower))
  );
}

export function getForkopLogNotification(
  line: string,
): ForkopLogNotification | null {
  if (isErrorLogLine(line)) {
    return { kind: 'error', line };
  }

  const update = line.match(
    /\[component-update\]\s+(forkop|sing_box|zapret|zapret2|byedpi)\s+(\S+)/i,
  );

  if (!update) {
    return null;
  }

  return {
    kind: 'component-update',
    line,
    component: update[1].toLowerCase(),
    version: update[2],
  };
}

export function getLogNotificationKey(line: string) {
  return line.trim();
}

export class LogNotificationDeduper {
  private readonly storage: Storage | null;
  private readonly seenKeys: Set<string>;

  constructor(storage: Storage | null = getSessionStorage()) {
    this.storage = storage;
    this.seenKeys = new Set(readStoredKeys(storage));
  }

  shouldNotify(line: string) {
    if (!getForkopLogNotification(line)) {
      return false;
    }

    const key = getLogNotificationKey(line);

    if (!key || this.seenKeys.has(key)) {
      return false;
    }

    this.seenKeys.add(key);
    writeStoredKeys(this.storage, Array.from(this.seenKeys));
    return true;
  }
}
