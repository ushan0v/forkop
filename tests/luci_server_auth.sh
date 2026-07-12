#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/server.js"

node - "$SERVER_JS" <<'NODE'
const fs = require("fs");
const source = fs.readFileSync(process.argv[2], "utf8");

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}

function requiredIndex(needle, from = 0) {
  const index = source.indexOf(needle, from);
  if (index < 0) fail(`missing source contract: ${needle}`);
  return index;
}

const flag = requiredIndex('"socks_auth_enabled"');
const username = requiredIndex('"server_username", _("Username")', flag);
const password = requiredIndex('"server_password", _("Password")', username);
const nextOption = requiredIndex('"vmess_alter_id", _("Alter ID")', password);

const flagBlock = source.slice(flag, username);
if (!flagBlock.includes('_("Enable authentication")') ||
    !flagBlock.includes('o.default = "1"') ||
    !flagBlock.includes('o.depends("protocol", "socks")')) {
  fail("SOCKS authentication switch must be enabled by default and limited to SOCKS servers");
}

for (const block of [source.slice(username, password), source.slice(password, nextOption)]) {
  if (!block.includes('o.depends({ protocol: "socks", socks_auth_enabled: "1" })')) {
    fail("SOCKS credentials must only be required while authentication is enabled");
  }
}

const link = source.slice(
  requiredIndex("function buildSocksLink"),
  requiredIndex("function normalizeSha256"),
);
if (!link.includes("isSocksAuthenticationEnabled(sectionId)") ||
    !link.includes('socks5://${userInfo}${uriHost}:${port}')) {
  fail("SOCKS share links must omit credentials when authentication is disabled");
}
NODE

printf 'LuCI SOCKS server authentication checks passed\n'
