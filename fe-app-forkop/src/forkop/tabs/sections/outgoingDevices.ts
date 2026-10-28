// The devices a section can send its traffic out of: those of the router's uplinks and tunnels.
// A LAN port, a bridge member, or the port under a VLAN or PPPoE has no route to the internet of
// its own, so a socket bound to it gets no answer.

const callNetworkInterfaceDump = rpc.declare({
  object: 'network.interface',
  method: 'dump',
  expect: { interface: [] },
});

// What netifd reports of a logical interface (ubus call network.interface dump).
export interface NetifdInterface {
  interface: string;
  proto?: string;
  device?: string;
  l3_device?: string;
  route?: { target?: string; mask?: number }[];
}

export interface KnownDevice {
  name: string;
  type: string;
}

export interface OutgoingDevice {
  name: string;
  networks: string[];
}

const TUNNEL_PROTOCOLS = [
  'wireguard',
  'amneziawg',
  'openvpn',
  'openconnect',
  'vpnc',
  'sstp',
  'l2tp',
  'pptp',
  'gre',
  'gretap',
  'grev6',
  'grev6tap',
  'ipip',
  '6in4',
  '6to4',
  '6rd',
  'dslite',
  'vti',
  'vtiv6',
  'xfrm',
  'vxlan',
  'vxlan6',
];

// netifd's ppp.sh names the device of these "<proto>-<interface>" unless pppname is set; it
// exists only while the connection is up.
const PPP_PROTOCOLS = ['ppp', 'pppoe', 'pppoa', 'pptp', 'l2tp', '3g'];

// A tunnel without a netifd interface of its own: OpenVPN's tun, tailscaled, ZeroTier.
const TUNNEL_DEVICE_NAME = /^(tun|tap|wg|awg|ovpn|tailscale|zt)/;
const TUNNEL_DEVICE_TYPES = ['wireguard', 'tunnel'];

const DEVICE_NAME = /^[^\s:/%@]{1,15}$/;

function hasDefaultRoute(networkInterface: NetifdInterface) {
  return (networkInterface.route ?? []).some(
    (route) =>
      route.mask === 0 && (route.target === '0.0.0.0' || route.target === '::'),
  );
}

// The device the interface's addresses and routes are on, or will be once it is up.
function layer3Device(
  networkInterface: NetifdInterface,
  pppName: (name: string) => string,
) {
  if (networkInterface.l3_device) {
    return networkInterface.l3_device;
  }
  const proto = networkInterface.proto ?? '';
  if (PPP_PROTOCOLS.includes(proto)) {
    return (
      pppName(networkInterface.interface) ||
      `${proto}-${networkInterface.interface}`
    );
  }
  const device = networkInterface.device ?? '';
  return DEVICE_NAME.test(device) ? device : '';
}

// Uplinks are the interfaces of the firewall zones that masquerade and those with a default
// route; tunnels go by netifd protocol, or by device name and type when netifd has none.
export function outgoingDevices(
  interfaces: NetifdInterface[],
  devices: KnownDevice[],
  masqueradeNetworks: string[],
  pppName: (name: string) => string = () => '',
): OutgoingDevice[] {
  const networksOf = new Map<string, string[]>();
  const offered = new Set<string>();

  interfaces.forEach((networkInterface) => {
    const device = layer3Device(networkInterface, pppName);
    if (!device || device === 'lo') {
      return;
    }
    networksOf.set(device, [
      ...(networksOf.get(device) ?? []),
      networkInterface.interface,
    ]);
    if (
      masqueradeNetworks.includes(networkInterface.interface) ||
      hasDefaultRoute(networkInterface) ||
      TUNNEL_PROTOCOLS.includes(networkInterface.proto ?? '')
    ) {
      offered.add(device);
    }
  });

  devices.forEach((device) => {
    if (
      TUNNEL_DEVICE_TYPES.includes(device.type) ||
      TUNNEL_DEVICE_NAME.test(device.name)
    ) {
      offered.add(device.name);
    }
  });

  const known = devices.map((device) => device.name);
  return [
    ...known.filter((name) => offered.has(name)),
    ...[...offered].filter((name) => !known.includes(name)),
  ].map((name) => ({ name, networks: networksOf.get(name) ?? [] }));
}

function masqueradeNetworks() {
  return uci
    .sections('firewall', 'zone')
    .filter((zone) => zone.masq === '1')
    .flatMap((zone) => L.toArray(zone.network as string | string[]));
}

function pppName(name: string) {
  return `${uci.get('network', name, 'pppname') ?? ''}`.trim();
}

// LuCI's network module has loaded the network configuration by the time getDevices resolves.
export function loadOutgoingDevices(devices: NetworkDevice[]) {
  return Promise.all([
    callNetworkInterfaceDump(),
    uci.load('firewall').catch(() => null),
  ]).then(([interfaces]) =>
    outgoingDevices(
      Array.isArray(interfaces) ? (interfaces as NetifdInterface[]) : [],
      devices.map((device) => ({
        name: device.getName(),
        type: device.getType(),
      })),
      masqueradeNetworks(),
      pppName,
    ),
  );
}
