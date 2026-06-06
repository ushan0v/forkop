import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { PodkopShellMethods } from '../index';

describe('PodkopShellMethods.subscriptionUpdate', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    mocks.executeShellCommand.mockReset();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('keeps waiting until the background subscription update job succeeds', async () => {
    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'subscription_update_async') {
        return Promise.resolve({
          stdout: JSON.stringify({
            success: true,
            job_id: 'job-1',
            message: 'Subscription update started',
          }),
          stderr: '',
          code: 0,
        });
      }

      if (args[0] === 'subscription_update_status') {
        return Promise.resolve({
          stdout: JSON.stringify({
            success: true,
            running: false,
            message: 'Subscription update completed',
            exit_code: 0,
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

    const responsePromise = PodkopShellMethods.subscriptionUpdate('main');

    await vi.advanceTimersByTimeAsync(1500);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: 'Subscription update completed',
    });
    expect(mocks.executeShellCommand).toHaveBeenNthCalledWith(1, {
      command: '/usr/bin/podkop-plus',
      args: ['subscription_update_async', 'main'],
      timeout: 15000,
    });
    expect(mocks.executeShellCommand).toHaveBeenNthCalledWith(2, {
      command: '/usr/bin/podkop-plus',
      args: ['subscription_update_status', 'job-1'],
      timeout: 15000,
    });
  });

  it('fails when the background job reports a failed subscription update', async () => {
    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'subscription_update_async') {
        return Promise.resolve({
          stdout: JSON.stringify({
            success: true,
            job_id: 'job-1',
            message: 'Subscription update started',
          }),
          stderr: '',
          code: 0,
        });
      }

      if (args[0] === 'subscription_update_status') {
        return Promise.resolve({
          stdout: JSON.stringify({
            success: false,
            running: false,
            message: 'Failed to download subscriptions',
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

    const responsePromise = PodkopShellMethods.subscriptionUpdate('main');

    await vi.advanceTimersByTimeAsync(1500);

    await expect(responsePromise).resolves.toEqual({
      success: false,
      error: 'Failed to download subscriptions',
    });
  });

  it('returns failed finished job state from the low-level waiter for UI restoration', async () => {
    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'subscription_update_status') {
        return Promise.resolve({
          stdout: JSON.stringify({
            success: false,
            running: false,
            message: 'Failed to download subscriptions',
            section: 'main',
            source_index: '',
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

    const responsePromise =
      PodkopShellMethods.waitSubscriptionUpdateJob('job-1');

    await vi.advanceTimersByTimeAsync(1500);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: {
        success: false,
        running: false,
        message: 'Failed to download subscriptions',
        section: 'main',
        source_index: '',
        exit_code: 1,
      },
    });
  });
});
