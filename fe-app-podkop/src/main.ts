'use strict';
'require baseclass';
'require fs';
'require uci';
'require ui';

if (typeof structuredClone !== 'function')
  globalThis.structuredClone = (obj) => JSON.parse(JSON.stringify(obj));

export { validateIPV4 } from './validators/validateIp';
export { validateDomain } from './validators/validateDomain';
export { validateDNS } from './validators/validateDns';
export { validateUrl } from './validators/validateUrl';
export { validatePath } from './validators/validatePath';
export { validateSubnet } from './validators/validateSubnet';
export { bulkValidate } from './validators/bulkValidate';
export { validateOutboundJson } from './validators/validateOutboundJson';
export { validateProxyUrl } from './validators/validateProxyUrl';
export { parseValueList } from './helpers/parseValueList';
export { injectGlobalStyles } from './helpers/injectGlobalStyles';
export { showToast } from './helpers/showToast';
export { getClashUIUrl } from './helpers/getClashApiUrl';
export { PodkopShellMethods } from './podkop/methods/shell';
export { coreService } from './podkop/services/core.service';
export { store } from './podkop/services/store.service';
export { applyUiStateToStore } from './podkop/services/uiState.service';
export { DashboardTab } from './podkop/tabs/dashboard';
export { DiagnosticTab } from './podkop/tabs/diagnostic';
export { MonitoringTab } from './podkop/tabs/monitoring';
export { UpdatesTab } from './podkop/tabs/updates';
export {
  ALLOWED_WITH_RUSSIA_INSIDE,
  BOOTSTRAP_DNS_SERVER_OPTIONS,
  DNS_SERVER_OPTIONS,
  DOMAIN_LIST_OPTIONS,
  PODKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT,
  PODKOP_UCI_PACKAGE,
  REGIONAL_OPTIONS,
} from './constants';
