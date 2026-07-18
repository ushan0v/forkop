#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECTION_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js"
LOCAL_DEVICES_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/local_devices.js"

node - "$SECTION_JS" "$LOCAL_DEVICES_JS" <<'NODE'
const fs = require("fs");
const source = fs.readFileSync(process.argv[2], "utf8");
const localDevicesSource = fs.readFileSync(process.argv[3], "utf8");

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
if (!source.slice(sourceIpOption, fullyRoutedOption).includes("dependsOnRuleConditions(sourceIpOption)")) {
  fail("device filter visibility must follow section conditions");
}
if (!source.slice(fullyRoutedOption, portsOption).includes('fullyRoutedOption.depends("action", "dns")')) {
  fail("DNS action must expose forced device routing");
}
if (!source.slice(fullyRoutedOption, portsOption).includes("makeDeviceOptionsExclusive(sourceIpOption, fullyRoutedOption)")) {
  fail("device filter and forced routing must be mutually exclusive");
}

const conditionDependencies = source.slice(
  requiredIndex("function dependsOnRuleConditions(option)"),
  requiredIndex("const ZAPRET_LEGACY_DEFAULT_NFQWS_OPT"),
);
for (const condition of [
  '"domain"',
  '"ip_cidr"',
  '"community_lists"',
  '"rule_set"',
  '"domain_ip_lists"',
  '"ports"',
  '"_dns_rule_set"',
  '"_dns_domain_ip_lists"',
]) {
  if (!conditionDependencies.includes(condition)) {
    fail(`device filter is missing dependency on ${condition}`);
  }
}
if (!conditionDependencies.includes("/\\S/")) {
  fail("device filter visibility must ignore empty whitespace");
}
for (const expected of [
  'option.onDeviceWidgetReady(section_id, widget)',
  'node.addEventListener("cbi-dynlist-change"',
  "option.onDeviceListChange(section_id, widget.getValue())",
]) {
  if (!localDevicesSource.includes(expected)) {
    fail(`local device list is missing live event contract: ${expected}`);
  }
}
if (!source.includes('node.dispatchEvent(new CustomEvent("widget-change", { bubbles: true }))')) {
  fail("text conditions must refresh device-filter visibility while editing");
}

function extractFunction(name, nextName) {
  const start = requiredIndex(`function ${name}(`);
  const end = requiredIndex(`function ${nextName}(`, start);
  return source.slice(start, end);
}

eval(extractFunction("normalizeOptionValues", "getUciSectionName"));
eval(extractFunction("normalizeDynamicListItems", "uniqueDynamicListItems"));
eval(extractFunction("stringArraysEqual", "writeListOption"));
eval(extractFunction("makeDeviceOptionsExclusive", "childOwnerOption"));

function deviceOption(values) {
  const widget = {
    values,
    getValue() {
      return this.values;
    },
    setValue(next) {
      this.values = next;
    },
  };
  return {
    widget,
  };
}

const filtered = deviceOption(["192.0.2.1/32"]);
const forced = deviceOption(["192.0.2.1/32", "192.0.2.2/32"]);
makeDeviceOptionsExclusive(filtered, forced);
filtered.onDeviceWidgetReady("section", filtered.widget);
forced.onDeviceWidgetReady("section", forced.widget);
filtered.onDeviceListChange("section", filtered.widget.values);
if (JSON.stringify(forced.widget.values) !== JSON.stringify(["192.0.2.2/32"])) {
  fail("adding a filtered device must remove it from forced routing");
}
forced.widget.values = ["192.0.2.1/32", "192.0.2.2/32"];
forced.onDeviceListChange("section", forced.widget.values);
if (filtered.widget.values.length !== 0) {
  fail("adding a forced device must remove it from the device filter");
}
NODE

printf 'DNS action UI checks passed\n'
