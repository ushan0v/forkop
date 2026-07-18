#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECTION_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js"

node - "$SECTION_JS" <<'NODE'
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

const domains = requiredIndex('key: "domain_suffix"');
const ips = requiredIndex('const ipConditionOption = addTextConditionField(section, {', domains);
const builtIns = requiredIndex('const builtInRulesetOption = section.taboption(', ips);
if (source.slice(domains, ips).includes("dependsOnRoutingAction")) {
  fail("DNS action must keep the Domains field visible");
}
if (!source.slice(ips, builtIns).includes("dependsOnRoutingAction(ipConditionOption)")) {
  fail("DNS action must hide the IPs field");
}

const sectionContent = requiredIndex("function createSectionContent(section)");
const protocol = requiredIndex('"dns_type"', sectionContent);
const server = requiredIndex('"dns_server"', protocol);
if (server <= protocol || !source.slice(protocol, server).includes('_("DNS protocol")')) {
  fail("DNS protocol must be rendered before DNS server");
}
if (source.slice(server, requiredIndex('"dns_detour_enabled"', server)).includes('placeholder = "1.1.1.1"')) {
  fail("DNS server must not render the 1.1.1.1 placeholder");
}

for (const expected of [
  '_("DNS server used by the resolver")',
  '_("DNS requests through section")',
  '"Add URLs or local paths to .srs / .json lists. Only domain rules are supported."',
  '"Add URLs or local paths to .lst lists containing domains. IP entries are ignored."',
]) {
  requiredIndex(expected);
}

const ruleSetOption = requiredIndex("const ruleSetOption = section.taboption(");
const dnsRuleSetOption = requiredIndex("const dnsRuleSetOption = section.taboption(", ruleSetOption);
const domainLists = requiredIndex("const domainIpListsOption", dnsRuleSetOption);
if (!source.slice(ruleSetOption, dnsRuleSetOption).includes("SettingsDynamicList") ||
    !source.slice(ruleSetOption, dnsRuleSetOption).includes("dependsOnRoutingAction(ruleSetOption)") ||
    !source.slice(ruleSetOption, dnsRuleSetOption).includes("ruleSetOption.retain = true")) {
  fail("routing rule sets must keep their retained settings DynamicList");
}
if (!source.slice(dnsRuleSetOption, domainLists).includes("form.DynamicList") ||
    !source.slice(dnsRuleSetOption, domainLists).includes('"_dns_rule_set"') ||
    !source.slice(dnsRuleSetOption, domainLists).includes('dnsRuleSetOption.depends("action", "dns")') ||
    !source.slice(dnsRuleSetOption, domainLists).includes("dnsRuleSetOption.retain = true") ||
    !source.slice(dnsRuleSetOption, domainLists).includes("writeDnsRulesetReferences")) {
  fail("DNS rule sets must use a retained classic DynamicList");
}

const sourceIpOption = requiredIndex("const sourceIpOption = addLocalDeviceSubnetDynamicField(section");
const fullyRoutedOption = requiredIndex("const fullyRoutedOption = addLocalDeviceSubnetDynamicField(section", sourceIpOption);
const portsOption = requiredIndex("const portsOption = addDynamicConditionField(section", fullyRoutedOption);
if (!source.slice(sourceIpOption, fullyRoutedOption).includes('sourceIpOption.depends("action", "dns")')) {
  fail("DNS action must expose the device filter");
}
if (!source.slice(fullyRoutedOption, portsOption).includes('fullyRoutedOption.depends("action", "dns")')) {
  fail("DNS action must expose forced device routing");
}
NODE

printf 'DNS action UI checks passed\n'
