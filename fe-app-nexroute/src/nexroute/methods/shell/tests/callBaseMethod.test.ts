import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { Forkop } from '../../../types';
import { callBaseMethod } from '../callBaseMethod';

describe('callBaseMethod', () => {
  beforeEach(() => {
    mocks.executeShellCommand.mockReset();
  });

  it('fails on non-zero exit code even when stdout is present by default', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: '{"ok":false}',
      stderr: 'command failed',
      code: 1,
    });

    const response = await callBaseMethod(
      Forkop.AvailableMethods.CHECK_DNS_AVAILABLE,
    );

    expect(response).toEqual({
      success: false,
      error: 'command failed',
    });
  });

  it('can return stdout for diagnostic commands with non-zero exit code', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: 'Global check run\n[FAIL] Sing-box process running',
      stderr: '',
      code: 1,
    });

    const response = await callBaseMethod(
      Forkop.AvailableMethods.GLOBAL_CHECK,
      [],
      '/usr/bin/forkop',
      { allowNonZeroWithStdout: true },
    );

    expect(response).toEqual({
      success: true,
      data: 'Global check run\n[FAIL] Sing-box process running',
    });
  });

  it('passes a custom timeout to long-running commands', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: '{"ok":true}',
      stderr: '',
      code: 0,
    });

    await callBaseMethod(
      Forkop.AvailableMethods.GLOBAL_CHECK,
      [],
      '/usr/bin/forkop',
      { timeout: 60000 },
    );

    expect(mocks.executeShellCommand).toHaveBeenCalledWith({
      command: '/usr/bin/forkop',
      args: ['global_check'],
      timeout: 60000,
    });
  });
});
