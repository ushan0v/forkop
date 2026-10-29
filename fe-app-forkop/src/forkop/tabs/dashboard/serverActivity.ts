import { Forkop } from '../../types';
import { connectionInboundTag } from '../monitoring/source';

export interface ActivityConnection {
  id?: string;
  upload?: number;
  download?: number;
  metadata?: {
    sourceIP?: string;
    type?: string;
    user?: string;
  };
  rule?: string;
}

export type ConnectionCounters = Map<string, { up: number; down: number }>;

export interface ServerClientView {
  key: string;
  name: string;
  online: boolean;
  addresses: string[];
  // Bytes per second since the previous snapshot; null until there is one.
  up: number | null;
  down: number | null;
}

export interface ServerView {
  sectionName: string;
  tag: string;
  protocol: string;
  port: string;
  clients: ServerClientView[];
}

function text(value?: string | number | null): string {
  return value == null ? '' : String(value).trim();
}

// The core counts bytes only on open connections, so a client's rate is what its connections
// gained since the previous snapshot; one opened in between counts whole, one closed in between
// is lost.
export function describeServers(
  servers: Forkop.DashboardServer[],
  connections: ActivityConnection[],
  previous: ConnectionCounters | null,
  seconds: number,
): { servers: ServerView[]; counters: ConnectionCounters } {
  const counters: ConnectionCounters = new Map();
  const byTag = new Map(servers.map((server) => [server.tag, server]));
  const views = new Map<string, Map<string, ServerClientView>>(
    servers.map((server) => [
      server.tag,
      new Map(
        server.clients.map((client) => [
          client.sectionName,
          {
            key: client.sectionName,
            name: client.name,
            online: false,
            addresses: [],
            up: previous ? 0 : null,
            down: previous ? 0 : null,
          },
        ]),
      ),
    ]),
  );

  for (const connection of connections) {
    const server = byTag.get(connectionInboundTag(connection));

    if (!server) {
      continue;
    }

    const user = text(connection.metadata?.user);
    const ip = text(connection.metadata?.sourceIP);
    const client = server.clients.find((item) =>
      user ? item.users.includes(user) : item.addresses.includes(ip),
    );
    // A server without client sections, such as a JSON inbound, still shows who connects.
    const key = client?.sectionName || `@${user || ip}`;
    const clients = views.get(server.tag)!;
    let view = clients.get(key);

    if (!view) {
      view = {
        key,
        name: user || ip,
        online: false,
        addresses: [],
        up: previous ? 0 : null,
        down: previous ? 0 : null,
      };
      clients.set(key, view);
    }

    view.online = true;
    if (ip && !view.addresses.includes(ip)) {
      view.addresses.push(ip);
    }

    const up = Number(connection.upload) || 0;
    const down = Number(connection.download) || 0;
    const id = text(connection.id);

    if (id) {
      counters.set(id, { up, down });
    }

    if (previous && seconds > 0) {
      const before = previous.get(id) || { up: 0, down: 0 };
      view.up! += Math.max(0, up - before.up) / seconds;
      view.down! += Math.max(0, down - before.down) / seconds;
    }
  }

  return {
    servers: servers.map((server) => ({
      sectionName: server.sectionName,
      tag: server.tag,
      protocol: server.protocol,
      port: server.port,
      clients: [...views.get(server.tag)!.values()].map((view) => ({
        ...view,
        up: view.up === null ? null : Math.round(view.up),
        down: view.down === null ? null : Math.round(view.down),
      })),
    })),
    counters,
  };
}
