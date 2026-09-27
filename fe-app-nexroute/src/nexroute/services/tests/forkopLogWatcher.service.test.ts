import { beforeEach, describe, expect, it } from 'vitest';

import { ForkopLogWatcher } from '../forkopLogWatcher.service';

describe('ForkopLogWatcher', () => {
  const watcher = ForkopLogWatcher.getInstance();
  let rawLogs = '';
  let seenLines: string[] = [];

  beforeEach(() => {
    watcher.stop();
    watcher.reset();
    rawLogs = '';
    seenLines = [];
  });

  it('emits the initial logread snapshot', async () => {
    watcher.init(() => rawLogs, {
      onNewLog: (line) => seenLines.push(line),
    });

    rawLogs = 'old info\nold error';
    await watcher.checkOnce();

    expect(seenLines).toEqual(['old info', 'old error']);
  });

  it('does not emit the same log line twice', async () => {
    watcher.init(() => rawLogs, {
      onNewLog: (line) => seenLines.push(line),
    });

    rawLogs = 'line 1\nline 2';
    await watcher.checkOnce();
    await watcher.checkOnce();

    rawLogs = 'line 1\nline 2\nline 3';
    await watcher.checkOnce();

    expect(seenLines).toEqual(['line 1', 'line 2', 'line 3']);
  });

  it('forgets old tracked lines only after the tracked window is exceeded', async () => {
    watcher.init(() => rawLogs, {
      maxTrackedLines: 3,
      onNewLog: (line) => seenLines.push(line),
    });

    rawLogs = 'line 1\nline 2\nline 3';
    await watcher.checkOnce();

    rawLogs = 'line 1\nline 2\nline 3\nline 4';
    await watcher.checkOnce();

    rawLogs = 'line 1\nline 2\nline 3\nline 4\nline 5';
    await watcher.checkOnce();

    expect(seenLines).toEqual([
      'line 1',
      'line 2',
      'line 3',
      'line 4',
      'line 5',
    ]);
  });
});
