import { insertIf } from '../../../../helpers';
import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { PodkopShellMethods, RemoteFakeIPMethods } from '../../../methods';
import type { IDiagnosticsChecksItem } from '../../../services';
import { updateCheckStore } from './updateCheckStore';
import { getMeta } from '../helpers/getMeta';

export async function runFakeIPCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.FAKEIP;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  const routerFakeIPResponse = await PodkopShellMethods.checkFakeIP();
  const checkFakeIPResponse = await RemoteFakeIPMethods.getFakeIpCheck();
  const checkIPResponse = await RemoteFakeIPMethods.getIpCheck();

  const checks = {
    singBoxFakeIP:
      routerFakeIPResponse.success && routerFakeIPResponse.data.fakeip,
    browserFakeIP:
      checkFakeIPResponse.success && checkFakeIPResponse.data.fakeip,
    canComparePublicIP: checkFakeIPResponse.success && checkIPResponse.success,
    differentIP:
      checkFakeIPResponse.success &&
      checkIPResponse.success &&
      checkFakeIPResponse.data.IP !== checkIPResponse.data.IP,
  };

  const fakeIPWorks = checks.singBoxFakeIP && checks.browserFakeIP;
  const { state, description } = fakeIPWorks
    ? checks.differentIP
      ? { state: 'success' as const, description: _('Checks passed') }
      : {
          state: 'warning' as const,
          description: _('FakeIP works; public IP comparison is inconclusive'),
        }
    : getMeta({
        allGood: false,
        atLeastOneGood: checks.singBoxFakeIP || checks.browserFakeIP,
      });

  updateCheckStore({
    order,
    code,
    title,
    description,
    state,
    items: [
      {
        state: checks.singBoxFakeIP ? 'success' : 'error',
        key: checks.singBoxFakeIP
          ? _('Sing-box FakeIP DNS works')
          : _('Sing-box FakeIP DNS does not work'),
        value: routerFakeIPResponse.success ? routerFakeIPResponse.data.IP : '',
      },
      {
        state: checks.browserFakeIP ? 'success' : 'error',
        key: checks.browserFakeIP
          ? _('Browser is using FakeIP correctly')
          : _('Browser is not using FakeIP'),
        value: '',
      },
      ...insertIf<IDiagnosticsChecksItem>(checks.browserFakeIP, [
        {
          state: checks.differentIP ? 'success' : 'warning',
          key: !checks.canComparePublicIP
            ? _('Could not compare FakeIP and control public IPs')
            : checks.differentIP
              ? _('FakeIP and control checks use different public IPs')
              : _('FakeIP and control checks use the same public IP'),
          value: '',
        },
      ]),
    ],
  });
}
