import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { ForkopShellMethods } from '../index';

describe('ForkopShellMethods.serviceAction', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    mocks.executeShellCommand.mockReset();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('keeps failed finished service state available to low-level waiters', async () => {
    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'service_action_status') {
        return Promise.resolve({
          stdout: JSON.stringify({
            success: false,
            running: false,
            kind: 'service',
            action: 'restart',
            message: 'Service restart failed',
            exit_code: 1,
          }),
          stderr: '',
          code: 0,
        });
      }

      return Promise.resolve({
        stdout: '',
        stderr: 'Unexpected command',
        code: 1,
      });
    });

    const responsePromise = ForkopShellMethods.waitServiceActionJob('job-1');

    await vi.advanceTimersByTimeAsync(1000);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: {
        success: false,
        running: false,
        kind: 'service',
        action: 'restart',
        message: 'Service restart failed',
        exit_code: 1,
      },
    });
  });

  it('returns the backend service action start error message', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify({
        success: false,
        message: 'Another service action is already running',
      }),
      stderr: '',
      code: 1,
    });

    await expect(
      ForkopShellMethods.serviceActionStart('restart'),
    ).resolves.toEqual({
      success: false,
      error: 'Another service action is already running',
    });
  });
});
