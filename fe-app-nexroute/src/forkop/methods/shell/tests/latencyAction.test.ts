import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { ForkopShellMethods } from '../index';

describe('ForkopShellMethods.latencyAction', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    mocks.executeShellCommand.mockReset();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('keeps waiting through a transient RPC reply loss', async () => {
    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'latency_test_status') {
        if (mocks.executeShellCommand.mock.calls.length === 1) {
          return Promise.resolve({
            stdout: '',
            stderr: 'No related RPC reply',
            code: 1,
          });
        }

        return Promise.resolve({
          stdout: JSON.stringify({
            success: true,
            running: false,
            message: 'Latency test completed',
            section: 'main',
            tag: 'proxy-1',
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

    const responsePromise = ForkopShellMethods.waitLatencyTestJob('job-1');

    await vi.advanceTimersByTimeAsync(2000);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: {
        success: true,
        running: false,
        message: 'Latency test completed',
        section: 'main',
        tag: 'proxy-1',
        exit_code: 0,
      },
    });
  });

  it('passes an optional timeout to latency jobs', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify({ success: true, job_id: 'latency-1' }),
      stderr: '',
      code: 0,
    });

    await ForkopShellMethods.latencyTestStart(
      'proxy',
      'AWG',
      'AWG-out',
      '10000',
    );

    expect(mocks.executeShellCommand).toHaveBeenCalledWith({
      command: '/usr/bin/forkop',
      args: ['latency_test_async', 'proxy', 'AWG', 'AWG-out', '10000'],
      timeout: 15000,
    });
  });
});
