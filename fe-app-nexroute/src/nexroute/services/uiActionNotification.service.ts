const UI_ACTION_NOTIFICATION_STORAGE_KEY =
  'forkop:owned-ui-action-notifications:v1';
const MAX_STORED_UI_ACTION_NOTIFICATIONS = 100;

export type UiActionNotificationKind = 'component' | 'subscription';

interface StoredUiActionNotification {
  kind: UiActionNotificationKind;
  jobId: string;
  notified: boolean;
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

function getNotificationKey(kind: UiActionNotificationKind, jobId: string) {
  return `${kind}:${jobId}`;
}

function isStoredNotification(
  value: unknown,
): value is StoredUiActionNotification {
  if (!value || typeof value !== 'object') {
    return false;
  }

  const candidate = value as Partial<StoredUiActionNotification>;

  return (
    (candidate.kind === 'component' || candidate.kind === 'subscription') &&
    typeof candidate.jobId === 'string' &&
    typeof candidate.notified === 'boolean' &&
    typeof candidate.updatedAt === 'number'
  );
}

function readStoredNotifications(
  storage: Storage | null,
): StoredUiActionNotification[] {
  if (!storage) {
    return [];
  }

  try {
    const parsed = JSON.parse(
      storage.getItem(UI_ACTION_NOTIFICATION_STORAGE_KEY) || '[]',
    );

    return Array.isArray(parsed) ? parsed.filter(isStoredNotification) : [];
  } catch {
    return [];
  }
}

function writeStoredNotifications(
  storage: Storage | null,
  notifications: StoredUiActionNotification[],
) {
  if (!storage) {
    return;
  }

  try {
    storage.setItem(
      UI_ACTION_NOTIFICATION_STORAGE_KEY,
      JSON.stringify(
        notifications
          .sort((a, b) => a.updatedAt - b.updatedAt)
          .slice(-MAX_STORED_UI_ACTION_NOTIFICATIONS),
      ),
    );
  } catch {
    // In-memory ownership still prevents duplicate notifications this session.
  }
}

export class UiActionNotificationTracker {
  private readonly storage: Storage | null;
  private readonly notifications = new Map<
    string,
    StoredUiActionNotification
  >();

  constructor(storage: Storage | null = getSessionStorage()) {
    this.storage = storage;

    for (const notification of readStoredNotifications(storage)) {
      this.notifications.set(
        getNotificationKey(notification.kind, notification.jobId),
        notification,
      );
    }
  }

  markOwned(kind: UiActionNotificationKind, jobId: string) {
    if (!jobId) {
      return;
    }

    const key = getNotificationKey(kind, jobId);
    const current = this.notifications.get(key);

    this.notifications.set(key, {
      kind,
      jobId,
      notified: current?.notified ?? false,
      updatedAt: Date.now(),
    });
    this.persist();
  }

  shouldNotify(kind: UiActionNotificationKind, jobId: string) {
    if (!jobId) {
      return false;
    }

    const key = getNotificationKey(kind, jobId);
    const current = this.notifications.get(key);

    if (!current || current.notified) {
      return false;
    }

    this.notifications.set(key, {
      ...current,
      notified: true,
      updatedAt: Date.now(),
    });
    this.persist();
    return true;
  }

  private persist() {
    writeStoredNotifications(
      this.storage,
      Array.from(this.notifications.values()),
    );
  }
}

const uiActionNotifications = new UiActionNotificationTracker();

export function markUiActionOwned(
  kind: UiActionNotificationKind,
  jobId: string,
) {
  uiActionNotifications.markOwned(kind, jobId);
}

export function shouldNotifyOwnedUiAction(
  kind: UiActionNotificationKind,
  jobId: string,
) {
  return uiActionNotifications.shouldNotify(kind, jobId);
}
