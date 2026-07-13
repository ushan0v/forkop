"use strict";
"require form";
"require baseclass";
"require fs";
"require network";
"require ui";
"require uci";
"require view.forkop.local_devices as localDevices";
"require view.forkop.main as main";

const UCI_PACKAGE = main.FORKOP_UCI_PACKAGE;
const ACTION_PROVIDERS_AVAILABILITY_EVENT =
  main.FORKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT ||
  "forkop:action-providers-availability";
const RULE_SET_ITEM_SETTINGS_KEY = "rule_set_settings";
const ROUTING_ACTIONS = [
  "connection",
  "proxy",
  "outbound",
  "vpn",
  "bypass",
  "block",
  "zapret",
  "zapret2",
  "byedpi",
];
const CONNECTIONS_BLOCKED_INTERFACES = [
  "br-lan",
  "eth0",
  "eth1",
  "wan",
  "phy0-ap0",
  "phy1-ap0",
  "pppoe-wan",
  "lan",
];

function valuesToText(values) {
  if (!values) {
    return "";
  }

  if (Array.isArray(values)) {
    return values.filter(Boolean).join("\n");
  }

  return values ? `${values}` : "";
}

function normalizeOptionValues(value) {
  if (!value) {
    return [];
  }

  if (Array.isArray(value)) {
    return value
      .filter(Boolean)
      .map((item) => `${item}`.trim())
      .filter(Boolean);
  }

  return `${value}`
    .split(/\s+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function getUciSectionName(section) {
  return section && section[".name"] ? section[".name"] : "";
}

function getUciSectionLabel(section) {
  return (section && section.label) || getUciSectionName(section);
}

function isOutboundDetourTargetSection(section, currentSectionId) {
  const sectionName = getUciSectionName(section);
  const action = (section && section.action) || "";

  return (
    sectionName &&
    sectionName !== currentSectionId &&
    section.enabled !== "0" &&
    ["connection", "proxy", "outbound", "vpn"].includes(action)
  );
}

function getOutboundDetourTargetSections(currentSectionId) {
  return (uci.sections(UCI_PACKAGE, "section") || []).filter((section) =>
    isOutboundDetourTargetSection(section, currentSectionId),
  );
}

function getDefaultOutboundDetourSection(currentSectionId) {
  const targetSections = getOutboundDetourTargetSections(currentSectionId);

  return targetSections.length ? getUciSectionName(targetSections[0]) : "";
}

function refreshOutboundDetourSectionOptionValues(option, sectionId) {
  option.keylist = [];
  option.vallist = [];

  getOutboundDetourTargetSections(sectionId).forEach((targetSection) => {
    option.value(
      getUciSectionName(targetSection),
      getUciSectionLabel(targetSection),
    );
  });
}

function isDnsDetourTargetSection(section, currentSectionId) {
  const sectionName = getUciSectionName(section);
  const action = (section && section.action) || "";

  if (
    !sectionName ||
    sectionName === currentSectionId ||
    section.enabled === "0"
  ) {
    return false;
  }

  if (["connection", "proxy", "outbound", "vpn"].includes(action)) {
    return true;
  }
  if (action === "zapret") {
    return isZapretInstalledForUi();
  }
  if (action === "zapret2") {
    return isZapret2InstalledForUi();
  }
  return action === "byedpi" && isByedpiInstalledForUi();
}

function refreshDnsDetourSectionOptionValues(option, sectionId) {
  option.keylist = [];
  option.vallist = [];

  (uci.sections(UCI_PACKAGE, "section") || [])
    .filter((section) => isDnsDetourTargetSection(section, sectionId))
    .forEach((targetSection) => {
      option.value(
        getUciSectionName(targetSection),
        getUciSectionLabel(targetSection),
      );
    });
}

function dependsOnRoutingAction(option) {
  ROUTING_ACTIONS.forEach((action) => option.depends("action", action));
  return option;
}

const ZAPRET_LEGACY_DEFAULT_NFQWS_OPT =
  "--filter-tcp=80 <HOSTLIST> --dpi-desync=fake,fakedsplit --dpi-desync-autottl=2 --dpi-desync-fooling=badsum --new --filter-tcp=443 --hostlist=/opt/zapret/ipset/zapret-hosts-google.txt --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=11 --dpi-desync-fooling=badsum --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com --new --filter-udp=443 --hostlist=/opt/zapret/ipset/zapret-hosts-google.txt --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-fake-quic=/opt/zapret/files/fake/quic_initial_www_google_com.bin --new --filter-udp=443 <HOSTLIST_NOAUTO> --dpi-desync=fake --dpi-desync-repeats=11 --new --filter-tcp=443 <HOSTLIST> --dpi-desync=multidisorder --dpi-desync-split-pos=1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1";

const ZAPRET_DEFAULT_NFQWS_OPT =
  "--filter-tcp=80 --dpi-desync=fake,fakedsplit --dpi-desync-autottl=2 --dpi-desync-fooling=badsum --new --filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=11 --dpi-desync-fooling=badsum --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-fake-quic=/opt/zapret/files/fake/quic_initial_www_google_com.bin";

const ZAPRET2_DEFAULT_NFQWS2_OPT =
  "--filter-tcp=80 --filter-l7=http --payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_md5 --lua-desync=multisplit:pos=method+2 --new --filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 --lua-desync=multidisorder:pos=1,midsld --new --filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6";

const BYEDPI_DEFAULT_CMD_OPTS = "-o 2 --auto=t,r,a,s -d 2";
const ANNOTATED_TEXTAREA_STYLE_ID = "fkp-annotated-textarea-styles";
const CONNECTIONS_DYNLIST_STYLE_ID = "fkp-connections-dynlist-styles";
const NFQWS_REMOTE_VALIDATION_DEBOUNCE_MS = 500;
const NFQWS_VALIDATION_COMMAND = "/usr/bin/forkop";
const nfqwsRemoteValidationCache = new Map();
const nfqwsRemoteValidationInflight = new Map();
const nfqws2RemoteValidationCache = new Map();
const nfqws2RemoteValidationInflight = new Map();
const byedpiRemoteValidationCache = new Map();
const byedpiRemoteValidationInflight = new Map();
const BYEDPI_LONG_VALUE_OPTIONS = new Set([
  "--max-conn",
  "--conn-ip",
  "--buf-size",
  "--debug",
  "--def-ttl",
  "--auto",
  "--auto-mode",
  "--cache-ttl",
  "--cache-dump",
  "--timeout",
  "--proto",
  "--hosts",
  "--ipset",
  "--pf",
  "--round",
  "--split",
  "--disorder",
  "--oob",
  "--disoob",
  "--fake",
  "--fake-sni",
  "--ttl",
  "--fake-offset",
  "--fake-data",
  "--fake-tls-mod",
  "--oob-data",
  "--mod-http",
  "--tlsrec",
  "--tlsminor",
  "--udp-fake",
]);
const BYEDPI_LONG_FLAG_OPTIONS = new Set([
  "--md5sig",
  "--tfo",
  "--drop-sack",
  "--no-domain",
  "--no-udp",
]);
const BYEDPI_SHORT_VALUE_OPTIONS = new Set([
  "-c",
  "-I",
  "-b",
  "-x",
  "-g",
  "-A",
  "-L",
  "-u",
  "-y",
  "-T",
  "-K",
  "-H",
  "-j",
  "-V",
  "-R",
  "-s",
  "-d",
  "-o",
  "-q",
  "-f",
  "-n",
  "-t",
  "-O",
  "-l",
  "-Q",
  "-e",
  "-M",
  "-r",
  "-m",
  "-a",
]);
const BYEDPI_SHORT_FLAG_OPTIONS = new Set(["-N", "-U", "-F", "-S", "-Y"]);
const NFQWS_OPTIONAL_ARG_OPTIONS = new Set([
  "--comment",
  "--ctrack-disable",
  "--debug",
  "--dpi-desync-any-protocol",
  "--dpi-desync-autottl",
  "--dpi-desync-autottl6",
  "--dpi-desync-skip-nosni",
  "--dpi-desync-tcp-flags-set",
  "--dpi-desync-tcp-flags-unset",
  "--dup-autottl",
  "--dup-autottl6",
  "--dup-replace",
  "--dup-tcp-flags-set",
  "--dup-tcp-flags-unset",
  "--ipcache-hostname",
  "--orig-autottl",
  "--orig-autottl6",
  "--orig-tcp-flags-set",
  "--orig-tcp-flags-unset",
  "--synack-split",
]);
const NFQWS_NO_ARG_OPTIONS = new Set([
  "--bind-fix4",
  "--bind-fix6",
  "--daemon",
  "--domcase",
  "--dry-run",
  "--hostcase",
  "--hostnospace",
  "--methodeol",
  "--new",
  "--skip",
  "--version",
]);
const NFQWS_REQUIRED_ARG_OPTIONS = new Set([
  "--ctrack-timeouts",
  "--dpi-desync",
  "--dpi-desync-badack-increment",
  "--dpi-desync-badseq-increment",
  "--dpi-desync-cutoff",
  "--dpi-desync-fake-dht",
  "--dpi-desync-fake-discord",
  "--dpi-desync-fake-http",
  "--dpi-desync-fake-quic",
  "--dpi-desync-fake-stun",
  "--dpi-desync-fake-syndata",
  "--dpi-desync-fake-tcp-mod",
  "--dpi-desync-fake-tls",
  "--dpi-desync-fake-tls-mod",
  "--dpi-desync-fake-unknown",
  "--dpi-desync-fake-unknown-udp",
  "--dpi-desync-fake-wireguard",
  "--dpi-desync-fakedsplit-mod",
  "--dpi-desync-fakedsplit-pattern",
  "--dpi-desync-fooling",
  "--dpi-desync-fwmark",
  "--dpi-desync-hostfakesplit-midhost",
  "--dpi-desync-hostfakesplit-mod",
  "--dpi-desync-ipfrag-pos-tcp",
  "--dpi-desync-ipfrag-pos-udp",
  "--dpi-desync-repeats",
  "--dpi-desync-split-http-req",
  "--dpi-desync-split-pos",
  "--dpi-desync-split-seqovl",
  "--dpi-desync-split-seqovl-pattern",
  "--dpi-desync-split-tls",
  "--dpi-desync-start",
  "--dpi-desync-ts-increment",
  "--dpi-desync-ttl",
  "--dpi-desync-ttl6",
  "--dpi-desync-udplen-increment",
  "--dpi-desync-udplen-pattern",
  "--dup",
  "--dup-badack-increment",
  "--dup-badseq-increment",
  "--dup-cutoff",
  "--dup-fooling",
  "--dup-ip-id",
  "--dup-start",
  "--dup-ts-increment",
  "--dup-ttl",
  "--dup-ttl6",
  "--filter-l3",
  "--filter-l7",
  "--filter-tcp",
  "--filter-udp",
  "--hostlist",
  "--hostlist-auto",
  "--hostlist-auto-debug",
  "--hostlist-auto-fail-threshold",
  "--hostlist-auto-fail-time",
  "--hostlist-auto-retrans-threshold",
  "--hostlist-domains",
  "--hostlist-exclude",
  "--hostlist-exclude-domains",
  "--hostspell",
  "--ip-id",
  "--ipcache-lifetime",
  "--ipset",
  "--ipset-exclude",
  "--ipset-exclude-ip",
  "--ipset-ip",
  "--orig-mod-cutoff",
  "--orig-mod-start",
  "--orig-ttl",
  "--orig-ttl6",
  "--pidfile",
  "--qnum",
  "--uid",
  "--user",
  "--wsize",
  "--wssize",
  "--wssize-cutoff",
  "--wssize-forced-cutoff",
]);
const NFQWS2_OPTIONAL_ARG_OPTIONS = new Set([
  "--chdir",
  "--comment",
  "--ctrack-disable",
  "--debug",
  "--hostlist-auto-retrans-reset",
  "--intercept",
  "--ipcache-hostname",
  "--new",
  "--payload-disable",
  "--reasm-disable",
  "--server",
  "--template",
  "--writeable",
]);
const NFQWS2_NO_ARG_OPTIONS = new Set([
  "--bind-fix4",
  "--bind-fix6",
  "--daemon",
  "--dry-run",
  "--skip",
  "--version",
]);
const NFQWS2_REQUIRED_ARG_OPTIONS = new Set([
  "--blob",
  "--cookie",
  "--ctrack-timeouts",
  "--filter-l3",
  "--filter-l7",
  "--filter-tcp",
  "--filter-udp",
  "--fwmark",
  "--fuzz",
  "--hostlist",
  "--hostlist-auto",
  "--hostlist-auto-debug",
  "--hostlist-auto-fail-threshold",
  "--hostlist-auto-fail-time",
  "--hostlist-auto-retrans-threshold",
  "--hostlist-domains",
  "--hostlist-exclude",
  "--hostlist-exclude-domains",
  "--import",
  "--in-range",
  "--ipcache-lifetime",
  "--ipset",
  "--ipset-exclude",
  "--ipset-exclude-ip",
  "--ipset-ip",
  "--lua-gc",
  "--lua-init",
  "--lua-desync",
  "--name",
  "--out-range",
  "--payload",
  "--pidfile",
  "--qnum",
  "--uid",
  "--user",
]);
const actionProvidersAvailabilityState = {
  loaded: false,
  zapretInstalled: false,
  zapret2Installed: false,
  byedpiInstalled: false,
};
let actionProvidersAvailabilityPromise = null;
let actionProvidersAvailabilityLoader = null;
const outboundNameChoicesCache = new Map();
const outboundNameChoicesInflight = new Map();
const outboundNameSourceOptions = new Map();
const SECTION_CACHE_DIR = "/var/run/forkop/section-cache";
const COUNTRY_CODES =
  "AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW XK".split(
    " ",
  );
const REGION_NAME_FALLBACKS = {
  XK: "Kosovo",
};
let regionDisplayNamesCache = {};

function updateActionProvidersAvailabilityState(nextState) {
  if (!nextState) {
    return;
  }

  actionProvidersAvailabilityState.loaded = true;

  if (typeof nextState.zapretInstalled !== "undefined") {
    actionProvidersAvailabilityState.zapretInstalled = Boolean(
      nextState.zapretInstalled,
    );
  }

  if (typeof nextState.zapret2Installed !== "undefined") {
    actionProvidersAvailabilityState.zapret2Installed = Boolean(
      nextState.zapret2Installed,
    );
  }

  if (typeof nextState.byedpiInstalled !== "undefined") {
    actionProvidersAvailabilityState.byedpiInstalled = Boolean(
      nextState.byedpiInstalled,
    );
  }

  actionProvidersAvailabilityPromise = null;
}

function updateActionProvidersAvailabilityFromSystemInfo(systemInfo) {
  if (!systemInfo || !systemInfo.providerInfoLoaded) {
    return;
  }

  updateActionProvidersAvailabilityState({
    zapretInstalled: Boolean(systemInfo.zapret_installed),
    zapret2Installed: Boolean(systemInfo.zapret2_installed),
    byedpiInstalled: Boolean(systemInfo.byedpi_installed),
  });
}

function setActionProvidersAvailabilityLoader(loader) {
  actionProvidersAvailabilityLoader =
    typeof loader === "function" ? loader : null;
}

if (typeof window !== "undefined") {
  window.addEventListener(ACTION_PROVIDERS_AVAILABILITY_EVENT, (event) => {
    updateActionProvidersAvailabilityState(event.detail);
  });
}

if (main.store && typeof main.store.subscribe === "function") {
  main.store.subscribe((next, _prev, diff) => {
    if (!diff || diff.diagnosticsSystemInfo) {
      updateActionProvidersAvailabilityFromSystemInfo(
        next.diagnosticsSystemInfo,
      );
    }
  });
}

function getLuciLanguage() {
  if (typeof L !== "undefined" && L.env && L.env.lang) {
    return `${L.env.lang}`.replace("_", "-");
  }

  if (document.documentElement.lang) {
    return document.documentElement.lang;
  }

  return navigator.language || "en";
}

function getRegionDisplayName(code) {
  const normalizedCode = `${code || ""}`.toUpperCase();
  const language = getLuciLanguage();
  const cacheKey = `${language}:${normalizedCode}`;

  if (regionDisplayNamesCache[cacheKey]) {
    return regionDisplayNamesCache[cacheKey];
  }

  try {
    if (typeof Intl !== "undefined" && Intl.DisplayNames) {
      const displayNames = new Intl.DisplayNames([language, "en"], {
        type: "region",
      });
      const displayName = displayNames.of(normalizedCode);
      if (displayName && displayName !== normalizedCode) {
        regionDisplayNamesCache[cacheKey] = displayName;
        return displayName;
      }
    }
  } catch (_error) {
    // Fall through to the static fallback.
  }

  const fallback = REGION_NAME_FALLBACKS[normalizedCode] || normalizedCode;
  regionDisplayNamesCache[cacheKey] = fallback;
  return fallback;
}

function getCountryFlagEmoji(code) {
  const normalizedCode = `${code || ""}`.toUpperCase();

  if (!/^[A-Z]{2}$/.test(normalizedCode)) {
    return "";
  }

  return String.fromCodePoint(
    ...normalizedCode
      .split("")
      .map((char) => 0x1f1e6 + char.charCodeAt(0) - 65),
  );
}

function getCountryOptionLabel(code) {
  return `${getCountryFlagEmoji(code)} ${getRegionDisplayName(code)}`;
}

function validateCountryCode(_section_id, value) {
  const values = Array.isArray(value) ? value : [value];
  const normalizedValues = values
    .filter((item) => item && `${item}`.length)
    .map((item) => `${item}`.toUpperCase());

  if (!normalizedValues.length) {
    return true;
  }

  return normalizedValues.every((item) => COUNTRY_CODES.includes(item))
    ? true
    : _("Unknown country");
}

function plainObject(value) {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value
    : {};
}

function safeCacheSectionName(section_id) {
  return /^[A-Za-z0-9_-]+$/.test(`${section_id || ""}`);
}

function filteredOutboundMetadataFromCache(cache) {
  const metadata = plainObject(plainObject(cache).outboundMetadata);
  const names = plainObject(metadata.names);
  const countries = plainObject(metadata.countries);
  const candidateTags = Array.isArray(cache.urltestCandidateTags)
    ? cache.urltestCandidateTags
    : [];
  const groups = plainObject(cache.urltestGroups);
  const result = {
    names: {},
    countries: {},
  };

  if (candidateTags.length > 0) {
    candidateTags.forEach((tag) => {
      tag = `${tag || ""}`;
      if (!tag) {
        return;
      }
      if (names[tag] != null) {
        result.names[tag] = names[tag];
      }
      if (countries[tag] != null) {
        result.countries[tag] = countries[tag];
      }
    });
    return result;
  }

  Object.entries(names).forEach(([tag, name]) => {
    if (!groups[tag]) {
      result.names[tag] = name;
    }
  });
  Object.entries(countries).forEach(([tag, country]) => {
    if (!groups[tag]) {
      result.countries[tag] = country;
    }
  });

  return result;
}

function readOutboundMetadataFromSectionCache(section_id) {
  if (!safeCacheSectionName(section_id)) {
    return Promise.resolve({ names: {}, countries: {} });
  }

  return fs
    .read(`${SECTION_CACHE_DIR}/${section_id}.json`)
    .then((raw) => filteredOutboundMetadataFromCache(JSON.parse(raw || "{}")))
    .catch(() => ({ names: {}, countries: {} }));
}

function loadOutboundNameChoices(section_id) {
  if (outboundNameChoicesCache.has(section_id)) {
    return Promise.resolve(outboundNameChoicesCache.get(section_id));
  }

  if (outboundNameChoicesInflight.has(section_id)) {
    return outboundNameChoicesInflight.get(section_id);
  }

  const task = readOutboundMetadataFromSectionCache(section_id)
    .then((metadata) => {
      const names = Object.values(plainObject(metadata.names));

      const choices = names
        .filter(Boolean)
        .filter((name, index, values) => values.indexOf(name) === index)
        .sort((a, b) => `${a}`.localeCompare(`${b}`));

      outboundNameChoicesCache.set(section_id, choices);

      return choices;
    })
    .catch(() => [])
    .finally(() => {
      outboundNameChoicesInflight.delete(section_id);
    });

  outboundNameChoicesInflight.set(section_id, task);

  return task;
}

function normalizeDynamicListItems(value) {
  if (!value) {
    return [];
  }

  if (Array.isArray(value)) {
    return value
      .map((item) => `${item || ""}`.trim())
      .filter((item) => item.length);
  }

  const normalized = `${value}`.trim();
  return normalized.length ? [normalized] : [];
}

function uniqueDynamicListItems(value) {
  const seen = new Set();
  const result = [];

  normalizeDynamicListItems(value).forEach((item) => {
    if (!seen.has(item)) {
      seen.add(item);
      result.push(item);
    }
  });

  return result;
}

function readItemSettingsMap(section_id, settingsKey) {
  const raw = uci.get(UCI_PACKAGE, section_id, settingsKey);

  if (!raw) {
    return {};
  }

  try {
    const parsed = JSON.parse(`${raw}`);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? parsed
      : {};
  } catch (_error) {
    return {};
  }
}

function compactItemSettings(values) {
  const result = {};

  Object.entries(values || {}).forEach(([key, value]) => {
    if (value === undefined || value === null || value === "") {
      return;
    }

    if (Array.isArray(value)) {
      const items = value
        .map((item) => `${item || ""}`.trim())
        .filter((item) => item.length);

      if (items.length) {
        result[key] = items;
      }
      return;
    }

    result[key] = `${value}`;
  });

  return result;
}

function writeItemSettingsMap(section_id, settingsKey, map) {
  const result = {};

  Object.entries(map || {}).forEach(([item, settings]) => {
    const compact = compactItemSettings(settings);
    if (item && Object.keys(compact).length) {
      result[item] = compact;
    }
  });

  if (Object.keys(result).length) {
    uci.set(UCI_PACKAGE, section_id, settingsKey, JSON.stringify(result));
  } else {
    uci.unset(UCI_PACKAGE, section_id, settingsKey);
  }
}

function cleanupListItemSettings(section_id, settingsKey, values) {
  if (!settingsKey) {
    return;
  }

  const keep = new Set(normalizeDynamicListItems(values));
  const map = readItemSettingsMap(section_id, settingsKey);
  let changed = false;

  Object.keys(map).forEach((item) => {
    if (!keep.has(item)) {
      delete map[item];
      changed = true;
    }
  });

  if (changed) {
    writeItemSettingsMap(section_id, settingsKey, map);
  }
}

function itemSettingsFlag(settings, key, defaultValue) {
  const value = settings ? settings[key] : null;

  if (value === undefined || value === null || value === "") {
    return Boolean(defaultValue);
  }

  return value === true || `${value}` === "1";
}

function ensureConnectionsDynamicListStyles() {
  if (document.getElementById(CONNECTIONS_DYNLIST_STYLE_ID)) {
    return;
  }

  document.head.appendChild(
    E(
      "style",
      { id: CONNECTIONS_DYNLIST_STYLE_ID },
      `
.fkp-connections-dynlist > .item {
  --fkp-dynlist-action-width: 2em;
  padding-right: calc(var(--fkp-dynlist-action-width) * 2);
  position: relative;
}

.fkp-connections-dynlist > .item > .fkp-dynlist-settings {
  align-items: center;
  border: 1px solid var(--border-color-high, currentColor);
  border-right: 0;
  border-radius: 0;
  bottom: -1px;
  color: inherit;
  cursor: pointer;
  display: inline-flex;
  font: inherit;
  font-size: 0.9em;
  justify-content: center;
  line-height: 1;
  min-height: 0;
  padding: 0;
  pointer-events: auto;
  position: absolute;
  right: calc(var(--fkp-dynlist-action-width) - 1px);
  user-select: none;
  text-decoration: none;
  top: -1px;
  width: var(--fkp-dynlist-action-width);
  z-index: 1;
}

.fkp-connections-dynlist > .item > .fkp-dynlist-settings:hover,
.fkp-connections-dynlist > .item > .fkp-dynlist-settings:focus {
  --focus-color-rgb: 82, 168, 236;
  outline: 0;
  border-color: rgba(var(--focus-color-rgb), 0.8) !important;
  box-shadow: inset 0 1px 3px hsla(var(--border-color-low-hsl), .01), 0 0 8px rgba(var(--focus-color-rgb), 0.6);
  text-decoration: none;
}

.fkp-connections-dynlist > .add-item > .cbi-dropdown {
  width: 100%;
}

.fkp-interface-dynlist-label {
  align-items: center;
  display: inline-flex;
  gap: 0.25em;
  max-width: 100%;
  vertical-align: middle;
}

.fkp-interface-dynlist-label > img {
  flex: 0 0 auto;
  height: 1.35em;
  width: auto;
}

.fkp-interface-dynlist-label > span {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.fkp-button-add-dynlist > .add-item {
  align-items: stretch;
  background: transparent;
  border: 0;
  border-radius: 0;
  box-shadow: none;
  display: flex;
  margin-top: 4px;
  max-width: 100%;
  overflow: visible;
  padding: 0;
  width: var(--fkp-button-add-width, 210px);
}

.fkp-button-add-dynlist > .add-item > input[type="text"] {
  display: none !important;
}

.fkp-button-add-dynlist > .add-item > .cbi-button-add {
  align-items: center !important;
  background: linear-gradient(var(--background-color-high) 0%, var(--border-color-low) 100%) !important;
  border: 1px solid var(--border-color-high) !important;
  border-radius: 3px !important;
  box-shadow: inset 0 1px 3px hsla(var(--border-color-low-hsl), .01) !important;
  box-sizing: border-box !important;
  color: var(--text-color-medium) !important;
  cursor: pointer !important;
  display: flex !important;
  font-size: 13px !important;
  height: 30px !important;
  justify-content: flex-start !important;
  margin-left: 0 !important;
  max-height: 30px !important;
  min-height: 30px !important;
  max-width: 100% !important;
  overflow: hidden !important;
  padding: 0 4px !important;
  text-overflow: ellipsis !important;
  transition: border linear .2s, box-shadow linear .2s !important;
  white-space: nowrap !important;
  width: 100% !important;
}

.fkp-button-add-dynlist > .add-item > .cbi-button-add:hover,
.fkp-button-add-dynlist > .add-item > .cbi-button-add:focus {
  border-color: rgba(82, 168, 236, .8) !important;
  box-shadow: inset 0 1px 3px hsla(var(--border-color-low-hsl), .01), 0 0 8px rgba(82, 168, 236, .6) !important;
  outline: 0;
}

body.modal-overlay-active > #modal_overlay > .modal.cbi-modal > .cbi-map.flash {
  animation: none !important;
}

`,
    ),
  );
}

function findDynamicListItemByValue(dl, value) {
  const stringValue = `${value}`;
  const items = dl.querySelectorAll(".item");

  for (let i = 0; i < items.length; i += 1) {
    const hidden = items[i].querySelector('input[type="hidden"]');
    if (
      hidden &&
      hidden.parentNode === items[i] &&
      hidden.value === stringValue
    ) {
      return items[i];
    }
  }

  return null;
}

function dynamicListItemCurrentValue(item, fallback) {
  const hidden = item ? item.querySelector('input[type="hidden"]') : null;
  return hidden && hidden.parentNode === item ? hidden.value : fallback;
}

function dynamicListItemValues(dl) {
  return Array.from(dl.querySelectorAll(".item"))
    .map((item) => {
      const hidden = item.querySelector('input[type="hidden"]');
      return hidden && hidden.parentNode === item ? hidden.value : null;
    })
    .filter((value) => value != null);
}

function updateDynamicListItemLabel(item, label) {
  const labelNode = item ? item.querySelector(".fkp-dynlist-label") : null;
  if (labelNode) {
    labelNode.textContent = `${label || ""}`;
  }
}

function addDynamicListItem(widget, value, text) {
  if (!widget || !widget.node) {
    return null;
  }

  const normalized = `${value || ""}`.trim();
  if (!normalized) {
    return null;
  }

  if (
    typeof widget.options.hasEquivalentValue === "function" &&
    widget.options.hasEquivalentValue(normalized, widget.node)
  ) {
    widget.dispatchCbiDynlistChange(widget.node, normalized);
    return null;
  }

  widget.addItem(widget.node, normalized, text || null, false);
  widget.dispatchCbiDynlistChange(widget.node, normalized);
  updateButtonAddDynamicListLayout(widget.node, widget.options.addButtonLabel);

  return findDynamicListItemByValue(widget.node, normalized);
}

function updateButtonAddDynamicListLayout(dl, label) {
  const addButton = dl ? dl.querySelector(".add-item > .cbi-button-add") : null;
  if (!addButton) {
    return;
  }

  addButton.textContent = label || "+";
  addButton.setAttribute("role", "button");
  addButton.setAttribute("tabindex", "0");
  dl.style.setProperty(
    "--fkp-button-add-width",
    dl.querySelector(".item") ? "100%" : "210px",
  );
}

function setDynamicListItemValue(item, value) {
  const hidden = item ? item.querySelector('input[type="hidden"]') : null;
  if (hidden && hidden.parentNode === item) {
    hidden.value = `${value || ""}`;
  }
}

function parseOutboundJsonObject(value) {
  try {
    const parsed = JSON.parse(`${value || ""}`);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? parsed
      : null;
  } catch (_error) {
    return null;
  }
}

function outboundJsonDisplayTag(value) {
  const parsed = parseOutboundJsonObject(value);
  const tag = parsed && typeof parsed.tag === "string" ? parsed.tag.trim() : "";
  return tag || "";
}

function outboundJsonListItemLabel(value) {
  return E(
    "span",
    { class: "fkp-dynlist-label" },
    outboundJsonDisplayTag(value) || _("JSON outbound"),
  );
}

function cleanFormSectionData(sectionData) {
  const result = {};

  Object.entries(sectionData || {}).forEach(([key, value]) => {
    if (!key || key.charAt(0) === ".") {
      return;
    }

    result[key] = Array.isArray(value) ? value.slice() : value;
  });

  return result;
}

const SettingsUIDynamicList = ui.DynamicList.extend({
  render() {
    ensureConnectionsDynamicListStyles();

    const node = ui.DynamicList.prototype.render.apply(this, arguments);
    node.classList.add("fkp-connections-dynlist");
    return node;
  },

  addItem(dl, value, text, flash) {
    if (
      flash &&
      typeof this.options.hasEquivalentValue === "function" &&
      this.options.hasEquivalentValue(value, dl)
    ) {
      this.dispatchCbiDynlistChange(dl, value);
      return;
    }

    const itemText =
      typeof this.options.itemLabel === "function"
        ? this.options.itemLabel(value, text)
        : text;

    ui.DynamicList.prototype.addItem.call(this, dl, value, itemText, flash);

    const item = findDynamicListItemByValue(dl, value);
    const hasSettings =
      typeof this.options.hasSettings === "function"
        ? this.options.hasSettings(value)
        : true;

    if (!item || item.querySelector(".fkp-dynlist-settings") || !hasSettings) {
      return;
    }

    item.appendChild(
      E(
        "span",
        {
          role: "button",
          tabindex: this.options.disabled ? null : "0",
          class: "fkp-dynlist-settings",
          "aria-label": _("Settings"),
          "aria-disabled": this.options.disabled ? "true" : null,
          click: (event) => {
            event.preventDefault();
            event.stopPropagation();

            if (this.options.disabled) {
              return;
            }

            if (typeof this.options.settingsHandler === "function") {
              this.options.settingsHandler(
                dynamicListItemCurrentValue(item, value),
                item,
                this,
                {},
              );
            }
          },
          keydown: (event) => {
            if (event.key !== "Enter" && event.key !== " ") {
              return;
            }

            event.preventDefault();
            event.stopPropagation();

            if (
              !this.options.disabled &&
              typeof this.options.settingsHandler === "function"
            ) {
              this.options.settingsHandler(
                dynamicListItemCurrentValue(item, value),
                item,
                this,
                {},
              );
            }
          },
        },
        "\u2699",
      ),
    );
  },
  handleClick(event) {
    if (event.target.closest(".fkp-dynlist-settings")) {
      return;
    }

    return ui.DynamicList.prototype.handleClick.apply(this, arguments);
  },
});

const ButtonAddSettingsUIDynamicList = SettingsUIDynamicList.extend({
  render() {
    const node = SettingsUIDynamicList.prototype.render.apply(this, arguments);
    node.classList.add("fkp-button-add-dynlist");

    const input = node.querySelector('.add-item > input[type="text"]');
    if (input) {
      input.setAttribute("aria-hidden", "true");
      input.setAttribute("tabindex", "-1");
    }

    updateButtonAddDynamicListLayout(node, this.options.addButtonLabel);

    node.addEventListener("cbi-dynlist-change", () => {
      updateButtonAddDynamicListLayout(node, this.options.addButtonLabel);
    });

    return node;
  },

  addButtonItem() {
    if (typeof this.options.settingsHandler === "function") {
      this.options.settingsHandler("", null, this, { adding: true });
    }
  },

  handleClick(event) {
    if (
      !this.options.disabled &&
      event.target.closest(".add-item > .cbi-button-add")
    ) {
      event.preventDefault();
      event.stopPropagation();
      this.addButtonItem(event.currentTarget);
      return;
    }

    return SettingsUIDynamicList.prototype.handleClick.apply(this, arguments);
  },

  handleKeydown(event) {
    if (
      !this.options.disabled &&
      event.target.closest(".add-item > .cbi-button-add") &&
      (event.key === "Enter" || event.key === " ")
    ) {
      event.preventDefault();
      event.stopPropagation();
      this.addButtonItem(event.currentTarget);
      return;
    }

    return ui.DynamicList.prototype.handleKeydown.apply(this, arguments);
  },
});

const SettingsDynamicList = form.DynamicList.extend({
  childOwner(section_id) {
    return typeof this.childOwnerId === "function"
      ? `${this.childOwnerId(section_id) || ""}`.trim()
      : section_id;
  },

  parentSection(section_id) {
    return typeof this.parentSectionId === "function"
      ? `${this.parentSectionId(section_id) || ""}`.trim()
      : section_id;
  },

  load(section_id) {
    if (this.childType) {
      return getChildItemIds(
        this.childOwner(section_id),
        this.childType,
        this.ownerOption,
      );
    }

    return form.DynamicList.prototype.load.apply(this, arguments);
  },

  renderWidget(section_id, _option_index, cfgvalue) {
    const value = cfgvalue != null ? cfgvalue : this.default;
    const choices = this.transformChoices();
    const WidgetClass = this.buttonAdd
      ? ButtonAddSettingsUIDynamicList
      : SettingsUIDynamicList;
    const widget = new WidgetClass(L.toArray(value), choices, {
      id: this.cbid(section_id),
      sort: this.keylist,
      allowduplicates: this.allowduplicates,
      optional: this.optional || this.rmempty,
      datatype: this.datatype,
      placeholder: this.placeholder,
      validate: L.bind(this.validate, this, section_id),
      disabled: this.readonly != null ? this.readonly : this.map.readonly,
      addButtonLabel:
        typeof this.addButtonLabel === "function"
          ? this.addButtonLabel(section_id)
          : this.addButtonLabel,
      settingsHandler: (itemValue, _item, widget, context) => {
        if (typeof this.renderItemSettingsModal === "function") {
          const ownerId = this.childOwner(section_id);
          this.renderItemSettingsModal(
            ownerId,
            `${itemValue}`,
            this,
            widget,
            _item,
            Object.assign({}, context || {}, {
              parentSectionId: this.parentSection(section_id),
              ownerId,
            }),
          );
        }
      },
      itemLabel: (itemValue, text) => {
        if (typeof this.renderListItemLabel === "function") {
          return this.renderListItemLabel(
            this.childOwner(section_id),
            `${itemValue}`,
            text,
          );
        }

        return text;
      },
      hasSettings: (itemValue) => {
        if (typeof this.hasItemSettings === "function") {
          return this.hasItemSettings(
            this.childOwner(section_id),
            `${itemValue}`,
          );
        }

        if (this.childType) {
          return isExistingChildItem(
            this.childOwner(section_id),
            `${itemValue}`,
            this.childType,
            this.ownerOption,
          );
        }

        return true;
      },
      hasEquivalentValue: (itemValue, dl) => {
        const inputValueForItem = (value) => {
          const ownerId = this.childOwner(section_id);

          if (typeof this.inputValueForItem === "function") {
            return `${this.inputValueForItem(ownerId, `${value || ""}`) || ""}`.trim();
          }

          if (this.childType && this.childValueOption) {
            return childItemInputValue(
              ownerId,
              `${value || ""}`,
              this.childType,
              this.childValueOption,
              this.ownerOption,
            );
          }

          return `${value || ""}`.trim();
        };
        const normalized = inputValueForItem(itemValue);

        return Boolean(
          normalized &&
            dynamicListItemValues(dl).some(
              (existingValue) =>
                inputValueForItem(existingValue) === normalized,
            ),
        );
      },
    });

    return widget.render();
  },

  parse(section_id) {
    if (
      this.isActive(section_id) &&
      typeof this.validateItemsOnSave === "function"
    ) {
      const result = this.validateItemsOnSave(
        this.childType ? this.childOwner(section_id) : section_id,
        this.formvalue(section_id),
        this,
        section_id,
      );
      if (result !== true) {
        const title = this.stripTags(this.title).trim();
        return Promise.reject(
          new TypeError(
            `${_('Option "%s" contains an invalid input value.').format(title || this.option)} ${result}`,
          ),
        );
      }
    }

    return form.DynamicList.prototype.parse.apply(this, arguments);
  },

  write(section_id, value) {
    if (this.childType) {
      const ownerId = this.childOwner(section_id);
      const itemIds = materializeChildItems(
        ownerId,
        {
          typeName: this.childType,
          valueOption: this.childValueOption,
          ownerOption: this.ownerOption,
          createId: this.createId,
          defaults: this.childDefaults,
          stagedSettings:
            typeof this.stagedChildSettings === "function"
              ? (itemValue, itemId, created) =>
                  this.stagedChildSettings(ownerId, itemValue, itemId, created)
              : null,
        },
        value,
      );
      cleanupRemovedChildItems(
        ownerId,
        this.childType,
        itemIds,
        this.ownerOption,
      );
      if (typeof this.afterMaterializeChildItems === "function") {
        this.afterMaterializeChildItems(ownerId, itemIds);
      }
      uci.unset(UCI_PACKAGE, section_id, this.option);
      cleanupListItemSettings(ownerId, this.settingsKey, itemIds);
      if (typeof this.clearStagedChildSettings === "function") {
        this.clearStagedChildSettings(ownerId);
      }
      return;
    }

    const result = form.DynamicList.prototype.write.apply(this, arguments);
    cleanupListItemSettings(section_id, this.settingsKey, value);
    return result;
  },

  remove(section_id) {
    if (this.childType) {
      cleanupRemovedChildItems(
        this.childOwner(section_id),
        this.childType,
        [],
        this.ownerOption,
      );
      uci.unset(UCI_PACKAGE, section_id, this.option);
      return;
    }

    if (this.settingsKey) {
      uci.unset(UCI_PACKAGE, section_id, this.settingsKey);
    }

    return form.DynamicList.prototype.remove.apply(this, arguments);
  },
});

const ButtonAddSettingsDynamicList = SettingsDynamicList.extend({
  buttonAdd: true,
});

function countryChoices() {
  return COUNTRY_CODES.map((code) => ({
    value: code,
    label: getCountryOptionLabel(code),
  })).sort((a, b) => a.label.localeCompare(b.label));
}

function currentOutboundNameChoices(section_id, values) {
  if (!outboundNameChoicesCache.has(section_id)) {
    loadOutboundNameChoices(section_id);
  }

  const seen = new Set();
  const result = [];
  const append = (name) => {
    const value = `${name || ""}`.trim();
    if (!value || seen.has(value)) {
      return;
    }

    seen.add(value);
    result.push({ value, label: value });
  };

  (outboundNameChoicesCache.get(section_id) || []).forEach(append);
  currentDraftOutboundNames(section_id).forEach(append);
  normalizeDynamicListItems(values).forEach(append);

  return result.sort((a, b) => a.label.localeCompare(b.label));
}

function currentSourceOptionValues(section_id, optionName) {
  const liveValues = currentLiveDynamicListValues(section_id, optionName);
  if (liveValues != null) {
    return liveValues;
  }

  const option = outboundNameSourceOptions.get(optionName);

  if (option && typeof option.formvalue === "function") {
    try {
      const value = option.formvalue(section_id);
      if (value != null) {
        return normalizeDynamicListItems(value);
      }
    } catch (_error) {
      // Fall back to the LuCI UCI cache when the section widget is not mounted.
    }
  }

  return getConfigListValues(section_id, optionName);
}

function currentLiveDynamicListValues(section_id, optionName) {
  if (typeof document === "undefined") {
    return null;
  }

  const widget = document.getElementById(
    `cbid.${UCI_PACKAGE}.${section_id}.${optionName}`,
  );
  if (!widget) {
    return null;
  }

  const values = Array.from(
    widget.querySelectorAll('.item > input[type="hidden"]'),
  )
    .map((input) => `${input.value || ""}`.trim())
    .filter(Boolean);
  const pendingInput = widget.querySelector('.add-item > input[type="text"]');
  const pendingValue = `${(pendingInput && pendingInput.value) || ""}`.trim();

  if (
    pendingValue &&
    !pendingInput.classList.contains("cbi-input-invalid") &&
    !values.includes(pendingValue)
  ) {
    values.push(pendingValue);
  }

  return values;
}

function currentDraftOutboundNames(section_id) {
  const names = [];

  currentSourceOptionValues(section_id, "selector_proxy_links").forEach(
    (value, index) => {
      const name = main.getProxyUrlName(`${value || ""}`);
      names.push(name || `${section_id}-${index + 1}-out`);
    },
  );
  currentSourceOptionValues(section_id, "interfaces").forEach((itemId) => {
    const normalized = childItemInputValue(
      section_id,
      itemId,
      "section_interface",
      "name",
    ).trim();
    if (normalized) {
      names.push(normalized);
    }
  });
  currentSourceOptionValues(section_id, "outbound_jsons").forEach((value) => {
    const tag = outboundJsonDisplayTag(value);
    if (tag) {
      names.push(tag);
    }
  });

  return names;
}

function isDownloadThroughTargetSection(section, currentSectionId) {
  const sectionName = getUciSectionName(section);
  const action = (section && section.action) || "";

  if (
    !sectionName ||
    sectionName === currentSectionId ||
    section.enabled === "0"
  ) {
    return false;
  }

  if (["connection", "proxy", "outbound", "vpn"].includes(action)) {
    return true;
  }

  if (action === "zapret") {
    return isZapretInstalledForUi();
  }

  if (action === "zapret2") {
    return isZapret2InstalledForUi();
  }

  if (action === "byedpi") {
    return isByedpiInstalledForUi();
  }

  return false;
}

function subscriptionDownloadTargetChoices(section_id) {
  return (uci.sections(UCI_PACKAGE, "section") || [])
    .filter((section) => isDownloadThroughTargetSection(section, section_id))
    .map((section) => ({
      value: getUciSectionName(section),
      label: getUciSectionLabel(section),
    }));
}

function dnsTypeChoices() {
  return [
    { value: "doh", label: _("DNS over HTTPS (DoH)") },
    { value: "dot", label: _("DNS over TLS (DoT)") },
    { value: "udp", label: "UDP" },
  ];
}

function isConnectionNetworkInterfaceAllowed(deviceName, device) {
  if (CONNECTIONS_BLOCKED_INTERFACES.includes(deviceName)) {
    return false;
  }

  if (!device) {
    return true;
  }

  const type = device.getType();
  const isWireless =
    type === "wifi" || type === "wireless" || type.indexOf("wlan") >= 0;

  return !isWireless;
}

function renderNetworkInterfaceChoice(device) {
  const name = device.getName();
  const type = device.getType();

  return E([
    E("img", {
      title: device.getI18n(),
      src: L.resource(
        "icons/%s%s.svg".format(type, device.isUp() ? "" : "_disabled"),
      ),
    }),
    E("span", { class: "hide-open" }, [name]),
    E("span", { class: "hide-close" }, [device.getI18n()]),
  ]);
}

function renderNetworkInterfaceListItem(device, fallbackName) {
  const name = device ? device.getName() : fallbackName;
  const type = device ? device.getType() : "ethernet";
  const up = device ? device.isUp() : false;

  return E("span", { class: "fkp-interface-dynlist-label" }, [
    E("img", {
      title: device ? device.getI18n() : _("Network Interface"),
      src: L.resource("icons/%s%s.svg".format(type, up ? "" : "_disabled")),
    }),
    E("span", {}, [name]),
  ]);
}

function refreshNetworkInterfaceOptionValues(option) {
  option.keylist = [];
  option.vallist = [];
  option.interfaceChoiceMap = {};
  option.interfaceDeviceMap = {};

  (option.devices || []).forEach((device) => {
    const name = device.getName();
    const type = device.getType();

    if (
      name === "lo" ||
      type === "alias" ||
      !isConnectionNetworkInterfaceAllowed(name, device)
    ) {
      return;
    }

    option.value(name, renderNetworkInterfaceChoice(device));
    option.interfaceChoiceMap[name] = true;
    option.interfaceDeviceMap[name] = device;
  });
}

const InterfaceSettingsDynamicList = SettingsDynamicList.extend({
  load(section_id) {
    return network.getDevices().then(
      L.bind(function (devices) {
        this.devices = devices || [];
        refreshNetworkInterfaceOptionValues(this);

        return this.super("load", section_id);
      }, this),
    );
  },

  validate(section_id, value) {
    value = childItemInputValue(section_id, value, "section_interface", "name");

    if (!value || value.length === 0) {
      return true;
    }

    if (!this.interfaceChoiceMap || !this.interfaceChoiceMap[value]) {
      return _("Select an existing network interface");
    }

    return true;
  },

  renderListItemLabel(section_id, value, text) {
    value = childItemInputValue(section_id, value, "section_interface", "name");

    return renderNetworkInterfaceListItem(
      this.interfaceDeviceMap ? this.interfaceDeviceMap[value] : null,
      value || text,
    );
  },
});

function urlTestFilterModeChoices() {
  return [
    { value: "disabled", label: _("All servers") },
    { value: "exclude", label: _("All except selected") },
    { value: "include", label: _("Only selected") },
    { value: "mixed", label: _("Only selected except exclusions") },
  ];
}

function priorityLevelFilterModeChoices() {
  return [
    { value: "disabled", label: _("All remaining servers") },
    { value: "include", label: _("Only selected") },
    { value: "exclude", label: _("All remaining except selected") },
    { value: "mixed", label: _("Only selected except exclusions") },
  ];
}

function serverCountryDetectionChoices() {
  return [
    { value: "flag_emoji", label: _("By flag emoji from name") },
    { value: "country_is", label: _("Via country.is") },
  ];
}

function proxyProtocolChoices() {
  return [
    ["vless", "VLESS"],
    ["vmess", "VMess"],
    ["trojan", "Trojan"],
    ["shadowsocks", "Shadowsocks"],
    ["socks", "SOCKS"],
    ["http", "HTTP"],
    ["hysteria2", "Hysteria2"],
    ["direct", "Direct"],
  ];
}

function proxyTransportChoices() {
  return [
    ["tcp", "TCP"],
    ["ws", "WebSocket"],
    ["grpc", "gRPC"],
    ["http", "HTTP"],
    ["httpupgrade", "HTTPUpgrade"],
    ["xhttp", "XHTTP"],
  ];
}

function proxySecurityChoices() {
  return [
    ["none", "None"],
    ["tls", "TLS"],
    ["reality", "Reality"],
  ];
}

function addProxyParameterFilterOptions(itemSection, options) {
  const prefix = options.prefix;
  const dependencies = options.dependencies;

  let o = itemSection.option(
    form.Flag,
    `${prefix}_proxy_parameters`,
    options.toggleLabel,
    options.toggleDescription,
  );
  dependencies.forEach((dependency) => o.depends(dependency));
  o.default = "0";
  o.rmempty = false;

  [
    [
      "protocols",
      _("Protocol"),
      options.protocolDescription,
      proxyProtocolChoices(),
    ],
    [
      "transports",
      _("Transport"),
      options.transportDescription,
      proxyTransportChoices(),
    ],
    [
      "securities",
      _("Security"),
      options.securityDescription,
      proxySecurityChoices(),
    ],
  ].forEach(([suffix, label, description, choices]) => {
    const list = itemSection.option(
      form.DynamicList,
      `${prefix}_${suffix}`,
      label,
      description,
    );
    dependencies.forEach((dependency) =>
      list.depends(
        Object.assign({}, dependency, {
          [`${prefix}_proxy_parameters`]: "1",
        }),
      ),
    );
    list.rmempty = true;
    choices.forEach(([value, choiceLabel]) => list.value(value, choiceLabel));
    list.placeholder = _("-- Select --");
  });
}

function urlTestUrlChoices() {
  return Array.isArray(main.LATENCY_TEST_URL_OPTIONS)
    ? main.LATENCY_TEST_URL_OPTIONS
    : [main.DEFAULT_LATENCY_TEST_URL || "https://www.gstatic.com/generate_204"];
}

function validateUrlTestTolerance(value) {
  if (!value || `${value}`.length === 0) {
    return _("Must be a number in the range of 0 - 10000");
  }

  const normalized = `${value}`;
  const parsed = parseFloat(normalized);
  if (
    /^[0-9]+$/.test(normalized) &&
    !isNaN(parsed) &&
    isFinite(parsed) &&
    parsed >= 0 &&
    parsed <= 10000
  ) {
    return true;
  }

  return _("Must be a number in the range of 0 - 10000");
}

function validateUrlTestUrl(value) {
  const validation = main.validateUrl(`${value || ""}`.trim());
  return validation.valid ? true : validation.message;
}

function optionMapValue(option, section_id, key) {
  const value =
    option && option.map && option.map.data
      ? option.map.data.get(option.map.config, section_id, key)
      : uci.get(UCI_PACKAGE, section_id, key);

  return value == null ? "" : value;
}

function subscriptionUrlSettingsKeys() {
  return [
    "subscription_update_enabled",
    "subscription_update_interval",
    "download_via_proxy_enabled",
    "download_via_proxy_section",
    "auto_user_agent",
    "user_agent",
    "auto_hwid",
    "hwid",
    "show_dashboard_metadata",
    "prefix_nodes",
    "node_prefix",
    "include_urltest_groups",
    "hide_urltest_group_outbounds",
    "hide_detour_outbounds",
  ];
}

function defaultSubscriptionUrlSettings() {
  return {
    subscription_update_enabled: "1",
    subscription_update_interval: "1h",
    download_via_proxy_enabled: "0",
    download_via_proxy_section: "",
    auto_user_agent: "1",
    user_agent: "",
    auto_hwid: "1",
    hwid: "",
    show_dashboard_metadata: "1",
    prefix_nodes: "0",
    node_prefix: "",
    include_urltest_groups: "1",
    hide_urltest_group_outbounds: "1",
    hide_detour_outbounds: "1",
  };
}

function interfaceSettingsKeys() {
  return [
    "domain_resolver_enabled",
    "domain_resolver_dns_type",
    "domain_resolver_dns_server",
  ];
}

function defaultInterfaceSettings() {
  return {
    domain_resolver_enabled: "0",
    domain_resolver_dns_type: "udp",
    domain_resolver_dns_server: "8.8.8.8",
  };
}

function subscriptionUserAgentChoices() {
  return [
    "sing-box",
    "Happ",
    "v2rayN",
    "v2rayNG",
    "v2RayTun",
    "Incy",
    "Hiddify",
    "HiddifyNext",
    "Clash",
    "Clash.Meta",
    "ClashMetaForAndroid",
    "Mihomo",
    "NekoBox",
    "Karing",
    "Husi",
  ];
}

function urlTestSettingsKeys() {
  return [
    "name",
    "check_interval",
    "tolerance",
    "testing_url",
    "idle_timeout",
    "interrupt_exist_connections",
    "pin_dashboard",
    "hide_added_outbounds",
    "filter_mode",
    "detect_server_country",
    "include_countries",
    "include_outbounds",
    "include_regex",
    "include_proxy_parameters",
    "include_protocols",
    "include_transports",
    "include_securities",
    "exclude_countries",
    "exclude_outbounds",
    "exclude_regex",
    "exclude_proxy_parameters",
    "exclude_protocols",
    "exclude_transports",
    "exclude_securities",
  ];
}

function defaultUrlTestSettings(name) {
  return {
    name: "",
    check_interval: "3m",
    tolerance: "50",
    testing_url: "https://www.gstatic.com/generate_204",
    idle_timeout: "30m",
    interrupt_exist_connections: "1",
    pin_dashboard: "1",
    hide_added_outbounds: "0",
    filter_mode: "disabled",
    detect_server_country: "flag_emoji",
  };
}

function urlTestChildDefaults() {
  return {
    check_interval: "3m",
    tolerance: "50",
    testing_url: "https://www.gstatic.com/generate_204",
    idle_timeout: "30m",
    interrupt_exist_connections: "1",
    pin_dashboard: "1",
    hide_added_outbounds: "0",
    filter_mode: "disabled",
    detect_server_country: "flag_emoji",
  };
}

function priorityGroupSettingsKeys() {
  return [
    "name",
    "health_url",
    "active_check_interval",
    "check_timeout",
    "recovery_check_interval",
    "pick_fastest",
    "switch_to_faster_same_priority",
    "fastest_check_interval",
    "interrupt_exist_connections",
    "pin_dashboard",
    "hide_added_outbounds",
  ];
}

function defaultPriorityGroupSettings() {
  return {
    name: "",
    health_url: "https://www.gstatic.com/generate_204",
    active_check_interval: "5s",
    check_timeout: "2s",
    recovery_check_interval: "15s",
    pick_fastest: "0",
    switch_to_faster_same_priority: "0",
    fastest_check_interval: "3m",
    interrupt_exist_connections: "1",
    pin_dashboard: "1",
    hide_added_outbounds: "0",
  };
}

function priorityGroupChildDefaults() {
  return {
    health_url: "https://www.gstatic.com/generate_204",
    active_check_interval: "5s",
    check_timeout: "2s",
    recovery_check_interval: "15s",
    pick_fastest: "0",
    switch_to_faster_same_priority: "0",
    fastest_check_interval: "3m",
    interrupt_exist_connections: "1",
    pin_dashboard: "1",
    hide_added_outbounds: "0",
  };
}

function priorityLevelSettingsKeys() {
  return [
    "name",
    "order",
    "direct",
    "filter_mode",
    "detect_server_country",
    "country",
    "server_name",
    "regex",
    "include_proxy_parameters",
    "include_protocols",
    "include_transports",
    "include_securities",
    "exclude_countries",
    "exclude_outbounds",
    "exclude_regex",
    "exclude_proxy_parameters",
    "exclude_protocols",
    "exclude_transports",
    "exclude_securities",
  ];
}

function defaultPriorityLevelSettings() {
  return {
    name: "",
    order: "0",
    direct: "0",
    filter_mode: "include",
    detect_server_country: "flag_emoji",
  };
}

function randomPriorityGroupId() {
  for (let i = 0; i < 100; i += 1) {
    const value = Math.floor(Math.random() * 0xffffffff)
      .toString(16)
      .padStart(8, "0");
    const id = `pg_${value}`;

    if (!uci.get(UCI_PACKAGE, id)) {
      return id;
    }
  }

  return `pg_${Date.now().toString(16)}`;
}

function addSubscriptionUrlItemOptions(itemSection, options = {}) {
  const parentSectionForItem =
    typeof options.parentSectionId === "function"
      ? options.parentSectionId
      : parentSectionIdForItem;

  let o = itemSection.option(
    form.Flag,
    "subscription_update_enabled",
    _("Subscription auto update"),
    _("Update this subscription automatically"),
  );
  o.default = "1";
  o.rmempty = false;

  o = itemSection.option(
    form.Value,
    "subscription_update_interval",
    _("Subscription update interval"),
    _("Use sing-box duration format like 1d, 12h or 30m"),
  );
  o.depends("subscription_update_enabled", "1");
  o.placeholder = "1h";
  o.validate = function (itemId, value) {
    return optionMapValue(this, itemId, "subscription_update_enabled") === "1"
      ? validateRequiredSingBoxDuration(value)
      : validateOptionalSingBoxDuration(value);
  };

  o = itemSection.option(
    form.Flag,
    "download_via_proxy_enabled",
    _("Download subscription through a section"),
    _("Download subscriptions via the selected section"),
  );
  o.default = "0";
  o.rmempty = false;

  o = itemSection.option(
    form.ListValue,
    "download_via_proxy_section",
    _("Download through"),
  );
  o.depends("download_via_proxy_enabled", "1");
  o.load = function (itemId) {
    const sectionId = parentSectionForItem(itemId);
    refreshOptionChoices(this, subscriptionDownloadTargetChoices(sectionId));
    return optionMapValue(this, itemId, "download_via_proxy_section") || "";
  };
  o.validate = function (itemId, value) {
    const sectionId = parentSectionForItem(itemId);
    if (optionMapValue(this, itemId, "download_via_proxy_enabled") !== "1") {
      return true;
    }
    if (!value) {
      return _("Select a section for downloading this subscription");
    }
    if (value === sectionId) {
      return _("Current section cannot download its own subscription");
    }
    return true;
  };

  o = itemSection.option(
    form.Flag,
    "auto_user_agent",
    _("Automatic User-Agent selection"),
    _(
      "Try compatible User-Agent profiles automatically when downloading this subscription",
    ),
  );
  o.default = "1";
  o.rmempty = false;

  o = itemSection.option(
    form.Value,
    "user_agent",
    _("User-Agent"),
    _("Select a common client profile or enter a custom User-Agent"),
  );
  o.depends("auto_user_agent", "0");
  o.placeholder = _("-- Select --");
  o.rmempty = false;
  subscriptionUserAgentChoices().forEach((choice) => o.value(choice));
  o.load = function (itemId) {
    return optionMapValue(this, itemId, "user_agent") || "";
  };
  o.validate = function (itemId, value) {
    if (optionMapValue(this, itemId, "auto_user_agent") !== "0") {
      return true;
    }
    return `${value || ""}`.trim() ? true : _("Select or enter a User-Agent");
  };

  o = itemSection.option(
    form.Flag,
    "auto_hwid",
    _("Auto-generate HWID"),
    _("Generate HWID from router hardware information for this subscription"),
  );
  o.default = "1";
  o.rmempty = false;

  o = itemSection.option(
    form.Value,
    "hwid",
    _("HWID"),
    _("Enter the HWID sent with subscription requests"),
  );
  o.depends("auto_hwid", "0");
  o.rmempty = false;
  o.validate = function (itemId, value) {
    if (optionMapValue(this, itemId, "auto_hwid") !== "0") {
      return true;
    }
    return `${value || ""}`.trim() ? true : _("Enter HWID");
  };

  o = itemSection.option(
    form.Flag,
    "show_dashboard_metadata",
    _("Show metadata on dashboard"),
    _("Show subscription metadata for this source on the dashboard"),
  );
  o.default = "1";
  o.rmempty = false;

  o = itemSection.option(
    form.Flag,
    "prefix_nodes",
    _("Add prefix to nodes"),
    _(
      "Automatically add text to the name of each server from this subscription for convenient filtering.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = itemSection.option(form.Value, "node_prefix", _("Prefix text"));
  o.depends("prefix_nodes", "1");
  o.rmempty = false;

  o = itemSection.option(
    form.Flag,
    "include_urltest_groups",
    _("Import subscription URLTest groups"),
    _("Import URLTest groups returned by this subscription provider"),
  );
  o.default = "1";
  o.rmempty = false;

  o = itemSection.option(
    form.Flag,
    "hide_urltest_group_outbounds",
    _("Hide URLTest group nodes"),
    _(
      "Hide individual nodes that are already included in imported subscription URLTest groups",
    ),
  );
  o.depends("include_urltest_groups", "1");
  o.default = "1";
  o.rmempty = false;

  o = itemSection.option(
    form.Flag,
    "hide_detour_outbounds",
    _("Hide cascade connection nodes"),
    _("Hide intermediate nodes used as detours by other subscription nodes"),
  );
  o.default = "1";
  o.rmempty = false;
}

function addInterfaceItemOptions(itemSection) {
  let o = itemSection.option(
    form.Flag,
    "domain_resolver_enabled",
    _("Domain Resolver"),
    _("Enable built-in DNS resolver for domains handled by this section"),
  );
  o.default = "0";
  o.rmempty = false;

  o = itemSection.option(
    form.ListValue,
    "domain_resolver_dns_type",
    _("DNS protocol"),
    _("DNS protocol used by the resolver"),
  );
  o.depends("domain_resolver_enabled", "1");
  dnsTypeChoices().forEach((choice) => o.value(choice.value, choice.label));
  o.default = "udp";

  o = itemSection.option(
    form.Value,
    "domain_resolver_dns_server",
    _("DNS server"),
    _("DNS server used by the resolver"),
  );
  o.depends("domain_resolver_enabled", "1");
  o.default = "8.8.8.8";
  o.validate = function (itemId, value) {
    if (optionMapValue(this, itemId, "domain_resolver_enabled") !== "1") {
      return true;
    }
    const validation = main.validateDNS(value);
    return validation.valid ? true : validation.message;
  };
}

function addUrlTestItemOptions(itemSection, options = {}) {
  const parentSectionForItem =
    typeof options.parentSectionId === "function"
      ? options.parentSectionId
      : parentSectionIdForItem;

  let o = itemSection.option(
    form.Value,
    "name",
    _("Display name"),
    _("Name displayed on the dashboard"),
  );
  o.rmempty = false;
  o.load = function (itemId) {
    return (
      optionMapValue(this, itemId, "name") ||
      optionMapValue(this, itemId, "display_name") ||
      ""
    );
  };
  o.validate = function (_itemId, value) {
    return `${value || ""}`.trim() ? true : _("Enter a display name");
  };

  o = itemSection.option(
    form.Value,
    "check_interval",
    _("Check interval"),
    _("Use sing-box duration format like 1d, 12h or 30m"),
  );
  o.default = "3m";
  o.rmempty = false;
  o.validate = function (_itemId, value) {
    return validateRequiredSingBoxDuration(value);
  };

  o = itemSection.option(
    form.Value,
    "tolerance",
    _("Tolerance"),
    _(
      "Minimum latency difference in milliseconds that triggers switching to a faster server.",
    ),
  );
  o.default = "50";
  o.rmempty = false;
  o.validate = function (_itemId, value) {
    return validateUrlTestTolerance(value);
  };

  o = itemSection.option(
    form.Value,
    "testing_url",
    _("Check URL"),
    _("URL used to test server latency"),
  );
  o.default = "https://www.gstatic.com/generate_204";
  o.rmempty = false;
  urlTestUrlChoices().forEach((value) => o.value(value));
  o.validate = function (_itemId, value) {
    return validateUrlTestUrl(value);
  };

  o = itemSection.option(
    form.Value,
    "idle_timeout",
    _("Idle timeout"),
    _(
      "Stop checking when URLTest group is not used. Use sing-box duration format like 1d, 12h or 30m.",
    ),
  );
  o.default = "30m";
  o.rmempty = false;
  o.validate = function (_itemId, value) {
    return validateRequiredSingBoxDuration(value);
  };

  o = itemSection.option(
    form.Flag,
    "interrupt_exist_connections",
    _("Interrupt existing connections"),
    _(
      "Interrupt existing connections when URLTest switches the selected server",
    ),
  );
  o.default = "1";
  o.rmempty = false;

  o = itemSection.option(
    form.Flag,
    "pin_dashboard",
    _("Pin on dashboard"),
    _("Keep URLTest before latency-sorted servers"),
  );
  o.default = "1";
  o.rmempty = false;

  o = itemSection.option(
    form.Flag,
    "hide_added_outbounds",
    _("Hide added servers"),
    _("Hide dashboard servers added to URLTest"),
  );
  o.default = "0";
  o.rmempty = false;

  o = itemSection.option(
    form.ListValue,
    "filter_mode",
    _("Server filtering"),
    _("Allows limiting the list of servers for URLTest"),
  );
  urlTestFilterModeChoices().forEach((choice) =>
    o.value(choice.value, choice.label),
  );
  o.default = "disabled";

  o = itemSection.option(
    form.ListValue,
    "detect_server_country",
    _("Detect server country"),
  );
  o.depends("filter_mode", "exclude");
  o.depends("filter_mode", "include");
  o.depends("filter_mode", "mixed");
  serverCountryDetectionChoices().forEach((choice) =>
    o.value(choice.value, choice.label),
  );
  o.default = "flag_emoji";

  const includeProxyParameterOptions = {
    prefix: "include",
    toggleLabel: _("Include by proxy parameters"),
    toggleDescription: _(
      "Additionally filter servers by protocol, transport, and security. Add only servers matching the specified parameters.",
    ),
    dependencies: [{ filter_mode: "include" }, { filter_mode: "mixed" }],
    protocolDescription: _(
      "Test only servers with one of the selected protocols.",
    ),
    transportDescription: _(
      "Test only servers with one of the selected transports.",
    ),
    securityDescription: _(
      "Test only servers with one of the selected security types.",
    ),
  };
  const excludeProxyParameterOptions = {
    prefix: "exclude",
    toggleLabel: _("Exclude by proxy parameters"),
    toggleDescription: _(
      "Additionally exclude servers by protocol, transport, and security. Exclude only servers matching the specified parameters.",
    ),
    dependencies: [{ filter_mode: "exclude" }, { filter_mode: "mixed" }],
    protocolDescription: _(
      "Do not test servers with one of the selected protocols.",
    ),
    transportDescription: _(
      "Do not test servers with one of the selected transports.",
    ),
    securityDescription: _(
      "Do not test servers with one of the selected security types.",
    ),
  };

  [
    [
      "include_countries",
      _("Include countries"),
      _("Test servers only from the specified countries."),
      countryChoices(),
      validateCountryCode,
      ["include", "mixed"],
    ],
    [
      "include_outbounds",
      _("Include servers"),
      _("Test only selected servers."),
      null,
      null,
      ["include", "mixed"],
    ],
    [
      "include_regex",
      _("Include by regular expression"),
      _("Test servers whose names match the expression."),
      null,
      validateRegex,
      ["include", "mixed"],
    ],
    [
      "exclude_countries",
      _("Exclude countries"),
      _("Do not test servers from these countries."),
      countryChoices(),
      validateCountryCode,
      ["exclude", "mixed"],
    ],
    [
      "exclude_outbounds",
      _("Exclude servers"),
      _("Do not test specified servers."),
      null,
      null,
      ["exclude", "mixed"],
    ],
    [
      "exclude_regex",
      _("Exclude by regular expression"),
      _("Do not test servers whose names match the expression."),
      null,
      validateRegex,
      ["exclude", "mixed"],
    ],
  ].forEach(([key, label, description, choices, validator, modes]) => {
    const list = itemSection.option(form.DynamicList, key, label, description);
    modes.forEach((mode) => list.depends("filter_mode", mode));
    list.rmempty = true;
    if (choices) {
      choices.forEach((choice) => list.value(choice.value, choice.label));
      list.placeholder = _("-- Select --");
    }
    if (key.endsWith("_outbounds")) {
      list.load = function (itemId) {
        const sectionId = parentSectionForItem(itemId);
        const values = normalizeOptionValues(optionMapValue(this, itemId, key));

        return loadOutboundNameChoices(sectionId).then(() => {
          refreshOptionChoices(
            this,
            currentOutboundNameChoices(sectionId, values),
          );
          return values;
        });
      };
      list.placeholder = _("-- Select --");
    }
    if (validator) {
      list.validate = function (_itemId, value) {
        return validator(null, value);
      };
    }
    if (key === "include_regex") {
      addProxyParameterFilterOptions(itemSection, includeProxyParameterOptions);
    } else if (key === "exclude_regex") {
      addProxyParameterFilterOptions(itemSection, excludeProxyParameterOptions);
    }
  });
}

function priorityLevelSettingsForValidation(groupId, levelId, option) {
  const store = childPendingSettingsStore(option, groupId);

  if (isExistingChildItem(groupId, levelId, "priority_level", "group")) {
    return readChildSettings(
      levelId,
      priorityLevelSettingsKeys(),
      defaultPriorityLevelSettings(),
    );
  }

  return Object.assign({}, store[levelId] || {});
}

function validatePriorityLevelItemsBeforeSave(groupId, values, option) {
  const normalizedValues = normalizeDynamicListItems(values);

  for (const value of normalizedValues) {
    const levelId = `${value || ""}`;
    const settings = priorityLevelSettingsForValidation(
      groupId,
      levelId,
      option,
    );

    if (!`${settings.name || ""}`.trim()) {
      return _("Enter a level name");
    }
  }

  return true;
}

function addPriorityLevelItemOptions(itemSection, options = {}) {
  const parentSectionForItem =
    typeof options.parentSectionId === "function"
      ? options.parentSectionId
      : parentSectionIdForItem;

  let o = itemSection.option(
    form.Value,
    "name",
    _("Level name"),
    _("Name shown in the priority level list"),
  );
  o.rmempty = false;
  o.validate = function (_itemId, value) {
    return `${value || ""}`.trim() ? true : _("Enter a level name");
  };

  o = itemSection.option(
    form.Flag,
    "direct",
    _("Direct connection"),
    _("Traffic for this level goes directly."),
  );
  o.default = "0";
  o.rmempty = false;

  o = itemSection.option(
    form.ListValue,
    "filter_mode",
    _("Server filtering"),
    _(
      "All remaining servers means every server not already assigned to a higher-priority level.",
    ),
  );
  priorityLevelFilterModeChoices().forEach((choice) =>
    o.value(choice.value, choice.label),
  );
  o.default = "include";
  o.depends("direct", "0");

  o = itemSection.option(
    form.ListValue,
    "detect_server_country",
    _("Detect server country"),
  );
  ["exclude", "include", "mixed"].forEach((mode) =>
    o.depends({ direct: "0", filter_mode: mode }),
  );
  serverCountryDetectionChoices().forEach((choice) =>
    o.value(choice.value, choice.label),
  );
  o.default = "flag_emoji";

  const includeProxyParameterOptions = {
    prefix: "include",
    toggleLabel: _("Include by proxy parameters"),
    toggleDescription: _(
      "Additionally filter servers by protocol, transport, and security. Add only servers matching the specified parameters.",
    ),
    dependencies: [
      { direct: "0", filter_mode: "include" },
      { direct: "0", filter_mode: "mixed" },
    ],
    protocolDescription: _("Only servers with one of the selected protocols."),
    transportDescription: _(
      "Only servers with one of the selected transports.",
    ),
    securityDescription: _(
      "Only servers with one of the selected security types.",
    ),
  };
  const excludeProxyParameterOptions = {
    prefix: "exclude",
    toggleLabel: _("Exclude by proxy parameters"),
    toggleDescription: _(
      "Additionally exclude servers by protocol, transport, and security. Exclude only servers matching the specified parameters.",
    ),
    dependencies: [
      { direct: "0", filter_mode: "exclude" },
      { direct: "0", filter_mode: "mixed" },
    ],
    protocolDescription: _(
      "Exclude servers with one of the selected protocols from this level.",
    ),
    transportDescription: _(
      "Exclude servers with one of the selected transports from this level.",
    ),
    securityDescription: _(
      "Exclude servers with one of the selected security types from this level.",
    ),
  };

  [
    [
      "country",
      _("Include countries"),
      _("Only from the specified countries."),
      countryChoices(),
      validateCountryCode,
      ["include", "mixed"],
    ],
    [
      "server_name",
      _("Include servers"),
      _("Only the specified servers."),
      null,
      null,
      ["include", "mixed"],
    ],
    [
      "regex",
      _("Include by regular expression"),
      _("Only servers whose names match the expression."),
      null,
      validateRegex,
      ["include", "mixed"],
    ],
    [
      "exclude_countries",
      _("Exclude countries"),
      _("Remove servers from the specified countries from this level."),
      countryChoices(),
      validateCountryCode,
      ["exclude", "mixed"],
    ],
    [
      "exclude_outbounds",
      _("Exclude servers"),
      _("Remove the specified servers from this level."),
      null,
      null,
      ["exclude", "mixed"],
    ],
    [
      "exclude_regex",
      _("Exclude by regular expression"),
      _("Remove servers whose names match the expression from this level."),
      null,
      validateRegex,
      ["exclude", "mixed"],
    ],
  ].forEach(([key, label, description, choices, validator, modes]) => {
    const list = itemSection.option(form.DynamicList, key, label, description);
    modes.forEach((mode) => list.depends({ direct: "0", filter_mode: mode }));
    list.rmempty = true;
    if (choices) {
      choices.forEach((choice) => list.value(choice.value, choice.label));
      list.placeholder = _("-- Select --");
    }
    if (key === "server_name" || key === "exclude_outbounds") {
      list.load = function (itemId) {
        const sectionId = parentSectionForItem(itemId);
        const values = normalizeOptionValues(optionMapValue(this, itemId, key));

        return loadOutboundNameChoices(sectionId).then(() => {
          refreshOptionChoices(
            this,
            currentOutboundNameChoices(sectionId, values),
          );
          return values;
        });
      };
      list.placeholder = _("-- Select --");
    }
    if (validator) {
      list.validate = function (_itemId, value) {
        return validator(null, value);
      };
    }
    if (key === "regex") {
      addProxyParameterFilterOptions(itemSection, includeProxyParameterOptions);
    } else if (key === "exclude_regex") {
      addProxyParameterFilterOptions(itemSection, excludeProxyParameterOptions);
    }
  });
}

function addPriorityGroupItemOptions(itemSection, options = {}) {
  const parentSectionForGroup =
    typeof options.parentSectionId === "function"
      ? options.parentSectionId
      : parentSectionIdForItem;
  const ownerId =
    typeof options.ownerId === "function" ? options.ownerId : () => "";

  let o = itemSection.option(
    form.Value,
    "name",
    _("Display name"),
    _("Name displayed on the dashboard"),
  );
  o.rmempty = false;
  o.validate = function (_itemId, value) {
    return `${value || ""}`.trim() ? true : _("Enter a display name");
  };

  o = itemSection.option(
    form.Value,
    "health_url",
    _("Check URL"),
    _("URL used to check whether a server is alive"),
  );
  o.default = "https://www.gstatic.com/generate_204";
  o.rmempty = false;
  urlTestUrlChoices().forEach((value) => o.value(value));
  o.validate = function (_itemId, value) {
    return validateUrlTestUrl(value);
  };

  o = itemSection.option(
    form.Value,
    "active_check_interval",
    _("Check interval"),
    _("How often the currently selected server is checked"),
  );
  o.default = "5s";
  o.rmempty = false;
  o.validate = function (_itemId, value) {
    return validateRequiredSingBoxDuration(value);
  };

  o = itemSection.option(
    form.Value,
    "check_timeout",
    _("Unavailability timeout"),
    _("Check timeout after which the server is considered dead"),
  );
  o.default = "2s";
  o.rmempty = false;
  o.validate = function (_itemId, value) {
    return validateRequiredSingBoxDuration(value);
  };

  o = itemSection.option(
    form.Value,
    "recovery_check_interval",
    _("Higher-level check interval"),
    _(
      "How often higher priority levels are checked while a lower level is active",
    ),
  );
  o.default = "15s";
  o.rmempty = false;
  o.validate = function (_itemId, value) {
    return validateRequiredSingBoxDuration(value);
  };

  o = itemSection.option(
    form.Flag,
    "pick_fastest",
    _("Select the fastest node"),
    _(
      "When switching to another level, test every server and select the fastest instead of the first working one.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = itemSection.option(
    form.Flag,
    "switch_to_faster_same_priority",
    _("Automatically select the fastest node in the current level"),
    _(
      "Periodically check the current level and switch to a faster server even when the current one works.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = itemSection.option(
    form.Value,
    "fastest_check_interval",
    _("Faster server search interval"),
    _("Use sing-box duration format like 1d, 12h or 30m"),
  );
  o.depends("switch_to_faster_same_priority", "1");
  o.default = "3m";
  o.rmempty = false;
  o.validate = function (itemId, value) {
    return optionMapValue(this, itemId, "switch_to_faster_same_priority") ===
      "1"
      ? validateRequiredSingBoxDuration(value)
      : true;
  };

  o = itemSection.option(
    form.Flag,
    "interrupt_exist_connections",
    _("Interrupt existing connections"),
    _("Interrupt existing connections when priority failover switches server"),
  );
  o.default = "1";
  o.rmempty = false;

  o = itemSection.option(
    form.Flag,
    "pin_dashboard",
    _("Pin on dashboard"),
    _("Keep Priority before latency-sorted servers"),
  );
  o.default = "1";
  o.rmempty = false;

  o = itemSection.option(
    form.Flag,
    "hide_added_outbounds",
    _("Hide added servers"),
    _("Hide dashboard servers added to Priority"),
  );
  o.default = "0";
  o.rmempty = false;

  o = itemSection.option(
    ButtonAddSettingsDynamicList,
    "priority_level",
    _("Priority levels"),
    _("Top level has the highest priority; lower levels are used as fallback"),
  );
  o.rmempty = true;
  o.modalonly = true;
  o.addButtonLabel = _("+ Add level");
  o.childType = "priority_level";
  o.ownerOption = "group";
  o.childOwnerId = ownerId;
  o.parentSectionId = parentSectionForGroup;
  o.childValueOption = "name";
  o.childDefaults = defaultPriorityLevelSettings();
  o.renderItemSettingsModal = showPriorityLevelSettingsModal;
  o.validateItemsOnSave = function (groupId, values) {
    return validatePriorityLevelItemsBeforeSave(groupId, values, this);
  };
  o.hasItemSettings = function (groupId, value) {
    const normalized = `${value || ""}`.trim();

    if (isExistingChildItem(groupId, normalized, "priority_level", "group")) {
      return true;
    }

    return normalized.length > 0;
  };
  o.inputValueForItem = function (groupId, value) {
    const inputValue = childItemInputValue(
      groupId,
      value,
      "priority_level",
      "name",
      "group",
    );
    const store = childPendingSettingsStore(this, groupId);
    return store[inputValue] && store[inputValue].name
      ? store[inputValue].name
      : inputValue;
  };
  o.stagedChildSettings = function (groupId, value) {
    const id = childItemInputValue(
      groupId,
      value,
      "priority_level",
      "name",
      "group",
    );
    const store = childPendingSettingsStore(this, groupId);
    return store[id] ? Object.assign({}, store[id]) : null;
  };
  o.clearStagedChildSettings = function (groupId) {
    if (this.pendingChildSettings) {
      delete this.pendingChildSettings[groupId];
    }
  };
  o.afterMaterializeChildItems = function (_groupId, itemIds) {
    itemIds.forEach((itemId, index) => {
      uci.set(UCI_PACKAGE, itemId, "order", `${index}`);
    });
  };
  o.renderListItemLabel = function (groupId, itemId) {
    return E(
      "span",
      { class: "fkp-dynlist-label" },
      this.inputValueForItem(groupId, itemId),
    );
  };
}

function settingValueEquals(left, right) {
  const normalize = (value) => {
    if (Array.isArray(value)) {
      return JSON.stringify(value.map((item) => `${item || ""}`));
    }

    return value === undefined || value === null ? "" : `${value}`;
  };

  return normalize(left) === normalize(right);
}

function readChildSettings(itemId, keys, defaults) {
  const result = Object.assign({}, defaults || {});

  keys.forEach((key) => {
    const value = uci.get(UCI_PACKAGE, itemId, key);
    if (value !== null && value !== undefined) {
      result[key] = Array.isArray(value) ? value.slice() : value;
    }
  });

  return result;
}

function changedSettings(base, next, keys) {
  const result = {};

  keys.forEach((key) => {
    if (!settingValueEquals(base ? base[key] : null, next ? next[key] : null)) {
      result[key] = next ? next[key] : null;
    }
  });

  return result;
}

function hasChangedSettings(settings) {
  return Object.keys(settings || {}).length > 0;
}

function childPendingSettingsStore(option, section_id) {
  if (!option.pendingChildSettings) {
    option.pendingChildSettings = {};
  }

  if (!option.pendingChildSettings[section_id]) {
    option.pendingChildSettings[section_id] = {};
  }

  return option.pendingChildSettings[section_id];
}

function pendingChildSettings(option, section_id, value, defaults) {
  value = `${value || ""}`.trim();
  const store = childPendingSettingsStore(option, section_id);

  if (!store[value]) {
    store[value] = Object.assign({}, defaults || {});
  }

  return store[value];
}

function renderStackedJsonSettingsModal(title, map, onSave) {
  const modal = document.querySelector("#modal_overlay > .modal.cbi-modal");
  const activeMap = modal ? modal.querySelector(".cbi-map:not(.hidden)") : null;
  const buttonRow = modal ? modal.querySelector("div.button-row") : null;
  const heading = modal ? modal.querySelector("h4") : null;

  if (!modal || !activeMap || !buttonRow || !heading) {
    return Promise.resolve();
  }

  return map.render().then((nodes) => {
    const titleNode = E("span", title ? ` » ${title}` : "");
    const originalButtonClass = buttonRow.getAttribute("class") || "";
    const originalButtonNodes = Array.from(buttonRow.childNodes);
    let closed = false;
    let saveButton;

    const restoreButtonRow = () => {
      buttonRow.textContent = "";
      originalButtonNodes.forEach((node) => buttonRow.appendChild(node));
      buttonRow.setAttribute("class", originalButtonClass);
    };

    const close = () => {
      if (closed) {
        return;
      }

      closed = true;

      if (nodes.parentNode) {
        nodes.parentNode.removeChild(nodes);
      }
      if (titleNode.parentNode) {
        titleNode.parentNode.removeChild(titleNode);
      }

      activeMap.classList.remove("hidden");
      restoreButtonRow();
    };

    const save = () => {
      if (saveButton) {
        saveButton.disabled = true;
      }

      return map
        .parse()
        .then(() => {
          onSave(cleanFormSectionData(map.data.get(map.config, "settings")));
          close();
        })
        .catch(() => {
          if (saveButton) {
            saveButton.disabled = false;
          }
        });
    };

    buttonRow.textContent = "";
    buttonRow.append(
      E(
        "button",
        {
          class: "btn cbi-button",
          click: close,
        },
        _("Close"),
      ),
      " ",
      (saveButton = E(
        "button",
        {
          class: "btn cbi-button cbi-button-positive important",
          click: save,
        },
        _("Save"),
      )),
    );

    heading.appendChild(titleNode);
    activeMap.classList.add("hidden");
    activeMap.parentNode.insertBefore(nodes, activeMap.nextElementSibling);
  });
}

function showChildItemSettingsModal(section_id, itemValue, option, settings) {
  const value = `${itemValue || ""}`.trim();
  const existing = isExistingChildItem(
    section_id,
    value,
    settings.typeName,
    settings.ownerOption,
  );
  const inputValue = childItemInputValue(
    section_id,
    value,
    settings.typeName,
    settings.valueOption,
    settings.ownerOption,
  );
  const defaults =
    typeof settings.defaults === "function"
      ? settings.defaults(inputValue)
      : Object.assign({}, settings.defaults || {});
  const initialSettings = existing
    ? readChildSettings(value, settings.keys, defaults)
    : Object.assign(
        {},
        pendingChildSettings(option, section_id, inputValue, defaults),
      );
  const data = {
    settings: Object.assign({}, initialSettings),
  };
  const map = new form.JSONMap(data);
  const itemSection = map.section(form.NamedSection, "settings");
  itemSection.anonymous = true;
  itemSection.addremove = false;
  settings.addOptions(itemSection, {
    parentSectionId: () => section_id,
    ownerId: () => value || section_id,
  });

  return renderStackedJsonSettingsModal(
    settings.title(inputValue),
    map,
    (nextSettings) => {
      if (existing) {
        const diff = changedSettings(
          initialSettings,
          nextSettings,
          settings.keys,
        );
        if (hasChangedSettings(diff)) {
          applyChildItemSettings(value, diff);
        }
        if (typeof settings.afterSave === "function") {
          settings.afterSave(value, inputValue, nextSettings, existing);
        }
        return;
      }

      const nextInputValue =
        `${nextSettings[settings.valueOption] || inputValue || ""}`.trim();
      const store = childPendingSettingsStore(option, section_id);
      if (nextInputValue !== inputValue) {
        delete store[inputValue];
      }
      store[nextInputValue] = nextSettings;
      if (typeof settings.afterSave === "function") {
        settings.afterSave(value, nextInputValue, nextSettings, existing);
      }
    },
  );
}

function ruleSetIncludesSubnets(section_id, value) {
  const settings = readItemSettingsMap(section_id, RULE_SET_ITEM_SETTINGS_KEY);
  const itemSettings = settings && settings[value];

  if (
    itemSettings &&
    typeof itemSettings === "object" &&
    itemSettings.include_subnets != null
  ) {
    return itemSettingsFlag(itemSettings, "include_subnets", false);
  }

  return getConfigListValues(section_id, "rule_set_with_subnets").includes(
    value,
  );
}

function showSubscriptionUrlSettingsModal(_section_id, itemValue, option) {
  return showChildItemSettingsModal(_section_id, itemValue, option, {
    typeName: "subscription_url",
    valueOption: "url",
    keys: subscriptionUrlSettingsKeys(),
    defaults: defaultSubscriptionUrlSettings(),
    addOptions: addSubscriptionUrlItemOptions,
    title: () => _("Subscription URL settings"),
  });
}

function showInterfaceSettingsModal(_section_id, itemValue, option) {
  return showChildItemSettingsModal(_section_id, itemValue, option, {
    typeName: "section_interface",
    valueOption: "name",
    keys: interfaceSettingsKeys(),
    defaults: defaultInterfaceSettings(),
    addOptions: addInterfaceItemOptions,
    title: () => _("Network interface settings"),
  });
}

function showUrlTestSettingsModal(
  _section_id,
  itemValue,
  option,
  widget,
  itemNode,
  context = {},
) {
  return showChildItemSettingsModal(_section_id, itemValue, option, {
    typeName: "urltest",
    valueOption: "name",
    keys: urlTestSettingsKeys(),
    defaults: defaultUrlTestSettings,
    addOptions: addUrlTestItemOptions,
    title: (name) => {
      const normalized = `${name || ""}`.trim();
      return !normalized || /^urltest-[a-z0-9]+-\d+$/.test(normalized)
        ? _("URLTest settings")
        : `${_("URLTest settings")}: ${normalized}`;
    },
    afterSave: (itemId, inputValue, settings, existing) => {
      const displayName = `${settings.name || inputValue || ""}`.trim();

      if (existing) {
        uci.unset(UCI_PACKAGE, itemId, "id");
        uci.unset(UCI_PACKAGE, itemId, "display_name");
        updateDynamicListItemLabel(itemNode, displayName);
        return;
      }

      if (context.adding) {
        addDynamicListItem(widget, displayName, displayName);
      } else {
        updateDynamicListItemLabel(itemNode, displayName);
      }
    },
  });
}

function showPriorityLevelSettingsModal(
  groupId,
  itemValue,
  option,
  widget,
  itemNode,
  context = {},
) {
  return showChildItemSettingsModal(groupId, itemValue, option, {
    typeName: "priority_level",
    ownerOption: "group",
    valueOption: "name",
    keys: priorityLevelSettingsKeys(),
    defaults: defaultPriorityLevelSettings(),
    addOptions: (itemSection) =>
      addPriorityLevelItemOptions(itemSection, {
        parentSectionId: () => context.parentSectionId || "",
      }),
    title: (name) => {
      const normalized = `${name || ""}`.trim();
      return normalized
        ? `${_("Priority level settings")}: ${normalized}`
        : _("Priority level settings");
    },
    afterSave: (itemId, inputValue, settings, existing) => {
      const displayName = `${settings.name || inputValue || ""}`.trim();

      if (existing) {
        updateDynamicListItemLabel(itemNode, displayName);
        return;
      }

      if (context.adding) {
        addDynamicListItem(widget, displayName, displayName);
      } else {
        updateDynamicListItemLabel(itemNode, displayName);
      }
    },
  });
}

function createPriorityGroupItem(section_id, groupId, settings) {
  const created = uci.add(UCI_PACKAGE, "priority_group", groupId) || groupId;

  uci.set(UCI_PACKAGE, created, "section", section_id);
  Object.entries(priorityGroupChildDefaults()).forEach(([key, value]) => {
    if (value !== undefined && value !== null && value !== "") {
      uci.set(UCI_PACKAGE, created, key, `${value}`);
    }
  });
  applyChildItemSettings(created, settings);

  return created;
}

function showPriorityGroupSettingsModal(
  section_id,
  itemValue,
  option,
  widget,
  itemNode,
  context = {},
) {
  const groupId = context.adding
    ? randomPriorityGroupId()
    : `${itemValue || ""}`.trim();

  if (!groupId) {
    return null;
  }

  return showChildItemSettingsModal(section_id, groupId, option, {
    typeName: "priority_group",
    valueOption: "name",
    keys: priorityGroupSettingsKeys(),
    defaults: defaultPriorityGroupSettings(),
    addOptions: addPriorityGroupItemOptions,
    title: (name) => {
      if (context.adding) {
        return _("Priority settings");
      }

      const normalized = `${name || ""}`.trim();
      return normalized
        ? `${_("Priority settings")}: ${normalized}`
        : _("Priority settings");
    },
    afterSave: (itemId, inputValue, settings, existing) => {
      const displayName = `${settings.name || inputValue || ""}`.trim();

      if (!existing) {
        const created = createPriorityGroupItem(section_id, groupId, settings);
        const store = childPendingSettingsStore(option, section_id);
        delete store[groupId];
        delete store[inputValue];
        delete store[displayName];
        addDynamicListItem(widget, created, displayName);
        return;
      }

      updateDynamicListItemLabel(itemNode, displayName);
    },
  });
}

function validateUrlTestItemsBeforeSave(section_id, values, option) {
  const store = childPendingSettingsStore(option, section_id);

  for (const value of normalizeDynamicListItems(values)) {
    const itemId = `${value || ""}`;
    let name = "";

    if (isExistingChildItem(section_id, itemId, "urltest")) {
      name =
        uci.get(UCI_PACKAGE, itemId, "name") ||
        uci.get(UCI_PACKAGE, itemId, "display_name") ||
        "";
    } else if (store[itemId]) {
      name = store[itemId].name || "";
    }

    if (!`${name || ""}`.trim()) {
      return _("Enter a display name");
    }
  }

  return true;
}

function validatePriorityGroupItemsBeforeSave(section_id, values) {
  for (const value of normalizeDynamicListItems(values)) {
    const groupId = `${value || ""}`.trim();

    if (!isExistingChildItem(section_id, groupId, "priority_group")) {
      return _("Open priority settings and enter a display name");
    }

    if (!`${uci.get(UCI_PACKAGE, groupId, "name") || ""}`.trim()) {
      return _("Enter a display name");
    }
  }

  return true;
}

function showOutboundJsonSettingsModal(
  _section_id,
  itemValue,
  _option,
  widget,
  itemNode,
  context = {},
) {
  const data = {
    settings: {
      outbound_json: `${itemValue || ""}`,
    },
  };
  const map = new form.JSONMap(data);
  const itemSection = map.section(form.NamedSection, "settings");
  itemSection.anonymous = true;
  itemSection.addremove = false;

  const jsonOption = itemSection.option(
    form.TextValue,
    "outbound_json",
    _("JSON outbound"),
    _("Enter a complete sing-box outbound object"),
  );
  jsonOption.rows = 12;
  jsonOption.wrap = "soft";
  jsonOption.textarea = true;
  jsonOption.modalonly = true;
  jsonOption.rmempty = false;
  jsonOption.validate = function (_itemId, value) {
    const usedTags =
      widget && widget.node
        ? Array.from(widget.node.querySelectorAll(".item"))
            .filter((item) => item !== itemNode)
            .map((item) =>
              outboundJsonDisplayTag(dynamicListItemCurrentValue(item, "")),
            )
            .filter(Boolean)
        : [];
    const validation = main.validateOutboundJson(`${value || ""}`, usedTags);
    return validation.valid ? true : validation.message;
  };
  configureTextareaOption(jsonOption);

  return renderStackedJsonSettingsModal(
    _("JSON outbound settings"),
    map,
    (settings) => {
      const value = `${settings.outbound_json || ""}`.trim();
      if (context.adding) {
        addDynamicListItem(widget, value);
        return;
      }

      setDynamicListItemValue(itemNode, value);
      updateDynamicListItemLabel(itemNode, outboundJsonDisplayTag(value));
      if (widget && widget.node) {
        widget.dispatchCbiDynlistChange(widget.node, value);
      }
    },
  );
}

function validateOutboundJsonItemsBeforeSave(_section_id, values) {
  const items = Array.isArray(values) ? values : values ? [values] : [];
  const tags = [];

  for (const value of items) {
    const validation = main.validateOutboundJson(`${value || ""}`, tags);
    if (!validation.valid) {
      const tag = outboundJsonDisplayTag(value);
      return tag ? `${tag}: ${validation.message}` : validation.message;
    }

    const tag = outboundJsonDisplayTag(value);
    tags.push(tag);
  }

  return true;
}

function showRuleSetSettingsModal(section_id, itemValue, option, widget) {
  const data = {
    settings: {
      include_subnets: ruleSetIncludesSubnets(section_id, itemValue)
        ? "1"
        : "0",
    },
  };
  const map = new form.JSONMap(data);
  const section = map.section(form.NamedSection, "settings");
  section.anonymous = true;
  section.addremove = false;

  const includeSubnets = section.option(
    form.Flag,
    "include_subnets",
    _("Include IP addresses and subnets"),
    _("Subnets from the list will be extracted and added to nftables"),
  );
  includeSubnets.default = "0";
  includeSubnets.rmempty = false;

  return renderStackedJsonSettingsModal(
    _("Rule set settings"),
    map,
    (settings) => {
      const value = settings.include_subnets === "1";
      const refs = uniqueDynamicListItems(
        widget && typeof widget.getValue === "function"
          ? widget.getValue()
          : getCustomRulesetReferences(section_id),
      );
      const subnets = new Set(
        getConfigListValues(section_id, "rule_set_with_subnets").filter((ref) =>
          refs.includes(ref),
        ),
      );

      if (value) {
        subnets.add(itemValue);
      } else {
        subnets.delete(itemValue);
      }

      writeListOption(
        section_id,
        "rule_set",
        refs.filter((ref) => !subnets.has(ref)),
      );
      writeListOption(section_id, "rule_set_with_subnets", [...subnets]);
      if (option && typeof option.getUIElement === "function") {
        option.getUIElement(section_id).setValue(refs);
      }
    },
  );
}

function ensureActionProvidersAvailabilityLoaded() {
  if (actionProvidersAvailabilityState.loaded) {
    return Promise.resolve(actionProvidersAvailabilityState);
  }

  if (actionProvidersAvailabilityPromise) {
    return actionProvidersAvailabilityPromise;
  }

  if (actionProvidersAvailabilityLoader) {
    actionProvidersAvailabilityPromise = actionProvidersAvailabilityLoader()
      .then((capabilities) => {
        updateActionProvidersAvailabilityState({
          zapretInstalled: Boolean(capabilities?.zapretInstalled),
          zapret2Installed: Boolean(capabilities?.zapret2Installed),
          byedpiInstalled: Boolean(capabilities?.byedpiInstalled),
        });
        return actionProvidersAvailabilityState;
      })
      .catch(() => {
        actionProvidersAvailabilityLoader = null;
        actionProvidersAvailabilityPromise = null;
        return ensureActionProvidersAvailabilityLoaded();
      })
      .finally(() => {
        actionProvidersAvailabilityPromise = null;
      });

    return actionProvidersAvailabilityPromise;
  }

  actionProvidersAvailabilityPromise = Promise.allSettled([
    main.ForkopShellMethods.checkZapretRuntime(),
    main.ForkopShellMethods.checkZapret2Runtime(),
    main.ForkopShellMethods.checkByedpiRuntime(),
  ])
    .then(([zapretResult, zapret2Result, byedpiResult]) => {
      const zapret =
        zapretResult && zapretResult.status === "fulfilled"
          ? zapretResult.value
          : null;
      const zapret2 =
        zapret2Result && zapret2Result.status === "fulfilled"
          ? zapret2Result.value
          : null;
      const byedpi =
        byedpiResult && byedpiResult.status === "fulfilled"
          ? byedpiResult.value
          : null;

      actionProvidersAvailabilityState.loaded = true;
      actionProvidersAvailabilityState.zapretInstalled = Boolean(
        zapret && zapret.success && zapret.data && zapret.data.zapret_installed,
      );
      actionProvidersAvailabilityState.zapret2Installed = Boolean(
        zapret2 &&
          zapret2.success &&
          zapret2.data &&
          zapret2.data.zapret2_installed,
      );
      actionProvidersAvailabilityState.byedpiInstalled = Boolean(
        byedpi && byedpi.success && byedpi.data && byedpi.data.byedpi_installed,
      );
      return actionProvidersAvailabilityState;
    })
    .catch(() => {
      actionProvidersAvailabilityState.loaded = true;
      actionProvidersAvailabilityState.zapretInstalled = false;
      actionProvidersAvailabilityState.zapret2Installed = false;
      actionProvidersAvailabilityState.byedpiInstalled = false;
      return actionProvidersAvailabilityState;
    })
    .finally(() => {
      actionProvidersAvailabilityPromise = null;
    });

  return actionProvidersAvailabilityPromise;
}

function isZapretInstalledForUi() {
  return actionProvidersAvailabilityState.zapretInstalled;
}

function isZapret2InstalledForUi() {
  return actionProvidersAvailabilityState.zapret2Installed;
}

function isByedpiInstalledForUi() {
  return actionProvidersAvailabilityState.byedpiInstalled;
}

function getRuleConfiguredAction(section_id) {
  const action = uci.get(UCI_PACKAGE, section_id, "action");
  return action ? `${action}` : null;
}

function getRuleResolvedAction(section_id) {
  return getRuleConfiguredAction(section_id) || "connection";
}

function getActionOptionLabel(action) {
  switch (`${action}`) {
    case "block":
      return "Block";
    case "bypass":
      return "Bypass";
    case "connection":
      return "Connection";
    case "dns":
      return "DNS";
    case "vpn":
      return "VPN";
    case "zapret":
      return "Zapret";
    case "zapret2":
      return "Zapret2";
    case "byedpi":
      return "ByeDPI";
    case "outbound":
      return _("JSON outbound");
    case "proxy":
    default:
      return "Proxy";
  }
}

function getRuleActionDisplayValue(section_id) {
  const action = getRuleResolvedAction(section_id);

  if (action === "zapret") {
    return "Zapret";
  }

  if (action === "zapret2") {
    return "Zapret2";
  }

  if (action === "byedpi") {
    return "ByeDPI";
  }

  return getActionOptionLabel(action);
}

function getRuleActionDisplayMarkup(section_id) {
  return getRuleActionDisplayValue(section_id);
}

function populateActionOptionValues(option) {
  delete option.keylist;
  delete option.vallist;

  option.value("connection", getActionOptionLabel("connection"));
  option.value("bypass", "Bypass");
  option.value("block", "Block");
  option.value("dns", "DNS");
  if (isZapretInstalledForUi()) {
    option.value("zapret", getActionOptionLabel("zapret"));
  }
  if (isZapret2InstalledForUi()) {
    option.value("zapret2", getActionOptionLabel("zapret2"));
  }
  if (isByedpiInstalledForUi()) {
    option.value("byedpi", getActionOptionLabel("byedpi"));
  }
}

function setFlagOptionWidgetValue(section_id, optionName, enabled) {
  const frame = document.getElementById(
    `cbid.${UCI_PACKAGE}.${section_id}.${optionName}`,
  );
  const checkbox = frame ? frame.querySelector('input[type="checkbox"]') : null;

  if (!checkbox || checkbox.checked === Boolean(enabled)) {
    return;
  }

  checkbox.checked = Boolean(enabled);
  checkbox.dispatchEvent(new Event("change", { bubbles: true }));
}

function getConfigListValues(section_id, key) {
  return normalizeOptionValues(uci.get(UCI_PACKAGE, section_id, key));
}

function stringArraysEqual(left, right) {
  left = normalizeDynamicListItems(left);
  right = normalizeDynamicListItems(right);

  return (
    left.length === right.length &&
    left.every((value, index) => value === right[index])
  );
}

function writeListOption(section_id, key, values) {
  const normalized = normalizeOptionValues(values);

  if (stringArraysEqual(getConfigListValues(section_id, key), normalized)) {
    return;
  }

  if (normalized.length) {
    uci.set(UCI_PACKAGE, section_id, key, normalized);
  } else {
    uci.unset(UCI_PACKAGE, section_id, key);
  }
}

function childOwnerOption(ownerOption) {
  return ownerOption || "section";
}

function childItemOrder(item) {
  const value = item ? item.order : null;
  const parsed = Number.parseInt(value == null ? "0" : `${value}`, 10);
  return Number.isFinite(parsed) ? parsed : 0;
}

function getChildItemIds(section_id, typeName, ownerOption) {
  const ownerKey = childOwnerOption(ownerOption);
  const items = uci
    .sections(UCI_PACKAGE, typeName)
    .filter((item) => item[ownerKey] === section_id);

  if (typeName === "priority_level") {
    items.sort((a, b) => {
      const orderDiff = childItemOrder(a) - childItemOrder(b);
      if (orderDiff !== 0) {
        return orderDiff;
      }

      return `${a[".name"] || ""}`.localeCompare(`${b[".name"] || ""}`);
    });
  }

  return items.map((item) => item[".name"]).filter(Boolean);
}

function childItemValue(itemId, valueOption, fallback) {
  if (!valueOption) {
    return itemId;
  }

  const value = uci.get(UCI_PACKAGE, itemId, valueOption);
  return value == null || value === "" ? fallback || itemId : `${value}`;
}

function childItemInputValue(
  section_id,
  value,
  typeName,
  valueOption,
  ownerOption,
) {
  const itemId = `${value || ""}`;

  if (isExistingChildItem(section_id, itemId, typeName, ownerOption)) {
    return childItemValue(itemId, valueOption, itemId);
  }

  return itemId;
}

function isExistingChildItem(section_id, itemId, typeName, ownerOption) {
  const ownerKey = childOwnerOption(ownerOption);

  return Boolean(
    itemId &&
      uci.get(UCI_PACKAGE, itemId, ".type") === typeName &&
      uci.get(UCI_PACKAGE, itemId, ownerKey) === section_id,
  );
}

function findChildItemForInput(section_id, options, inputValue) {
  const rawValue = `${inputValue || ""}`.trim();

  if (
    isExistingChildItem(
      section_id,
      rawValue,
      options.typeName,
      options.ownerOption,
    )
  ) {
    return rawValue;
  }

  if (options.valueOption) {
    return getChildItemIds(
      section_id,
      options.typeName,
      options.ownerOption,
    ).find(
      (itemId) =>
        childItemValue(itemId, options.valueOption, itemId) === rawValue,
    );
  }

  return null;
}

function createChildItem(section_id, options, inputValue) {
  const rawValue = `${inputValue || ""}`.trim();
  const existing = findChildItemForInput(section_id, options, rawValue);

  if (existing) {
    return {
      value: existing,
      text: options.valueOption
        ? childItemValue(existing, options.valueOption, existing)
        : existing,
      created: false,
    };
  }

  const requestedId =
    typeof options.createId === "function"
      ? `${options.createId(rawValue, section_id) || ""}`.trim()
      : "";
  const itemId =
    (requestedId && uci.add(UCI_PACKAGE, options.typeName, requestedId)) ||
    requestedId ||
    uci.add(UCI_PACKAGE, options.typeName);

  uci.set(
    UCI_PACKAGE,
    itemId,
    childOwnerOption(options.ownerOption),
    section_id,
  );

  if (options.valueOption) {
    uci.set(UCI_PACKAGE, itemId, options.valueOption, rawValue);
  }

  if (options.defaults && typeof options.defaults === "object") {
    Object.entries(options.defaults).forEach(([key, value]) => {
      value =
        typeof value === "function"
          ? value(rawValue, section_id, itemId)
          : value;
      if (value !== undefined && value !== null && value !== "") {
        uci.set(UCI_PACKAGE, itemId, key, `${value}`);
      }
    });
  }

  return {
    value: itemId,
    text: options.valueOption ? rawValue : itemId,
    created: true,
  };
}

function applyChildItemSettings(itemId, settings) {
  Object.entries(settings || {}).forEach(([key, value]) => {
    if (!key || key.charAt(0) === ".") {
      return;
    }

    if (value === undefined || value === null || value === "") {
      uci.unset(UCI_PACKAGE, itemId, key);
    } else if (Array.isArray(value)) {
      uci.set(
        UCI_PACKAGE,
        itemId,
        key,
        value
          .map((item) => `${item || ""}`.trim())
          .filter((item) => item.length),
      );
    } else {
      uci.set(UCI_PACKAGE, itemId, key, `${value}`);
    }
  });
}

function materializeChildItems(section_id, options, inputValue) {
  const result = [];
  const seen = new Set();

  normalizeDynamicListItems(inputValue).forEach((value) => {
    const createdItem = createChildItem(section_id, options, value);
    const itemId = createdItem.value;
    const stagedSettings =
      createdItem.created && typeof options.stagedSettings === "function"
        ? options.stagedSettings(value, itemId, createdItem.created)
        : null;

    if (stagedSettings) {
      applyChildItemSettings(itemId, stagedSettings);
    }

    if (itemId && !seen.has(itemId)) {
      seen.add(itemId);
      result.push(itemId);
    }
  });

  return result;
}

function cleanupPriorityLevelsForGroup(groupId) {
  getChildItemIds(groupId, "priority_level", "group").forEach((levelId) => {
    uci.remove(UCI_PACKAGE, levelId);
  });
}

function cleanupRemovedChildItems(
  section_id,
  typeName,
  keepValues,
  ownerOption,
) {
  const keep = new Set(normalizeDynamicListItems(keepValues));

  getChildItemIds(section_id, typeName, ownerOption).forEach((itemId) => {
    if (!keep.has(itemId)) {
      if (typeName === "priority_group") {
        cleanupPriorityLevelsForGroup(itemId);
      }
      uci.remove(UCI_PACKAGE, itemId);
    }
  });
}

function parentSectionIdForItem(itemId) {
  return uci.get(UCI_PACKAGE, itemId, "section") || "";
}

function refreshOptionChoices(option, choices) {
  delete option.keylist;
  delete option.vallist;

  (choices || []).forEach((choice) => {
    if (typeof choice === "object") {
      option.value(choice.value, choice.label);
    } else {
      option.value(choice);
    }
  });
}

function validateRegex(_section_id, value) {
  if (!value || !value.length) {
    return true;
  }

  try {
    new RegExp(value);
    return true;
  } catch (_error) {
    return _("Invalid regular expression");
  }
}

function validateKeyword(_section_id, value) {
  if (!value || !value.length) {
    return true;
  }

  if (/[,\s]/.test(value)) {
    return _("Keyword must not contain spaces or commas");
  }

  return true;
}

function isSingBoxDuration(value) {
  return /^([0-9]+(?:\.[0-9]+)?(?:ns|us|ms|s|m|h|d))+$/.test(value);
}

function readDurationOptionWithDefault(section_id, key, defaultValue) {
  if (uci.get(UCI_PACKAGE, section_id, `${key}_disabled`) === "1") {
    return "";
  }

  const rawValue = uci.get(UCI_PACKAGE, section_id, key);

  if (rawValue == null) {
    return defaultValue;
  }

  return `${rawValue}`;
}

function writeOptionalDurationOption(section_id, key, value) {
  const normalized = value ? `${value}`.trim() : "";
  const disabledKey = `${key}_disabled`;

  if (normalized.length) {
    uci.set(UCI_PACKAGE, section_id, key, normalized);
    uci.unset(UCI_PACKAGE, section_id, disabledKey);
  } else {
    uci.unset(UCI_PACKAGE, section_id, key);
    uci.set(UCI_PACKAGE, section_id, disabledKey, "1");
  }
}

function removeOptionalDurationOption(section_id, key) {
  writeOptionalDurationOption(section_id, key, "");
}

function validateOptionalSingBoxDuration(value) {
  const normalized = value ? `${value}`.trim() : "";

  if (!normalized.length) {
    return true;
  }

  if (isSingBoxDuration(normalized)) {
    return true;
  }

  return _("Use sing-box duration format like 1d, 12h or 30m");
}

function validateRequiredSingBoxDuration(value) {
  const normalized = value ? `${value}`.trim() : "";

  if (!normalized.length) {
    return _("Use sing-box duration format like 1d, 12h or 30m");
  }

  if (isSingBoxDuration(normalized)) {
    return true;
  }

  return _("Use sing-box duration format like 1d, 12h or 30m");
}

function parseSubscriptionUrlEntry(value) {
  const normalized = value ? `${value}`.trim() : "";

  if (!normalized.length) {
    return { valid: true, url: "" };
  }

  if (normalized.includes("|")) {
    return {
      valid: false,
      message: _("Configure User-Agent in the item settings"),
    };
  }

  return { valid: true, url: normalized };
}

function validateSubscriptionUrlEntry(_section_id, value) {
  if (!value || value.length === 0) {
    return true;
  }

  const parsed = parseSubscriptionUrlEntry(value);
  if (!parsed.valid) {
    return parsed.message;
  }

  const validation = main.validateUrl(parsed.url);
  return validation.valid ? true : validation.message;
}

function parseRequiredValueOnSave(section_id) {
  const active = this.isActive(section_id);

  if (active && !this.isValid(section_id)) {
    const title = this.stripTags(this.title).trim();
    const error = this.getValidationError(section_id);
    return Promise.reject(
      new TypeError(
        `${_('Option "%s" contains an invalid input value.').format(title || this.option)} ${error}`,
      ),
    );
  }

  if (active) {
    const formValue = this.formvalue(section_id);
    const normalized = formValue ? `${formValue}`.trim() : "";

    if (!normalized.length) {
      return Promise.reject(
        new TypeError(_("Subscription URL cannot be empty")),
      );
    }

    return Promise.resolve(this.write(section_id, normalized));
  }

  if (!this.retain) {
    return Promise.resolve(this.remove(section_id));
  }

  return Promise.resolve();
}

function getDuplicateTextListErrors(values, normalizeValue, duplicateMessage) {
  const seen = new Set();
  const duplicates = [];

  values.forEach((item) => {
    const normalized = normalizeValue ? normalizeValue(item) : item;

    if (seen.has(normalized)) {
      if (!duplicates.includes(item)) {
        duplicates.push(item);
      }
      return;
    }

    seen.add(normalized);
  });

  return duplicates.map((item) => `${item}: ${duplicateMessage}`);
}

function validateTextList(
  _section_id,
  value,
  validateItem,
  emptyMessage,
  options = {},
) {
  if (!value || value.length === 0) {
    return true;
  }

  const values = main.parseValueList(value);

  if (!values.length) {
    return emptyMessage;
  }

  if (!validateItem) {
    const duplicateErrors = getDuplicateTextListErrors(
      values,
      options.normalizeDuplicateValue,
      options.duplicateMessage || _("Duplicate value"),
    );

    if (!duplicateErrors.length) {
      return true;
    }

    return [_("Validation errors:"), ...duplicateErrors].join("\n");
  }

  const { valid, results } = main.bulkValidate(values, validateItem);

  const duplicateErrors = getDuplicateTextListErrors(
    values,
    options.normalizeDuplicateValue,
    options.duplicateMessage || _("Duplicate value"),
  );

  if (valid && !duplicateErrors.length) {
    return true;
  }

  const errors = results
    .filter((item) => !item.valid)
    .map((item) => `${item.value}: ${item.message}`)
    .concat(duplicateErrors);

  return [_("Validation errors:"), ...errors].join("\n");
}

function getValidationHeaderText() {
  return _("Validation errors:");
}

function getDuplicateValueText() {
  return _("Duplicate value");
}

function escapeHtml(value) {
  return `${value}`
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function ensureAnnotatedTextareaStyles() {
  if (
    typeof document === "undefined" ||
    !document.head ||
    document.getElementById(ANNOTATED_TEXTAREA_STYLE_ID)
  ) {
    return;
  }

  document.head.insertAdjacentHTML(
    "beforeend",
    `<style id="${ANNOTATED_TEXTAREA_STYLE_ID}">
      .fkp-annotated-textarea {
        position: relative;
      }

      .fkp-annotated-textarea > textarea {
        position: relative;
        z-index: 1;
        background: transparent !important;
      }

      .fkp-annotated-textarea__overlay {
        position: absolute;
        inset: 0;
        z-index: 0;
        pointer-events: none;
        overflow: hidden;
        box-sizing: border-box;
        color: transparent;
        white-space: pre-wrap;
        word-break: break-word;
        overflow-wrap: break-word;
      }

      .fkp-annotated-textarea__invalid {
        color: transparent;
        text-decoration-line: underline;
        text-decoration-style: wavy;
        text-decoration-color: var(--error-color-medium, #d44);
        text-decoration-thickness: 1.5px;
        text-underline-offset: 2px;
        text-decoration-skip-ink: none;
      }
    </style>`,
  );
}

function applyTextareaInputAttributes(textarea) {
  textarea.setAttribute("spellcheck", "false");
  textarea.setAttribute("autocomplete", "off");
  textarea.setAttribute("autocorrect", "off");
  textarea.setAttribute("autocapitalize", "off");
  textarea.setAttribute("data-gramm", "false");
  textarea.setAttribute("data-gramm_editor", "false");
  textarea.setAttribute("data-enable-grammarly", "false");
  textarea.style.resize = "vertical";
  textarea.style.maxWidth = "100%";

  const getRowsMinHeight = () => {
    const rows = Number.parseInt(textarea.getAttribute("rows") || "0", 10);
    if (!rows || typeof window === "undefined") {
      return 0;
    }

    const style = window.getComputedStyle(textarea);
    const fontSize = Number.parseFloat(style.fontSize) || 16;
    const lineHeight =
      Number.parseFloat(style.lineHeight) || Math.ceil(fontSize * 1.2);
    const verticalPadding =
      (Number.parseFloat(style.paddingTop) || 0) +
      (Number.parseFloat(style.paddingBottom) || 0);
    const verticalBorder =
      (Number.parseFloat(style.borderTopWidth) || 0) +
      (Number.parseFloat(style.borderBottomWidth) || 0);

    return Math.ceil(rows * lineHeight + verticalPadding + verticalBorder);
  };

  const applyMinHeight = () => {
    const storedMinHeight = Number.parseFloat(
      textarea.getAttribute("data-fkp-default-min-height") || "0",
    );
    const nextMinHeight = Math.max(
      storedMinHeight,
      textarea.offsetHeight,
      getRowsMinHeight(),
    );

    if (nextMinHeight > 0) {
      if (storedMinHeight <= 0) {
        textarea.setAttribute(
          "data-fkp-default-min-height",
          `${nextMinHeight}`,
        );
      }

      textarea.style.minHeight = `${nextMinHeight}px`;
      return true;
    }

    return false;
  };

  if (
    !applyMinHeight() &&
    typeof window !== "undefined" &&
    typeof window.requestAnimationFrame === "function"
  ) {
    window.requestAnimationFrame(() => {
      if (!applyMinHeight()) {
        window.setTimeout(applyMinHeight, 0);
      }
    });
  }

  textarea.addEventListener("focus", applyMinHeight);
  textarea.addEventListener("pointerdown", applyMinHeight);
}

function syncAnnotatedTextareaOverlay(textarea, wrapper, overlay) {
  if (
    typeof window === "undefined" ||
    !textarea ||
    !wrapper ||
    !overlay ||
    typeof window.getComputedStyle !== "function"
  ) {
    return;
  }

  const style = window.getComputedStyle(textarea);

  wrapper.style.backgroundColor = style.backgroundColor;
  wrapper.style.borderRadius = style.borderRadius;

  overlay.style.font = style.font;
  overlay.style.lineHeight = style.lineHeight;
  overlay.style.letterSpacing = style.letterSpacing;
  overlay.style.paddingTop = style.paddingTop;
  overlay.style.paddingRight = style.paddingRight;
  overlay.style.paddingBottom = style.paddingBottom;
  overlay.style.paddingLeft = style.paddingLeft;
  overlay.style.borderTopWidth = style.borderTopWidth;
  overlay.style.borderRightWidth = style.borderRightWidth;
  overlay.style.borderBottomWidth = style.borderBottomWidth;
  overlay.style.borderLeftWidth = style.borderLeftWidth;
  overlay.style.borderStyle = "solid";
  overlay.style.borderColor = "transparent";
  overlay.style.textAlign = style.textAlign;
  overlay.style.direction = style.direction;
  overlay.style.tabSize = style.tabSize;
  overlay.style.textIndent = style.textIndent;
  overlay.style.textTransform = style.textTransform;
  overlay.style.boxSizing = style.boxSizing;
  overlay.style.scrollPaddingTop = style.scrollPaddingTop;

  overlay.scrollTop = textarea.scrollTop;
  overlay.scrollLeft = textarea.scrollLeft;
}

function createAnnotationKey(annotation) {
  return `${annotation.start}:${annotation.end}`;
}

function addAnnotationIssue(annotationMap, annotation, message) {
  const key = createAnnotationKey(annotation);
  const existing = annotationMap.get(key);
  if (existing) {
    if (!existing.messages.includes(message)) {
      existing.messages.push(message);
    }
    return;
  }

  annotationMap.set(key, {
    start: annotation.start,
    end: annotation.end,
    messages: [message],
  });
}

function finalizeAnnotations(annotationMap) {
  return Array.from(annotationMap.values())
    .map((annotation) => ({
      start: annotation.start,
      end: annotation.end,
      message: annotation.messages.join("; "),
    }))
    .sort((left, right) => left.start - right.start || left.end - right.end);
}

function renderAnnotatedTextareaOverlay(value, annotations) {
  const text = value ? `${value}` : "";
  const normalizedAnnotations = Array.isArray(annotations) ? annotations : [];

  if (!text.length) {
    return "&#8203;";
  }

  if (!normalizedAnnotations.length) {
    return `${escapeHtml(text)}${text.endsWith("\n") ? "\n " : ""}`;
  }

  let cursor = 0;
  let html = "";

  normalizedAnnotations.forEach((annotation) => {
    if (
      annotation.start < cursor ||
      annotation.start >= annotation.end ||
      annotation.start < 0
    ) {
      return;
    }

    html += escapeHtml(text.slice(cursor, annotation.start));
    html += `<span class="fkp-annotated-textarea__invalid">${escapeHtml(
      text.slice(annotation.start, annotation.end),
    )}</span>`;
    cursor = annotation.end;
  });

  html += escapeHtml(text.slice(cursor));

  if (text.endsWith("\n")) {
    html += "\n ";
  }

  return html;
}

function attachAnnotatedTextarea(textarea, analyzer) {
  if (!textarea || typeof analyzer !== "function") {
    return;
  }

  ensureAnnotatedTextareaStyles();

  if (textarea.__forkopAnnotatedTextareaController) {
    textarea.__forkopAnnotatedTextareaController.analyzer = analyzer;
    textarea.__forkopAnnotatedTextareaController.update();
    return;
  }

  const wrapper = textarea.parentNode;
  if (!wrapper) {
    return;
  }

  wrapper.classList.add("fkp-annotated-textarea");

  const overlay = document.createElement("div");
  overlay.className = "fkp-annotated-textarea__overlay";
  overlay.setAttribute("aria-hidden", "true");
  wrapper.insertBefore(overlay, textarea.nextSibling);

  const controller = {
    analyzer,
    textarea,
    wrapper,
    overlay,
    update() {
      const analysis = this.analyzer(this.textarea.value);
      this.overlay.innerHTML = renderAnnotatedTextareaOverlay(
        this.textarea.value,
        analysis.annotations,
      );
      syncAnnotatedTextareaOverlay(this.textarea, this.wrapper, this.overlay);
    },
  };

  textarea.__forkopAnnotatedTextareaController = controller;

  const updateAnnotatedTextarea = () => controller.update();
  textarea.addEventListener("input", updateAnnotatedTextarea);
  textarea.addEventListener("change", updateAnnotatedTextarea);
  textarea.addEventListener("scroll", updateAnnotatedTextarea, {
    passive: true,
  });
  textarea.addEventListener("keyup", updateAnnotatedTextarea);

  if (typeof ResizeObserver === "function") {
    const resizeObserver = new ResizeObserver(() => controller.update());
    resizeObserver.observe(textarea);
    controller.resizeObserver = resizeObserver;
  }

  controller.update();
}

function refreshAnnotatedTextareaValidation(option, section_id, textarea) {
  if (option && typeof option.triggerValidation === "function") {
    option.triggerValidation(section_id);
  }

  if (
    textarea &&
    textarea.__forkopAnnotatedTextareaController &&
    typeof textarea.__forkopAnnotatedTextareaController.update === "function"
  ) {
    textarea.__forkopAnnotatedTextareaController.update();
  }
}

function attachNfqwsRemoteValidation(option, section_id, textarea) {
  if (!textarea || textarea.__forkopNfqwsRemoteValidationAttached) {
    return;
  }

  textarea.__forkopNfqwsRemoteValidationAttached = true;
  textarea.__forkopNfqwsRemoteValidationRequestId = 0;
  textarea.__forkopNfqwsRemoteValidationTimer = null;

  const runValidation = () => {
    const value = textarea.value;
    const localAnalysis = buildNfqwsLocalAnalysis(value);
    if (!localAnalysis.valid) {
      refreshAnnotatedTextareaValidation(option, section_id, textarea);
      return;
    }

    const requestId =
      (textarea.__forkopNfqwsRemoteValidationRequestId || 0) + 1;
    textarea.__forkopNfqwsRemoteValidationRequestId = requestId;

    validateNfqwsStrategyRemotely(value).then(() => {
      if (textarea.__forkopNfqwsRemoteValidationRequestId !== requestId) {
        return;
      }

      refreshAnnotatedTextareaValidation(option, section_id, textarea);
    });
  };

  const scheduleValidation = (delay = NFQWS_REMOTE_VALIDATION_DEBOUNCE_MS) => {
    if (textarea.__forkopNfqwsRemoteValidationTimer) {
      window.clearTimeout(textarea.__forkopNfqwsRemoteValidationTimer);
    }

    textarea.__forkopNfqwsRemoteValidationTimer = window.setTimeout(() => {
      textarea.__forkopNfqwsRemoteValidationTimer = null;
      runValidation();
    }, delay);
  };

  textarea.addEventListener("input", () => scheduleValidation());
  textarea.addEventListener("change", () => scheduleValidation(0));
  textarea.addEventListener("blur", () => scheduleValidation(0));

  scheduleValidation(0);
}

function attachNfqws2RemoteValidation(option, section_id, textarea) {
  if (!textarea || textarea.__forkopNfqws2RemoteValidationAttached) {
    return;
  }

  textarea.__forkopNfqws2RemoteValidationAttached = true;
  textarea.__forkopNfqws2RemoteValidationRequestId = 0;
  textarea.__forkopNfqws2RemoteValidationTimer = null;

  const runValidation = () => {
    const value = textarea.value;
    const localAnalysis = buildNfqws2LocalAnalysis(value);
    if (!localAnalysis.valid) {
      refreshAnnotatedTextareaValidation(option, section_id, textarea);
      return;
    }

    const requestId =
      (textarea.__forkopNfqws2RemoteValidationRequestId || 0) + 1;
    textarea.__forkopNfqws2RemoteValidationRequestId = requestId;

    validateNfqws2StrategyRemotely(value).then(() => {
      if (textarea.__forkopNfqws2RemoteValidationRequestId !== requestId) {
        return;
      }

      refreshAnnotatedTextareaValidation(option, section_id, textarea);
    });
  };

  const scheduleValidation = (delay = NFQWS_REMOTE_VALIDATION_DEBOUNCE_MS) => {
    if (textarea.__forkopNfqws2RemoteValidationTimer) {
      window.clearTimeout(textarea.__forkopNfqws2RemoteValidationTimer);
    }

    textarea.__forkopNfqws2RemoteValidationTimer = window.setTimeout(() => {
      textarea.__forkopNfqws2RemoteValidationTimer = null;
      runValidation();
    }, delay);
  };

  textarea.addEventListener("input", () => scheduleValidation());
  textarea.addEventListener("change", () => scheduleValidation(0));
  textarea.addEventListener("blur", () => scheduleValidation(0));

  scheduleValidation(0);
}

function parseCommentAwareListTokens(value) {
  const text = value ? `${value}` : "";
  const tokens = [];
  const lines = text.split(/\r\n|\r|\n/);
  const newlines = text.match(/\r\n|\r|\n/g) || [];
  let offset = 0;

  lines.forEach((line, index) => {
    const hashIndex = line.indexOf("#");
    const slashIndex = line.indexOf("//");
    let commentIndex = -1;

    if (hashIndex >= 0 && slashIndex >= 0) {
      commentIndex = Math.min(hashIndex, slashIndex);
    } else if (hashIndex >= 0) {
      commentIndex = hashIndex;
    } else if (slashIndex >= 0) {
      commentIndex = slashIndex;
    }

    const source = commentIndex >= 0 ? line.slice(0, commentIndex) : line;
    const matcher = /[^,\s]+/g;
    let match;

    while ((match = matcher.exec(source)) !== null) {
      tokens.push({
        value: match[0],
        start: offset + match.index,
        end: offset + match.index + match[0].length,
      });
    }

    offset += line.length + (newlines[index] ? newlines[index].length : 0);
  });

  return tokens;
}

function analyzeTextListValue(value, validateItem, emptyMessage, options = {}) {
  const text = value ? `${value}` : "";
  if (!text.length) {
    return { valid: true, message: "", annotations: [] };
  }

  const tokens = parseCommentAwareListTokens(text);
  if (!tokens.length) {
    return { valid: false, message: emptyMessage, annotations: [] };
  }

  const duplicateMessage = options.duplicateMessage || getDuplicateValueText();
  const annotationMap = new Map();
  const errors = [];
  const seen = new Set();

  tokens.forEach((token) => {
    if (typeof validateItem === "function") {
      const validation = validateItem(token.value);
      if (!validation.valid) {
        errors.push(`${token.value}: ${validation.message}`);
        addAnnotationIssue(annotationMap, token, validation.message);
      }
    }

    const normalized = options.normalizeDuplicateValue
      ? options.normalizeDuplicateValue(token.value)
      : token.value;

    if (!normalized) {
      return;
    }

    if (seen.has(normalized)) {
      errors.push(`${token.value}: ${duplicateMessage}`);
      addAnnotationIssue(annotationMap, token, duplicateMessage);
      return;
    }

    seen.add(normalized);
  });

  if (!errors.length) {
    return { valid: true, message: "", annotations: [] };
  }

  return {
    valid: false,
    message: [getValidationHeaderText(), ...errors].join("\n"),
    annotations: finalizeAnnotations(annotationMap),
  };
}

function analyzeDomainSuffixText(value) {
  const validateDomainCondition = (domain) => {
    const normalized = `${domain || ""}`.trim();
    if (normalized.includes("/")) {
      return { valid: false, message: _("Invalid domain address") };
    }

    return main.validateDomain(normalized, true);
  };

  return analyzeTextListValue(
    value,
    (item) => {
      const colonIndex = item.indexOf(":");
      const prefix = colonIndex > 0 ? item.slice(0, colonIndex) : "";
      const body = colonIndex > 0 ? item.slice(colonIndex + 1) : item;

      if (!prefix) {
        return validateDomainCondition(body);
      }

      if (!["full", "keyword", "regex"].includes(prefix)) {
        return {
          valid: false,
          message: _("Allowed domain prefixes are full:, keyword:, and regex:"),
        };
      }

      if (!body.length) {
        return { valid: false, message: _("Value cannot be empty") };
      }

      if (prefix === "full") {
        return validateDomainCondition(body);
      }

      if (prefix === "keyword") {
        const validation = validateKeyword(null, body);
        return validation === true
          ? { valid: true, message: _("Valid") }
          : { valid: false, message: validation };
      }

      if (/[,\s]/.test(body)) {
        return {
          valid: false,
          message: _("Regular expression must not contain spaces or commas"),
        };
      }

      const validation = validateRegex(null, body);
      return validation === true
        ? { valid: true, message: _("Valid") }
        : { valid: false, message: validation };
    },
    _("At least one valid domain must be specified."),
    {
      normalizeDuplicateValue: (item) => `${item}`.toLowerCase(),
    },
  );
}

function domainValuesWithPrefix(section_id, key, prefix) {
  return getConfigListValues(section_id, key).map((value) =>
    prefix ? `${prefix}:${value}` : value,
  );
}

function domainTextValuesWithPrefix(section_id, key, prefix) {
  const legacyText = uci.get(UCI_PACKAGE, section_id, `${key}_text`);
  if (!legacyText) {
    return [];
  }

  return main
    .parseValueList(legacyText)
    .map((value) => (prefix ? `${prefix}:${value}` : value));
}

function uniqueDomainTextValues(values) {
  const seen = new Set();

  return values.filter((value) => {
    const key = `${value}`.toLowerCase();
    if (!key || seen.has(key)) {
      return false;
    }

    seen.add(key);
    return true;
  });
}

function appendUniqueDomainTextValues(textValue, values) {
  const originalText = typeof textValue === "string" ? textValue : "";
  const seen = new Set(
    main.parseValueList(originalText).map((value) => `${value}`.toLowerCase()),
  );
  const additions = uniqueDomainTextValues(values).filter((value) => {
    const key = `${value}`.toLowerCase();
    if (!key || seen.has(key)) {
      return false;
    }

    seen.add(key);
    return true;
  });

  if (!additions.length) {
    return originalText;
  }

  const base = originalText.replace(/\s+$/, "");
  return [base, ...additions].filter(Boolean).join("\n");
}

function loadCombinedDomainText(section_id) {
  const textValue =
    uci.get(UCI_PACKAGE, section_id, "domain") ||
    uci.get(UCI_PACKAGE, section_id, "domain_suffix_text");
  const values = [
    ...domainValuesWithPrefix(section_id, "domain_suffix", ""),
    ...domainValuesWithPrefix(section_id, "domain_keyword", "keyword"),
    ...domainValuesWithPrefix(section_id, "domain_regex", "regex"),
    ...domainTextValuesWithPrefix(section_id, "domain_suffix", ""),
    ...domainTextValuesWithPrefix(section_id, "domain", "full"),
    ...domainTextValuesWithPrefix(section_id, "domain_keyword", "keyword"),
    ...domainTextValuesWithPrefix(section_id, "domain_regex", "regex"),
  ];

  return appendUniqueDomainTextValues(textValue, values);
}

function analyzeIpCidrText(value) {
  return analyzeTextListValue(
    value,
    (item) => main.validateSubnet(item),
    _("At least one valid IP or subnet must be specified."),
    {
      normalizeDuplicateValue: (item) => `${item}`.trim(),
    },
  );
}

function validatePortCondition(_section_id, value) {
  const normalized = value ? `${value}`.trim() : "";

  if (!normalized.length) {
    return true;
  }

  const match = normalized.match(/^(\d+)(?:-(\d+))?$/);
  if (!match) {
    return _("Invalid port or range. Use 80 or 1000-2000");
  }

  const start = Number.parseInt(match[1], 10);
  const end = match[2] ? Number.parseInt(match[2], 10) : start;

  if (start < 1 || start > 65535 || end < 1 || end > 65535) {
    return _("Port must be between 1 and 65535");
  }

  if (start > end) {
    return _("Port range start must be less than or equal to end");
  }

  return true;
}

function getNfqwsOptionArgumentMode(option) {
  if (NFQWS_REQUIRED_ARG_OPTIONS.has(option)) {
    return "required";
  }

  if (NFQWS_OPTIONAL_ARG_OPTIONS.has(option)) {
    return "optional";
  }

  if (NFQWS_NO_ARG_OPTIONS.has(option)) {
    return "none";
  }

  return "unknown";
}

function getNfqws2OptionArgumentMode(option) {
  if (NFQWS2_REQUIRED_ARG_OPTIONS.has(option)) {
    return "required";
  }

  if (NFQWS2_OPTIONAL_ARG_OPTIONS.has(option)) {
    return "optional";
  }

  if (NFQWS2_NO_ARG_OPTIONS.has(option)) {
    return "none";
  }

  return "unknown";
}

function normalizeNfqwsStrategyWhitespace(value) {
  return value ? `${value}`.replace(/\s+/g, " ").trim() : "";
}

function parseNfqwsRuntimeTokens(value) {
  const text = value ? `${value}` : "";
  const tokens = [];
  const matcher = /\S+/g;
  let match;

  while ((match = matcher.exec(text)) !== null) {
    tokens.push({
      value: match[0],
      start: match.index,
      end: match.index + match[0].length,
    });
  }

  return tokens;
}
function normalizeNfqwsStrategyValue(value) {
  const normalized = normalizeNfqwsStrategyWhitespace(value);
  if (!normalized.length) {
    return "";
  }

  return normalized === ZAPRET_LEGACY_DEFAULT_NFQWS_OPT
    ? ZAPRET_DEFAULT_NFQWS_OPT
    : normalized;
}

function getCachedNfqwsRemoteValidation(value) {
  const normalized = normalizeNfqwsStrategyValue(value);
  return normalized.length
    ? nfqwsRemoteValidationCache.get(normalized) || null
    : null;
}

function cacheNfqwsRemoteValidation(value, result) {
  const normalized = normalizeNfqwsStrategyValue(value);
  if (!normalized.length) {
    return result;
  }

  const cached = {
    valid: result && result.valid === true,
    message: result && result.message ? `${result.message}` : "",
    needle: result && result.needle ? `${result.needle}` : "",
    needles:
      result && Array.isArray(result.needles)
        ? result.needles.filter(Boolean).map((item) => `${item}`)
        : result && result.needle
          ? [`${result.needle}`]
          : [],
  };

  nfqwsRemoteValidationCache.set(normalized, cached);
  return cached;
}

function buildNfqwsRemoteValidationFallback(error) {
  const message =
    error && error.message
      ? `${error.message}`
      : _("Unable to validate the NFQWS strategy through the backend parser.");

  return {
    valid: false,
    message: _("Backend validation failed: %s").format(message),
    needle: "",
    needles: [],
  };
}

function validateNfqwsStrategyRemotely(value) {
  const normalized = normalizeNfqwsStrategyValue(value);

  if (!normalized.length) {
    return Promise.resolve({
      valid: true,
      message: "",
      needle: "",
      needles: [],
    });
  }

  if (nfqwsRemoteValidationCache.has(normalized)) {
    return Promise.resolve(nfqwsRemoteValidationCache.get(normalized));
  }

  if (nfqwsRemoteValidationInflight.has(normalized)) {
    return nfqwsRemoteValidationInflight.get(normalized);
  }

  const validationTask = fs
    .exec(NFQWS_VALIDATION_COMMAND, [
      "validate_nfqws_strategy_json",
      normalized,
    ])
    .then((result) => {
      const payload = JSON.parse(
        (result && result.stdout ? result.stdout : "{}").trim() || "{}",
      );
      return cacheNfqwsRemoteValidation(normalized, {
        valid: payload.valid === true,
        message: payload.message || "",
        needle: payload.needle || "",
        needles: Array.isArray(payload.needles)
          ? payload.needles.filter(Boolean)
          : payload.needle
            ? [payload.needle]
            : [],
      });
    })
    .catch((error) =>
      cacheNfqwsRemoteValidation(
        normalized,
        buildNfqwsRemoteValidationFallback(error),
      ),
    )
    .finally(() => {
      nfqwsRemoteValidationInflight.delete(normalized);
    });

  nfqwsRemoteValidationInflight.set(normalized, validationTask);
  return validationTask;
}

function getNfqwsForbiddenTokenInfo(token, index) {
  const configFileMessage = _(
    "External nfqws config files bypass Forkop queue management and explicit validation.",
  );
  const hostSelectionMessage = _(
    "Resource selection by hostname inside nfqws is not supported here; sing-box selects resources before NFQUEUE.",
  );
  const ipSelectionMessage = _(
    "Resource selection by IP or CIDR inside nfqws is not supported here; sing-box selects resources before NFQUEUE.",
  );
  const placeholderMessage = _(
    "Zapret hostlist templates are not supported here because Forkop does not expand them for per-rule NFQWS strategies.",
  );
  const queueMessage = _(
    "The NFQUEUE number is assigned by Forkop for each rule and must not be overridden here.",
  );
  const fwmarkMessage = _(
    "The desync fwmark is managed by Forkop for loop prevention and must not be overridden here.",
  );
  const daemonMessage = _(
    "Forkop manages the nfqws process lifecycle itself, so daemon mode is not allowed here.",
  );
  const dryRunMessage = _(
    "This field must start a working nfqws strategy; --dry-run exits immediately and is not allowed here.",
  );
  const versionMessage = _(
    "This field must start a working nfqws strategy; --version exits immediately and is not allowed here.",
  );

  if (index === 0 && (token.startsWith("@") || token.startsWith("$"))) {
    return {
      reason: configFileMessage,
      captureNextValue: false,
    };
  }

  if (token === "<HOSTLIST>" || token === "<HOSTLIST_NOAUTO>") {
    return {
      reason: placeholderMessage,
      captureNextValue: false,
    };
  }

  if (
    token === "--hostlist" ||
    token.startsWith("--hostlist=") ||
    token === "--hostlist-domains" ||
    token.startsWith("--hostlist-domains=") ||
    token === "--hostlist-exclude" ||
    token.startsWith("--hostlist-exclude=") ||
    token === "--hostlist-exclude-domains" ||
    token.startsWith("--hostlist-exclude-domains=") ||
    token === "--hostlist-auto" ||
    token.startsWith("--hostlist-auto=") ||
    token === "--hostlist-auto-fail-threshold" ||
    token.startsWith("--hostlist-auto-fail-threshold=") ||
    token === "--hostlist-auto-fail-time" ||
    token.startsWith("--hostlist-auto-fail-time=") ||
    token === "--hostlist-auto-retrans-threshold" ||
    token.startsWith("--hostlist-auto-retrans-threshold=") ||
    token === "--hostlist-auto-debug" ||
    token.startsWith("--hostlist-auto-debug=")
  ) {
    return {
      reason: hostSelectionMessage,
      captureNextValue: !token.includes("="),
    };
  }

  if (
    token === "--ipset" ||
    token.startsWith("--ipset=") ||
    token === "--ipset-ip" ||
    token.startsWith("--ipset-ip=") ||
    token === "--ipset-exclude" ||
    token.startsWith("--ipset-exclude=") ||
    token === "--ipset-exclude-ip" ||
    token.startsWith("--ipset-exclude-ip=")
  ) {
    return {
      reason: ipSelectionMessage,
      captureNextValue: !token.includes("="),
    };
  }

  if (token === "--qnum" || token.startsWith("--qnum=")) {
    return {
      reason: queueMessage,
      captureNextValue: !token.includes("="),
    };
  }

  if (
    token === "--dpi-desync-fwmark" ||
    token.startsWith("--dpi-desync-fwmark=")
  ) {
    return {
      reason: fwmarkMessage,
      captureNextValue: !token.includes("="),
    };
  }

  if (token === "--daemon") {
    return {
      reason: daemonMessage,
      captureNextValue: false,
    };
  }

  if (token === "--dry-run") {
    return {
      reason: dryRunMessage,
      captureNextValue: false,
    };
  }

  if (token === "--version") {
    return {
      reason: versionMessage,
      captureNextValue: false,
    };
  }

  return null;
}

function buildNfqwsLocalAnalysis(value) {
  const text = value ? `${value}` : "";
  if (!text.trim().length) {
    return {
      valid: false,
      message: _("NFQWS strategy cannot be empty"),
      annotations: [],
    };
  }

  if (text.trim() === ZAPRET_LEGACY_DEFAULT_NFQWS_OPT) {
    return { valid: true, message: "", annotations: [] };
  }

  const tokens = parseNfqwsRuntimeTokens(text);
  const annotationMap = new Map();
  const errors = [];

  for (let index = 0; index < tokens.length; ) {
    const token = tokens[index];
    const bareToken = token.value.includes("=")
      ? token.value.slice(0, token.value.indexOf("="))
      : token.value;
    const nextToken = tokens[index + 1] || null;

    const forbidden = getNfqwsForbiddenTokenInfo(token.value, index);
    if (forbidden) {
      addAnnotationIssue(annotationMap, token, forbidden.reason);

      let displayToken = token.value;

      if (
        forbidden.captureNextValue &&
        nextToken &&
        !nextToken.value.startsWith("--")
      ) {
        addAnnotationIssue(annotationMap, nextToken, forbidden.reason);
        displayToken = `${displayToken} ${nextToken.value}`;
        index += 2;
      } else {
        index += 1;
      }

      errors.push(`${displayToken}: ${forbidden.reason}`);
      continue;
    }

    if (!token.value.startsWith("--")) {
      const reason = _(
        "Unexpected standalone token. Use explicit flags such as --name or --name=value.",
      );
      addAnnotationIssue(annotationMap, token, reason);
      errors.push(`${token.value}: ${reason}`);
      index += 1;
      continue;
    }

    const mode = getNfqwsOptionArgumentMode(bareToken);
    if (mode === "unknown") {
      const reason = _("Unknown NFQWS flag.");
      addAnnotationIssue(annotationMap, token, reason);
      errors.push(`${token.value}: ${reason}`);
      index += 1;
      continue;
    }

    if (mode === "none") {
      if (token.value.includes("=")) {
        const reason = _("This flag does not accept a value.");
        addAnnotationIssue(annotationMap, token, reason);
        errors.push(`${token.value}: ${reason}`);
      }

      index += 1;
      continue;
    }

    if (mode === "optional") {
      if (
        nextToken &&
        !token.value.includes("=") &&
        !nextToken.value.startsWith("--")
      ) {
        const reason = _(
          "Optional values must be attached with '=' here; a separate token would be ignored by nfqws.",
        );
        addAnnotationIssue(annotationMap, token, reason);
        addAnnotationIssue(annotationMap, nextToken, reason);
        errors.push(`${token.value} ${nextToken.value}: ${reason}`);
        index += 2;
      } else {
        index += 1;
      }

      continue;
    }

    if (!token.value.includes("=")) {
      if (!nextToken || nextToken.value.startsWith("--")) {
        const reason = _("This option requires a value.");
        addAnnotationIssue(annotationMap, token, reason);
        errors.push(`${token.value}: ${reason}`);
        index += 1;
        continue;
      }

      index += 2;
      continue;
    }

    index += 1;
  }

  if (!errors.length) {
    return { valid: true, message: "", annotations: [] };
  }

  return {
    valid: false,
    message: [getValidationHeaderText(), ...errors].join("\n"),
    annotations: finalizeAnnotations(annotationMap),
  };
}

function addNfqwsRemoteValidationNeedleAnnotations(
  annotationMap,
  tokens,
  remoteValidation,
  needle,
) {
  if (!needle.length) {
    return;
  }

  let matched = false;

  tokens.forEach((token) => {
    const tokenValue = token.value || "";
    const optionMatch =
      needle.startsWith("--") &&
      (tokenValue === needle || tokenValue.startsWith(`${needle}=`));
    const valueMatch =
      tokenValue === needle ||
      tokenValue.endsWith(`=${needle}`) ||
      (!needle.startsWith("--") && tokenValue.includes(`=${needle},`)) ||
      (!needle.startsWith("--") && tokenValue.endsWith(`=${needle}`));

    if (optionMatch || valueMatch) {
      addAnnotationIssue(annotationMap, token, remoteValidation.message);
      matched = true;
    }
  });

  if (matched) {
    return;
  }

  if (needle.startsWith("--")) {
    tokens
      .filter((token) => token.value && token.value.startsWith(needle))
      .forEach((token) =>
        addAnnotationIssue(annotationMap, token, remoteValidation.message),
      );
  }
}

function addNfqwsRemoteValidationAnnotations(
  annotationMap,
  tokens,
  remoteValidation,
) {
  const needles =
    remoteValidation &&
    Array.isArray(remoteValidation.needles) &&
    remoteValidation.needles.length
      ? remoteValidation.needles.map((needle) => `${needle}`)
      : remoteValidation && remoteValidation.needle
        ? [`${remoteValidation.needle}`]
        : [];

  needles.forEach((needle) =>
    addNfqwsRemoteValidationNeedleAnnotations(
      annotationMap,
      tokens,
      remoteValidation,
      needle,
    ),
  );
}

function analyzeNfqwsStrategy(value) {
  const localAnalysis = buildNfqwsLocalAnalysis(value);
  if (!localAnalysis.valid) {
    return localAnalysis;
  }

  const remoteValidation = getCachedNfqwsRemoteValidation(value);
  if (!remoteValidation || remoteValidation.valid) {
    return localAnalysis;
  }

  const text = value ? `${value}` : "";
  const tokens = parseNfqwsRuntimeTokens(text);
  const annotationMap = new Map();

  localAnalysis.annotations.forEach((annotation) =>
    addAnnotationIssue(annotationMap, annotation, annotation.message),
  );
  addNfqwsRemoteValidationAnnotations(annotationMap, tokens, remoteValidation);

  return {
    valid: false,
    message: [getValidationHeaderText(), remoteValidation.message].join("\n"),
    annotations: finalizeAnnotations(annotationMap),
  };
}

function normalizeNfqws2StrategyValue(value) {
  const normalized = normalizeNfqwsStrategyWhitespace(value);
  return normalized.length ? normalized : ZAPRET2_DEFAULT_NFQWS2_OPT;
}

function getCachedNfqws2RemoteValidation(value) {
  const normalized = normalizeNfqws2StrategyValue(value);
  return normalized.length
    ? nfqws2RemoteValidationCache.get(normalized) || null
    : null;
}

function cacheNfqws2RemoteValidation(value, result) {
  const normalized = normalizeNfqws2StrategyValue(value);
  if (!normalized.length) {
    return result;
  }

  const cached = {
    valid: result && result.valid === true,
    message: result && result.message ? `${result.message}` : "",
    needle: result && result.needle ? `${result.needle}` : "",
    needles:
      result && Array.isArray(result.needles)
        ? result.needles.filter(Boolean).map((item) => `${item}`)
        : result && result.needle
          ? [`${result.needle}`]
          : [],
  };

  nfqws2RemoteValidationCache.set(normalized, cached);
  return cached;
}

function buildNfqws2RemoteValidationFallback(error) {
  const message =
    error && error.message
      ? `${error.message}`
      : _("Unable to validate the NFQWS2 strategy through the backend parser.");

  return {
    valid: false,
    message: _("Backend validation failed: %s").format(message),
    needle: "",
    needles: [],
  };
}

function validateNfqws2StrategyRemotely(value) {
  const normalized = normalizeNfqws2StrategyValue(value);

  if (!normalized.length) {
    return Promise.resolve({
      valid: true,
      message: "",
      needle: "",
      needles: [],
    });
  }

  if (nfqws2RemoteValidationCache.has(normalized)) {
    return Promise.resolve(nfqws2RemoteValidationCache.get(normalized));
  }

  if (nfqws2RemoteValidationInflight.has(normalized)) {
    return nfqws2RemoteValidationInflight.get(normalized);
  }

  const validationTask = fs
    .exec(NFQWS_VALIDATION_COMMAND, [
      "validate_nfqws2_strategy_json",
      normalized,
    ])
    .then((result) => {
      const payload = JSON.parse(
        (result && result.stdout ? result.stdout : "{}").trim() || "{}",
      );
      return cacheNfqws2RemoteValidation(normalized, {
        valid: payload.valid === true,
        message: payload.message || "",
        needle: payload.needle || "",
        needles: Array.isArray(payload.needles)
          ? payload.needles.filter(Boolean)
          : payload.needle
            ? [payload.needle]
            : [],
      });
    })
    .catch((error) =>
      cacheNfqws2RemoteValidation(
        normalized,
        buildNfqws2RemoteValidationFallback(error),
      ),
    )
    .finally(() => {
      nfqws2RemoteValidationInflight.delete(normalized);
    });

  nfqws2RemoteValidationInflight.set(normalized, validationTask);
  return validationTask;
}

function getNfqws2ForbiddenTokenInfo(token, index, nextToken) {
  const configFileMessage = _(
    "External nfqws2 config files bypass Forkop queue management and explicit validation.",
  );
  const hostSelectionMessage = _(
    "Resource selection by hostname inside nfqws2 is not supported here; sing-box selects resources before NFQUEUE.",
  );
  const ipSelectionMessage = _(
    "Resource selection by IP or CIDR inside nfqws2 is not supported here; sing-box selects resources before NFQUEUE.",
  );
  const placeholderMessage = _(
    "Zapret2 hostlist templates are not supported here because Forkop does not expand them for per-rule NFQWS2 strategies.",
  );
  const queueMessage = _(
    "The NFQUEUE number is assigned by Forkop for each rule and must not be overridden here.",
  );
  const fwmarkMessage = _(
    "The desync fwmark is managed by Forkop for loop prevention and must not be overridden here.",
  );
  const fuzzMessage = _(
    "Fuzzing is not supported here because Forkop needs deterministic runtime validation.",
  );
  const interceptMessage = _(
    "Disabling interception is incompatible with action=zapret2 because Forkop sends matched traffic through NFQUEUE.",
  );
  const daemonMessage = _(
    "Forkop manages the nfqws2 process lifecycle itself, so daemon mode is not allowed here.",
  );
  const dryRunMessage = _(
    "This field must start a working nfqws2 strategy; --dry-run exits immediately and is not allowed here.",
  );
  const versionMessage = _(
    "This field must start a working nfqws2 strategy; --version exits immediately and is not allowed here.",
  );

  if (index === 0 && (token.startsWith("@") || token.startsWith("$"))) {
    return {
      reason: configFileMessage,
      captureNextValue: false,
    };
  }

  if (token === "<HOSTLIST>" || token === "<HOSTLIST_NOAUTO>") {
    return {
      reason: placeholderMessage,
      captureNextValue: false,
    };
  }

  if (
    token === "--hostlist" ||
    token.startsWith("--hostlist=") ||
    token === "--hostlist-domains" ||
    token.startsWith("--hostlist-domains=") ||
    token === "--hostlist-exclude" ||
    token.startsWith("--hostlist-exclude=") ||
    token === "--hostlist-exclude-domains" ||
    token.startsWith("--hostlist-exclude-domains=") ||
    token === "--hostlist-auto" ||
    token.startsWith("--hostlist-auto=") ||
    token === "--hostlist-auto-fail-threshold" ||
    token.startsWith("--hostlist-auto-fail-threshold=") ||
    token === "--hostlist-auto-fail-time" ||
    token.startsWith("--hostlist-auto-fail-time=") ||
    token === "--hostlist-auto-retrans-threshold" ||
    token.startsWith("--hostlist-auto-retrans-threshold=") ||
    token === "--hostlist-auto-debug" ||
    token.startsWith("--hostlist-auto-debug=") ||
    token === "--hostlist-auto-retrans-reset" ||
    token.startsWith("--hostlist-auto-retrans-reset=")
  ) {
    return {
      reason: hostSelectionMessage,
      captureNextValue: !token.includes("="),
    };
  }

  if (
    token === "--ipset" ||
    token.startsWith("--ipset=") ||
    token === "--ipset-ip" ||
    token.startsWith("--ipset-ip=") ||
    token === "--ipset-exclude" ||
    token.startsWith("--ipset-exclude=") ||
    token === "--ipset-exclude-ip" ||
    token.startsWith("--ipset-exclude-ip=")
  ) {
    return {
      reason: ipSelectionMessage,
      captureNextValue: !token.includes("="),
    };
  }

  if (token === "--qnum" || token.startsWith("--qnum=")) {
    return {
      reason: queueMessage,
      captureNextValue: !token.includes("="),
    };
  }

  if (
    token === "--fwmark" ||
    token.startsWith("--fwmark=") ||
    token === "--dpi-desync-fwmark" ||
    token.startsWith("--dpi-desync-fwmark=")
  ) {
    return {
      reason: fwmarkMessage,
      captureNextValue: !token.includes("="),
    };
  }

  if (token === "--fuzz" || token.startsWith("--fuzz=")) {
    return {
      reason: fuzzMessage,
      captureNextValue: !token.includes("="),
    };
  }

  if (
    token === "--intercept=0" ||
    token === "--intercept=false" ||
    token === "--intercept=no" ||
    (token === "--intercept" && nextToken && nextToken.value === "0")
  ) {
    return {
      reason: interceptMessage,
      captureNextValue: token === "--intercept",
    };
  }

  if (token === "--daemon") {
    return {
      reason: daemonMessage,
      captureNextValue: false,
    };
  }

  if (token === "--dry-run") {
    return {
      reason: dryRunMessage,
      captureNextValue: false,
    };
  }

  if (token === "--version") {
    return {
      reason: versionMessage,
      captureNextValue: false,
    };
  }

  return null;
}

function buildNfqws2LocalAnalysis(value) {
  const text = value ? `${value}` : "";
  if (!text.trim().length) {
    return {
      valid: false,
      message: _("NFQWS2 strategy cannot be empty"),
      annotations: [],
    };
  }

  const tokens = parseNfqwsRuntimeTokens(text);
  const annotationMap = new Map();
  const errors = [];

  for (let index = 0; index < tokens.length; ) {
    const token = tokens[index];
    const bareToken = token.value.includes("=")
      ? token.value.slice(0, token.value.indexOf("="))
      : token.value;
    const nextToken = tokens[index + 1] || null;

    const forbidden = getNfqws2ForbiddenTokenInfo(
      token.value,
      index,
      nextToken,
    );
    if (forbidden) {
      addAnnotationIssue(annotationMap, token, forbidden.reason);

      let displayToken = token.value;

      if (
        forbidden.captureNextValue &&
        nextToken &&
        !nextToken.value.startsWith("--")
      ) {
        addAnnotationIssue(annotationMap, nextToken, forbidden.reason);
        displayToken = `${displayToken} ${nextToken.value}`;
        index += 2;
      } else {
        index += 1;
      }

      errors.push(`${displayToken}: ${forbidden.reason}`);
      continue;
    }

    if (!token.value.startsWith("--")) {
      const reason = _(
        "Unexpected standalone token. Use explicit flags such as --name or --name=value.",
      );
      addAnnotationIssue(annotationMap, token, reason);
      errors.push(`${token.value}: ${reason}`);
      index += 1;
      continue;
    }

    const mode = getNfqws2OptionArgumentMode(bareToken);
    if (mode === "unknown") {
      const reason = _("Unknown NFQWS2 flag.");
      addAnnotationIssue(annotationMap, token, reason);
      errors.push(`${token.value}: ${reason}`);
      index += 1;
      continue;
    }

    if (mode === "none") {
      if (token.value.includes("=")) {
        const reason = _("This flag does not accept a value.");
        addAnnotationIssue(annotationMap, token, reason);
        errors.push(`${token.value}: ${reason}`);
      }

      index += 1;
      continue;
    }

    if (mode === "optional") {
      if (
        nextToken &&
        !token.value.includes("=") &&
        !nextToken.value.startsWith("--")
      ) {
        const reason = _(
          "Optional values must be attached with '=' here; a separate token would be ignored by nfqws2.",
        );
        addAnnotationIssue(annotationMap, token, reason);
        addAnnotationIssue(annotationMap, nextToken, reason);
        errors.push(`${token.value} ${nextToken.value}: ${reason}`);
        index += 2;
      } else {
        index += 1;
      }

      continue;
    }

    if (!token.value.includes("=")) {
      if (!nextToken || nextToken.value.startsWith("--")) {
        const reason = _("This option requires a value.");
        addAnnotationIssue(annotationMap, token, reason);
        errors.push(`${token.value}: ${reason}`);
        index += 1;
        continue;
      }

      index += 2;
      continue;
    }

    index += 1;
  }

  if (!errors.length) {
    return { valid: true, message: "", annotations: [] };
  }

  return {
    valid: false,
    message: [getValidationHeaderText(), ...errors].join("\n"),
    annotations: finalizeAnnotations(annotationMap),
  };
}

function analyzeNfqws2Strategy(value) {
  const localAnalysis = buildNfqws2LocalAnalysis(value);
  if (!localAnalysis.valid) {
    return localAnalysis;
  }

  const remoteValidation = getCachedNfqws2RemoteValidation(value);
  if (!remoteValidation || remoteValidation.valid) {
    return localAnalysis;
  }

  const text = value ? `${value}` : "";
  const tokens = parseNfqwsRuntimeTokens(text);
  const annotationMap = new Map();

  localAnalysis.annotations.forEach((annotation) =>
    addAnnotationIssue(annotationMap, annotation, annotation.message),
  );
  addNfqwsRemoteValidationAnnotations(annotationMap, tokens, remoteValidation);

  return {
    valid: false,
    message: [getValidationHeaderText(), remoteValidation.message].join("\n"),
    annotations: finalizeAnnotations(annotationMap),
  };
}

function normalizeByedpiStrategyWhitespace(value) {
  return value ? `${value}`.replace(/\s+/g, " ").trim() : "";
}

function normalizeByedpiStrategyValue(value) {
  const normalized = normalizeByedpiStrategyWhitespace(value);
  return normalized.length ? normalized : BYEDPI_DEFAULT_CMD_OPTS;
}

function getCachedByedpiRemoteValidation(value) {
  const normalized = normalizeByedpiStrategyValue(value);
  return normalized.length
    ? byedpiRemoteValidationCache.get(normalized) || null
    : null;
}

function cacheByedpiRemoteValidation(value, result) {
  const normalized = normalizeByedpiStrategyValue(value);
  if (!normalized.length) {
    return result;
  }

  const cached = {
    valid: result && result.valid === true,
    message: result && result.message ? `${result.message}` : "",
    needle: result && result.needle ? `${result.needle}` : "",
    needles:
      result && Array.isArray(result.needles)
        ? result.needles.filter(Boolean).map((item) => `${item}`)
        : result && result.needle
          ? [`${result.needle}`]
          : [],
  };

  byedpiRemoteValidationCache.set(normalized, cached);
  return cached;
}

function buildByedpiRemoteValidationFallback(error) {
  const message =
    error && error.message
      ? `${error.message}`
      : _("Unable to validate the ByeDPI strategy through the backend parser.");

  return {
    valid: false,
    message: _("Backend validation failed: %s").format(message),
    needle: "",
    needles: [],
  };
}

function validateByedpiStrategyRemotely(value) {
  const normalized = normalizeByedpiStrategyValue(value);

  if (!normalized.length) {
    return Promise.resolve({
      valid: true,
      message: "",
      needle: "",
      needles: [],
    });
  }

  if (byedpiRemoteValidationCache.has(normalized)) {
    return Promise.resolve(byedpiRemoteValidationCache.get(normalized));
  }

  if (byedpiRemoteValidationInflight.has(normalized)) {
    return byedpiRemoteValidationInflight.get(normalized);
  }

  const validationTask = fs
    .exec(NFQWS_VALIDATION_COMMAND, [
      "validate_byedpi_strategy_json",
      normalized,
    ])
    .then((result) => {
      const payload = JSON.parse(
        (result && result.stdout ? result.stdout : "{}").trim() || "{}",
      );
      return cacheByedpiRemoteValidation(normalized, {
        valid: payload.valid === true,
        message: payload.message || "",
        needle: payload.needle || "",
        needles: Array.isArray(payload.needles)
          ? payload.needles.filter(Boolean)
          : payload.needle
            ? [payload.needle]
            : [],
      });
    })
    .catch((error) =>
      cacheByedpiRemoteValidation(
        normalized,
        buildByedpiRemoteValidationFallback(error),
      ),
    )
    .finally(() => {
      byedpiRemoteValidationInflight.delete(normalized);
    });

  byedpiRemoteValidationInflight.set(normalized, validationTask);
  return validationTask;
}

function getByedpiShortOptionName(token) {
  return token.length > 2 ? token.slice(0, 2) : token;
}

function byedpiTokenLooksLikeOption(token) {
  return /^--.+/.test(token) || /^-[A-Za-z].*/.test(token);
}

function getByedpiControlledTokenInfo(token) {
  const listenMessage = _(
    "ByeDPI listen address and port are assigned by Forkop and must not be set in the strategy.",
  );
  const transparentMessage = _(
    "Transparent proxy mode is incompatible with action=byedpi because Forkop connects to ciadpi through SOCKS.",
  );
  const daemonMessage = _(
    "Forkop manages the ciadpi process lifecycle itself, so daemon mode is not allowed here.",
  );
  const pidfileMessage = _(
    "Forkop manages ciadpi pid files itself, so pidfile options are not allowed here.",
  );
  const exitMessage = _(
    "This field must start a working ciadpi strategy; help/version options exit immediately and are not allowed here.",
  );

  if (
    token === "--ip" ||
    token.startsWith("--ip=") ||
    token === "-i" ||
    /^-i.+/.test(token) ||
    token === "--port" ||
    token.startsWith("--port=") ||
    token === "-p" ||
    /^-p.+/.test(token)
  ) {
    return {
      reason: listenMessage,
      captureNextValue:
        token === "--ip" ||
        token === "-i" ||
        token === "--port" ||
        token === "-p",
    };
  }

  if (token === "--transparent" || token === "-E" || /^-E.+/.test(token)) {
    return {
      reason: transparentMessage,
      captureNextValue: false,
    };
  }

  if (token === "--daemon" || token === "-D" || /^-D.+/.test(token)) {
    return {
      reason: daemonMessage,
      captureNextValue: false,
    };
  }

  if (
    token === "--pidfile" ||
    token.startsWith("--pidfile=") ||
    token === "-w" ||
    /^-w.+/.test(token)
  ) {
    return {
      reason: pidfileMessage,
      captureNextValue: token === "--pidfile" || token === "-w",
    };
  }

  if (
    token === "--help" ||
    token === "-h" ||
    /^-h.+/.test(token) ||
    token === "--version" ||
    token === "-v" ||
    /^-v.+/.test(token)
  ) {
    return {
      reason: exitMessage,
      captureNextValue: false,
    };
  }

  return null;
}

function validateByedpiStrategyToken(token, nextToken) {
  const controlled = getByedpiControlledTokenInfo(token);
  if (controlled) {
    return {
      valid: false,
      reason: controlled.reason,
      captureNextValue: controlled.captureNextValue,
    };
  }

  if (/^--[^=]+=/.test(token)) {
    const base = token.split("=", 1)[0];
    const value = token.slice(base.length + 1);

    if (BYEDPI_LONG_VALUE_OPTIONS.has(base)) {
      return value.length
        ? { valid: true, consumeNext: false }
        : {
            valid: false,
            reason: _("ByeDPI option requires a value: %s").format(base),
            captureNextValue: false,
          };
    }

    if (BYEDPI_LONG_FLAG_OPTIONS.has(base)) {
      return {
        valid: false,
        reason: _("ByeDPI option does not accept a value: %s").format(base),
        captureNextValue: false,
      };
    }

    return {
      valid: false,
      reason: _("Unknown ByeDPI option: %s").format(base),
      captureNextValue: false,
    };
  }

  if (/^--.+/.test(token)) {
    if (BYEDPI_LONG_VALUE_OPTIONS.has(token)) {
      return nextToken && !byedpiTokenLooksLikeOption(nextToken)
        ? { valid: true, consumeNext: true }
        : {
            valid: false,
            reason: _("ByeDPI option requires a value: %s").format(token),
            captureNextValue: false,
          };
    }

    if (BYEDPI_LONG_FLAG_OPTIONS.has(token)) {
      return { valid: true, consumeNext: false };
    }

    return {
      valid: false,
      reason: _("Unknown ByeDPI option: %s").format(token),
      captureNextValue: false,
    };
  }

  if (/^-./.test(token)) {
    if (token === "-") {
      return {
        valid: false,
        reason: _("Unexpected ByeDPI strategy argument: %s").format(token),
        captureNextValue: false,
      };
    }

    const short = getByedpiShortOptionName(token);
    const compactValue = token.slice(short.length);

    if (BYEDPI_SHORT_VALUE_OPTIONS.has(short)) {
      if (token === short) {
        return nextToken && !byedpiTokenLooksLikeOption(nextToken)
          ? { valid: true, consumeNext: true }
          : {
              valid: false,
              reason: _("ByeDPI option requires a value: %s").format(short),
              captureNextValue: false,
            };
      }

      return compactValue.length
        ? { valid: true, consumeNext: false }
        : {
            valid: false,
            reason: _("ByeDPI option requires a value: %s").format(short),
            captureNextValue: false,
          };
    }

    if (BYEDPI_SHORT_FLAG_OPTIONS.has(short)) {
      return token === short
        ? { valid: true, consumeNext: false }
        : {
            valid: false,
            reason: _(
              "ByeDPI option does not accept a compact value: %s",
            ).format(short),
            captureNextValue: false,
          };
    }

    return {
      valid: false,
      reason: _("Unknown ByeDPI option: %s").format(short),
      captureNextValue: false,
    };
  }

  return {
    valid: false,
    reason: _("Unexpected ByeDPI strategy argument: %s").format(token),
    captureNextValue: false,
  };
}

function buildByedpiLocalAnalysis(value) {
  const text = value ? `${value}` : "";
  if (!text.trim().length) {
    return {
      valid: false,
      message: _("ByeDPI strategy cannot be empty"),
      annotations: [],
    };
  }

  const tokens = parseNfqwsRuntimeTokens(text);
  const annotationMap = new Map();
  const errors = [];

  for (let index = 0; index < tokens.length; ) {
    const token = tokens[index];
    const nextToken = tokens[index + 1] || null;
    const tokenValidation = validateByedpiStrategyToken(
      token.value,
      nextToken ? nextToken.value : null,
    );

    if (tokenValidation.valid) {
      index += tokenValidation.consumeNext ? 2 : 1;
      continue;
    }

    addAnnotationIssue(annotationMap, token, tokenValidation.reason);
    let displayToken = token.value;

    if (
      tokenValidation.captureNextValue &&
      nextToken &&
      !nextToken.value.startsWith("-")
    ) {
      addAnnotationIssue(annotationMap, nextToken, tokenValidation.reason);
      displayToken = `${displayToken} ${nextToken.value}`;
      index += 2;
    } else {
      index += 1;
    }

    errors.push(`${displayToken}: ${tokenValidation.reason}`);
  }

  if (!errors.length) {
    return { valid: true, message: "", annotations: [] };
  }

  return {
    valid: false,
    message: [getValidationHeaderText(), ...errors].join("\n"),
    annotations: finalizeAnnotations(annotationMap),
  };
}

function analyzeByedpiStrategy(value) {
  const localAnalysis = buildByedpiLocalAnalysis(value);
  if (!localAnalysis.valid) {
    return localAnalysis;
  }

  const remoteValidation = getCachedByedpiRemoteValidation(value);
  if (!remoteValidation || remoteValidation.valid) {
    return localAnalysis;
  }

  const text = value ? `${value}` : "";
  const tokens = parseNfqwsRuntimeTokens(text);
  const annotationMap = new Map();

  localAnalysis.annotations.forEach((annotation) =>
    addAnnotationIssue(annotationMap, annotation, annotation.message),
  );
  addNfqwsRemoteValidationAnnotations(annotationMap, tokens, remoteValidation);

  return {
    valid: false,
    message: [getValidationHeaderText(), remoteValidation.message].join("\n"),
    annotations: finalizeAnnotations(annotationMap),
  };
}

function configureTextareaOption(option, analyzer, remoteValidationAttacher) {
  const originalRenderWidget = option.renderWidget;

  option.renderWidget = function (section_id, option_index, cfgvalue) {
    const node = originalRenderWidget.call(
      this,
      section_id,
      option_index,
      cfgvalue,
    );
    const textarea =
      node && typeof node.querySelector === "function"
        ? node.querySelector("textarea")
        : node;

    if (textarea) {
      applyTextareaInputAttributes(textarea);
      if (typeof analyzer === "function") {
        attachAnnotatedTextarea(textarea, analyzer);
      }
      if (typeof remoteValidationAttacher === "function") {
        remoteValidationAttacher(this, section_id, textarea);
      }
    }

    return node;
  };
}

function getOptionTextarea(option, section_id) {
  const field =
    typeof option.map.findElement === "function"
      ? option.map.findElement("data-field", option.cbid(section_id))
      : null;

  if (field && typeof field.querySelector === "function") {
    return field.querySelector("textarea");
  }

  const elem =
    typeof option.getUIElement === "function"
      ? option.getUIElement(section_id)
      : null;
  const node = elem && elem.node ? elem.node : null;

  if (node && node.nodeName === "TEXTAREA") {
    return node;
  }

  return node && typeof node.querySelector === "function"
    ? node.querySelector("textarea")
    : null;
}

function rejectStrategyValidation(option, section_id, message) {
  const title = option.stripTags(option.title).trim();
  const error = message || option.getValidationError(section_id) || "";

  return Promise.reject(
    new TypeError(
      `${_('Option "%s" contains an invalid input value.').format(title || option.option)} ${error}`,
    ),
  );
}

function parseStrategyWithRemoteValidation(section_id, config) {
  const active = this.isActive(section_id);

  if (active) {
    if (typeof this.triggerValidation === "function") {
      this.triggerValidation(section_id);
    }

    if (!this.isValid(section_id)) {
      return rejectStrategyValidation(
        this,
        section_id,
        this.getValidationError(section_id),
      );
    }

    const cval = this.cfgvalue(section_id);
    const fval = this.formvalue(section_id);
    const cvalString = cval == null ? "" : `${cval}`;
    const fvalString = fval == null ? "" : `${fval}`;
    const shouldWrite = this.forcewrite || cvalString !== fvalString;

    if (!shouldWrite) {
      return Promise.resolve();
    }

    return config.remoteValidate(fvalString).then((result) => {
      const textarea = getOptionTextarea(this, section_id);

      if (textarea) {
        refreshAnnotatedTextareaValidation(this, section_id, textarea);
      }

      if (typeof this.triggerValidation === "function") {
        this.triggerValidation(section_id);
      }

      if (!result || result.valid !== true) {
        return rejectStrategyValidation(
          this,
          section_id,
          result && result.message ? result.message : config.invalidMessage,
        );
      }

      return Promise.resolve(this.write(section_id, fvalString));
    });
  }

  if (!this.retain) {
    return Promise.resolve(this.remove(section_id));
  }

  return Promise.resolve();
}

function parseNfqwsStrategyOnSave(section_id) {
  return parseStrategyWithRemoteValidation.call(this, section_id, {
    remoteValidate: validateNfqwsStrategyRemotely,
    invalidMessage: _(
      "Unable to validate the NFQWS strategy through the backend parser.",
    ),
  });
}

function parseNfqws2StrategyOnSave(section_id) {
  return parseStrategyWithRemoteValidation.call(this, section_id, {
    remoteValidate: validateNfqws2StrategyRemotely,
    invalidMessage: _(
      "Unable to validate the NFQWS2 strategy through the backend parser.",
    ),
  });
}

function addDynamicConditionField(section, config) {
  const o = section.taboption(
    "conditions",
    form.DynamicList,
    config.key,
    config.label,
    config.description,
  );

  o.modalonly = true;
  if (config.placeholder) {
    o.placeholder = config.placeholder;
  }
  if (config.dynamicValidate) {
    o.validate = config.dynamicValidate;
  }

  o.load = function (section_id) {
    const values = getConfigListValues(section_id, config.key);
    if (values.length) {
      return values;
    }

    const legacyText = uci.get(UCI_PACKAGE, section_id, `${config.key}_text`);
    return legacyText ? main.parseValueList(legacyText) : [];
  };

  o.write = function (section_id, value) {
    writeListOption(section_id, config.key, value);
    uci.unset(UCI_PACKAGE, section_id, `${config.key}_text`);
    uci.unset(UCI_PACKAGE, section_id, `${config.key}_text_mode`);
  };

  return o;
}

function addLocalDeviceSubnetDynamicField(section, config) {
  const o = section.taboption(
    "conditions",
    form.DynamicList,
    config.key,
    config.label,
    config.description,
  );

  o.modalonly = true;
  o.placeholder = _("Device or IP");
  o.validate = function (_section_id, value) {
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateSubnet(value);
    return validation.valid ? true : validation.message;
  };
  o.load = function (section_id) {
    const values = getConfigListValues(section_id, config.key);
    if (values.length) {
      return values;
    }

    const legacyText = uci.get(UCI_PACKAGE, section_id, `${config.key}_text`);
    return legacyText ? main.parseValueList(legacyText) : [];
  };
  o.write = function (section_id, value) {
    writeListOption(section_id, config.key, value);
    uci.unset(UCI_PACKAGE, section_id, `${config.key}_text`);
    uci.unset(UCI_PACKAGE, section_id, `${config.key}_text_mode`);
  };
  o.renderWidget = function (section_id, _option_index, cfgvalue) {
    return localDevices.createLocalDeviceDynamicListWidget(
      this,
      section_id,
      cfgvalue,
    );
  };

  return o;
}

function addTextConditionField(section, config) {
  const optionName = config.optionName || `${config.key}_text`;
  const legacyTextOptionName =
    config.legacyTextOptionName || `${config.key}_text`;
  const o = section.taboption(
    "conditions",
    form.TextValue,
    optionName,
    config.label,
    config.description,
  );

  o.rows = 8;
  o.wrap = "soft";
  o.textarea = true;
  o.modalonly = true;
  if (config.textAnalyze) {
    o.validate = function (_section_id, value) {
      const analysis = config.textAnalyze(value);
      return analysis.valid ? true : analysis.message;
    };
  } else if (config.textValidate) {
    o.validate = config.textValidate;
  }
  configureTextareaOption(o, config.textAnalyze);

  o.load = function (section_id) {
    if (typeof config.loadText === "function") {
      return config.loadText(section_id);
    }

    const textValue =
      uci.get(UCI_PACKAGE, section_id, optionName) ||
      uci.get(UCI_PACKAGE, section_id, legacyTextOptionName);
    if (textValue) {
      return valuesToText(textValue);
    }

    return valuesToText(uci.get(UCI_PACKAGE, section_id, config.key));
  };

  o.write = function (section_id, value) {
    const normalized = value ? `${value}`.trim() : "";

    if (normalized.length) {
      uci.set(UCI_PACKAGE, section_id, optionName, normalized);
    } else {
      uci.unset(UCI_PACKAGE, section_id, optionName);
    }

    if (config.key !== optionName) {
      uci.unset(UCI_PACKAGE, section_id, config.key);
    }
    if (legacyTextOptionName !== optionName) {
      uci.unset(UCI_PACKAGE, section_id, legacyTextOptionName);
    }
    uci.unset(UCI_PACKAGE, section_id, `${config.key}_text_mode`);

    if (typeof config.afterWrite === "function") {
      config.afterWrite(section_id);
    }
  };

  return o;
}

function loadRulesetValues(option) {
  delete option.keylist;
  delete option.vallist;

  Object.entries(main.DOMAIN_LIST_OPTIONS).forEach(([key, label]) => {
    option.value(key, _(label));
  });
}

function isBuiltinRulesetValue(value) {
  return Object.prototype.hasOwnProperty.call(main.DOMAIN_LIST_OPTIONS, value);
}

function normalizeReferenceForExtensionCheck(value) {
  return `${value || ""}`.split(/[?#]/, 1)[0].toLowerCase();
}

function hasAllowedReferenceExtension(value, extensions) {
  const normalized = normalizeReferenceForExtensionCheck(value);
  return extensions.some((extension) => normalized.endsWith(extension));
}

function validateFileReference(value, extensions, errorMessage, options = {}) {
  if (!value || value.length === 0) {
    return true;
  }

  if (value.startsWith("http://") || value.startsWith("https://")) {
    const validation = main.validateUrl(value);
    if (
      validation.valid &&
      (options.allowRemoteWithoutExtension ||
        hasAllowedReferenceExtension(value, extensions))
    ) {
      return true;
    }

    return errorMessage;
  }

  if (value.startsWith("/")) {
    const validation = main.validatePath(value);
    if (validation.valid && hasAllowedReferenceExtension(value, extensions)) {
      return true;
    }

    return errorMessage;
  }

  return errorMessage;
}

function validateCustomRulesetReference(value) {
  return validateFileReference(
    value,
    [".srs", ".json"],
    _("Rule set must be an HTTP(S) URL or a local .srs / .json path"),
    { allowRemoteWithoutExtension: true },
  );
}

function validatePlainListReference(value) {
  return validateFileReference(
    value,
    [".lst"],
    _("List must be an HTTP(S) URL or a local .lst path"),
    { allowRemoteWithoutExtension: true },
  );
}

function getRulesetReferences(section_id) {
  return getConfigListValues(section_id, "rule_set");
}

function getBuiltInRulesetReferences(section_id) {
  const values = getConfigListValues(section_id, "community_lists").filter(
    (value) => isBuiltinRulesetValue(value),
  );

  return values.filter(
    (value, index, values) =>
      isBuiltinRulesetValue(value) && values.indexOf(value) === index,
  );
}

function getCustomRulesetReferences(section_id) {
  return uniqueDynamicListItems([
    ...getRulesetReferences(section_id).filter(
      (value) => !isBuiltinRulesetValue(value),
    ),
    ...getConfigListValues(section_id, "rule_set_with_subnets"),
  ]);
}

function writeBuiltInRulesetReferences(section_id, values) {
  const refs = normalizeDynamicListItems(values).filter((value) =>
    isBuiltinRulesetValue(value),
  );
  writeListOption(section_id, "community_lists", refs);
}

function writeCustomRulesetReferences(section_id, values) {
  const refs = uniqueDynamicListItems(values);
  if (getRuleResolvedAction(section_id) === "dns") {
    writeDnsRulesetReferences(section_id, refs);
    return;
  }
  const subnetRefs = getConfigListValues(
    section_id,
    "rule_set_with_subnets",
  ).filter((value) => refs.includes(value));
  const subnetRefSet = new Set(subnetRefs);

  writeListOption(
    section_id,
    "rule_set",
    refs.filter((value) => !subnetRefSet.has(value)),
  );
  writeListOption(section_id, "rule_set_with_subnets", subnetRefs);
  uci.unset(UCI_PACKAGE, section_id, RULE_SET_ITEM_SETTINGS_KEY);
}

function writeDnsRulesetReferences(section_id, values) {
  writeListOption(section_id, "rule_set", uniqueDynamicListItems(values));
  uci.unset(UCI_PACKAGE, section_id, "rule_set_with_subnets");
  uci.unset(UCI_PACKAGE, section_id, RULE_SET_ITEM_SETTINGS_KEY);
}

function createSectionContent(section) {
  let o;

  section.tab("settings", _("Settings"));
  section.tab("conditions", _("Conditions"));

  o = section.taboption("settings", form.Flag, "enabled", _("Enable"));
  o.default = "1";
  o.rmempty = false;
  o.editable = true;
  o.width = "6rem";

  o = section.taboption(
    "settings",
    form.DummyValue,
    "_action_display",
    _("Action"),
  );
  o.modalonly = false;
  o.rawhtml = true;
  o.cfgvalue = function (section_id) {
    return getRuleActionDisplayMarkup(section_id);
  };
  o.textvalue = function (section_id) {
    return getRuleActionDisplayValue(section_id);
  };
  o.width = "7rem";

  o = section.taboption(
    "settings",
    form.Value,
    "label",
    _("Section name"),
    _("Visible name of this section"),
  );
  o.rmempty = false;
  o.modalonly = true;
  o.load = function (section_id) {
    return uci.get(UCI_PACKAGE, section_id, "label") || section_id;
  };

  o = section.taboption(
    "settings",
    form.ListValue,
    "action",
    _("Action"),
    _("What Forkop should do when this section matches"),
  );
  populateActionOptionValues(o);
  o.default = "connection";
  o.rmempty = false;
  o.modalonly = true;
  o.cfgvalue = function (section_id) {
    return getRuleConfiguredAction(section_id);
  };
  o.load = function (section_id) {
    return ensureActionProvidersAvailabilityLoaded().then(() => {
      populateActionOptionValues(this);
      return this.cfgvalue(section_id);
    });
  };

  o = section.taboption(
    "settings",
    form.ListValue,
    "dns_type",
    _("DNS protocol"),
    _("DNS protocol used by the resolver"),
  );
  o.depends("action", "dns");
  dnsTypeChoices().forEach((choice) => o.value(choice.value, choice.label));
  o.default = "udp";
  o.rmempty = false;
  o.modalonly = true;

  o = section.taboption(
    "settings",
    form.Value,
    "dns_server",
    _("DNS server"),
    _("DNS server used by the resolver"),
  );
  o.depends("action", "dns");
  o.rmempty = false;
  o.modalonly = true;
  o.validate = function (_section_id, value) {
    const normalized = `${value || ""}`.trim();
    if (!normalized) {
      return _("DNS server address cannot be empty");
    }
    const validation = main.validateDNS(normalized);
    return validation.valid ? true : _("Enter a valid DNS server address");
  };

  o = section.taboption(
    "settings",
    form.Flag,
    "dns_detour_enabled",
    _("DNS through section"),
    _("Route requests to this DNS server through another section."),
  );
  o.depends("action", "dns");
  o.default = "0";
  o.rmempty = false;
  o.modalonly = true;

  o = section.taboption(
    "settings",
    form.ListValue,
    "dns_detour_section",
    _("DNS requests through section"),
  );
  o.depends({ action: "dns", dns_detour_enabled: "1" });
  o.rmempty = false;
  o.modalonly = true;
  o.load = function (section_id) {
    refreshDnsDetourSectionOptionValues(this, section_id);
    return uci.get(UCI_PACKAGE, section_id, "dns_detour_section") || "";
  };
  o.validate = function (_section_id, value) {
    return value ? true : _("Select a section");
  };

  o = section.taboption(
    "settings",
    form.TextValue,
    "nfqws_opt",
    _("NFQWS Strategy"),
  );
  o.depends("action", "zapret");
  o.rows = 6;
  o.wrap = "soft";
  o.textarea = true;
  o.modalonly = true;
  o.load = function (section_id) {
    const value = uci.get(UCI_PACKAGE, section_id, "nfqws_opt");
    if (!value || value === ZAPRET_LEGACY_DEFAULT_NFQWS_OPT) {
      return ZAPRET_DEFAULT_NFQWS_OPT;
    }

    return value;
  };
  o.write = function (section_id, value) {
    const normalized = normalizeNfqwsStrategyValue(value);
    const nextValue =
      !normalized.length || normalized === ZAPRET_LEGACY_DEFAULT_NFQWS_OPT
        ? ZAPRET_DEFAULT_NFQWS_OPT
        : normalized;

    return validateNfqwsStrategyRemotely(nextValue).then((result) => {
      if (!result || result.valid !== true) {
        throw new TypeError(
          result && result.message
            ? result.message
            : _(
                "Unable to validate the NFQWS strategy through the backend parser.",
              ),
        );
      }

      uci.set(UCI_PACKAGE, section_id, "nfqws_opt", nextValue);
    });
  };
  o.validate = function (_section_id, value) {
    const analysis = analyzeNfqwsStrategy(value);
    return analysis.valid ? true : analysis.message;
  };
  o.parse = parseNfqwsStrategyOnSave;
  configureTextareaOption(o, analyzeNfqwsStrategy, attachNfqwsRemoteValidation);

  o = section.taboption(
    "settings",
    form.TextValue,
    "nfqws2_opt",
    _("NFQWS2 Strategy"),
  );
  o.depends("action", "zapret2");
  o.rows = 6;
  o.wrap = "soft";
  o.textarea = true;
  o.modalonly = true;
  o.load = function (section_id) {
    return (
      uci.get(UCI_PACKAGE, section_id, "nfqws2_opt") ||
      ZAPRET2_DEFAULT_NFQWS2_OPT
    );
  };
  o.write = function (section_id, value) {
    const normalized = normalizeNfqws2StrategyValue(value);

    return validateNfqws2StrategyRemotely(normalized).then((result) => {
      if (!result || result.valid !== true) {
        throw new TypeError(
          result && result.message
            ? result.message
            : _("Invalid NFQWS2 strategy"),
        );
      }

      uci.set(UCI_PACKAGE, section_id, "nfqws2_opt", normalized);
    });
  };
  o.validate = function (_section_id, value) {
    const analysis = analyzeNfqws2Strategy(value);
    return analysis.valid ? true : analysis.message;
  };
  o.parse = parseNfqws2StrategyOnSave;
  configureTextareaOption(
    o,
    analyzeNfqws2Strategy,
    attachNfqws2RemoteValidation,
  );

  o = section.taboption(
    "settings",
    form.TextValue,
    "byedpi_cmd_opts",
    _("ByeDPI Strategy"),
  );
  o.depends("action", "byedpi");
  o.rows = 6;
  o.wrap = "soft";
  o.textarea = true;
  o.modalonly = true;
  o.load = function (section_id) {
    return (
      uci.get(UCI_PACKAGE, section_id, "byedpi_cmd_opts") ||
      BYEDPI_DEFAULT_CMD_OPTS
    );
  };
  o.write = function (section_id, value) {
    const normalized = normalizeByedpiStrategyValue(value);

    return validateByedpiStrategyRemotely(normalized).then((result) => {
      if (!result || result.valid !== true) {
        throw new TypeError(
          result && result.message
            ? result.message
            : _("Invalid ByeDPI strategy"),
        );
      }

      uci.set(UCI_PACKAGE, section_id, "byedpi_cmd_opts", normalized);
    });
  };
  o.validate = function (_section_id, value) {
    const analysis = analyzeByedpiStrategy(value);
    return analysis.valid ? true : analysis.message;
  };
  configureTextareaOption(o, analyzeByedpiStrategy);

  o = section.taboption(
    "settings",
    form.DynamicList,
    "selector_proxy_links",
    _("Connection URL"),
    _(
      "vless://, vmess://, ss://, trojan://, socks4/5://, http(s)://, hy2/hysteria2:// links",
    ),
  );
  o.depends("action", "connection");
  o.rmempty = true;
  o.modalonly = true;
  o.validate = function (_section_id, value) {
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateProxyUrl(value);
    return validation.valid ? true : validation.message;
  };
  outboundNameSourceOptions.set("selector_proxy_links", o);

  o = section.taboption(
    "settings",
    SettingsDynamicList,
    "subscription_url",
    _("Subscription URL"),
    _("Enter the subscription URL"),
  );
  o.depends("action", "connection");
  o.rmempty = true;
  o.modalonly = true;
  o.childType = "subscription_url";
  o.childValueOption = "url";
  o.childDefaults = defaultSubscriptionUrlSettings();
  o.renderItemSettingsModal = showSubscriptionUrlSettingsModal;
  o.hasItemSettings = function (section_id, value) {
    const normalized = `${value || ""}`.trim();
    if (isExistingChildItem(section_id, normalized, "subscription_url")) {
      return true;
    }

    return this.validate(section_id, normalized) === true;
  };
  o.stagedChildSettings = function (section_id, value) {
    const inputValue = childItemInputValue(
      section_id,
      value,
      "subscription_url",
      "url",
    );
    const store = childPendingSettingsStore(this, section_id);
    return store[inputValue] ? Object.assign({}, store[inputValue]) : null;
  };
  o.clearStagedChildSettings = function (section_id) {
    if (this.pendingChildSettings) {
      delete this.pendingChildSettings[section_id];
    }
  };
  o.renderListItemLabel = function (section_id, itemId) {
    return childItemInputValue(section_id, itemId, "subscription_url", "url");
  };
  o.validate = validateSubscriptionUrlEntry;
  o.validate = function (section_id, value) {
    return validateSubscriptionUrlEntry(
      section_id,
      childItemInputValue(section_id, value, "subscription_url", "url"),
    );
  };

  o = section.taboption(
    "settings",
    InterfaceSettingsDynamicList,
    "interfaces",
    _("Network Interface"),
    _("Select network interface for VPN connection"),
  );
  o.depends("action", "connection");
  o.rmempty = true;
  o.modalonly = true;
  o.placeholder = _("Select a network interface");
  o.childType = "section_interface";
  o.childValueOption = "name";
  o.childDefaults = defaultInterfaceSettings();
  o.renderItemSettingsModal = showInterfaceSettingsModal;
  o.hasItemSettings = function (section_id, value) {
    const normalized = `${value || ""}`.trim();
    if (isExistingChildItem(section_id, normalized, "section_interface")) {
      return true;
    }

    return this.validate(section_id, normalized) === true;
  };
  o.stagedChildSettings = function (section_id, value) {
    const inputValue = childItemInputValue(
      section_id,
      value,
      "section_interface",
      "name",
    );
    const store = childPendingSettingsStore(this, section_id);
    return store[inputValue] ? Object.assign({}, store[inputValue]) : null;
  };
  o.clearStagedChildSettings = function (section_id) {
    if (this.pendingChildSettings) {
      delete this.pendingChildSettings[section_id];
    }
  };
  outboundNameSourceOptions.set("interfaces", o);

  o = section.taboption(
    "settings",
    ButtonAddSettingsDynamicList,
    "outbound_jsons",
    _("JSON outbound"),
    _("Custom outbound configurations in JSON format"),
  );
  o.depends("action", "connection");
  o.rmempty = true;
  o.modalonly = true;
  o.addButtonLabel = _("+ Add JSON outbound");
  o.renderItemSettingsModal = showOutboundJsonSettingsModal;
  o.renderListItemLabel = function (_section_id, value) {
    return outboundJsonListItemLabel(value);
  };
  o.validateItemsOnSave = validateOutboundJsonItemsBeforeSave;
  o.validate = function (_section_id, value) {
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateOutboundJson(value);
    return validation.valid ? true : validation.message;
  };
  outboundNameSourceOptions.set("outbound_jsons", o);

  o = section.taboption(
    "settings",
    ButtonAddSettingsDynamicList,
    "urltest",
    _("URLTest"),
    _("Server group for automatic lowest-latency selection"),
  );
  o.depends("action", "connection");
  o.rmempty = true;
  o.modalonly = true;
  o.addButtonLabel = _("+ Add URLTest");
  o.childType = "urltest";
  o.childValueOption = "name";
  o.childDefaults = urlTestChildDefaults();
  o.renderItemSettingsModal = showUrlTestSettingsModal;
  o.validateItemsOnSave = function (section_id, values) {
    return validateUrlTestItemsBeforeSave(section_id, values, this);
  };
  o.hasItemSettings = function (section_id, value) {
    const normalized = `${value || ""}`.trim();

    if (isExistingChildItem(section_id, normalized, "urltest")) {
      return true;
    }

    return normalized.length > 0;
  };
  o.inputValueForItem = function (section_id, value) {
    const inputValue = childItemInputValue(
      section_id,
      value,
      "urltest",
      "name",
    );
    const store = childPendingSettingsStore(this, section_id);
    return store[inputValue] && store[inputValue].name
      ? store[inputValue].name
      : inputValue;
  };
  o.stagedChildSettings = function (section_id, value) {
    const id = childItemInputValue(section_id, value, "urltest", "name");
    const store = childPendingSettingsStore(this, section_id);
    return store[id] ? Object.assign({}, store[id]) : null;
  };
  o.clearStagedChildSettings = function (section_id) {
    if (this.pendingChildSettings) {
      delete this.pendingChildSettings[section_id];
    }
  };
  o.renderListItemLabel = function (section_id, itemId) {
    return E(
      "span",
      { class: "fkp-dynlist-label" },
      this.inputValueForItem(section_id, itemId),
    );
  };

  o = section.taboption(
    "settings",
    ButtonAddSettingsDynamicList,
    "priority_group",
    _("Priority"),
    _("Server group for priority failover"),
  );
  o.depends("action", "connection");
  o.rmempty = true;
  o.modalonly = true;
  o.addButtonLabel = _("+ Add priority");
  o.childType = "priority_group";
  o.childValueOption = "name";
  o.childDefaults = priorityGroupChildDefaults();
  o.createId = () => randomPriorityGroupId();
  o.renderItemSettingsModal = showPriorityGroupSettingsModal;
  o.validateItemsOnSave = validatePriorityGroupItemsBeforeSave;
  o.hasItemSettings = function (section_id, value) {
    const normalized = `${value || ""}`.trim();

    if (isExistingChildItem(section_id, normalized, "priority_group")) {
      return true;
    }

    return normalized.length > 0;
  };
  o.inputValueForItem = function (section_id, value) {
    return childItemInputValue(section_id, value, "priority_group", "name");
  };
  o.renderListItemLabel = function (section_id, itemId) {
    return E(
      "span",
      { class: "fkp-dynlist-label" },
      this.inputValueForItem(section_id, itemId),
    );
  };

  o = section.taboption(
    "settings",
    form.Flag,
    "outbound_detour_enabled",
    _("Cascade connection"),
    _(
      "Use another section as an intermediate hop to connect to servers in this section. Does not apply to network interfaces or JSON outbounds.",
    ),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("action", "connection");
  o.modalonly = true;
  o.write = function (section_id, value) {
    if (value === "1") {
      const currentValue =
        uci.get(UCI_PACKAGE, section_id, "outbound_detour_section") || "";
      const targetSections = getOutboundDetourTargetSections(section_id);
      const currentIsValid = targetSections.some(
        (targetSection) => getUciSectionName(targetSection) === currentValue,
      );
      const selectedValue = currentIsValid
        ? currentValue
        : getDefaultOutboundDetourSection(section_id);

      if (selectedValue) {
        uci.set(
          UCI_PACKAGE,
          section_id,
          "outbound_detour_section",
          selectedValue,
        );
      }
    }

    return form.Flag.prototype.write.apply(this, arguments);
  };

  o = section.taboption(
    "settings",
    form.ListValue,
    "outbound_detour_section",
    _("Connect through"),
    _("Select a transit section"),
  );
  o.rmempty = false;
  o.depends({ action: "connection", outbound_detour_enabled: "1" });
  o.modalonly = true;
  o.load = function (section_id) {
    refreshOutboundDetourSectionOptionValues(this, section_id);
    return Promise.resolve(
      uci.get(UCI_PACKAGE, section_id, "outbound_detour_section") || "",
    );
  };
  o.validate = function (section_id, value) {
    if (!value) {
      return _("Select an intermediate section");
    }
    if (value === section_id) {
      return _("Current section cannot be used as its own transit section");
    }
    return true;
  };

  o = section.taboption(
    "settings",
    form.Flag,
    "sort_by_latency",
    _("Sort by latency"),
    _("Sorts servers in this section by lowest latency in the dashboard."),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("action", "connection");
  o.modalonly = true;

  o = section.taboption(
    "settings",
    form.Flag,
    "mixed_proxy_enabled",
    _("Enable Mixed Proxy"),
    _("Expose this section as a local HTTP+SOCKS proxy"),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("action", "connection");
  o.depends("action", "byedpi");
  o.depends("action", "zapret");
  o.depends("action", "zapret2");
  o.modalonly = true;

  o = section.taboption(
    "settings",
    form.Value,
    "mixed_proxy_port",
    _("Mixed Proxy Port"),
    _("Port for the local mixed proxy of this section"),
  );
  o.rmempty = false;
  o.depends({ action: "connection", mixed_proxy_enabled: "1" });
  o.depends({ action: "byedpi", mixed_proxy_enabled: "1" });
  o.depends({ action: "zapret", mixed_proxy_enabled: "1" });
  o.depends({ action: "zapret2", mixed_proxy_enabled: "1" });
  o.modalonly = true;
  o.validate = function (_section_id, value) {
    if (!value || value.length === 0) {
      return _("Port cannot be empty");
    }

    const parsed = parseInt(value, 10);
    if (!isNaN(parsed) && parsed >= 1 && parsed <= 65535) {
      return true;
    }

    return _("Invalid port number. Must be between 1 and 65535");
  };

  o = section.taboption(
    "settings",
    form.Flag,
    "mixed_proxy_auth_enabled",
    _("Enable Mixed Proxy Authentication"),
    _("Require a username and password for the local mixed proxy"),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends({ action: "connection", mixed_proxy_enabled: "1" });
  o.depends({ action: "byedpi", mixed_proxy_enabled: "1" });
  o.depends({ action: "zapret", mixed_proxy_enabled: "1" });
  o.depends({ action: "zapret2", mixed_proxy_enabled: "1" });
  o.modalonly = true;

  o = section.taboption(
    "settings",
    form.Value,
    "mixed_proxy_username",
    _("Mixed Proxy Username"),
  );
  o.rmempty = false;
  o.depends({
    action: "connection",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.depends({
    action: "byedpi",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.depends({
    action: "zapret",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.depends({
    action: "zapret2",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.modalonly = true;
  o.validate = function (_section_id, value) {
    if (!value || value.length === 0) {
      return _("Username cannot be empty");
    }

    return true;
  };

  o = section.taboption(
    "settings",
    form.Value,
    "mixed_proxy_password",
    _("Mixed Proxy Password"),
  );
  o.rmempty = false;
  o.depends({
    action: "connection",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.depends({
    action: "byedpi",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.depends({
    action: "zapret",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.depends({
    action: "zapret2",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.modalonly = true;
  o.validate = function (_section_id, value) {
    if (!value || value.length === 0) {
      return _("Password cannot be empty");
    }

    return true;
  };

  o = section.taboption(
    "settings",
    form.Flag,
    "resolve_real_ip_for_routing",
    _("Resolve real IP for routing"),
    _(
      "Resolve domain names before routing so sing-box can use real destination IPs.",
    ),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("action", "connection");
  o.modalonly = true;
  o.cfgvalue = function (section_id) {
    const value = uci.get(
      UCI_PACKAGE,
      section_id,
      "resolve_real_ip_for_routing",
    );
    if (value !== null && value !== undefined && value !== "") {
      return value;
    }

    return getRuleResolvedAction(section_id) === "byedpi" ? "1" : "0";
  };

  addTextConditionField(section, {
    key: "domain_suffix",
    optionName: "domain",
    legacyTextOptionName: "domain_suffix_text",
    label: _("Domains"),
    description: _(
      "The rule applies to the domain and all its subdomains. Use full:, keyword:, or regex: prefixes for exact match, keyword match, or regular expression.",
    ),
    textAnalyze: analyzeDomainSuffixText,
    loadText: loadCombinedDomainText,
    afterWrite: function (section_id) {
      [
        "domain_suffix",
        "domain_suffix_text",
        "domain_suffix_text_mode",
        "domain_keyword",
        "domain_regex",
        "domain_text",
        "domain_keyword_text",
        "domain_regex_text",
        "domain_text_mode",
        "domain_keyword_text_mode",
        "domain_regex_text_mode",
      ].forEach((key) => {
        uci.unset(UCI_PACKAGE, section_id, key);
      });
    },
  });

  const ipConditionOption = addTextConditionField(section, {
    key: "ip_cidr",
    optionName: "ip_cidr",
    legacyTextOptionName: "ip_cidr_text",
    label: _("IPs"),
    description: _("Match destination IPs or subnets"),
    textAnalyze: analyzeIpCidrText,
  });
  dependsOnRoutingAction(ipConditionOption);

  const builtInRulesetOption = section.taboption(
    "conditions",
    form.DynamicList,
    "community_lists",
    _("Built-in rule sets"),
    _("Select a predefined domain list"),
  );
  builtInRulesetOption.modalonly = true;
  builtInRulesetOption.placeholder = _("Service list");
  builtInRulesetOption.load = function (section_id) {
    loadRulesetValues(this);
    return getBuiltInRulesetReferences(section_id);
  };
  builtInRulesetOption.write = function (section_id, values) {
    writeBuiltInRulesetReferences(section_id, values);
  };
  builtInRulesetOption.remove = function (section_id) {
    uci.unset(UCI_PACKAGE, section_id, "community_lists");
  };
  let isProcessingBuiltIns = false;
  builtInRulesetOption.onchange = function (_ev, section_id, value) {
    if (isProcessingBuiltIns) {
      return;
    }

    isProcessingBuiltIns = true;

    try {
      const values = Array.isArray(value)
        ? value.filter(Boolean)
        : value
          ? [value]
          : [];
      let newValues = [...values];
      const notifications = [];

      const selectedRegionalOptions = main.REGIONAL_OPTIONS.filter((opt) =>
        newValues.includes(opt),
      );

      if (selectedRegionalOptions.length > 1) {
        const lastSelected =
          selectedRegionalOptions[selectedRegionalOptions.length - 1];
        const removedRegions = selectedRegionalOptions.slice(0, -1);
        newValues = newValues.filter(
          (v) => v === lastSelected || !main.REGIONAL_OPTIONS.includes(v),
        );
        notifications.push(
          E("p", {}, [
            E("strong", {}, _("Regional options cannot be used together")),
            E("br"),
            _(
              "Warning: %s cannot be used together with %s. Previous selections have been removed.",
            ).format(removedRegions.join(", "), lastSelected),
          ]),
        );
      }

      if (newValues.includes("russia_inside")) {
        const removedServices = newValues.filter(
          (v) => !main.ALLOWED_WITH_RUSSIA_INSIDE.includes(v),
        );
        if (removedServices.length > 0) {
          newValues = newValues.filter((v) =>
            main.ALLOWED_WITH_RUSSIA_INSIDE.includes(v),
          );
          notifications.push(
            E("p", { class: "alert-message warning" }, [
              E("strong", {}, _("Russia inside restrictions")),
              E("br"),
              _(
                "Warning: Russia inside can only be used with %s. %s already in Russia inside and have been removed from selection.",
              ).format(
                main.ALLOWED_WITH_RUSSIA_INSIDE.map(
                  (key) => main.DOMAIN_LIST_OPTIONS[key],
                )
                  .filter((label) => label !== "Russia inside")
                  .join(", "),
                removedServices.join(", "),
              ),
            ]),
          );
        }
      }

      if (
        JSON.stringify(newValues.slice().sort()) !==
        JSON.stringify(values.slice().sort())
      ) {
        this.getUIElement(section_id).setValue(newValues);
      }

      notifications.forEach((notification) =>
        ui.addNotification(null, notification),
      );
    } finally {
      isProcessingBuiltIns = false;
    }
  };

  const ruleSetOption = section.taboption(
    "conditions",
    SettingsDynamicList,
    "rule_set",
    _("Rule sets"),
    _(
      "Add URLs or local paths to .srs / .json lists. Only domain rules are supported.",
    ),
  );
  ruleSetOption.modalonly = true;
  dependsOnRoutingAction(ruleSetOption);
  ruleSetOption.renderItemSettingsModal = showRuleSetSettingsModal;
  ruleSetOption.load = function (section_id) {
    return getCustomRulesetReferences(section_id);
  };
  ruleSetOption.write = function (section_id, value) {
    writeCustomRulesetReferences(section_id, value);
  };
  ruleSetOption.remove = function (section_id) {
    uci.unset(UCI_PACKAGE, section_id, "rule_set");
    uci.unset(UCI_PACKAGE, section_id, "rule_set_with_subnets");
    uci.unset(UCI_PACKAGE, section_id, RULE_SET_ITEM_SETTINGS_KEY);
  };
  ruleSetOption.validate = function (section_id, value) {
    return validateCustomRulesetReference(value);
  };

  const dnsRuleSetOption = section.taboption(
    "conditions",
    form.DynamicList,
    "_dns_rule_set",
    _("Rule sets"),
    _(
      "Add URLs or local paths to .srs / .json lists. Only domain rules are supported.",
    ),
  );
  dnsRuleSetOption.depends("action", "dns");
  dnsRuleSetOption.modalonly = true;
  dnsRuleSetOption.load = function (section_id) {
    return getCustomRulesetReferences(section_id);
  };
  dnsRuleSetOption.write = function (section_id, value) {
    writeDnsRulesetReferences(section_id, value);
  };
  dnsRuleSetOption.remove = function (section_id) {
    writeDnsRulesetReferences(section_id, []);
  };
  dnsRuleSetOption.validate = function (_section_id, value) {
    return validateCustomRulesetReference(value);
  };

  const domainIpListsOption = section.taboption(
    "conditions",
    form.DynamicList,
    "domain_ip_lists",
    _("Domain lists"),
    _(
      "Add URLs or local paths to .lst lists. Only domain rules are supported.",
    ),
  );
  domainIpListsOption.modalonly = true;
  domainIpListsOption.load = function (section_id) {
    return getConfigListValues(section_id, "domain_ip_lists");
  };
  domainIpListsOption.validate = function (_section_id, value) {
    return validatePlainListReference(value);
  };

  const sourceIpOption = addLocalDeviceSubnetDynamicField(section, {
    key: "source_ip_cidr",
    label: _("Device filter"),
    description: _(
      "Apply section rules only to the specified local IP addresses",
    ),
  });
  dependsOnRoutingAction(sourceIpOption);

  const fullyRoutedOption = addLocalDeviceSubnetDynamicField(section, {
    key: "fully_routed_ips",
    label: _("Forced device routing"),
    description: _(
      "All traffic from these IP addresses will be routed through the section unconditionally, ignoring all other conditions.",
    ),
  });
  dependsOnRoutingAction(fullyRoutedOption);

  const portsOption = addDynamicConditionField(section, {
    key: "ports",
    label: _("Ports"),
    description: _("Match destination ports. Use a single port or a range"),
    dynamicValidate: validatePortCondition,
  });
  dependsOnRoutingAction(portsOption);
}

function loadSectionTableOptions(sectionRef) {
  const sectionIds = sectionRef.cfgsections();
  const tasks = [];

  for (let i = 0; i < sectionIds.length; i += 1) {
    const sectionId = sectionIds[i];

    for (let j = 0; j < sectionRef.children.length; j += 1) {
      const option = sectionRef.children[j];

      if (option.disable || option.modalonly) {
        continue;
      }

      tasks.push(
        Promise.resolve(option.load.call(option, sectionId)).then((value) => {
          option.cfgvalue(sectionId, value);
        }),
      );
    }
  }

  return Promise.all(tasks);
}

function configureSectionSection(sectionRef, options = {}) {
  setActionProvidersAvailabilityLoader(options.loadActionProvidersAvailability);

  sectionRef.load = function () {
    // The table renders only non-modal fields; the cloned Add/Edit modal loads
    // action/provider details when the user opens it.
    return loadSectionTableOptions(this);
  };
}

const EntryPoint = {
  configureSectionSection,
  createSectionContent,
  setActionProvidersAvailabilityLoader,
};

return baseclass.extend(EntryPoint);
