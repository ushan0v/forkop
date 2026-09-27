import { describe, expect, it } from 'vitest';

import {
  getLogNotificationKey,
  getForkopLogNotification,
  isErrorLogLine,
  LogNotificationDeduper,
} from '../logNotificationDeduper.service';

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

describe('LogNotificationDeduper', () => {
  it('accepts error, fatal, and component update log lines', () => {
    expect(isErrorLogLine('forkop: [info] ok')).toBe(false);
    expect(isErrorLogLine('forkop: [error] failed')).toBe(true);
    expect(isErrorLogLine('forkop: [fatal] failed')).toBe(true);
    expect(
      isErrorLogLine(
        'daemon.err sing-box[123]: FATAL[0000] start service: initialize rule-set[0]: download failed',
      ),
    ).toBe(true);
    expect(
      isErrorLogLine(
        'daemon.err sing-box[123]: ERROR[0000] connection: dial failed',
      ),
    ).toBe(false);
    expect(
      getForkopLogNotification(
        'forkop: [info] [component-update] zapret2 v1.2.3',
      ),
    ).toEqual({
      kind: 'component-update',
      line: 'forkop: [info] [component-update] zapret2 v1.2.3',
      component: 'zapret2',
      version: 'v1.2.3',
    });
    expect(getForkopLogNotification('forkop: [info] ok')).toBeNull();
  });

  it('dedupes already shown log lines through session storage', () => {
    const storage = new MemoryStorage();
    const first = new LogNotificationDeduper(storage);

    expect(first.shouldNotify('forkop: [error] failed')).toBe(true);
    expect(first.shouldNotify('forkop: [error] failed')).toBe(false);
    expect(first.shouldNotify('forkop: [error] another failure')).toBe(true);
    expect(
      first.shouldNotify('forkop: [info] [component-update] forkop 1.2.3'),
    ).toBe(true);

    const afterReload = new LogNotificationDeduper(storage);

    expect(afterReload.shouldNotify('forkop: [error] failed')).toBe(false);
    expect(afterReload.shouldNotify('forkop: [fatal] fatal failure')).toBe(
      true,
    );
  });

  it('keeps the full log line as the replay key', () => {
    expect(getLogNotificationKey('  Jun 06 forkop: [error] failed  ')).toBe(
      'Jun 06 forkop: [error] failed',
    );
  });
});
