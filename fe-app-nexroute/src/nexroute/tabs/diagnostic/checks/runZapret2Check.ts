import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { ForkopShellMethods } from '../../../methods';
import { updateCheckStore } from './updateCheckStore';
import { IDiagnosticsChecksItem } from '../../../services';
import { getCheckItemsMeta } from './getCheckItemsMeta';

export async function runZapret2Check() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.ZAPRET2;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  const zapret2Status = await ForkopShellMethods.getZapret2Status();

  if (!zapret2Status.success) {
    updateCheckStore({
      order,
      code,
      title,
      description: _('Cannot receive checks result'),
      state: 'error',
      items: [],
    });

    throw new Error('Zapret2 checks failed');
  }

  const data = zapret2Status.data;
  const providerAvailable = Boolean(data.provider_available ?? data.installed);
  const packageInstalled = Boolean(data.package_installed);
  const hasZapret2Rules = Number(data.enabled_rule_count || 0) > 0;
  const queueOverlap = Boolean(data.queue_overlap);
  const expectedProcesses = Number(data.expected_process_count || 0);
  const runningProcesses = Number(data.running_process_count || 0);
  const supervisorProcesses = Number(data.supervisor_process_count || 0);
  const forkopRuntimeReady =
    !hasZapret2Rules ||
    (runningProcesses === expectedProcesses &&
      supervisorProcesses === expectedProcesses);
  const unexpectedRuntime =
    !hasZapret2Rules && (runningProcesses > 0 || supervisorProcesses > 0);
  const outboundsConfigured = Boolean(data.outbounds_configured);
  const standaloneServiceEnabled = Boolean(data.standalone_service_enabled);
  const standaloneServiceRunning = Boolean(data.standalone_service_running);
  const standaloneConflict = hasZapret2Rules && standaloneServiceRunning;
  const standaloneAutostartRisk =
    hasZapret2Rules && standaloneServiceEnabled && !standaloneServiceRunning;

  const items: Array<IDiagnosticsChecksItem> = [
    {
      state: providerAvailable
        ? 'success'
        : hasZapret2Rules
          ? 'error'
          : 'warning',
      key: providerAvailable
        ? _('Zapret2 provider binary is available')
        : _('Zapret2 provider binary is not available'),
      value: data.provider_path || '',
    },
    {
      state: packageInstalled
        ? 'success'
        : hasZapret2Rules
          ? 'error'
          : 'warning',
      key: packageInstalled
        ? _('Zapret2 package is installed')
        : _('Zapret2 package is not installed'),
      value: '',
    },
    {
      state: hasZapret2Rules && !providerAvailable ? 'error' : 'success',
      key: hasZapret2Rules
        ? _('There are rules using Zapret2')
        : _('No rules use Zapret2'),
      value: '',
    },
    {
      state: unexpectedRuntime || !forkopRuntimeReady ? 'error' : 'success',
      key: hasZapret2Rules
        ? forkopRuntimeReady
          ? _('Forkop-managed nfqws2 runtime is ready')
          : _('Forkop-managed nfqws2 runtime is not ready')
        : unexpectedRuntime
          ? _('Unexpected Forkop-managed nfqws2 runtime is running')
          : _('Forkop-managed nfqws2 runtime is not running'),
      value: hasZapret2Rules ? `${runningProcesses}/${expectedProcesses}` : '',
    },
    {
      state: queueOverlap ? 'error' : 'success',
      key: queueOverlap
        ? _('NFQUEUE range overlaps with another rule')
        : _('NFQUEUE range is available'),
      value: `${Number(data.queue_base || 0)}-${Number(data.queue_range_end || 0)}`,
    },
    {
      state: !hasZapret2Rules || outboundsConfigured ? 'success' : 'error',
      key: outboundsConfigured
        ? _('Zapret2 sing-box outbound is configured')
        : _('Zapret2 sing-box outbound is not configured'),
      value: '',
    },
    {
      state: standaloneConflict
        ? 'error'
        : standaloneAutostartRisk
          ? 'warning'
          : 'success',
      key: standaloneServiceRunning
        ? hasZapret2Rules
          ? _('Standalone Zapret2 is active together with Forkop Zapret2 rules')
          : _('Standalone Zapret2 service is active')
        : standaloneAutostartRisk
          ? _('Standalone Zapret2 autostart is enabled')
          : _('Standalone Zapret2 service is inactive'),
      value: '',
    },
  ];
  const { state, description } = getCheckItemsMeta(items);

  updateCheckStore({
    order,
    code,
    title,
    description,
    state,
    items,
  });
}
