import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { ForkopShellMethods } from '../../../methods';
import { updateCheckStore } from './updateCheckStore';
import { IDiagnosticsChecksItem } from '../../../services';
import { getCheckItemsMeta } from './getCheckItemsMeta';

export async function runZapretCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.ZAPRET;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  const zapretStatus = await ForkopShellMethods.getZapretStatus();

  if (!zapretStatus.success) {
    updateCheckStore({
      order,
      code,
      title,
      description: _('Cannot receive checks result'),
      state: 'error',
      items: [],
    });

    throw new Error('Zapret checks failed');
  }

  const data = zapretStatus.data;
  const providerAvailable = Boolean(data.provider_available ?? data.installed);
  const packageInstalled = Boolean(data.package_installed);
  const hasZapretRules = Number(data.enabled_rule_count || 0) > 0;
  const queueOverlap = Boolean(data.queue_overlap);
  const standaloneServiceRunning = Boolean(data.standalone_service_running);
  const standaloneConflict = hasZapretRules && standaloneServiceRunning;
  const expectedProcesses = Number(data.expected_process_count || 0);
  const runningProcesses = Number(data.running_process_count || 0);
  const supervisorProcesses = Number(data.supervisor_process_count || 0);
  const forkopRuntimeReady =
    !hasZapretRules ||
    (runningProcesses === expectedProcesses &&
      supervisorProcesses === expectedProcesses);
  const unexpectedRuntime =
    !hasZapretRules && (runningProcesses > 0 || supervisorProcesses > 0);
  const outboundsConfigured = Boolean(data.outbounds_configured);

  const items: Array<IDiagnosticsChecksItem> = [
    {
      state: providerAvailable
        ? 'success'
        : hasZapretRules
          ? 'error'
          : 'warning',
      key: providerAvailable
        ? _('Zapret provider binary is available')
        : _('Zapret provider binary is not available'),
      value: data.provider_path || '',
    },
    {
      state: packageInstalled
        ? 'success'
        : hasZapretRules
          ? 'error'
          : 'warning',
      key: packageInstalled
        ? _('Zapret package is installed')
        : _('Zapret package is not installed'),
      value: '',
    },
    {
      state: hasZapretRules && !providerAvailable ? 'error' : 'success',
      key: hasZapretRules
        ? _('There are rules using Zapret')
        : _('No rules use Zapret'),
      value: '',
    },
    {
      state: unexpectedRuntime || !forkopRuntimeReady ? 'error' : 'success',
      key: hasZapretRules
        ? forkopRuntimeReady
          ? _('Forkop-managed nfqws runtime is ready')
          : _('Forkop-managed nfqws runtime is not ready')
        : unexpectedRuntime
          ? _('Unexpected Forkop-managed nfqws runtime is running')
          : _('Forkop-managed nfqws runtime is not running'),
      value: hasZapretRules ? `${runningProcesses}/${expectedProcesses}` : '',
    },
    {
      state: queueOverlap ? 'error' : 'success',
      key: queueOverlap
        ? _('NFQUEUE range overlaps with another rule')
        : _('NFQUEUE range is available'),
      value: `${Number(data.queue_base || 0)}-${Number(data.queue_range_end || 0)}`,
    },
    {
      state: !hasZapretRules || outboundsConfigured ? 'success' : 'error',
      key: outboundsConfigured
        ? _('Zapret sing-box outbound is configured')
        : _('Zapret sing-box outbound is not configured'),
      value: '',
    },
    {
      state: standaloneConflict ? 'warning' : 'success',
      key: standaloneServiceRunning
        ? hasZapretRules
          ? _('Standalone Zapret is active together with Forkop Zapret rules')
          : _('Standalone Zapret service is active')
        : _('Standalone Zapret service is inactive'),
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
