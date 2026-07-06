#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

function usage() {
  console.error("Usage: config_contract_matrix.js --current <repo> --stable <repo> [--check]");
  process.exit(2);
}

function parseArgs(argv) {
  const args = { check: false };
  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--check") {
      args.check = true;
    } else if (arg === "--current" || arg === "--stable") {
      if (!argv[i + 1]) usage();
      args[arg.slice(2)] = path.resolve(argv[++i]);
    } else {
      usage();
    }
  }
  if (!args.current || !args.stable) usage();
  return args;
}

function gitDescribe(repo) {
  const result = spawnSync("git", ["describe", "--tags", "--always", "HEAD"], {
    cwd: repo,
    encoding: "utf8",
  });
  if (result.status === 0 && result.stdout.trim()) return result.stdout.trim();

  const fallback = path.basename(repo).match(/[0-9]+\.[0-9]+\.[0-9]+(?:[.-][0-9]+)?/);
  return fallback ? fallback[0] : "";
}

function readFileIfExists(file) {
  try {
    return fs.readFileSync(file, "utf8");
  } catch {
    return "";
  }
}

function walkFiles(dir, result = []) {
  if (!fs.existsSync(dir)) return result;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === ".git" || entry.name === "sandbox") continue;
      walkFiles(full, result);
    } else {
      result.push(full);
    }
  }
  return result;
}

function ensure(map, key) {
  if (!map.has(key)) {
    map.set(key, {
      name: key,
      ui: [],
      backend: [],
      defaults: [],
      examples: [],
      migrations: [],
    });
  }
  return map.get(key);
}

function addUnique(array, value) {
  if (value && !array.includes(value)) array.push(value);
}

function rel(repo, file) {
  return path.relative(repo, file).replace(/\\/g, "/");
}

function extractBraceBody(data, marker) {
  const markerIndex = data.indexOf(marker);
  if (markerIndex < 0) return "";

  const start = data.indexOf("{", markerIndex);
  if (start < 0) return "";

  let depth = 0;
  for (let i = start; i < data.length; i++) {
    const char = data[i];
    if (char === "{") {
      depth++;
    } else if (char === "}") {
      depth--;
      if (depth === 0) return data.slice(start + 1, i);
    }
  }

  return "";
}

function extractObjectKeys(data, constName) {
  const body = extractBraceBody(data, `const ${constName}`);
  return [...body.matchAll(/^\s*([A-Za-z0-9_]+)\s*:/gm)].map((match) => match[1]);
}

function extractFunctionFirstStringArgs(data, functionName, callName) {
  const body = extractBraceBody(data, `function ${functionName}`);
  const pattern = new RegExp(`${callName}\\(\\s*["']([^"']*)["']`, "g");
  return [...body.matchAll(pattern)].map((match) => match[1]);
}

function extractFunctionSecondStringArgs(data, functionName, callName) {
  const body = extractBraceBody(data, `function ${functionName}`);
  const pattern = new RegExp(`${callName}\\(\\s*[^,]+,\\s*["']([^"']*)["']`, "g");
  return [...body.matchAll(pattern)].map((match) => match[1]);
}

function extractFunctionObjectValues(data, functionName) {
  const body = extractBraceBody(data, `function ${functionName}`);
  return [...body.matchAll(/\bvalue:\s*["']([^"']*)["']/g)].map((match) => match[1]);
}

function enrichUiValues(fileData, option, block, values) {
  if (option === "action" && block.includes("populateActionOptionValues(")) {
    for (const value of extractFunctionFirstStringArgs(fileData, "populateActionOptionValues", "option.value"))
      addUnique(values, value);
  }

  if (option === "protocol" && block.includes("populateProtocolValues(")) {
    for (const constName of ["TAILSCALE_PROTOCOL_LABELS", "BASE_PROTOCOL_LABELS", "EXTENDED_PROTOCOL_LABELS", "CUSTOM_PROTOCOL_LABELS"]) {
      for (const value of extractObjectKeys(fileData, constName))
        addUnique(values, value);
    }
  }

  if (option === "transport" && block.includes("populateTransportValues(")) {
    for (const value of extractFunctionSecondStringArgs(fileData, "populateTransportValues", "addOptionValue"))
      addUnique(values, value);
  }
}

