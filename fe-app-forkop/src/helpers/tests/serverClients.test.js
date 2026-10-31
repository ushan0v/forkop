import { describe, expect, it, vi } from 'vitest';

import { installLuciStubs } from './luciStubs';
import {
  clientSections,
  clientSettingsDefaults,
  listClients,
  listedClientNames,
  nextClientName,
  pruneClientCredentials,
  validateClientCredential,
  validateClientName,
  validateClientsOnSave,
  visibleClientFields,
} from '../../forkop/tabs/servers/clients';

const UUID = '11111111-1111-4111-8111-111111111111';

function load(sections = {}) {
  return {
    uci: installLuciStubs({
      ...sections,
      srv: { '.type': 'server', label: 'Home', enabled: '1', ...sections.srv },
    }),
    clients: {
      clientSections,
      listClients,
      listedClientNames,
      nextClientName,
      pruneClientCredentials,
      validateClientCredential,
      validateClientName,
      validateClientsOnSave,
      visibleClientFields,
    },
  };
}

function client(id, owner, values = {}) {
  return {
    [id]: {
      '.type': 'server_client',
      server: owner,
      ...values,
    },
  };
}

describe('server client names', () => {
  it('names a client user- and five random characters', () => {
    const { clients } = load({ srv: { protocol: 'trojan' } });
    const names = Array.from({ length: 20 }, () => clients.nextClientName([]));

    names.forEach((name) => expect(name).toMatch(/^user-[a-z0-9]{5}$/));
    expect(new Set(names).size).toBeGreaterThan(1);
  });

  it('gives a name the login protocols accept as an account', () => {
    const { clients } = load({ srv: { protocol: 'mieru' } });

    expect(clients.validateClientName('srv', clients.nextClientName([]))).toBe(
      true,
    );
  });

  it('skips a name any server on the router already has', () => {
    load({
      srv: { protocol: 'trojan' },
      ...client('other-one', 'other', { name: 'User-K7M3P' }),
    });
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    const letters = 'k7m3pabcde'
      .split('')
      .map((char) => alphabet.indexOf(char));
    const random = vi
      .spyOn(globalThis.window.crypto, 'getRandomValues')
      .mockImplementation((bytes) => {
        bytes[0] = letters.length ? letters.shift() : 0;
        return bytes;
      });

    try {
      expect(clientSettingsDefaults('srv', '', false, null).name).toBe(
        'user-abcde',
      );
    } finally {
      random.mockRestore();
    }
  });

  it('keeps the name typed for a new client', () => {
    load({ srv: { protocol: 'trojan' } });

    expect(clientSettingsDefaults('srv', ' laptop ', false, null).name).toBe(
      'laptop',
    );
  });

  it('reads the names from the list as it stands', () => {
    const { clients } = load({
      srv: { protocol: 'trojan' },
      ...client('one', 'srv', { name: 'client-1' }),
      ...client('two', 'srv', { name: 'client-2' }),
    });
    const listOption = {
      formvalue: () => ['one'],
      inputValueForItem: (_sectionId, value) =>
        value === 'one' ? 'client-1' : value,
    };

    expect(clients.listedClientNames('srv', listOption)).toEqual(['client-1']);
    expect(clients.listedClientNames('srv', null)).toEqual([
      'client-1',
      'client-2',
    ]);
  });

  it('rejects an empty, over-long or unprintable name', () => {
    const { clients } = load({ srv: { protocol: 'trojan' } });

    expect(clients.validateClientName('srv', '')).toBe('Required');
    expect(clients.validateClientName('srv', 'a'.repeat(65))).toMatch(/64/);
    expect(clients.validateClientName('srv', 'Дом')).toBe(true);
    expect(
      clients.validateClientName('srv', `a${String.fromCharCode(7)}b`),
    ).toBe('Control characters are not allowed');
  });

  it('requires an account-safe name where the protocol sends it on the wire', () => {
    const { clients } = load({ srv: { protocol: 'mieru' } });

    expect(clients.validateClientName('srv', 'alice')).toBe(true);
    expect(clients.validateClientName('srv', 'alice smith')).toMatch(
      /letters, digits/,
    );
    expect(clients.validateClientName('srv', 'алиса')).toMatch(
      /letters, digits/,
    );
  });
});

