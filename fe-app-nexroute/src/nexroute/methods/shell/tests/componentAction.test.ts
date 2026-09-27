import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
  fsRead: vi.fn(),
}));

vi.mock('../../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { ForkopShellMethods } from '../index';

describe('ForkopShellMethods.componentAction', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    mocks.executeShellCommand.mockReset();
    mocks.fsRead.mockReset();
    vi.stubGlobal('fs', {
      read: mocks.fsRead,
    });
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('does not fail Forkop self-update when status polling disappears after package replacement', async () => {
    mocks.fsRead.mockRejectedValue(new Error('Access denied'));
    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'component_action_status') {
        return Promise.resolve({
          stdout: '',
          stderr: 'Unknown command',
          code: 1,
        });
      }

      if (args[0] === 'show_version') {
        return Promise.resolve({
          stdout: '0.7.17.11\n',
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

    const responsePromise = ForkopShellMethods.waitComponentActionJob(
      'job-1',
      'forkop',
      'install',
      '0.7.17.11',
    );

    await vi.advanceTimersByTimeAsync(33000);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: {
        success: true,
        component: 'forkop',
        action: 'install',
        message: 'Forkop has been installed',
        current_version: '0.7.17.11',
        latest_version: '0.7.17.11',
        changed: true,
        status: 'latest',
      },
    });
  });

  it('returns the backend component action start error message', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify({
        success: false,
        message: 'Another component action is already running',
      }),
      stderr: '',
      code: 1,
    });

    await expect(
      ForkopShellMethods.componentActionStart('zapret', 'install'),
    ).resolves.toEqual({
      success: false,
      error: 'Another component action is already running',
    });
  });

  it('keeps following a component job after the former browser-side wait timeout while the backend reports it running', async () => {
    let stateReads = 0;

    mocks.fsRead.mockImplementation(() =>
      Promise.resolve(
        JSON.stringify(
          stateReads++ < 401
            ? {
                success: true,
                running: true,
                component: 'sing_box',
                action: 'check_update',
                message: 'Component action is running',
                job_id: 'job-1',
              }
            : {
                success: true,
                running: false,
                component: 'sing_box',
                action: 'check_update',
                message: 'sing-box is up to date',
                current_version: '1.13.12-extended-2.3.2',
                latest_version: '1.13.12-extended-2.3.2',
                changed: false,
                status: 'latest',
              },
        ),
      ),
    );

    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'component_action_status') {
        return Promise.resolve({
          stdout: JSON.stringify({
            success: true,
            running: true,
            component: 'sing_box',
            action: 'check_update',
            message: 'Component action is running',
            job_id: 'job-1',
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

    const responsePromise = ForkopShellMethods.waitComponentActionJob(
      'job-1',
      'sing_box',
      'check_update',
    );

    await vi.advanceTimersByTimeAsync(10 * 60 * 1000 + 3000);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: {
        success: true,
        running: false,
        component: 'sing_box',
        action: 'check_update',
        message: 'sing-box is up to date',
        current_version: '1.13.12-extended-2.3.2',
        latest_version: '1.13.12-extended-2.3.2',
        changed: false,
        status: 'latest',
      },
    });
  });

  it('keeps waiting when status polling briefly fails but UI state still reports the job running', async () => {
    mocks.fsRead
      .mockRejectedValueOnce(new Error('State is temporarily unavailable'))
      .mockResolvedValueOnce(
        JSON.stringify({
          success: true,
          running: false,
          component: 'sing_box',
          action: 'install_extended',
          message: 'sing-box-extended has been installed',
          current_version: '1.13.12-extended-2.3.2',
          latest_version: '1.13.12-extended-2.3.2',
          changed: true,
          status: 'latest',
        }),
      );

    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'component_action_status') {
        return Promise.resolve({
          stdout: '',
          stderr: 'Component action job was not found',
          code: 1,
        });
      }

      if (args[0] === 'get_ui_state') {
        return Promise.resolve({
          stdout: JSON.stringify({
            service: {
              forkop: {
                running: 0,
                enabled: 1,
                status: 'stopped but enabled',
                dns_configured: 0,
              },
              sing_box: {
                running: 0,
                enabled: 1,
                status: 'stopped but enabled',
              },
            },
            capabilities: {
              sing_box_extended: 0,
              sing_box_tiny: 1,
              sing_box_compressed: 0,
              sing_box_tailscale: 0,
              zapret_installed: 1,
              zapret2_installed: 1,
              byedpi_installed: 0,
              server_inbounds_enabled_count: 0,
            },
            actions: {
              service: [],
              latency: [],
              component: [
                {
                  success: true,
                  running: true,
                  component: 'sing_box',
                  action: 'install_extended',
                  message: 'Component action is running',
                  job_id: 'job-1',
                },
              ],
              subscription: [],
            },
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

    const responsePromise = ForkopShellMethods.waitComponentActionJob(
      'job-1',
      'sing_box',
      'install_extended',
    );

    await vi.advanceTimersByTimeAsync(3000);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: {
        success: true,
        running: false,
        component: 'sing_box',
        action: 'install_extended',
        message: 'sing-box-extended has been installed',
        current_version: '1.13.12-extended-2.3.2',
        latest_version: '1.13.12-extended-2.3.2',
        changed: true,
        status: 'latest',
      },
    });
    expect(mocks.executeShellCommand).toHaveBeenCalledWith({
      command: '/usr/bin/forkop',
      args: ['get_ui_state'],
      timeout: 3000,
    });
  });

  it('keeps waiting through a transient RPC reply loss until the action state settles', async () => {
    mocks.fsRead
      .mockRejectedValueOnce(new Error('State is temporarily unavailable'))
      .mockResolvedValueOnce(
        JSON.stringify({
          success: true,
          running: false,
          component: 'zapret',
          action: 'check_update',
          message: 'zapret is up to date',
          current_version: '70.2',
          latest_version: '70.2',
          changed: false,
          status: 'latest',
        }),
      );

    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'component_action_status') {
        return Promise.resolve({
          stdout: '',
          stderr: 'No related RPC reply',
          code: 1,
        });
      }

      if (args[0] === 'get_ui_state') {
        return Promise.resolve({
          stdout: '',
          stderr: 'No related RPC reply',
          code: 1,
        });
      }

      return Promise.resolve({
        stdout: '',
        stderr: 'Unexpected command',
        code: 1,
      });
    });

    const responsePromise = ForkopShellMethods.waitComponentActionJob(
      'job-1',
      'zapret',
      'check_update',
    );

    await vi.advanceTimersByTimeAsync(3000);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: {
        success: true,
        running: false,
        component: 'zapret',
        action: 'check_update',
        message: 'zapret is up to date',
        current_version: '70.2',
        latest_version: '70.2',
        changed: false,
        status: 'latest',
      },
    });
  });
});
