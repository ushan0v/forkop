import { TabServiceInstance } from './tab.service';
import { store } from './store.service';
import { logger } from './logger.service';
import { PodkopLogWatcher } from './podkopLogWatcher.service';
import { PodkopShellMethods } from '../methods';

const LOG_NOTIFICATION_DEDUPE_WINDOW_MS = 15000;
const recentErrorNotifications = new Map<string, number>();
const activeErrorNotifications = new Map<string, HTMLElement>();

type CoreServiceOptions = {
  waitForLogWatcherStart?: () => Promise<unknown>;
  logWatcherStartDelayMs?: number;
};

function isErrorLogLine(line: string) {
  const lower = line.toLowerCase();
  return lower.includes('[error]') || lower.includes('[fatal]');
}

function isLogLifecycleBoundary(line: string) {
  const lower = line.toLowerCase();
  return (
    lower.includes('[info] starting podkop plus') ||
    lower.includes('[info] stopping podkop plus') ||
    lower.includes('[info] podkop plus reload') ||
    lower.includes('[info] podkop plus restart')
  );
}

function getNotificationKey(line: string) {
  const lower = line.toLowerCase();
  const errorIndex = lower.indexOf('[error]');
  const fatalIndex = lower.indexOf('[fatal]');
  const markerIndex =
    errorIndex >= 0 && fatalIndex >= 0
      ? Math.min(errorIndex, fatalIndex)
      : Math.max(errorIndex, fatalIndex);

  return (markerIndex >= 0 ? line.slice(markerIndex) : line).trim();
}

function shouldNotifyAboutLogLine(line: string) {
  const key = getNotificationKey(line);
  const now = Date.now();
  const lastShownAt = recentErrorNotifications.get(key) ?? 0;

  recentErrorNotifications.forEach((shownAt, storedKey) => {
    if (now - shownAt > LOG_NOTIFICATION_DEDUPE_WINDOW_MS) {
      recentErrorNotifications.delete(storedKey);
    }
  });

  if (now - lastShownAt < LOG_NOTIFICATION_DEDUPE_WINDOW_MS) {
    return false;
  }

  recentErrorNotifications.set(key, now);
  return true;
}

function removeNotification(notification: HTMLElement) {
  if (!notification.parentNode) {
    return;
  }

  notification.classList.add('fade-out');
  notification.classList.remove('fade-in');
  setTimeout(() => notification.remove(), 500);
}

function clearLogErrorNotifications() {
  activeErrorNotifications.forEach(removeNotification);
  activeErrorNotifications.clear();
  recentErrorNotifications.clear();
}

function showLogErrorNotification(line: string) {
  const key = getNotificationKey(line);
  const existingNotification = activeErrorNotifications.get(key);

  if (existingNotification) {
    removeNotification(existingNotification);
  }

  const notification = ui.addNotification(
    _('Podkop Plus Error'),
    E('div', {}, line),
    'error',
    'pdk-log-error-notification',
  );

  activeErrorNotifications.set(key, notification);
}

export function coreService(options: CoreServiceOptions = {}) {
  TabServiceInstance.onChange((activeId, tabs) => {
    logger.info('[TAB]', activeId);
    store.set({
      tabService: {
        current: activeId || '',
        all: tabs.map((tab) => tab.id),
      },
    });
  });

  const watcher = PodkopLogWatcher.getInstance();

  watcher.init(
    async () => {
      const logs = await PodkopShellMethods.checkLogs();

      if (logs.success) {
        return logs.data as string;
      }

      return '';
    },
    {
      intervalMs: 3000,
      suppressInitialLogs: true,
      onNewLog: (line) => {
        if (isLogLifecycleBoundary(line)) {
          clearLogErrorNotifications();
        }

        if (isErrorLogLine(line) && shouldNotifyAboutLogLine(line)) {
          showLogErrorNotification(line);
        }
      },
    },
  );

  const startWatcher = () => watcher.start();

  if (typeof window !== 'undefined') {
    window.setTimeout(() => {
      if (options.waitForLogWatcherStart) {
        Promise.resolve()
          .then(() => options.waitForLogWatcherStart?.())
          .catch(() => null)
          .finally(() =>
            window.setTimeout(startWatcher, options.logWatcherStartDelayMs ?? 0),
          );
        return;
      }

      startWatcher();
    }, 0);
  } else {
    startWatcher();
  }
}
