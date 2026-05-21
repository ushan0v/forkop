"use strict";
"require form";
"require baseclass";
"require fs";
"require rpc";
"require ui";
"require tools.widgets as widgets";
"require uci";
"require view.podkop_plus.main as main";

const UCI_PACKAGE = main.PODKOP_UCI_PACKAGE;
const callHostHints = rpc.declare({
  object: "luci-rpc",
  method: "getHostHints",
  expect: { "": {} },
});
const callDHCPLeases = rpc.declare({
  object: "luci-rpc",
  method: "getDHCPLeases",
  expect: { "": {} },
});
const callNetworkInterfaceDump = rpc.declare({
  object: "network.interface",
  method: "dump",
  expect: { interface: [] },
});

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

const ZAPRET_LEGACY_DEFAULT_NFQWS_OPT =
  "--filter-tcp=80 <HOSTLIST> --dpi-desync=fake,fakedsplit --dpi-desync-autottl=2 --dpi-desync-fooling=badsum --new --filter-tcp=443 --hostlist=/opt/zapret/ipset/zapret-hosts-google.txt --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=11 --dpi-desync-fooling=badsum --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com --new --filter-udp=443 --hostlist=/opt/zapret/ipset/zapret-hosts-google.txt --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-fake-quic=/opt/zapret/files/fake/quic_initial_www_google_com.bin --new --filter-udp=443 <HOSTLIST_NOAUTO> --dpi-desync=fake --dpi-desync-repeats=11 --new --filter-tcp=443 <HOSTLIST> --dpi-desync=multidisorder --dpi-desync-split-pos=1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1";

const ZAPRET_DEFAULT_NFQWS_OPT =
  "--filter-tcp=80 --dpi-desync=fake,fakedsplit --dpi-desync-autottl=2 --dpi-desync-fooling=badsum --new --filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=11 --dpi-desync-fooling=badsum --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-fake-quic=/opt/zapret/files/fake/quic_initial_www_google_com.bin";

const BYEDPI_DEFAULT_CMD_OPTS = "-o 2 --auto=t,r,a,s -d 2";
const ANNOTATED_TEXTAREA_STYLE_ID = "pdk-annotated-textarea-styles";
const NFQWS_REMOTE_VALIDATION_DEBOUNCE_MS = 500;
const NFQWS_VALIDATION_COMMAND = "/usr/bin/podkop-plus";
const nfqwsRemoteValidationCache = new Map();
const nfqwsRemoteValidationInflight = new Map();
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
const actionProvidersAvailabilityState = {
  loaded: false,
  zapretInstalled: false,
  byedpiInstalled: false,
};
let actionProvidersAvailabilityPromise = null;
const outboundNameChoicesCache = {};
const COUNTRY_CODES =
  "AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW XK".split(
    " ",
  );
const REGION_NAME_FALLBACKS = {
  XK: "Kosovo",
};
let regionDisplayNamesCache = {};

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

function resetOptionChoices(option) {
  delete option.keylist;
  delete option.vallist;
}

