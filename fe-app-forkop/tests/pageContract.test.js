import fs from 'fs';
import path from 'path';

import { beforeEach, describe, expect, it } from 'vitest';

import { ROOT } from './lib/paths.js';
import { createHarness } from './lib/luciForm.js';
import {
  DOMAIN_LIST_OPTIONS,
  FAKEIP_CHECK_DOMAIN,
  RESERVED_RUNTIME_TAGS,
} from '../src/constants';
import { RESERVED_PORTS } from '../src/forkop/tabs/servers/constants';
import {
  groupTypeChoices,
  providerTypeChoices,
} from '../src/forkop/tabs/sections/providers';
import { RESERVED_OVERRIDE_PATCH_PATHS } from '../src/forkop/tabs/sections/subscriptions/overrides';
import {
  FALLBACK_DEFAULTS,
  URLTEST_DEFAULTS,
} from '../src/forkop/methods/custom/getDashboardSections';
import { FORKOP_WAIT_TIMEOUT_MS } from '../src/forkop/services/forkopWaitTransport';
import { FORKOP_ACTION_OPENINGS } from '../src/forkop/services/logNotificationDeduper.service';
import { tunnelStorageSettings } from '../src/forkop/tabs/sections/tunnels/model';
import { AMNEZIA_PARAMETERS } from '../src/helpers/wireguard';
import {
  INSTALLER_ACTIONS,
  INSTALLER_OBJECT,
} from '../src/forkop/tabs/components/installerApi';

const contract = JSON.parse(
  fs.readFileSync(path.join(ROOT, 'tests/fixtures/page_contract.json'), 'utf8'),
);

describe('the tables the page carries', () => {
  it('reserve the ports Forkop binds', () => {
    expect(
      RESERVED_PORTS.map(([port]) => Number(port)).sort((a, b) => a - b),
    ).toEqual(contract.reserved_ports);
  });

  it('reserve the tags Forkop uses', () => {
    expect([...RESERVED_RUNTIME_TAGS].sort()).toEqual(contract.reserved_tags);
  });

  it('offer the community rule sets the backend downloads', () => {
    expect(Object.keys(DOMAIN_LIST_OPTIONS).sort()).toEqual(
      contract.community_rule_sets,
    );
  });

  it('filter by the server types the backend accepts', () => {
    expect(providerTypeChoices().map(({ value }) => value)).toEqual(
      contract.provider_types,
    );
    expect(groupTypeChoices().map(({ value }) => value)).toEqual(
      contract.group_types,
    );
  });

  it('refuse the override paths the backend refuses', () => {
    expect(RESERVED_OVERRIDE_PATCH_PATHS).toEqual(
      contract.reserved_override_patch_paths,
    );
  });

  it('check the domains the configuration answers for', () => {
    expect({ fakeip: FAKEIP_CHECK_DOMAIN }).toEqual(contract.check_domains);
  });

  it('read the AmneziaWG parameters by the kinds and sides the backend does', () => {
    expect(
      AMNEZIA_PARAMETERS.map(({ key, kind, oneSided }) => ({
        key,
        kind,
        one_sided: oneSided,
      })),
    ).toEqual(contract.amnezia_parameters);
  });

  it('describe an unset group option as the generator reads it', () => {
    expect(URLTEST_DEFAULTS).toEqual(contract.urltest_defaults);
    expect(FALLBACK_DEFAULTS).toEqual(contract.fallback_defaults);
  });

  it('leave LuCI to drop only the defaults the backend reads the same', async () => {
    const harness = createHarness();
    const found = {};
    const opened = new Set();
    const walk = async (kind, options, ownerId) => {
      for (const option of options) {
        if (
          option.default != null &&
          option.default !== '' &&
          option.__name__ !== 'CBI.FlagValue' &&
          (option.optional || option.rmempty)
        ) {
          (found[kind] ??= {})[option.option] = option.default;
        }
        const type = option.childType;
        if (
          !type ||
          opened.has(type) ||
          typeof option.renderItemSettingsModal !== 'function'
        ) {
          continue;
        }
        opened.add(type);
        harness.uci.add('forkop', type, `${type}_probe`);
        harness.uci.set(
          'forkop',
          `${type}_probe`,
          option.ownerOption || 'section',
          ownerId,
        );
        const dialog = await harness.openDialog(
          option,
          ownerId,
          `${type}_probe`,
        );
        for (const section of dialog.map.children) {
          await walk(type, section.children, `${type}_probe`);
        }
      }
    };
    const page = (kind, sectionClass, sid, values, render) => {
      harness.uci.add('forkop', kind, sid);
      Object.assign(harness.store.get(sid), values);
      const section = new harness.form.Map('forkop').section(sectionClass, sid);
      render(section);
      return walk(kind, section.children, sid);
    };

    await page(
      'settings',
      harness.form.NamedSection,
      'settings',
      {},
      harness.bundle.createSettingsContent,
    );
    await page(
      'section',
      harness.form.GridSection,
      'section_probe',
      { action: 'connection' },
      harness.bundle.createSectionContent,
    );
    await page(
      'server',
      harness.form.GridSection,
      'server_probe',
      { protocol: 'vless' },
      harness.bundle.createServerContent,
    );

    expect(found).toEqual(contract.defaults_dropped_on_save);
  });

  it('wait for a parked request longer than the state service holds it', () => {
    expect(FORKOP_WAIT_TIMEOUT_MS).toBeGreaterThan(contract.state_wait_ms);
  });

  it('close the alerts of earlier actions at the line a new one opens with', () => {
    expect(FORKOP_ACTION_OPENINGS).toEqual(contract.action_openings);
  });
});

