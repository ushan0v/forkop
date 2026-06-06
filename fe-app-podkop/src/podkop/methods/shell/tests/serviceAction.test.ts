import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { PodkopShellMethods } from '../index';

describe('PodkopShellMethods.serviceAction', () => {
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

    const responsePromise = PodkopShellMethods.waitServiceActionJob('job-1');

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

  it('preserves the public failure contract for failed service actions', async () => {
    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'service_action_async') {
        return Promise.resolve({
          stdout: JSON.stringify({
            success: true,
            job_id: 'job-1',
            message: 'Service restart started',
          }),
          stderr: '',
          code: 0,
        });
      }

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

    const responsePromise = PodkopShellMethods.serviceAction('restart');

    await vi.advanceTimersByTimeAsync(1000);

    await expect(responsePromise).resolves.toEqual({
      success: false,
      error: 'Service restart failed',
    });
  });
});
