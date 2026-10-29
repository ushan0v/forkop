import { describe, expect, it } from 'vitest';
import type { Forkop } from '../../../types';
import { describeServers } from '../serverActivity';
import type { ActivityConnection } from '../serverActivity';

const servers: Forkop.DashboardServer[] = [
  {
    sectionName: 'server_a',
    tag: 'Office',
    protocol: 'vless',
    port: '443',
    clients: [
      { sectionName: 'c1', name: 'phone', users: ['phone'], addresses: [] },
      { sectionName: 'c2', name: 'laptop', users: ['laptop'], addresses: [] },
    ],
  },
  {
    sectionName: 'server_b',
    tag: 'WG',
    protocol: 'wireguard',
    port: '51820',
    clients: [
      { sectionName: 'c3', name: 'tablet', users: [], addresses: ['10.8.0.2'] },
    ],
  },
];

function connection(
  id: string,
  type: string,
  sourceIP: string,
  user: string,
  upload: number,
  download: number,
): ActivityConnection {
  return { id, upload, download, metadata: { type, sourceIP, user } };
}

describe('describeServers', () => {
  it('matches clients by user, or by address without one', () => {
    const { servers: views } = describeServers(
      servers,
      [
        connection('1', 'vless/Office', '203.0.113.9', 'phone', 10, 20),
        connection('2', 'wireguard/WG', '10.8.0.2', '', 1, 1),
        connection('3', 'tproxy/tproxy-in', '192.168.1.5', '', 1, 1),
      ],
      null,
      0,
    );

    expect(views[0].clients).toEqual([
      expect.objectContaining({
        name: 'phone',
        online: true,
        addresses: ['203.0.113.9'],
        up: null,
      }),
      expect.objectContaining({ name: 'laptop', online: false }),
    ]);
    expect(views[1].clients[0]).toMatchObject({
      name: 'tablet',
      online: true,
    });
  });

  it('shows an unknown user of a server as a client of its own', () => {
    const { servers: views } = describeServers(
      servers,
      [connection('1', 'vless/Office', '203.0.113.9', 'guest', 0, 0)],
      null,
      0,
    );

    expect(views[0].clients.map((client) => client.name)).toEqual([
      'phone',
      'laptop',
      'guest',
    ]);
  });

  it('rates a client by what its connections gained since the last snapshot', () => {
    const first = describeServers(
      servers,
      [connection('1', 'vless/Office', '203.0.113.9', 'phone', 100, 1000)],
      null,
      0,
    );
    const second = describeServers(
      servers,
      [
        connection('1', 'vless/Office', '203.0.113.9', 'phone', 300, 5000),
        connection('2', 'vless/Office', '203.0.113.9', 'phone', 200, 1000),
      ],
      first.counters,
      2,
    );

    expect(second.servers[0].clients[0]).toMatchObject({
      up: 200,
      down: 2500,
    });
    expect(second.servers[0].clients[1]).toMatchObject({ up: 0, down: 0 });
  });
});
