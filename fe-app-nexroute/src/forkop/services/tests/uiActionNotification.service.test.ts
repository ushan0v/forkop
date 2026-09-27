import { describe, expect, it } from 'vitest';

import { UiActionNotificationTracker } from '../uiActionNotification.service';

class MemoryStorage implements Storage {
  private values = new Map<string, string>();

  get length() {
    return this.values.size;
  }

  clear() {
    this.values.clear();
  }

  getItem(key: string) {
    return this.values.get(key) ?? null;
  }

  key(index: number) {
    return Array.from(this.values.keys())[index] ?? null;
  }

  removeItem(key: string) {
    this.values.delete(key);
  }

  setItem(key: string, value: string) {
    this.values.set(key, value);
  }
}

describe('UiActionNotificationTracker', () => {
  it('does not notify jobs that were not started by this UI session', () => {
    const tracker = new UiActionNotificationTracker(new MemoryStorage());

    expect(tracker.shouldNotify('component', 'component-1')).toBe(false);
  });

  it('notifies an owned job exactly once', () => {
    const tracker = new UiActionNotificationTracker(new MemoryStorage());

    tracker.markOwned('subscription', 'subscription-1');

    expect(tracker.shouldNotify('subscription', 'subscription-1')).toBe(true);
    expect(tracker.shouldNotify('subscription', 'subscription-1')).toBe(false);
  });

  it('keeps ownership and notification state across reloads', () => {
    const storage = new MemoryStorage();
    const beforeReload = new UiActionNotificationTracker(storage);

    beforeReload.markOwned('component', 'component-1');

    const afterReload = new UiActionNotificationTracker(storage);

    expect(afterReload.shouldNotify('component', 'component-1')).toBe(true);

    const afterNotification = new UiActionNotificationTracker(storage);

    expect(afterNotification.shouldNotify('component', 'component-1')).toBe(
      false,
    );
  });
});
