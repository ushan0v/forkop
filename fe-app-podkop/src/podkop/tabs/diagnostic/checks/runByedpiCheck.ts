import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { PodkopShellMethods } from '../../../methods';
import { updateCheckStore } from './updateCheckStore';
import { IDiagnosticsChecksItem } from '../../../services';

type CheckState = 'success' | 'warning' | 'error';

export async function runByedpiCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.BYEDPI;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  const byedpiStatus = await PodkopShellMethods.getByedpiStatus();

  if (!byedpiStatus.success) {
    updateCheckStore({
      order,
      code,
      title,
      description: _('Cannot receive checks result'),
      state: 'error',
      items: [],
    });

    throw new Error('ByeDPI checks failed');
  }

  const data = byedpiStatus.data;
  const providerAvailable = Boolean(data.provider_available ?? data.installed);
  const packageInstalled = Boolean(data.package_installed);
  const hasByedpiRules = Number(data.enabled_rule_count || 0) > 0;
  const ready = Boolean(data.ready);
  const expectedProcesses = Number(data.expected_process_count || 0);
  const runningProcesses = Number(data.running_process_count || 0);
  const supervisorProcesses = Number(data.supervisor_process_count || 0);
  const restartCount = Number(data.restart_count || 0);
  const runtimeUnstable = Boolean(data.runtime_unstable);
  const podkopRuntimeReady =
    !hasByedpiRules ||
    (runningProcesses === expectedProcesses &&
      supervisorProcesses === expectedProcesses);
  const unexpectedRuntime =
    !hasByedpiRules && (runningProcesses > 0 || supervisorProcesses > 0);
  const outboundsConfigured = Boolean(data.outbounds_configured);
  const routesConfigured = Boolean(data.routes_configured);
  const standaloneServiceEnabled = Boolean(data.standalone_service_enabled);
  const standaloneServiceRunning = Boolean(data.standalone_service_running);
  const standaloneConflict = hasByedpiRules && standaloneServiceRunning;
  const standaloneAutostartRisk =
    hasByedpiRules && standaloneServiceEnabled && !standaloneServiceRunning;

  let state: CheckState = 'success';
  let description = _('Checks passed');

  if (hasByedpiRules && !providerAvailable) {
    state = 'error';
    description = _('Checks failed');
  } else if (hasByedpiRules && !ready) {
    state = 'error';
    description = _('Checks failed');
  } else if (standaloneConflict) {
    state = 'error';
    description = _('Checks failed');
  } else if (runtimeUnstable) {
    state = 'warning';
    description = _('Issues detected');
  } else if (standaloneAutostartRisk) {
    state = 'warning';
    description = _('Issues detected');
  } else if (!packageInstalled) {
    state = 'warning';
    description = _('Issues detected');
  }

  const items: Array<IDiagnosticsChecksItem> = [
    {
      state: providerAvailable
        ? 'success'
        : hasByedpiRules
          ? 'error'
          : 'warning',
      key: providerAvailable
        ? _('ByeDPI provider binary is available')
        : _('ByeDPI provider binary is not available'),
      value: data.provider_path || '',
    },
    {
      state: packageInstalled ? 'success' : 'warning',
      key: packageInstalled
        ? _('ByeDPI package is installed')
        : _('ByeDPI package is not installed'),
      value: '',
    },
    {
      state: hasByedpiRules && !providerAvailable ? 'error' : 'success',
      key: hasByedpiRules
        ? _('There are rules using ByeDPI')
        : _('No rules use ByeDPI'),
      value: '',
    },
    {
      state:
        unexpectedRuntime || !podkopRuntimeReady
          ? 'error'
          : runtimeUnstable
            ? 'warning'
            : 'success',
      key: hasByedpiRules
        ? runtimeUnstable
          ? _('Podkop-managed ciadpi runtime has restarted')
          : podkopRuntimeReady
          ? _('Podkop-managed ciadpi runtime is ready')
          : _('Podkop-managed ciadpi runtime is not ready')
        : unexpectedRuntime
          ? _('Unexpected Podkop-managed ciadpi runtime is running')
          : _('Podkop-managed ciadpi runtime is not running'),
      value: hasByedpiRules
        ? runtimeUnstable
          ? `${restartCount}`
          : `${runningProcesses}/${expectedProcesses}`
        : '',
    },
    {
      state: !hasByedpiRules || outboundsConfigured ? 'success' : 'error',
      key: outboundsConfigured
        ? _('ByeDPI sing-box outbound is configured')
        : _('ByeDPI sing-box outbound is not configured'),
      value: `${data.listen_address}:${Number(data.port_base || 0)}`,
    },
    {
      state: !hasByedpiRules || routesConfigured ? 'success' : 'error',
      key: routesConfigured
        ? _('ByeDPI route rules are configured')
        : _('ByeDPI route rules are not configured'),
      value: '',
    },
    {
      state: standaloneConflict
        ? 'error'
        : standaloneAutostartRisk
          ? 'warning'
          : 'success',
      key: standaloneServiceRunning
        ? hasByedpiRules
          ? _('Standalone ByeDPI is active together with Podkop ByeDPI rules')
          : _('Standalone ByeDPI service is active')
        : standaloneAutostartRisk
          ? _('Standalone ByeDPI autostart is enabled')
        : _('Standalone ByeDPI service is inactive'),
      value: '',
    },
  ];

  updateCheckStore({
    order,
    code,
    title,
    description,
    state,
    items,
  });
}
