import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse } from '@babel/parser';
import { describe, expect, it } from 'vitest';

const testDir = path.dirname(fileURLToPath(import.meta.url));
const serverViewPath = path.resolve(
  testDir,
  '../../../../luci-app-podkop-plus/htdocs/luci-static/resources/view/podkop/server.js',
);

function loadBuildHysteria2Link(values) {
  const source = fs.readFileSync(serverViewPath, 'utf8');
  const requiredFunctions = [
    'encodeQuery',
    'getPublicHost',
    'normalizeSha256',
    'buildHysteria2Link',
  ];
  const ast = parse(source, {
    allowReturnOutsideFunction: true,
    sourceType: 'script',
  });
  const functionSources = new Map(
    ast.program.body
      .filter((node) => node.type === 'FunctionDeclaration')
      .map((node) => [node.id.name, source.slice(node.start, node.end)]),
  );
  const functions = requiredFunctions
    .map((name) => {
      const functionSource = functionSources.get(name);
      if (!functionSource) {
        throw new Error(`Function ${name} not found`);
      }
      return functionSource;
    })
    .join('\n');
  const factory = new Function(
    'uci',
    'UCI_PACKAGE',
    'window',
    `${functions}; return buildHysteria2Link;`,
  );
  const uci = {
    get(_packageName, sectionId, optionName) {
      return values[`${sectionId}.${optionName}`] || '';
    },
  };

  return factory(uci, 'podkop-plus', { location: { hostname: 'router.lan' } });
}

describe('buildHysteria2Link', () => {
  const certificatePin =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  it('exports a single certificate pin alias and omits stale obfs password when obfs is disabled', () => {
    const buildHysteria2Link = loadBuildHysteria2Link({
      'server1.public_host': 'vpn.example.com',
      'server1.listen_port': '8443',
      'server1.tls_server_name': 'sni.example.com',
      'server1.hysteria2_obfs_type': '',
      'server1.hysteria2_obfs_password': 'stale-secret',
    });

    const link = buildHysteria2Link(
      'server1',
      { password: 'p@ss word', name: 'Server 1' },
      { tlsCertificateSha256: certificatePin },
    );
    const params = new URL(link).searchParams;

    expect(params.get('pcs')).toBe(certificatePin);
    expect(params.has('pinSHA256')).toBe(false);
    expect(params.has('obfs')).toBe(false);
    expect(params.has('obfs-password')).toBe(false);
  });

  it('exports salamander obfuscation together with its password', () => {
    const buildHysteria2Link = loadBuildHysteria2Link({
      'server1.public_host': 'vpn.example.com',
      'server1.listen_port': '8443',
      'server1.hysteria2_obfs_type': 'salamander',
      'server1.hysteria2_obfs_password': 'secret',
    });

    const link = buildHysteria2Link(
      'server1',
      { password: 'password', name: 'Server 1' },
      { tlsCertificateSha256: certificatePin },
    );
    const params = new URL(link).searchParams;

    expect(params.get('pcs')).toBe(certificatePin);
    expect(params.has('pinSHA256')).toBe(false);
    expect(params.get('obfs')).toBe('salamander');
    expect(params.get('obfs-password')).toBe('secret');
  });
});