describe('a password field', () => {
  let harness;

  beforeEach(() => {
    harness = createHarness();
  });

  function passwordFields(options) {
    return options
      .filter((option) => option.password === true)
      .map((option) => option.option);
  }

  async function dialogPasswordFields(ownerId, option, found) {
    const typeName =
      option.childType || (option.option === 'peer_ids' ? 'tunnel_peer' : '');
    if (!typeName || typeof option.renderItemSettingsModal !== 'function') {
      return;
    }
    const itemId = `${typeName}_probe`;
    harness.uci.add('forkop', typeName, itemId);
    harness.uci.set('forkop', itemId, option.ownerOption || 'section', ownerId);
    const dialog = await harness.openDialog(option, ownerId, itemId);
    const options = dialog.map.children.flatMap((section) => section.children);
    for (const field of passwordFields(options)) {
      found.push({ field, typeName });
    }
    for (const child of options) {
      await dialogPasswordFields(itemId, child, found);
    }
  }

  async function renderedPasswordFields() {
    const view = harness.bundle;
    harness.uci.add('forkop', 'settings', 'settings');
    harness.uci.add('forkop', 'section', 'section_probe');
    harness.uci.set('forkop', 'section_probe', 'action', 'connection');
    harness.uci.add('forkop', 'server', 'server_probe');
    harness.uci.set('forkop', 'server_probe', 'protocol', 'vless');

    const sections = new harness.form.Map('forkop').section(
      harness.form.GridSection,
      'section',
    );
    view.createSectionContent(sections);
    const servers = new harness.form.Map('forkop').section(
      harness.form.GridSection,
      'server',
    );
    view.createServerContent(servers);
    const settings = new harness.form.Map('forkop').section(
      harness.form.NamedSection,
      'settings',
    );
    view.createSettingsContent(settings);

    const found = passwordFields([
      ...sections.children,
      ...servers.children,
      ...settings.children,
    ]).map((field) => ({ field, typeName: '' }));
    for (const option of sections.children) {
      await dialogPasswordFields('section_probe', option, found);
    }
    for (const option of servers.children) {
      await dialogPasswordFields('server_probe', option, found);
    }
    return found;
  }

  it('is one the contract names', async () => {
    const found = await renderedPasswordFields();
    expect([...new Set(found.map(({ field }) => field))].sort()).toEqual(
      Object.keys(contract.password_fields).sort(),
    );
  });

  it('is stored in the option the contract says the diagnostics mask', async () => {
    const PROBE = 'probe-secret';
    const found = await renderedPasswordFields();
    for (const { field, typeName } of found) {
      const stored = contract.password_fields[field];
      if (typeName !== 'tunnel') {
        expect(stored, field).toBe(field);
        continue;
      }
      const kinds = {
        wireguard: {},
        amneziawg: {},
        warp: {},
        tailscale: {},
        'openvpn-client': {},
        openconnect: {
          openconnect_advanced: '1',
          openconnect_certificate_enabled: '1',
          openconnect_token_mode: 'stoken',
        },
      };
      const written = Object.entries(kinds).some(([kind, switches]) =>
        `${
          tunnelStorageSettings({
            tunnel_type: kind,
            ...switches,
            [field]: PROBE,
          })[stored] ?? ''
        }`.includes(PROBE),
      );
      expect(written, `${field} is not stored in ${stored}`).toBe(true);
    }
  });
});

describe('the installer', () => {
  it('is followed through the object its runner publishes, with the methods the ACL grants', () => {
    expect(INSTALLER_OBJECT).toBe(contract.installer.object);
    expect([...INSTALLER_ACTIONS]).toEqual(contract.installer.actions);
    const acl = JSON.parse(
      fs.readFileSync(
        path.join(
          ROOT,
          'luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json',
        ),
        'utf8',
      ),
    );
    expect(
      [...acl['luci-app-forkop'].read.ubus[INSTALLER_OBJECT]].sort(),
    ).toEqual(contract.installer.methods);
  });
});