function extractUi(repo, fields) {
  const viewDir = path.join(
    repo,
    "luci-app-podkop-plus",
    "htdocs",
    "luci-static",
    "resources",
    "view",
    "podkop",
  );
  const files = walkFiles(viewDir).filter((file) => file.endsWith(".js"));

  for (const file of files) {
    const data = readFileIfExists(file);
    const optionRe = /\.(option|taboption)\(\s*(?:(["'])[^"']+\2\s*,\s*)?([^,\n]+)\s*,\s*["']([^"']+)["']/g;
    const matches = [...data.matchAll(optionRe)];

    for (let i = 0; i < matches.length; i++) {
      const match = matches[i];
      const option = match[4];
      const start = match.index;
      const end = i + 1 < matches.length ? matches[i + 1].index : data.length;
      const block = data.slice(start, end);
      const field = ensure(fields, option);
      const type = match[3].trim().replace(/\s+/g, " ");
      const defaults = [...block.matchAll(/\bo\.default\s*=\s*["']([^"']*)["']/g)].map((m) => m[1]);
      const values = [...block.matchAll(/\bo\.value\(\s*["']([^"']*)["']/g)].map((m) => m[1]);
      enrichUiValues(data, option, block, values);
      addUnique(
        field.ui,
        JSON.stringify({
          file: rel(repo, file),
          type,
          default: defaults[0] || "",
          values: values.sort(),
        }),
      );
    }

    const urltestFilterModeValues = extractFunctionObjectValues(data, "urlTestFilterModeChoices");
    if (urltestFilterModeValues.length) {
      const field = ensure(fields, "urltest_filter_mode");
      addUnique(
        field.ui,
        JSON.stringify({
          file: rel(repo, file),
          type: "custom URLTest settings",
          default: "disabled",
          values: urltestFilterModeValues.sort(),
        }),
      );
    }
  }
}

function extractConfigDefaults(repo, fields) {
  const file = path.join(repo, "podkop", "files", "etc", "config", "podkop");
  const data = readFileIfExists(file);
  for (const line of data.split(/\n/)) {
    const match = line.match(/^\s*(#\s*)?(option|list)\s+([A-Za-z0-9_]+)\s+['"]?([^'"]*)/);
    if (!match) continue;
    const field = ensure(fields, match[3]);
    const item = `${rel(repo, file)}:${match[2]}:${match[4]}`;
    addUnique(match[1] ? field.examples : field.defaults, item);
  }
}

function extractBackend(repo, fields) {
  const roots = [
    path.join(repo, "podkop", "files", "usr", "lib"),
    path.join(repo, "podkop", "files", "usr", "bin"),
    path.join(repo, "podkop", "files", "etc", "init.d"),
  ];
  const files = roots.flatMap((root) => walkFiles(root)).filter((file) => /\.(sh|uc)$/.test(file) || /[\\/]podkop$/.test(file));

  const shellOptionRe = /\bconfig_(?:get|get_bool|list_foreach)\s+\S+\s+(?:"[^"]+"|'[^']+'|\$[A-Za-z_][A-Za-z0-9_]*|\$\{[^}]+\})\s+["']([A-Za-z0-9_]+)["']/g;
  const ucodeOptionRe = /\b(?:option|list_option|bool_option|int_option)\(\s*[^,\n]+,\s*["']([A-Za-z0-9_]+)["']/g;
  const ucodeStaticOptionKeyArrayRe = /^\s*\[\s*["']([A-Za-z0-9_]+)["']\s*,/gm;
  const migrationRe = /\bpodkop_uci_(?:set_option|set_option_if_missing|delete_option|add_list_unique)\s+["'$A-Za-z0-9_{}.-]+\s+["']([A-Za-z0-9_]+)["']/g;
  const ucodeMigrationRe = /\b(?:set_option|set_option_if_missing|delete_option|add_list_unique)\(\s*[^,\n]+,\s*[^,\n]+,\s*["']([A-Za-z0-9_]+)["']/g;

  for (const file of files) {
    const data = readFileIfExists(file);
    const backendScanData = data.replace(/\\"/g, '"');
    for (const match of backendScanData.matchAll(shellOptionRe)) {
      addUnique(ensure(fields, match[1]).backend, rel(repo, file));
    }
    for (const match of backendScanData.matchAll(ucodeOptionRe)) {
      addUnique(ensure(fields, match[1]).backend, rel(repo, file));
    }
    if (backendScanData.includes("option(server, field[0]")) {
      for (const match of backendScanData.matchAll(ucodeStaticOptionKeyArrayRe)) {
        addUnique(ensure(fields, match[1]).backend, rel(repo, file));
      }
    }
    for (const match of backendScanData.matchAll(migrationRe)) {
      addUnique(ensure(fields, match[1]).migrations, rel(repo, file));
    }
    for (const match of backendScanData.matchAll(ucodeMigrationRe)) {
      addUnique(ensure(fields, match[1]).migrations, rel(repo, file));
    }
  }
}

function extractRepo(repo) {
  const fields = new Map();
  extractUi(repo, fields);
  extractConfigDefaults(repo, fields);
  extractBackend(repo, fields);
  return fields;
}

function publicPresence(field) {
  return field && (field.ui.length || field.backend.length || field.defaults.length || field.examples.length || field.migrations.length);
}

function compactField(field) {
  if (!field) return null;
  return {
    ui: field.ui.map((item) => JSON.parse(item)).sort((a, b) => a.file.localeCompare(b.file) || a.type.localeCompare(b.type)),
    backend: field.backend.slice().sort(),
    defaults: field.defaults.slice().sort(),
    examples: field.examples.slice().sort(),
    migrations: field.migrations.slice().sort(),
  };
}

function classify(stable, current) {
  if (publicPresence(stable) && publicPresence(current)) return "supported";
  if (publicPresence(stable) && current && current.migrations.length) return "migrated";
  if (publicPresence(stable)) return "missing_current";
  return "added_current";
}

function buildMatrix(currentRepo, stableRepo) {
  const stable = extractRepo(stableRepo);
  const current = extractRepo(currentRepo);
  const names = Array.from(new Set([...stable.keys(), ...current.keys()])).sort();
  const fields = names.map((name) => {
    const stableField = stable.get(name);
    const currentField = current.get(name);
    return {
      name,
      status: classify(stableField, currentField),
      stable: compactField(stableField),
      current: compactField(currentField),
    };
  });

  const summary = {};
  for (const field of fields) summary[field.status] = (summary[field.status] || 0) + 1;

  return {
    stable: {
      path: stableRepo,
      version: gitDescribe(stableRepo),
    },
    current: {
      path: currentRepo,
      version: gitDescribe(currentRepo),
    },
    summary,
    fields,
  };
}

function main() {
  const args = parseArgs(process.argv);
  const matrix = buildMatrix(args.current, args.stable);
  process.stdout.write(JSON.stringify(matrix, null, 2) + "\n");

  if (args.check) {
    const missing = matrix.fields.filter((field) => field.status === "missing_current");
    if (missing.length) {
      console.error(`Missing current config fields from stable contract: ${missing.map((f) => f.name).join(", ")}`);
      process.exit(1);
    }
  }
}

main();
