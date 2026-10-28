import { describe, expect, it } from 'vitest';

import {
  KnownDevice,
  NetifdInterface,
  outgoingDevices,
} from '../outgoingDevices';

const DEFAULT_ROUTE = [{ target: '0.0.0.0', mask: 0 }];
const DEFAULT_ROUTE6 = [{ target: '::', mask: 0 }];

const lan: NetifdInterface = {
  interface: 'lan',
  proto: 'static',
  device: 'br-lan',
  l3_device: 'br-lan',
};
const loopback: NetifdInterface = {
  interface: 'loopback',
  proto: 'static',
  device: 'lo',
  l3_device: 'lo',
};

function devices(spec: Record<string, string>): KnownDevice[] {
  return Object.entries(spec).map(([name, type]) => ({ name, type }));
}

const DSA_PORTS = {
  eth0: 'ethernet',
  lan1: 'switch',
  lan2: 'switch',
  lan3: 'switch',
  'br-lan': 'bridge',
  'radio0.network1': 'wifi',
};

describe('the devices a section can send its traffic out of', () => {
  it('offers the VLAN of the WAN, not the port under it, the CPU port or the LAN', () => {
    const result = outgoingDevices(
      [
        lan,
        loopback,
        {
          interface: 'wan',
          proto: 'dhcp',
          device: 'wan.30',
          l3_device: 'wan.30',
          route: DEFAULT_ROUTE,
        },
        {
          interface: 'wan6',
          proto: 'dhcpv6',
          device: 'wan.30',
          l3_device: 'wan.30',
          route: DEFAULT_ROUTE6,
        },
      ],
      devices({ ...DSA_PORTS, wan: 'switch', 'wan.30': 'vlan' }),
      ['wan', 'wan6'],
    );

    expect(result).toEqual([{ name: 'wan.30', networks: ['wan', 'wan6'] }]);
  });

  it('offers the WAN port of a DSA router when DHCP runs on it', () => {
    const result = outgoingDevices(
      [
        lan,
        loopback,
        { interface: 'wan', proto: 'dhcp', device: 'wan', l3_device: 'wan' },
      ],
      devices({ ...DSA_PORTS, wan: 'switch' }),
      ['wan', 'wan6'],
    );

    expect(result).toEqual([{ name: 'wan', networks: ['wan'] }]);
  });

  it("offers PPPoE's own device, not the port it runs over", () => {
    const result = outgoingDevices(
      [
        lan,
        {
          interface: 'wan',
          proto: 'pppoe',
          device: 'wan',
          l3_device: 'pppoe-wan',
          route: DEFAULT_ROUTE,
        },
      ],
      devices({ ...DSA_PORTS, wan: 'switch', 'pppoe-wan': 'tunnel' }),
      ['wan', 'wan6'],
    );

    expect(result).toEqual([{ name: 'pppoe-wan', networks: ['wan'] }]);
  });

  it('offers the device a PPPoE connection that is down will have', () => {
    const interfaces = [
      lan,
      { interface: 'wan', proto: 'pppoe', device: 'wan' },
    ];
    const known = devices({ ...DSA_PORTS, wan: 'switch' });

    expect(outgoingDevices(interfaces, known, ['wan'])).toEqual([
      { name: 'pppoe-wan', networks: ['wan'] },
    ]);
    expect(
      outgoingDevices(interfaces, known, ['wan'], (name) =>
        name === 'wan' ? 'isp' : '',
      ),
    ).toEqual([{ name: 'isp', networks: ['wan'] }]);
  });

  it('offers a second WAN and an LTE modem of the WAN zone, and tunnels of any zone', () => {
    const result = outgoingDevices(
      [
        lan,
        {
          interface: 'wan',
          proto: 'dhcp',
          device: 'eth1',
          l3_device: 'eth1',
          route: DEFAULT_ROUTE,
        },
        { interface: 'lte', proto: 'qmi', l3_device: 'wwan0' },
        { interface: 'wg0', proto: 'wireguard', l3_device: 'wg0' },
        { interface: 'awg', proto: 'amneziawg', l3_device: 'awg' },
        {
          interface: 'guest',
          proto: 'static',
          device: 'br-guest',
          l3_device: 'br-guest',
        },
        {
          interface: 'tailscale',
          proto: 'none',
          device: 'tailscale0',
          l3_device: 'tailscale0',
        },
      ],
      devices({
        eth0: 'ethernet',
        eth1: 'ethernet',
        'br-lan': 'bridge',
        'br-guest': 'bridge',
        wwan0: 'ethernet',
        wg0: 'wireguard',
        awg: 'ethernet',
        tun0: 'ethernet',
        tailscale0: 'ethernet',
      }),
      ['wan', 'lte'],
    );

    expect(result).toEqual([
      { name: 'eth1', networks: ['wan'] },
      { name: 'wwan0', networks: ['lte'] },
      { name: 'wg0', networks: ['wg0'] },
      { name: 'awg', networks: ['awg'] },
      { name: 'tun0', networks: [] },
      { name: 'tailscale0', networks: ['tailscale'] },
    ]);
  });

  it('offers an uplink with a default route outside a masquerading zone', () => {
    const result = outgoingDevices(
      [
        lan,
        {
          interface: 'isp2',
          proto: 'static',
          device: 'eth2',
          l3_device: 'eth2',
          route: DEFAULT_ROUTE,
        },
      ],
      devices({ 'br-lan': 'bridge', eth2: 'ethernet' }),
      [],
    );

    expect(result).toEqual([{ name: 'eth2', networks: ['isp2'] }]);
  });

  it('offers the device of a WAN that is down, but never a path netifd keeps as a device', () => {
    const result = outgoingDevices(
      [
        { interface: 'wan', proto: 'dhcp', device: 'eth1' },
        { interface: 'lte', proto: 'qmi', device: '/dev/cdc-wdm0' },
      ],
      devices({ eth1: 'ethernet' }),
      ['wan', 'lte'],
    );

    expect(result).toEqual([{ name: 'eth1', networks: ['wan'] }]);
  });
});