describe('server client sections', () => {
  it('keeps clients of one server out of another', () => {
    const { clients } = load({
      srv: { protocol: 'trojan' },
      other: {
        '.type': 'server',
        protocol: 'trojan',
        label: 'Other',
        enabled: '1',
      },
      ...client('mine', 'srv', { name: 'Client #1', password: 'a' }),
      ...client('theirs', 'other', { name: 'Client #1', password: 'b' }),
    });

    expect(clients.listClients('srv').map((entry) => entry.id)).toEqual([
      'mine',
    ]);
    expect(clients.listClients('other').map((entry) => entry.id)).toEqual([
      'theirs',
    ]);
  });

  it('reports every client of a server', () => {
    const { clients } = load({
      srv: { protocol: 'trojan' },
      ...client('one', 'srv', { name: 'Client #1', password: 'a' }),
      ...client('two', 'srv', { name: 'Client #2', password: 'b' }),
    });

    expect(clients.listClients('srv').map((entry) => entry.name)).toEqual([
      'Client #1',
      'Client #2',
    ]);
    expect(clients.listClients('srv')[0].enabled).toBeUndefined();
  });

  it('drops credentials the protocol stopped using', () => {
    const { uci, clients } = load({
      srv: { protocol: 'trojan' },
      ...client('one', 'srv', {
        name: 'Client #1',
        password: 'secret',
        uuid: UUID,
        flow: 'xtls-rprx-vision',
      }),
    });

    clients.pruneClientCredentials('srv');

    expect(uci.get('forkop', 'one', 'password')).toBe('secret');
    expect(uci.get('forkop', 'one', 'uuid')).toBe(null);
    expect(uci.get('forkop', 'one', 'flow')).toBe(null);
  });

  it('offers the flow where Vision runs: right over TLS, or over VLESS Encryption on any transport', () => {
    const fields = (srv) =>
      load({ srv: { protocol: 'vless', ...srv } }).clients.visibleClientFields(
        'srv',
      );

    expect(fields({ security: 'reality', transport: 'tcp' })).toContain('flow');
    expect(fields({ security: 'reality', transport: 'xhttp' })).toEqual([
      'uuid',
    ]);
    expect(fields({ security: 'none', transport: 'tcp' })).toEqual(['uuid']);
    for (const security of ['reality', 'tls', 'none']) {
      expect(
        fields({ security, transport: 'xhttp', vless_encryption: 'native' }),
      ).toContain('flow');
    }
    expect(
      fields({
        security: 'reality',
        transport: 'tcp',
        vless_encryption: 'random',
        multiplex_enabled: '1',
      }),
    ).toEqual(['uuid']);
  });

  it('hides the password while mixed authentication is disabled', () => {
    const { clients } = load({
      srv: { protocol: 'mixed', mixed_auth_enabled: '0' },
    });

    expect(clients.visibleClientFields('srv')).toEqual([]);
  });
});

describe('server client credentials', () => {
  it('validates each credential against the protocol', () => {
    const { clients } = load({
      srv: {
        protocol: 'shadowsocks',
        shadowsocks_method: '2022-blake3-aes-128-gcm',
      },
    });

    expect(
      clients.validateClientCredential(
        'srv',
        'password',
        'ajXWye37k0IsLRrpEhB3pA==',
      ),
    ).toBe(true);
    expect(
      clients.validateClientCredential('srv', 'password', 'short'),
    ).toMatch(/16 bytes/);
  });

  it('checks a UUID', () => {
    const { clients } = load({ srv: { protocol: 'vless' } });

    expect(clients.validateClientCredential('srv', 'uuid', UUID)).toBe(true);
    expect(clients.validateClientCredential('srv', 'uuid', 'nope')).toMatch(
      /UUID/,
    );
  });
});

describe('saving the client list', () => {
  it('asks for at least one client', () => {
    const { clients } = load({ srv: { protocol: 'trojan' } });

    expect(clients.validateClientsOnSave('srv', [])).toBe('Required');
  });

  it('reports a client whose credential is missing', () => {
    const { clients } = load({
      srv: { protocol: 'trojan' },
      ...client('one', 'srv', { name: 'Client #1' }),
    });

    expect(clients.validateClientsOnSave('srv', ['one'], {})).toMatch(
      /Client #1: /,
    );
  });

  it('reports two clients with the same name', () => {
    const { clients } = load({
      srv: { protocol: 'trojan' },
      ...client('one', 'srv', { name: 'Client #1', password: 'a' }),
      ...client('two', 'srv', { name: 'Client #1', password: 'b' }),
    });

    expect(clients.validateClientsOnSave('srv', ['one', 'two'], {})).toBe(
      'Client #1: Name already taken',
    );
  });

  it('accepts a complete list', () => {
    const { clients } = load({
      srv: { protocol: 'trojan' },
      ...client('one', 'srv', { name: 'Client #1', password: 'a' }),
      ...client('two', 'srv', { name: 'Client #2', password: 'b' }),
    });

    expect(clients.validateClientsOnSave('srv', ['one', 'two'], {})).toBe(true);
  });
});
