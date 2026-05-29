import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { PodkopShellMethods } from '../../../methods';
import { updateCheckStore } from './updateCheckStore';
import { getMeta } from '../helpers/getMeta';
import { IDiagnosticsChecksItem } from '../../../services';
import { Podkop } from '../../../types';

function serverPrefix(item: Podkop.InboundCheckItem) {
  return `${item.label}:`;
}

function formatListen(item: Podkop.InboundCheckItem) {
  return `${item.listen}:${Number(item.listen_port || 0)} [${item.required_proto}]`;
}

function getPublicHostItem(
  item: Podkop.InboundCheckItem,
  wanIp: string,
): IDiagnosticsChecksItem {
  const key = `${serverPrefix(item)} ${_('Public host')}`;

  if (!item.public_host) {
    return {
      state: 'warning',
      key,
      value: _('Not configured'),
    };
  }

  if (item.public_host_resolved === 0) {
    return {
      state: 'warning',
      key,
      value: `${item.public_host} (${_('Does not resolve')})`,
    };
  }

  if (item.public_host_public === 0) {
    return {
      state: 'warning',
      key,
      value: `${item.public_host} (${_('Not public')})`,
    };
  }

  if (item.public_host_matches_wan === 0) {
    return {
      state: 'warning',
      key,
      value: `${item.public_host_ips || item.public_host} / ${_('WAN')}: ${wanIp || _('Not detected')}`,
    };
  }

  return {
    state: 'success',
    key,
    value: item.public_host,
  };
}

function getServerItems(
  item: Podkop.InboundCheckItem,
  wanIp: string,
): IDiagnosticsChecksItem[] {
  const prefix = serverPrefix(item);
  const items: IDiagnosticsChecksItem[] = [
    {
      state: item.runtime_ok ? 'success' : 'error',
      key: `${prefix} ${_('Generated inbound')}`,
      value: `${item.tag} [${item.protocol}]`,
    },
  ];

  if (item.protocol === 'tailscale') {
    items.push(
      {
        state: 'success',
        key: `${prefix} ${_('Tailscale endpoint')}`,
        value: _('No public firewall port required'),
      },
      {
        state: item.routes_configured ? 'success' : 'warning',
        key: `${prefix} ${_('Routing rules')}`,
        value: item.routing_mode,
      },
    );

    return items;
  }

  items.push(
    {
      state: item.listening === 1 ? 'success' : 'error',
      key: `${prefix} ${_('Listening port')}`,
      value: formatListen(item),
    },
    {
      state:
        item.firewall_required === 0
          ? 'warning'
          : item.firewall_open === 1
            ? 'success'
            : 'error',
      key: `${prefix} ${_('Firewall WAN port')}`,
      value:
        item.firewall_required === 0
          ? _('Not required for this listen address')
          : `${item.required_proto}/${Number(item.listen_port || 0)}`,
    },
    {
      state: item.routes_configured ? 'success' : 'warning',
      key: `${prefix} ${_('Routing rules')}`,
      value: item.routing_mode,
    },
    getPublicHostItem(item, wanIp),
  );

  return items;
}

export async function runInboundsCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.INBOUNDS;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  const inboundsChecks = await PodkopShellMethods.checkInbounds();

  if (!inboundsChecks.success) {
    updateCheckStore({
      order,
      code,
      title,
      description: _('Cannot receive checks result'),
      state: 'error',
      items: [],
    });

    throw new Error('Inbounds checks failed');
  }

  const data = inboundsChecks.data;

  if (!data.enabled_count) {
    updateCheckStore({
      order,
      code,
      title,
      description: _('No enabled server inbounds configured'),
      state: 'skipped',
      items: [],
    });

    return;
  }

  const items: IDiagnosticsChecksItem[] = [
    {
      state: data.wan_public ? 'success' : 'warning',
      key: _('WAN public IP'),
      value: data.wan_ip || _('Not detected'),
    },
  ];

  data.items.forEach((item) => {
    items.push(...getServerItems(item, data.wan_ip));
  });

  const allGood = items.every((item) => item.state === 'success');
  const atLeastOneGood = items.some((item) => item.state !== 'error');
  const { state, description } = getMeta({ atLeastOneGood, allGood });

  updateCheckStore({
    order,
    code,
    title,
    description,
    state,
    items,
  });

  if (!atLeastOneGood) {
    throw new Error('Inbounds checks failed');
  }
}