function populateCountryOptionValues(option) {
  resetOptionChoices(option);
  COUNTRY_CODES.map((code) => ({
    code,
    label: getCountryOptionLabel(code),
    name: getRegionDisplayName(code),
  }))
    .sort((a, b) => a.name.localeCompare(b.name))
    .forEach((country) => option.value(country.code, country.label));
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

function loadOutboundNameChoices(section_id) {
  if (outboundNameChoicesCache[section_id]) {
    return Promise.resolve(outboundNameChoicesCache[section_id]);
  }

  return main.PodkopShellMethods.getOutboundMetadata(section_id)
    .then((response) => {
      const names =
        response && response.success && response.data && response.data.names
          ? Object.values(response.data.names)
          : [];

      const choices = names
        .filter(Boolean)
        .filter((name, index, values) => values.indexOf(name) === index)
        .sort((a, b) => `${a}`.localeCompare(`${b}`));

      outboundNameChoicesCache[section_id] = choices;

      return choices;
    })
    .catch(() => []);
}

function createOutboundNameDynamicListWidget(option, section_id, cfgvalue) {
  const values = normalizeOptionValues(
    cfgvalue != null ? cfgvalue : option.default,
  );

  return loadOutboundNameChoices(section_id).then((choices) => {
    const choiceMap = {};

    choices.forEach((name) => {
      choiceMap[name] = name;
    });

    return new ui.DynamicList(values, choiceMap, {
      id: option.cbid(section_id),
      sort: choices,
      optional: option.optional || option.rmempty,
      datatype: option.datatype,
      placeholder: option.placeholder,
      validate: option.validate.bind(option, section_id),
      disabled: option.readonly != null ? option.readonly : option.map.readonly,
    }).render();
  });
}

function ensureActionProvidersAvailabilityLoaded() {
  if (actionProvidersAvailabilityState.loaded) {
    return Promise.resolve(actionProvidersAvailabilityState);
  }

  if (actionProvidersAvailabilityPromise) {
    return actionProvidersAvailabilityPromise;
  }

  actionProvidersAvailabilityPromise = Promise.allSettled([
    main.PodkopShellMethods.getZapretStatus(),
    main.PodkopShellMethods.getByedpiStatus(),
  ])
    .then(([zapretResult, byedpiResult]) => {
      const zapret =
        zapretResult && zapretResult.status === "fulfilled"
          ? zapretResult.value
          : null;
      const byedpi =
        byedpiResult && byedpiResult.status === "fulfilled"
          ? byedpiResult.value
          : null;

      actionProvidersAvailabilityState.loaded = true;
      actionProvidersAvailabilityState.zapretInstalled = Boolean(
        zapret && zapret.success && zapret.data && zapret.data.installed,
      );
      actionProvidersAvailabilityState.byedpiInstalled = Boolean(
        byedpi && byedpi.success && byedpi.data && byedpi.data.installed,
      );
      return actionProvidersAvailabilityState;
    })
    .catch(() => {
      actionProvidersAvailabilityState.loaded = true;
      actionProvidersAvailabilityState.zapretInstalled = false;
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

function isByedpiInstalledForUi() {
  return actionProvidersAvailabilityState.byedpiInstalled;
}

function getRuleConfiguredAction(section_id) {
  const action = uci.get(UCI_PACKAGE, section_id, "action");
  return action ? `${action}` : null;
}

function getRuleResolvedAction(section_id) {
  return getRuleConfiguredAction(section_id) || "proxy";
}

function getActionOptionLabel(action) {
  switch (`${action}`) {
    case "block":
      return "Block";
    case "direct":
      return "Direct";
    case "vpn":
      return "VPN";
    case "zapret":
      return "Zapret";
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

  option.value("proxy", "Proxy");
  option.value("vpn", "VPN");
  option.value("direct", "Direct");
  option.value("block", "Block");
  if (isZapretInstalledForUi()) {
    option.value("zapret", getActionOptionLabel("zapret"));
  }
  if (isByedpiInstalledForUi()) {
    option.value("byedpi", getActionOptionLabel("byedpi"));
  }
  option.value("outbound", getActionOptionLabel("outbound"));
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

function writeListOption(section_id, key, values) {
  const normalized = normalizeOptionValues(values);

  if (normalized.length) {
    uci.set(UCI_PACKAGE, section_id, key, normalized);
  } else {
    uci.unset(UCI_PACKAGE, section_id, key);
  }
}

let localDeviceChoicesCache = null;
let localDeviceChoicesPromise = null;

function normalizeLocalDeviceName(name) {
  return `${name || ""}`.trim().replace(/\.lan$/i, "");
}

function addLocalDeviceChoice(choices, ip, name) {
  const normalizedIp = `${ip || ""}`.trim();
  const normalizedName = normalizeLocalDeviceName(name);

  if (!normalizedIp || !normalizedName) {
    return;
  }

  if (!main.validateIPV4(normalizedIp).valid) {
    return;
  }

  choices[normalizedIp] = normalizedName;
}

function addRouterIp(routerIps, ip) {
  const normalizedIp = `${ip || ""}`.trim();

  if (!normalizedIp || !main.validateIPV4(normalizedIp).valid) {
    return;
  }

  routerIps[normalizedIp] = true;
}

function buildRouterIpMap(networkInterfaces) {
  const routerIps = {};

  if (!Array.isArray(networkInterfaces)) {
    return routerIps;
  }

  networkInterfaces.forEach((networkInterface) => {
    const ipv4Addresses =
      networkInterface &&
      typeof networkInterface === "object" &&
      Array.isArray(networkInterface["ipv4-address"])
        ? networkInterface["ipv4-address"]
        : [];

    ipv4Addresses.forEach((address) => {
      addRouterIp(
        routerIps,
        address && typeof address === "object" ? address.address : address,
      );
    });
  });

  return routerIps;
}

function buildLocalDeviceChoices(hostHints, dhcpLeases, networkInterfaces) {
  const choices = {};
  const routerIps = buildRouterIpMap(networkInterfaces);

  if (hostHints && typeof hostHints === "object") {
    Object.values(hostHints).forEach((hint) => {
      if (!hint || typeof hint !== "object") {
        return;
      }

      normalizeOptionValues(hint.ipaddrs || hint.ipv4).forEach((ip) => {
        addLocalDeviceChoice(choices, ip, hint.name);
      });
    });
  }

  if (dhcpLeases && Array.isArray(dhcpLeases.dhcp_leases)) {
    dhcpLeases.dhcp_leases.forEach((lease) => {
      if (!lease || typeof lease !== "object") {
        return;
      }

      addLocalDeviceChoice(choices, lease.ipaddr, lease.hostname);
    });
  }

  Object.keys(routerIps).forEach((ip) => {
    delete choices[ip];
  });

  return choices;
}

function loadLocalDeviceChoices(refresh) {
  if (!refresh && localDeviceChoicesCache) {
    return Promise.resolve(localDeviceChoicesCache);
  }

  if (!refresh && localDeviceChoicesPromise) {
    return localDeviceChoicesPromise;
  }

  localDeviceChoicesPromise = Promise.all([
    callHostHints().catch(() => ({})),
    callDHCPLeases().catch(() => ({})),
    callNetworkInterfaceDump().catch(() => []),
  ])
    .then(([hostHints, dhcpLeases, networkInterfaces]) => {
      localDeviceChoicesCache = buildLocalDeviceChoices(
        hostHints,
        dhcpLeases,
        networkInterfaces,
      );
      return localDeviceChoicesCache;
    })
    .finally(() => {
      localDeviceChoicesPromise = null;
    });

  return localDeviceChoicesPromise;
}

function sortLocalDeviceChoiceValues(choices) {
  return Object.keys(choices).sort((a, b) => {
    const byName = `${choices[a]}`.localeCompare(`${choices[b]}`);
    return byName || a.localeCompare(b);
  });
}

function hasSingleIpValue(values) {
  return values.some((value) => main.validateIPV4(value).valid);
}

function createLocalDeviceDynamicListWidget(option, section_id, cfgvalue) {
  const values = normalizeOptionValues(
    cfgvalue != null ? cfgvalue : option.default,
  );
  const shouldResolveExistingLabels = hasSingleIpValue(values);

  return (
    shouldResolveExistingLabels ? loadLocalDeviceChoices() : Promise.resolve({})
  ).then((initialChoices) => {
    const widget = new ui.DynamicList(values, initialChoices || {}, {
      id: option.cbid(section_id),
      sort: sortLocalDeviceChoiceValues(initialChoices || {}),
      optional: option.optional || option.rmempty,
      datatype: option.datatype,
      placeholder: option.placeholder,
      validate: option.validate.bind(option, section_id),
      disabled: option.readonly != null ? option.readonly : option.map.readonly,
    });
    const node = widget.render();
    let choicesLoaded = shouldResolveExistingLabels;
    let choicesLoading = false;

    const loadChoices = () => {
      if (choicesLoaded || choicesLoading) {
        return;
      }

      choicesLoading = true;
      loadLocalDeviceChoices(true)
        .then((choices) => {
          widget.clearChoices();
          widget.addChoices(sortLocalDeviceChoiceValues(choices), choices);
          choicesLoaded = true;
        })
        .finally(() => {
          choicesLoading = false;
        });
    };

    const maybeLoadChoices = (ev) => {
      if (
        ev.target &&
        typeof ev.target.closest === "function" &&
        ev.target.closest(".cbi-dropdown")
      ) {
        loadChoices();
      }
    };

    node.addEventListener("mousedown", maybeLoadChoices, true);
    node.addEventListener("focusin", maybeLoadChoices, true);

    return node;
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

  if (/\s/.test(value)) {
    return _("Keyword must not contain spaces");
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
  const delimiter = " | ";
  const delimiterIndex = normalized.lastIndexOf(delimiter);

  if (!normalized.length) {
    return { valid: true, url: "", userAgent: "" };
  }

  if (delimiterIndex >= 0) {
    const url = normalized.slice(0, delimiterIndex).trim();
    const userAgent = normalized
      .slice(delimiterIndex + delimiter.length)
      .trim();

    if (!url || !userAgent) {
      return {
        valid: false,
        message: _("Use format: URL | User-Agent"),
      };
    }

    return { valid: true, url, userAgent };
  }

  if (/\s\||\|\s/.test(normalized)) {
    return {
      valid: false,
      message: _("Use format: URL | User-Agent"),
    };
  }

  return { valid: true, url: normalized, userAgent: "" };
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
      .pdk-annotated-textarea {
        position: relative;
      }

      .pdk-annotated-textarea > textarea {
        position: relative;
        z-index: 1;
        background: transparent !important;
      }

      .pdk-annotated-textarea__overlay {
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

      .pdk-annotated-textarea__invalid {
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
      textarea.getAttribute("data-pdk-default-min-height") || "0",
    );
    const nextMinHeight = Math.max(
      storedMinHeight,
      textarea.offsetHeight,
      getRowsMinHeight(),
    );

    if (nextMinHeight > 0) {
      if (storedMinHeight <= 0) {
        textarea.setAttribute(
          "data-pdk-default-min-height",
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
    html += `<span class="pdk-annotated-textarea__invalid">${escapeHtml(
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

  if (textarea.__podkopAnnotatedTextareaController) {
    textarea.__podkopAnnotatedTextareaController.analyzer = analyzer;
    textarea.__podkopAnnotatedTextareaController.update();
    return;
  }

  const wrapper = textarea.parentNode;
  if (!wrapper) {
    return;
  }

  wrapper.classList.add("pdk-annotated-textarea");

  const overlay = document.createElement("div");
  overlay.className = "pdk-annotated-textarea__overlay";
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

  textarea.__podkopAnnotatedTextareaController = controller;

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
    textarea.__podkopAnnotatedTextareaController &&
    typeof textarea.__podkopAnnotatedTextareaController.update === "function"
  ) {
    textarea.__podkopAnnotatedTextareaController.update();
  }
}

function attachNfqwsRemoteValidation(option, section_id, textarea) {
  if (!textarea || textarea.__podkopNfqwsRemoteValidationAttached) {
    return;
  }

  textarea.__podkopNfqwsRemoteValidationAttached = true;
  textarea.__podkopNfqwsRemoteValidationRequestId = 0;
  textarea.__podkopNfqwsRemoteValidationTimer = null;

  const runValidation = () => {
    const value = textarea.value;
    const localAnalysis = buildNfqwsLocalAnalysis(value);
    if (!localAnalysis.valid) {
      refreshAnnotatedTextareaValidation(option, section_id, textarea);
      return;
    }

    const requestId =
      (textarea.__podkopNfqwsRemoteValidationRequestId || 0) + 1;
    textarea.__podkopNfqwsRemoteValidationRequestId = requestId;

    validateNfqwsStrategyRemotely(value).then(() => {
      if (textarea.__podkopNfqwsRemoteValidationRequestId !== requestId) {
        return;
      }

      refreshAnnotatedTextareaValidation(option, section_id, textarea);
    });
  };

  const scheduleValidation = (delay = NFQWS_REMOTE_VALIDATION_DEBOUNCE_MS) => {
    if (textarea.__podkopNfqwsRemoteValidationTimer) {
      window.clearTimeout(textarea.__podkopNfqwsRemoteValidationTimer);
    }

    textarea.__podkopNfqwsRemoteValidationTimer = window.setTimeout(() => {
      textarea.__podkopNfqwsRemoteValidationTimer = null;
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
  return analyzeTextListValue(
    value,
    (item) => main.validateDomain(item, true),
    _("At least one valid domain must be specified."),
    {
      normalizeDuplicateValue: (item) => `${item}`.toLowerCase(),
    },
  );
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
    "External nfqws config files bypass Podkop Plus queue management and explicit validation.",
  );
  const hostSelectionMessage = _(
    "Resource selection by hostname inside nfqws is not supported here; sing-box selects resources before NFQUEUE.",
  );
  const ipSelectionMessage = _(
    "Resource selection by IP or CIDR inside nfqws is not supported here; sing-box selects resources before NFQUEUE.",
  );
  const placeholderMessage = _(
    "Zapret hostlist templates are not supported here because Podkop Plus does not expand them for per-rule NFQWS strategies.",
  );
  const queueMessage = _(
    "The NFQUEUE number is assigned by Podkop Plus for each rule and must not be overridden here.",
  );
  const fwmarkMessage = _(
    "The desync fwmark is managed by Podkop Plus for loop prevention and must not be overridden here.",
  );
  const daemonMessage = _(
    "Podkop Plus manages the nfqws process lifecycle itself, so daemon mode is not allowed here.",
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
    "ByeDPI listen address and port are assigned by Podkop Plus and must not be set in the strategy.",
  );
  const transparentMessage = _(
    "Transparent proxy mode is incompatible with action=byedpi because Podkop Plus connects to ciadpi through SOCKS.",
  );
  const daemonMessage = _(
    "Podkop Plus manages the ciadpi process lifecycle itself, so daemon mode is not allowed here.",
  );
  const pidfileMessage = _(
    "Podkop Plus manages ciadpi pid files itself, so pidfile options are not allowed here.",
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

function configureTextareaOption(option, analyzer) {
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
    }

    return node;
  };
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
  o.placeholder = _("Device, IP, or subnet");
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
    return createLocalDeviceDynamicListWidget(this, section_id, cfgvalue);
  };

  return o;
}

function addTextConditionField(section, config) {
  const o = section.taboption(
    "conditions",
    form.TextValue,
    `${config.key}_text`,
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
    const textValue = uci.get(UCI_PACKAGE, section_id, `${config.key}_text`);
    if (textValue) {
      return textValue;
    }

    return valuesToText(uci.get(UCI_PACKAGE, section_id, config.key));
  };

  o.write = function (section_id, value) {
    const normalized = value ? `${value}`.trim() : "";

    if (normalized.length) {
      uci.set(UCI_PACKAGE, section_id, `${config.key}_text`, normalized);
    } else {
      uci.unset(UCI_PACKAGE, section_id, `${config.key}_text`);
    }

    uci.unset(UCI_PACKAGE, section_id, config.key);
    uci.unset(UCI_PACKAGE, section_id, `${config.key}_text_mode`);
  };
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
  const communityValues = getConfigListValues(
    section_id,
    "community_lists",
  ).filter((value) => isBuiltinRulesetValue(value));
  const legacyBuiltIns = getRulesetReferences(section_id).filter((value) =>
    isBuiltinRulesetValue(value),
  );

  const values = communityValues.length > 0 ? communityValues : legacyBuiltIns;

  return values.filter(
    (value, index, values) =>
      isBuiltinRulesetValue(value) && values.indexOf(value) === index,
  );
}

function getCustomRulesetReferences(section_id) {
  return getRulesetReferences(section_id).filter(
    (value) => !isBuiltinRulesetValue(value),
  );
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
  o.load = function () {
    return ensureActionProvidersAvailabilityLoaded();
  };
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
    _("What Podkop Plus should do when this section matches"),
  );
  populateActionOptionValues(o);
  o.default = "proxy";
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

    uci.set(UCI_PACKAGE, section_id, "nfqws_opt", nextValue);
  };
  o.validate = function (_section_id, value) {
    const analysis = analyzeNfqwsStrategy(value);
    return analysis.valid ? true : analysis.message;
  };
  configureTextareaOption(o, analyzeNfqwsStrategy);

  o = section.taboption(
    "settings",
    form.TextValue,
    "byedpi_cmd_opts",
    _("ByeDPI Strategy"),
    _(
      "ciadpi command options. Podkop Plus manages the listen address and port.",
    ),
  );
  o.depends("action", "byedpi");
  o.rows = 5;
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
    _("vless://, ss://, trojan://, socks4/5://, hy2/hysteria2:// links"),
  );
  o.depends("action", "proxy");
  o.modalonly = true;
  o.validate = function (_section_id, value) {
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateProxyUrl(value);
    return validation.valid ? true : validation.message;
  };

  o = section.taboption(
    "settings",
    form.DynamicList,
    "subscription_urls",
    _("Subscription URL"),
    _("Enter the subscription URL"),
  );
  o.depends("action", "proxy");
  o.rmempty = true;
  o.modalonly = true;
  o.validate = validateSubscriptionUrlEntry;

  o = section.taboption(
    "settings",
    form.Flag,
    "subscription_update_enabled",
    _("Subscription auto updates"),
  );
  o.default = "1";
  o.rmempty = false;
  o.depends({ action: "proxy", subscription_urls: /.+/ });
  o.modalonly = true;

  o = section.taboption(
    "settings",
    form.Value,
    "subscription_update_interval",
    _("Subscription update interval"),
    _("Use sing-box duration format like 1d, 12h or 30m"),
  );
  o.default = "1h";
  o.placeholder = "1h";
  o.rmempty = false;
  o.depends({
    action: "proxy",
    subscription_urls: /.+/,
    subscription_update_enabled: "1",
  });
  o.modalonly = true;
  o.validate = function (_section_id, value) {
    return validateRequiredSingBoxDuration(value);
  };

  o = section.taboption(
    "settings",
    form.Flag,
    "detect_server_country",
    _("Detect server country"),
    _("Resolve server countries using country.is"),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("action", "proxy");
  o.modalonly = true;

  o = section.taboption(
    "settings",
    form.Flag,
    "urltest_enabled",
    _("Auto select by URLTest"),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("action", "proxy");
  o.modalonly = true;

  o = section.taboption(
    "settings",
    form.TextValue,
    "outbound_json",
    _("Outbound JSON"),
    _("Enter a complete sing-box outbound object"),
  );
  o.depends("action", "outbound");
  o.rows = 10;
  o.wrap = "soft";
  o.textarea = true;
  o.modalonly = true;
  o.validate = function (_section_id, value) {
    if (!value || value.length === 0) {
      return _("Outbound JSON cannot be empty");
    }

    const validation = main.validateOutboundJson(value);
    return validation.valid ? true : validation.message;
  };
  configureTextareaOption(o);

  o = section.taboption(
    "settings",
    form.Value,
    "urltest_check_interval",
    _("URLTest interval"),
    _("Use sing-box duration format like 1d, 12h or 30m"),
  );
  o.default = "3m";
  o.placeholder = "3m";
  o.rmempty = false;
  o.depends({ action: "proxy", urltest_enabled: "1" });
  o.modalonly = true;
  o.validate = function (_section_id, value) {
    return validateRequiredSingBoxDuration(value);
  };

  o = section.taboption(
    "settings",
    form.Value,
    "urltest_tolerance",
    _("URLTest tolerance"),
    _("Maximum response time delta in milliseconds"),
  );
  o.default = "50";
  o.rmempty = false;
  o.depends({ action: "proxy", urltest_enabled: "1" });
  o.modalonly = true;
  o.validate = function (_section_id, value) {
    if (!value || value.length === 0) {
      return true;
    }

    const parsed = parseFloat(value);
    if (
      /^[0-9]+$/.test(value) &&
      !isNaN(parsed) &&
      isFinite(parsed) &&
      parsed >= 50 &&
      parsed <= 1000
    ) {
      return true;
    }

    return _("Must be a number in the range of 50 - 1000");
  };

  o = section.taboption(
    "settings",
    form.Value,
    "urltest_testing_url",
    _("URLTest URL"),
  );
  o.value(
    "https://www.gstatic.com/generate_204",
    "https://www.gstatic.com/generate_204 (Google)",
  );
  o.value(
    "https://cp.cloudflare.com/generate_204",
    "https://cp.cloudflare.com/generate_204 (Cloudflare)",
  );
  o.value("https://captive.apple.com", "https://captive.apple.com (Apple)");
  o.value(
    "https://connectivity-check.ubuntu.com",
    "https://connectivity-check.ubuntu.com (Ubuntu)",
  );
  o.default = "https://www.gstatic.com/generate_204";
  o.rmempty = false;
  o.depends({ action: "proxy", urltest_enabled: "1" });
  o.modalonly = true;
  o.validate = function (_section_id, value) {
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateUrl(value);
    return validation.valid ? true : validation.message;
  };

  o = section.taboption(
    "settings",
    form.ListValue,
    "urltest_filter_mode",
    _("URLTest server filtering"),
    _("Allows limiting the list of servers for URLTest"),
  );
  o.value("disabled", _("Disabled"));
  o.value("exclude", _("Blacklist"));
  o.value("include", _("Whitelist"));
  o.default = "disabled";
  o.rmempty = false;
  o.depends({ action: "proxy", urltest_enabled: "1" });
  o.modalonly = true;

  o = section.taboption(
    "settings",
    form.DynamicList,
    "urltest_exclude_countries",
    _("Exclude country from URLTest"),
    _("Servers from selected countries will not be tested by URLTest"),
  );
  populateCountryOptionValues(o);
  o.create = false;
  o.rmempty = true;
  o.depends({
    action: "proxy",
    detect_server_country: "1",
    urltest_filter_mode: "exclude",
    urltest_enabled: "1",
  });
  o.modalonly = true;
  o.validate = validateCountryCode;

  o = section.taboption(
    "settings",
    form.DynamicList,
    "urltest_exclude_outbounds",
    _("Exclude server from URLTest"),
    _("Select a loaded server or enter an exact server name"),
  );
  o.placeholder = _("-- Select --");
  o.rmempty = true;
  o.depends({
    action: "proxy",
    urltest_enabled: "1",
    urltest_filter_mode: "exclude",
  });
  o.modalonly = true;
  o.renderWidget = function (section_id, _option_index, cfgvalue) {
    return createOutboundNameDynamicListWidget(this, section_id, cfgvalue);
  };

  o = section.taboption(
    "settings",
    form.DynamicList,
    "urltest_exclude_regex",
    _("Exclude server by regular expression from URLTest"),
    _(
      "Servers with names matching these regular expressions will not be tested by URLTest",
    ),
  );
  o.rmempty = true;
  o.depends({
    action: "proxy",
    urltest_enabled: "1",
    urltest_filter_mode: "exclude",
  });
  o.modalonly = true;
  o.validate = validateRegex;

  o = section.taboption(
    "settings",
    form.DynamicList,
    "urltest_include_countries",
    _("Include country in URLTest"),
    _("Only servers from selected countries will be tested by URLTest"),
  );
  populateCountryOptionValues(o);
  o.create = false;
  o.rmempty = true;
  o.depends({
    action: "proxy",
    detect_server_country: "1",
    urltest_filter_mode: "include",
    urltest_enabled: "1",
  });
  o.modalonly = true;
  o.validate = validateCountryCode;

  o = section.taboption(
    "settings",
    form.DynamicList,
    "urltest_include_outbounds",
    _("Include server in URLTest"),
    _(
      "Select servers that will participate in URLTest checks. Other servers will be ignored.",
    ),
  );
  o.placeholder = _("-- Select --");
  o.rmempty = true;
  o.depends({
    action: "proxy",
    urltest_enabled: "1",
    urltest_filter_mode: "include",
  });
  o.modalonly = true;
  o.renderWidget = function (section_id, _option_index, cfgvalue) {
    return createOutboundNameDynamicListWidget(this, section_id, cfgvalue);
  };

  o = section.taboption(
    "settings",
    form.DynamicList,
    "urltest_include_regex",
    _("Include server by regular expression in URLTest"),
    _(
      "Only servers whose names match these regular expressions will be checked through URLTest",
    ),
  );
  o.rmempty = true;
  o.depends({
    action: "proxy",
    urltest_enabled: "1",
    urltest_filter_mode: "include",
  });
  o.modalonly = true;
  o.validate = validateRegex;

  o = section.taboption(
    "settings",
    form.Flag,
    "enable_udp_over_tcp",
    _("UDP over TCP"),
    _("Applicable for SOCKS and Shadowsocks links"),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("action", "proxy");
  o.modalonly = true;

  o = section.taboption(
    "settings",
    widgets.DeviceSelect,
    "interface",
    _("Network Interface"),
    _("Select network interface for VPN connection"),
  );
  o.noaliases = true;
  o.nobridges = false;
  o.noinactive = false;
  o.depends("action", "vpn");
  o.modalonly = true;
  o.filter = function (_section_id, value) {
    const blockedInterfaces = [
      "br-lan",
      "eth0",
      "eth1",
      "wan",
      "phy0-ap0",
      "phy1-ap0",
      "pppoe-wan",
      "lan",
    ];

    if (blockedInterfaces.includes(value)) {
      return false;
    }

    const device = this.devices.find((dev) => dev.getName() === value);
    if (!device) {
      return true;
    }

    const type = device.getType();
    const isWireless =
      type === "wifi" || type === "wireless" || type.indexOf("wlan") >= 0;

    return !isWireless;
  };

  o = section.taboption(
    "settings",
    form.Flag,
    "domain_resolver_enabled",
    _("Domain Resolver"),
    _("Enable built-in DNS resolver for domains handled by this section"),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("action", "vpn");
  o.modalonly = true;

  o = section.taboption(
    "settings",
    form.ListValue,
    "domain_resolver_dns_type",
    _("DNS protocol"),
  );
  o.value("doh", _("DNS over HTTPS (DoH)"));
  o.value("dot", _("DNS over TLS (DoT)"));
  o.value("udp", "UDP");
  o.default = "udp";
  o.rmempty = false;
  o.depends({
    action: "vpn",
    domain_resolver_enabled: "1",
  });
  o.modalonly = true;

  o = section.taboption(
    "settings",
    form.Value,
    "domain_resolver_dns_server",
    _("DNS server"),
  );
  Object.entries(main.DNS_SERVER_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.default = "8.8.8.8";
  o.rmempty = false;
  o.depends({
    action: "vpn",
    domain_resolver_enabled: "1",
  });
  o.modalonly = true;
  o.validate = function (_section_id, value) {
    const validation = main.validateDNS(value);
    return validation.valid ? true : validation.message;
  };

  o = section.taboption(
    "settings",
    form.Flag,
    "mixed_proxy_enabled",
    _("Enable Mixed Proxy"),
    _("Expose this section as a local HTTP+SOCKS proxy"),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("action", "proxy");
  o.depends("action", "outbound");
  o.depends("action", "vpn");
  o.depends("action", "byedpi");
  o.depends("action", "zapret");
  o.modalonly = true;

  o = section.taboption(
    "settings",
    form.Value,
    "mixed_proxy_port",
    _("Mixed Proxy Port"),
    _("Port for the local mixed proxy of this section"),
  );
  o.rmempty = false;
  o.depends({ action: "proxy", mixed_proxy_enabled: "1" });
  o.depends({ action: "outbound", mixed_proxy_enabled: "1" });
  o.depends({ action: "vpn", mixed_proxy_enabled: "1" });
  o.depends({ action: "byedpi", mixed_proxy_enabled: "1" });
  o.depends({ action: "zapret", mixed_proxy_enabled: "1" });
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
    "resolve_real_ip_for_routing",
    _("Resolve real IP for routing"),
    _(
      "Resolve domain names before routing so sing-box can use real destination IPs.",
    ),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("action", "proxy");
  o.depends("action", "outbound");
  o.depends("action", "vpn");
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
    label: _("Domains"),
    description: _("Match domains including all subdomains"),
    textAnalyze: analyzeDomainSuffixText,
  });

  addTextConditionField(section, {
    key: "ip_cidr",
    label: _("IPs"),
    description: _("Match destination IPs or subnets"),
    textAnalyze: analyzeIpCidrText,
  });

  addDynamicConditionField(section, {
    key: "domain",
    label: _("Exact full domain"),
    description: _("Match only one exact full domain name"),
    dynamicValidate: function (_section_id, value) {
      if (!value || value.length === 0) {
        return true;
      }

      const validation = main.validateDomain(value);
      return validation.valid ? true : validation.message;
    },
  });

  addDynamicConditionField(section, {
    key: "domain_keyword",
    label: _("Domain keyword"),
    description: _("Match domains containing a substring"),
    dynamicValidate: validateKeyword,
  });

  addDynamicConditionField(section, {
    key: "domain_regex",
    label: _("Domain regex"),
    description: _("Match domains using a regular expression"),
    dynamicValidate: validateRegex,
  });

  addLocalDeviceSubnetDynamicField(section, {
    key: "source_ip_cidr",
    label: _("Source IPs"),
    description: _("Match source IPs or subnets"),
  });

  o = addLocalDeviceSubnetDynamicField(section, {
    key: "fully_routed_ips",
    label: _("Fully Routed IPs"),
    description: _(
      "Specify local IP addresses or subnets whose traffic will always be routed through the configured route",
    ),
  });

  const builtInRulesetOption = section.taboption(
    "conditions",
    form.DynamicList,
    "community_lists",
    _("Built-in rule sets"),
    _("Select a predefined list for routing"),
  );
  builtInRulesetOption.modalonly = true;
  builtInRulesetOption.placeholder = _("Service list");
  builtInRulesetOption.load = function (section_id) {
    loadRulesetValues(this);
    return getBuiltInRulesetReferences(section_id);
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
    form.DynamicList,
    "rule_set",
    _("Rule sets (domains)"),
    _(
      "Add URLs or local paths to .srs / .json lists. Subnet rules are ignored",
    ),
  );
  ruleSetOption.modalonly = true;
  ruleSetOption.load = function (section_id) {
    return getCustomRulesetReferences(section_id);
  };
  ruleSetOption.validate = function (_section_id, value) {
    return validateCustomRulesetReference(value);
  };

  const ruleSetWithSubnetsOption = section.taboption(
    "conditions",
    form.DynamicList,
    "rule_set_with_subnets",
    _("Rule sets (domains and subnets)"),
    _(
      "Add URLs or local paths to .srs / .json lists. Subnets from the list will be extracted and added to nftables",
    ),
  );
  ruleSetWithSubnetsOption.modalonly = true;
  ruleSetWithSubnetsOption.load = function (section_id) {
    return getConfigListValues(section_id, "rule_set_with_subnets");
  };
  ruleSetWithSubnetsOption.validate = function (_section_id, value) {
    return validateCustomRulesetReference(value);
  };

  const domainIpListsOption = section.taboption(
    "conditions",
    form.DynamicList,
    "domain_ip_lists",
    _("Domain and IP Lists"),
    _("Add URLs or local paths to .lst lists"),
  );
  domainIpListsOption.modalonly = true;
  domainIpListsOption.load = function (section_id) {
    return getConfigListValues(section_id, "domain_ip_lists");
  };
  domainIpListsOption.validate = function (_section_id, value) {
    return validatePlainListReference(value);
  };
}

const EntryPoint = {
  createSectionContent,
};

return baseclass.extend(EntryPoint);
