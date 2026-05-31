"use strict";
"require form";
"require baseclass";
"require dom";
"require fs";
"require rpc";
"require uci";
"require ui";
"require view.podkop_plus.main as main";

const UCI_PACKAGE = main.PODKOP_UCI_PACKAGE;
const ROUTING_SECTION_ACTIONS = [
  "proxy",
  "outbound",
  "vpn",
  "byedpi",
  "zapret",
  "direct",
  "block",
];
const callNetworkInterfaceDump = rpc.declare({
  object: "network.interface",
  method: "dump",
  expect: { interface: [] },
});
let defaultPublicHostPromise = null;
let defaultPublicHostCache = null;

function asList(value) {
  if (!value) {
    return [];
  }

  return Array.isArray(value) ? value.filter(Boolean) : [`${value}`];
}

const QR_EC_CODEWORDS_PER_BLOCK_LOW = [
  -1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28,
  28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
  30, 30,
];
const QR_NUM_ERROR_CORRECTION_BLOCKS_LOW = [
  -1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10,
  12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25,
];

function qrGetBit(value, index) {
  return ((value >>> index) & 1) !== 0;
}

function qrAppendBits(buffer, value, length) {
  for (let i = length - 1; i >= 0; i -= 1) {
    buffer.push(qrGetBit(value, i));
  }
}

function qrRawDataModules(version) {
  let result = (16 * version + 128) * version + 64;

  if (version >= 2) {
    const numAlign = Math.floor(version / 7) + 2;
    result -= (25 * numAlign - 10) * numAlign - 55;
    if (version >= 7) {
      result -= 36;
    }
  }

  return result;
}

function qrRawCodewords(version) {
  return Math.floor(qrRawDataModules(version) / 8);
}

function qrDataCodewords(version) {
  return (
    qrRawCodewords(version) -
    QR_EC_CODEWORDS_PER_BLOCK_LOW[version] *
      QR_NUM_ERROR_CORRECTION_BLOCKS_LOW[version]
  );
}

function qrEncodeText(text) {
  return Array.from(new TextEncoder().encode(text));
}

function qrBuildDataCodewords(bytes, version) {
  const capacity = qrDataCodewords(version);
  const bits = [];
  const countBits = version <= 9 ? 8 : 16;

  qrAppendBits(bits, 4, 4);
  qrAppendBits(bits, bytes.length, countBits);
  bytes.forEach((value) => qrAppendBits(bits, value, 8));
  qrAppendBits(bits, 0, Math.min(4, capacity * 8 - bits.length));

  while (bits.length % 8 !== 0) {
    bits.push(false);
  }

  const result = [];
  for (let i = 0; i < bits.length; i += 8) {
    let value = 0;
    for (let j = 0; j < 8; j += 1) {
      value = (value << 1) | (bits[i + j] ? 1 : 0);
    }
    result.push(value);
  }

  for (let pad = 0xec; result.length < capacity; pad ^= 0xfd) {
    result.push(pad);
  }

  return result;
}

function qrMultiply(x, y) {
  let z = 0;

  for (let i = 7; i >= 0; i -= 1) {
    z = (z << 1) ^ ((z >>> 7) * 0x11d);
    z ^= ((y >>> i) & 1) * x;
  }

  return z;
}

function qrReedSolomonDivisor(degree) {
  const result = Array(degree).fill(0);
  result[degree - 1] = 1;

  let root = 1;
  for (let i = 0; i < degree; i += 1) {
    for (let j = 0; j < degree; j += 1) {
      result[j] = qrMultiply(result[j], root);
      if (j + 1 < degree) {
        result[j] ^= result[j + 1];
      }
    }
    root = qrMultiply(root, 2);
  }

  return result;
}

function qrReedSolomonRemainder(data, divisor) {
  const result = Array(divisor.length).fill(0);

  data.forEach((value) => {
    const factor = value ^ result.shift();
    result.push(0);
    for (let i = 0; i < result.length; i += 1) {
      result[i] ^= qrMultiply(divisor[i], factor);
    }
  });

  return result;
}

function qrAddErrorCorrection(data, version) {
  const numBlocks = QR_NUM_ERROR_CORRECTION_BLOCKS_LOW[version];
  const blockEccLen = QR_EC_CODEWORDS_PER_BLOCK_LOW[version];
  const rawCodewords = qrRawCodewords(version);
  const numShortBlocks = numBlocks - (rawCodewords % numBlocks);
  const shortBlockDataLen = Math.floor(rawCodewords / numBlocks) - blockEccLen;
  const divisor = qrReedSolomonDivisor(blockEccLen);
  const blocks = [];

  for (let i = 0, offset = 0; i < numBlocks; i += 1) {
    const dataLen = shortBlockDataLen + (i < numShortBlocks ? 0 : 1);
    const blockData = data.slice(offset, offset + dataLen);
    offset += dataLen;
    blocks.push({
      data: blockData,
      ecc: qrReedSolomonRemainder(blockData, divisor),
    });
  }

  const result = [];
  const maxDataLen = Math.max(...blocks.map((block) => block.data.length));

  for (let i = 0; i < maxDataLen; i += 1) {
    blocks.forEach((block) => {
      if (i < block.data.length) {
        result.push(block.data[i]);
      }
    });
  }

  for (let i = 0; i < blockEccLen; i += 1) {
    blocks.forEach((block) => result.push(block.ecc[i]));
  }

  return result;
}

function qrAlignmentPatternPositions(version) {
  if (version === 1) {
    return [];
  }

  const size = version * 4 + 17;
  const numAlign = Math.floor(version / 7) + 2;
  const step =
    version === 32 ? 26 : Math.ceil((version * 4 + 4) / (numAlign * 2 - 2)) * 2;
  const result = [6];

  for (let pos = size - 7; result.length < numAlign; pos -= step) {
    result.splice(1, 0, pos);
  }

  return result;
}

function qrMakeMatrix(version, dataCodewords) {
  const size = version * 4 + 17;
  const modules = Array.from({ length: size }, () => Array(size).fill(false));
  const isFunction = Array.from({ length: size }, () =>
    Array(size).fill(false),
  );

  function setFunction(x, y, dark) {
    modules[y][x] = dark;
    isFunction[y][x] = true;
  }

  function drawFinder(cx, cy) {
    for (let dy = -4; dy <= 4; dy += 1) {
      for (let dx = -4; dx <= 4; dx += 1) {
        const x = cx + dx;
        const y = cy + dy;
        if (x < 0 || x >= size || y < 0 || y >= size) {
          continue;
        }
        const dist = Math.max(Math.abs(dx), Math.abs(dy));
        setFunction(x, y, dist !== 2 && dist !== 4);
      }
    }
  }

  function drawAlignment(cx, cy) {
    for (let dy = -2; dy <= 2; dy += 1) {
      for (let dx = -2; dx <= 2; dx += 1) {
        setFunction(
          cx + dx,
          cy + dy,
          Math.max(Math.abs(dx), Math.abs(dy)) !== 1,
        );
      }
    }
  }

  drawFinder(3, 3);
  drawFinder(size - 4, 3);
  drawFinder(3, size - 4);

  for (let i = 8; i < size - 8; i += 1) {
    setFunction(6, i, i % 2 === 0);
    setFunction(i, 6, i % 2 === 0);
  }

  const alignPositions = qrAlignmentPatternPositions(version);
  alignPositions.forEach((x) => {
    alignPositions.forEach((y) => {
      const overlapsFinder =
        (x === 6 && y === 6) ||
        (x === 6 && y === size - 7) ||
        (x === size - 7 && y === 6);
      if (!overlapsFinder) {
        drawAlignment(x, y);
      }
    });
  });

  if (version >= 7) {
    let rem = version;
    for (let i = 0; i < 12; i += 1) {
      rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25);
    }
    const bits = (version << 12) | rem;
    for (let i = 0; i < 18; i += 1) {
      const bit = qrGetBit(bits, i);
      const a = size - 11 + (i % 3);
      const b = Math.floor(i / 3);
      setFunction(a, b, bit);
      setFunction(b, a, bit);
    }
  }

  function drawFormatBits(mask) {
    const formatData = (1 << 3) | mask;
    let rem = formatData;

    for (let i = 0; i < 10; i += 1) {
      rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
    }

    const formatBits = ((formatData << 10) | rem) ^ 0x5412;

    for (let i = 0; i <= 5; i += 1) {
      setFunction(8, i, qrGetBit(formatBits, i));
    }
    setFunction(8, 7, qrGetBit(formatBits, 6));
    setFunction(8, 8, qrGetBit(formatBits, 7));
    setFunction(7, 8, qrGetBit(formatBits, 8));
    for (let i = 9; i < 15; i += 1) {
      setFunction(14 - i, 8, qrGetBit(formatBits, i));
    }
    for (let i = 0; i < 8; i += 1) {
      setFunction(size - 1 - i, 8, qrGetBit(formatBits, i));
    }
    for (let i = 8; i < 15; i += 1) {
      setFunction(8, size - 15 + i, qrGetBit(formatBits, i));
    }
    setFunction(8, size - 8, true);
  }

  drawFormatBits(0);

  const codewords = qrAddErrorCorrection(dataCodewords, version);
  let bitIndex = 0;
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) {
      right = 5;
    }
    for (let vert = 0; vert < size; vert += 1) {
      for (let j = 0; j < 2; j += 1) {
        const x = right - j;
        const upward = ((right + 1) & 2) === 0;
        const y = upward ? size - 1 - vert : vert;
        if (!isFunction[y][x] && bitIndex < codewords.length * 8) {
          modules[y][x] = qrGetBit(
            codewords[Math.floor(bitIndex / 8)],
            7 - (bitIndex % 8),
          );
          bitIndex += 1;
        }
      }
    }
  }

  for (let y = 0; y < size; y += 1) {
    for (let x = 0; x < size; x += 1) {
      if (!isFunction[y][x] && (x + y) % 2 === 0) {
        modules[y][x] = !modules[y][x];
      }
    }
  }

  drawFormatBits(0);

  return modules;
}

function qrSvgDataUri(text) {
  const bytes = qrEncodeText(text);
  let version = 1;

  for (; version <= 40; version += 1) {
    const countBits = version <= 9 ? 8 : 16;
    if (4 + countBits + bytes.length * 8 <= qrDataCodewords(version) * 8) {
      break;
    }
  }

  if (version > 40) {
    return "";
  }

  const matrix = qrMakeMatrix(version, qrBuildDataCodewords(bytes, version));
  const border = 4;
  const size = matrix.length;
  const viewSize = size + border * 2;
  const path = [];

  matrix.forEach((row, y) => {
    row.forEach((dark, x) => {
      if (dark) {
        path.push(`M${x + border},${y + border}h1v1h-1z`);
      }
    });
  });

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${viewSize} ${viewSize}" shape-rendering="crispEdges"><path fill="#fff" d="M0 0h${viewSize}v${viewSize}H0z"/><path fill="#000" d="${path.join(" ")}"/></svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

const SERVER_STYLE_ID = "podkop-plus-server-styles";
const STREAM_PROTOCOLS = ["vless", "vmess", "trojan"];
const PORT_PROTOCOLS = [
  "shadowsocks",
  "socks",
  "vmess",
  "vless",
  "trojan",
  "hysteria2",
];
const EXTENDED_PORT_PROTOCOLS = ["mtproto"];
const PASSWORD_PROTOCOLS = ["shadowsocks", "socks", "trojan", "hysteria2"];

const BASE_PROTOCOL_LABELS = {
  vless: "VLESS",
  shadowsocks: "Shadowsocks",
  socks: "SOCKS",
  vmess: "VMess",
  trojan: "Trojan",
  hysteria2: "Hysteria2",
  tailscale: "Tailscale",
};
const EXTENDED_PROTOCOL_LABELS = {
  mtproto: "MTProto",
};
const PROTOCOL_LABELS = {
  ...BASE_PROTOCOL_LABELS,
  ...EXTENDED_PROTOCOL_LABELS,
};

const SECURITY_BY_PROTOCOL = {
  vless: ["reality", "tls", "none"],
  vmess: ["tls", "none"],
  trojan: ["tls", "none"],
  hysteria2: ["tls"],
  shadowsocks: ["none"],
  socks: ["none"],
  mtproto: ["none"],
  tailscale: ["none"],
};

function getSecurityLabel(security) {
  if (security === "reality") {
    return "Reality";
  }
  if (security === "tls") {
    return "TLS";
  }
  return _("None");
}

function injectServerStyles() {
  if (document.getElementById(SERVER_STYLE_ID)) {
    return;
  }

  document.head.appendChild(
    E(
      "style",
      { id: SERVER_STYLE_ID },
      `
.pdk-server-icon-button{box-sizing:border-box;vertical-align:middle}
.pdk-server-icon-button__glyph{display:inline-block;line-height:1;transform:scale(1.55);transform-origin:center}
.pdk-server-icon-button--done{outline:2px solid var(--success-color,#37a969);outline-offset:1px}
.pdk-server-validation-summary{margin:0 0 12px}
#cbi-${UCI_PACKAGE}-server > h3:nth-child(1){display:none}
#cbi-${UCI_PACKAGE}-server > .cbi-section-remove{margin-bottom:-32px}
#cbi-${UCI_PACKAGE}-server .cbi-section-actions > div{display:inline-flex;align-items:center;gap:4px}
#cbi-${UCI_PACKAGE}-server .cbi-section-actions{text-align:right}

.pdk-server-info-modal{display:flex;flex-direction:column;gap:14px;width:560px;max-width:100%;box-sizing:border-box}
.pdk-server-info-modal__container{display:flex;gap:24px;align-items:flex-start;width:100%;box-sizing:border-box}
.pdk-server-info-modal__qr-col{display:flex;flex-direction:column;align-items:center;gap:12px;flex-shrink:0;width:180px}
.pdk-server-info-modal__qr-image{width:180px;height:180px;display:block;image-rendering:pixelated}
.pdk-server-info-modal__details-col{display:flex;flex-direction:column;gap:16px;flex-grow:1;min-width:0;box-sizing:border-box}
.pdk-server-info-modal__details-grid{display:flex;flex-direction:column;gap:10px;background:rgba(128,128,128,0.08);padding:14px;border:1px solid rgba(128,128,128,0.15);box-sizing:border-box}
.pdk-server-info-modal__detail-item{display:flex;justify-content:space-between;align-items:center;gap:16px}
.pdk-server-info-modal__detail-label{font-size:11px;opacity:0.65;text-transform:uppercase;letter-spacing:0.05em;font-weight:700}
.pdk-server-info-modal__detail-value{font-size:13px;font-weight:500}
.pdk-server-info-modal__detail-value--title{font-weight:600}
.pdk-server-info-modal__detail-value--mono{font-family:monospace;font-size:12px;background:rgba(128,128,128,0.12);padding:2px 6px;border-radius:4px;word-break:break-all}
.pdk-server-info-modal__badge{display:inline-flex;align-items:center;padding:2px 8px;font-size:11px;font-weight:600;border-radius:4px;border:1px solid var(--border-color,rgba(128,128,128,0.25));background:rgba(128,128,128,0.08);line-height:1.2}
.pdk-server-info-modal__link-section{display:flex;flex-direction:column;gap:8px;box-sizing:border-box}
.pdk-server-info-modal__link{width:100% !important;max-width:100% !important;font-family:monospace;font-size:11px;padding:8px 10px;resize:none;min-height:54px;box-sizing:border-box;margin:0 !important;line-height:1.4;word-break:break-all;float:none !important;position:static !important;border-radius:0 !important;background-color:transparent !important}
.pdk-server-info-modal__copy-btn{display:inline-flex;align-items:center;justify-content:center;gap:6px;align-self:flex-start;padding:3px 10px !important;font-size:11px !important;height:auto !important;min-height:24px !important;float:none !important;position:static !important;margin:0 !important}

@media (max-width:640px){
.pdk-server-info-modal{width:100%}
.pdk-server-info-modal__container{flex-direction:column;align-items:center;gap:20px}
.pdk-server-info-modal__qr-col{width:100%;max-width:180px}
.pdk-server-info-modal__details-col{width:100%}
}
`,
    ),
  );
}

function getFirstListValue(sectionId, option) {
  return asList(uci.get(UCI_PACKAGE, sectionId, option))[0] || "";
}

function serverInboundTag(sectionId) {
  return `server-${sectionId}-in`;
}

function getProtocol(sectionId) {
  return uci.get(UCI_PACKAGE, sectionId, "protocol") || "vless";
}

function getProtocolLabel(protocol) {
  return PROTOCOL_LABELS[protocol] || protocol || "";
}

function getAvailableProtocolLabels(singBoxExtended) {
  return singBoxExtended ? PROTOCOL_LABELS : BASE_PROTOCOL_LABELS;
}

function getServerName(sectionId) {
  return uci.get(UCI_PACKAGE, sectionId, "label") || sectionId;
}

function getSocksUsername(sectionId) {
  return (
    uci.get(UCI_PACKAGE, sectionId, "server_username") ||
    getServerName(sectionId) ||
    sectionId
  );
}

function getDefaultSecurity(protocol) {
  if (protocol === "vless") {
    return "reality";
  }
  if (protocol === "trojan" || protocol === "hysteria2") {
    return "tls";
  }
  return "none";
}

function normalizeVlessFlow(flow) {
  return flow === "xtls-rprx-vision" ? flow : "";
}

function getEffectiveSecurity(sectionId) {
  const protocol = getProtocol(sectionId);
  const security = uci.get(UCI_PACKAGE, sectionId, "security");

  if (
    protocol === "shadowsocks" ||
    protocol === "socks" ||
    protocol === "mtproto" ||
    protocol === "tailscale"
  ) {
    return "none";
  }
  if (protocol === "hysteria2") {
    return "tls";
  }
  if (security === "reality" && protocol !== "vless") {
    return getDefaultSecurity(protocol);
  }

  return security || getDefaultSecurity(protocol);
}

function normalizeHost(host) {
  return `${host || ""}`.trim().replace(/^\[|\]$/g, "");
}

function getBrowserHost() {
  return normalizeHost(window.location.hostname || "");
}

function isIpv4(value) {
  return /^(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3}$/.test(
    value,
  );
}

function isHostname(value) {
  const hostname = normalizeHost(value);
  if (hostname.length < 1 || hostname.length > 253 || hostname.endsWith(".")) {
    return false;
  }

  return hostname
    .split(".")
    .every((part) =>
      /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/.test(part),
    );
}

function isHost(value) {
  const host = normalizeHost(value);
  return isIpv4(host) || isHostname(host);
}

function isPrivateOrReservedIpv4(value) {
  if (!isIpv4(value)) {
    return true;
  }

  const octets = value.split(".").map((part) => parseInt(part, 10));
  const [a, b] = octets;

  return (
    a === 0 ||
    a === 10 ||
    a === 127 ||
    a >= 224 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) ||
    (a === 192 && b === 0) ||
    (a === 192 && b === 2) ||
    (a === 198 && (b === 18 || b === 19 || b === 51)) ||
    (a === 203 && b === 0)
  );
}

function getInterfaceIpv4Addresses(networkInterface) {
  const values =
    networkInterface &&
    typeof networkInterface === "object" &&
    Array.isArray(networkInterface["ipv4-address"])
      ? networkInterface["ipv4-address"]
      : [];

  return values
    .map((address) =>
      normalizeHost(
        address && typeof address === "object" ? address.address : address,
      ),
    )
    .filter(isIpv4);
}

function chooseDefaultPublicHost(networkInterfaces) {
  const interfaces = Array.isArray(networkInterfaces) ? networkInterfaces : [];
  const upInterfaces = interfaces.filter(
    (networkInterface) => networkInterface && networkInterface.up !== false,
  );
  const publicIp = upInterfaces
    .flatMap(getInterfaceIpv4Addresses)
    .find((ip) => !isPrivateOrReservedIpv4(ip));

  if (publicIp) {
    return publicIp;
  }

  const lanInterface =
    upInterfaces.find((networkInterface) => {
      const name = `${networkInterface.interface || ""}`;
      const device = `${networkInterface.device || networkInterface.l3_device || ""}`;
      return name === "lan" || device === "br-lan";
    }) || {};
  const lanIp = getInterfaceIpv4Addresses(lanInterface).find(
    (ip) => !ip.startsWith("127."),
  );

  if (lanIp) {
    return lanIp;
  }

  return (
    upInterfaces
      .flatMap(getInterfaceIpv4Addresses)
      .find((ip) => !ip.startsWith("127.")) || getBrowserHost()
  );
}

function loadDefaultPublicHost() {
  if (defaultPublicHostCache != null) {
    return Promise.resolve(defaultPublicHostCache);
  }

  if (defaultPublicHostPromise) {
    return defaultPublicHostPromise;
  }

  defaultPublicHostPromise = callNetworkInterfaceDump()
    .then((networkInterfaces) => {
      defaultPublicHostCache = chooseDefaultPublicHost(networkInterfaces);
      return defaultPublicHostCache;
    })
    .catch(() => getBrowserHost())
    .finally(() => {
      defaultPublicHostPromise = null;
    });

  return defaultPublicHostPromise;
}

function applyDefaultPublicHost(sectionId, host) {
  const normalizedHost = normalizeHost(host);
  const currentHost = normalizeHost(
    uci.get(UCI_PACKAGE, sectionId, "public_host"),
  );
  const browserHost = getBrowserHost();

  if (
    normalizedHost &&
    (!currentHost || currentHost === browserHost || currentHost === "127.0.0.1")
  ) {
    uci.set(UCI_PACKAGE, sectionId, "public_host", normalizedHost);
  }
}

function randomBytes(length) {
  const bytes = new Uint8Array(length);

  if (window.crypto && window.crypto.getRandomValues) {
    window.crypto.getRandomValues(bytes);
  } else {
    for (let i = 0; i < length; i += 1) {
      bytes[i] = Math.floor(Math.random() * 256);
    }
  }

  return bytes;
}

function randomHex(byteLength) {
  return Array.from(randomBytes(byteLength))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function stringToHex(value) {
  return Array.from(unescape(encodeURIComponent(`${value || ""}`)))
    .map((char) => char.charCodeAt(0).toString(16).padStart(2, "0"))
    .join("");
}

function generateUuid() {
  if (window.crypto && window.crypto.randomUUID) {
    return window.crypto.randomUUID();
  }

  const bytes = randomBytes(16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes)
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");

  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function base64Encode(value) {
  return btoa(unescape(encodeURIComponent(value)));
}

function base64UrlEncode(value) {
  return base64Encode(value)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function generatePassword() {
  return base64UrlEncode(
    Array.from(randomBytes(18))
      .map((byte) => String.fromCharCode(byte))
      .join(""),
  );
}

function generateMtprotoSecret(host = "google.com") {
  return `ee${randomHex(16)}${stringToHex(host)}`;
}

function randomPort() {
  const bytes = randomBytes(2);
  const value = (bytes[0] << 8) | bytes[1];
  return `${20000 + (value % 30000)}`;
}

function serverSafeName(sectionId) {
  return `${sectionId || "server"}`.replace(/[^A-Za-z0-9_.-]/g, "_");
}

function defaultTlsCertificatePath(sectionId) {
  return `/etc/podkop-plus/server-certs/${serverSafeName(sectionId)}.crt`;
}

function defaultTlsKeyPath(sectionId) {
  return `/etc/podkop-plus/server-certs/${serverSafeName(sectionId)}.key`;
}

function defaultTailscaleHostname(sectionId) {
  return `podkop-${serverSafeName(sectionId)}`;
}

function setDefault(sectionId, key, value) {
  const current = uci.get(UCI_PACKAGE, sectionId, key);
  if (current == null || current === "") {
    uci.set(UCI_PACKAGE, sectionId, key, value);
  }
}

function setValue(sectionId, key, value) {
  uci.set(UCI_PACKAGE, sectionId, key, value);
}

function cloneUciState(value) {
  return value == null ? null : JSON.parse(JSON.stringify(value));
}

function isEmptyObject(value) {
  return value && Object.keys(value).length === 0;
}

function setUciSectionState(bucketName, sectionId, value) {
  const state = uci.state;

  if (!state) {
    return;
  }

  state[bucketName] ??= {};
  const bucket = state[bucketName];

  if (value == null) {
    delete bucket[UCI_PACKAGE]?.[sectionId];
    if (isEmptyObject(bucket[UCI_PACKAGE])) {
      delete bucket[UCI_PACKAGE];
    }
    return;
  }

  bucket[UCI_PACKAGE] ??= {};
  bucket[UCI_PACKAGE][sectionId] = cloneUciState(value);
}

function captureServerEditState(sectionId) {
  const state = uci.state;

  if (!state || state.creates?.[UCI_PACKAGE]?.[sectionId]) {
    return null;
  }

  return {
    sectionId,
    changes: cloneUciState(state.changes?.[UCI_PACKAGE]?.[sectionId]),
    deletes: cloneUciState(state.deletes?.[UCI_PACKAGE]?.[sectionId]),
  };
}

function restoreServerEditState(snapshot) {
  if (!snapshot) {
    return;
  }

  setUciSectionState("changes", snapshot.sectionId, snapshot.changes);
  setUciSectionState("deletes", snapshot.sectionId, snapshot.deletes);
}

function ensureProtocolDefaults(sectionId, protocol, forceProtocolDefaults) {
  setValue(sectionId, "protocol", protocol);
  setDefault(sectionId, "enabled", "1");
  setDefault(sectionId, "label", sectionId);
  setDefault(sectionId, "listen", "0.0.0.0");
  setDefault(sectionId, "listen_port", randomPort());
  setDefault(sectionId, "public_host", getBrowserHost());
  setDefault(sectionId, "routing_mode", "rules");
  setDefault(
    sectionId,
    "tls_certificate_path",
    defaultTlsCertificatePath(sectionId),
  );
  setDefault(sectionId, "tls_key_path", defaultTlsKeyPath(sectionId));

  if (forceProtocolDefaults) {
    setValue(sectionId, "security", getDefaultSecurity(protocol));
    setValue(sectionId, "transport", "tcp");
  } else {
    setDefault(sectionId, "security", getDefaultSecurity(protocol));
    setDefault(sectionId, "transport", "tcp");
  }

  if (protocol === "vless" || protocol === "vmess") {
    setDefault(sectionId, "server_uuid", generateUuid());
  }

  if (PASSWORD_PROTOCOLS.includes(protocol)) {
    setDefault(sectionId, "server_password", generatePassword());
  }

  if (protocol === "socks") {
    setDefault(sectionId, "server_username", getServerName(sectionId));
  }

  if (protocol === "vless") {
    setDefault(sectionId, "vless_flow", "none");
    setDefault(sectionId, "tls_server_name", "www.microsoft.com");
    setDefault(sectionId, "client_fingerprint", "chrome");
    setDefault(sectionId, "reality_handshake_server", "www.microsoft.com");
    setDefault(sectionId, "reality_handshake_server_port", "443");
    setDefault(sectionId, "reality_short_id", randomHex(4));
    setDefault(sectionId, "reality_max_time_difference", "1m");
  }

  if (protocol === "vmess") {
    setDefault(sectionId, "vmess_alter_id", "0");
  }

  if (protocol === "shadowsocks") {
    setDefault(sectionId, "shadowsocks_method", "aes-128-gcm");
  }

  if (protocol === "tailscale") {
    setDefault(
      sectionId,
      "tailscale_control_url",
      "https://controlplane.tailscale.com",
    );
    setDefault(
      sectionId,
      "tailscale_hostname",
      defaultTailscaleHostname(sectionId),
    );
    setDefault(sectionId, "tailscale_advertise_exit_node", "1");
  }

  if (protocol === "hysteria2") {
    setDefault(sectionId, "hysteria2_obfs_password", generatePassword());
  }

  if (protocol === "mtproto") {
    setDefault(sectionId, "mtproto_secret", generateMtprotoSecret());
    setDefault(sectionId, "mtproto_domain_fronting_port", "443");
    setDefault(sectionId, "mtproto_prefer_ip", "prefer-ipv4");
    setDefault(sectionId, "mtproto_tolerate_time_skewness", "3s");
    setDefault(sectionId, "mtproto_idle_timeout", "5m");
    setDefault(sectionId, "mtproto_handshake_timeout", "10s");
  }
}

function parseLegacyServerUser(sectionId, protocol) {
  const entry = asList(uci.get(UCI_PACKAGE, sectionId, "server_users"))[0];
  if (!entry) {
    return null;
  }

  const parts = `${entry}`.split("|");
  return {
    name: parts.length > 1 ? parts[0].trim() : "client",
    credential: (parts.length > 1 ? parts[1] : parts[0] || "").trim(),
    extra: (parts[2] || "").trim(),
    protocol,
  };
}

function getServerIdentity(sectionId) {
  const protocol = getProtocol(sectionId);
  const legacy = parseLegacyServerUser(sectionId, protocol);
  const name = getServerName(sectionId);
  const uuid =
    uci.get(UCI_PACKAGE, sectionId, "server_uuid") || legacy?.credential || "";
  const password =
    uci.get(UCI_PACKAGE, sectionId, "server_password") ||
    (PASSWORD_PROTOCOLS.includes(protocol) ? legacy?.credential : "") ||
    "";
  const mtprotoSecret =
    uci.get(UCI_PACKAGE, sectionId, "mtproto_secret") ||
    (protocol === "mtproto" ? legacy?.credential : "") ||
    "";

  return {
    name,
    username: getSocksUsername(sectionId),
    uuid,
    password,
    mtprotoSecret,
    flow: normalizeVlessFlow(
      uci.get(UCI_PACKAGE, sectionId, "vless_flow") ||
        (protocol === "vless" ? legacy?.extra : "") ||
        "",
    ),
  };
}

function encodeQuery(params) {
  return Object.entries(params)
    .filter(([, value]) => value != null && value !== "")
    .map(
      ([key, value]) =>
        `${encodeURIComponent(key)}=${encodeURIComponent(`${value}`)}`,
    )
    .join("&");
}

function getPublicHost(sectionId) {
  return (
    uci.get(UCI_PACKAGE, sectionId, "public_host") ||
    window.location.hostname ||
    ""
  );
}

function getTransportParams(sectionId, params) {
  const transport = uci.get(UCI_PACKAGE, sectionId, "transport") || "tcp";
  params.type = transport === "raw" ? "tcp" : transport;

  if (transport === "ws" || transport === "httpupgrade") {
    params.path = uci.get(UCI_PACKAGE, sectionId, "transport_path") || "";
    params.host = uci.get(UCI_PACKAGE, sectionId, "transport_host") || "";
  } else if (transport === "xhttp") {
    params.path = uci.get(UCI_PACKAGE, sectionId, "transport_path") || "/";
    params.host = uci.get(UCI_PACKAGE, sectionId, "transport_host") || "";
    params.mode =
      uci.get(UCI_PACKAGE, sectionId, "transport_xhttp_mode") || "auto";
  } else if (transport === "grpc") {
    params.serviceName =
      uci.get(UCI_PACKAGE, sectionId, "transport_service_name") || "";
  } else if (transport === "http") {
    params.path = uci.get(UCI_PACKAGE, sectionId, "transport_path") || "";
    params.host = asList(
      uci.get(UCI_PACKAGE, sectionId, "transport_hosts"),
    ).join(",");
  }

  return transport;
}

function buildVlessTrojanLink(sectionId, identity) {
  const protocol = getProtocol(sectionId);
  const host = getPublicHost(sectionId);
  const port = uci.get(UCI_PACKAGE, sectionId, "listen_port") || "";
  const security = getEffectiveSecurity(sectionId);
  const tlsServerName =
    uci.get(UCI_PACKAGE, sectionId, "tls_server_name") ||
    uci.get(UCI_PACKAGE, sectionId, "reality_handshake_server") ||
    "";
  const params = { security };
  const credential = protocol === "vless" ? identity.uuid : identity.password;

  getTransportParams(sectionId, params);

  if (protocol === "vless") {
    params.encryption = "none";
  }

  if (security === "tls" || security === "reality") {
    params.sni = tlsServerName;
    params.alpn = asList(uci.get(UCI_PACKAGE, sectionId, "tls_alpn")).join(",");
  }

  if (security === "reality") {
    params.pbk = uci.get(UCI_PACKAGE, sectionId, "reality_public_key") || "";
    params.sid = getFirstListValue(sectionId, "reality_short_id");
    params.fp =
      uci.get(UCI_PACKAGE, sectionId, "client_fingerprint") || "chrome";
  }

  if (protocol === "vless" && identity.flow) {
    params.flow = identity.flow;
  }

  const query = encodeQuery(params);
  return `${protocol}://${encodeURIComponent(credential)}@${host}:${port}${query ? `?${query}` : ""}#${encodeURIComponent(identity.name || sectionId)}`;
}

function buildVmessLink(sectionId, identity) {
  const host = getPublicHost(sectionId);
  const port = uci.get(UCI_PACKAGE, sectionId, "listen_port") || "";
  const security = getEffectiveSecurity(sectionId);
  const transportParams = {};
  const transport = getTransportParams(sectionId, transportParams);
  if (
    security === "reality" &&
    (!uci.get(UCI_PACKAGE, sectionId, "reality_public_key") ||
      !getFirstListValue(sectionId, "reality_short_id"))
  ) {
    return "";
  }

  const payload = {
    v: "2",
    ps: identity.name || sectionId,
    add: host,
    port,
    id: identity.uuid,
    aid: uci.get(UCI_PACKAGE, sectionId, "vmess_alter_id") || "0",
    scy: "auto",
    net: transport === "tcp" ? "tcp" : transport,
    type: "none",
    host: transportParams.host || "",
    path: transportParams.path || transportParams.serviceName || "",
    tls: security === "tls" ? "tls" : "",
    sni: uci.get(UCI_PACKAGE, sectionId, "tls_server_name") || "",
    alpn: asList(uci.get(UCI_PACKAGE, sectionId, "tls_alpn")).join(","),
  };

  return `vmess://${base64Encode(JSON.stringify(payload))}`;
}

function buildShadowsocksLink(sectionId, identity) {
  const method =
    uci.get(UCI_PACKAGE, sectionId, "shadowsocks_method") || "aes-128-gcm";
  const host = getPublicHost(sectionId);
  const port = uci.get(UCI_PACKAGE, sectionId, "listen_port") || "";
  const userInfo = base64UrlEncode(`${method}:${identity.password}`);

  return `ss://${userInfo}@${host}:${port}#${encodeURIComponent(identity.name || sectionId)}`;
}

function buildSocksLink(sectionId, identity) {
  const host = getPublicHost(sectionId);
  const port = uci.get(UCI_PACKAGE, sectionId, "listen_port") || "";
  const username = identity.username || identity.name || sectionId;

  return `socks5://${encodeURIComponent(username)}:${encodeURIComponent(identity.password)}@${host}:${port}#${encodeURIComponent(identity.name || sectionId)}`;
}

function buildHysteria2Link(sectionId, identity) {
  const host = getPublicHost(sectionId);
  const port = uci.get(UCI_PACKAGE, sectionId, "listen_port") || "";
  const params = {
    sni: uci.get(UCI_PACKAGE, sectionId, "tls_server_name") || "",
    insecure: "1",
    obfs: uci.get(UCI_PACKAGE, sectionId, "hysteria2_obfs_type") || "",
    "obfs-password":
      uci.get(UCI_PACKAGE, sectionId, "hysteria2_obfs_password") || "",
  };
  const query = encodeQuery(params);

  return `hysteria2://${encodeURIComponent(identity.password)}@${host}:${port}${query ? `?${query}` : ""}#${encodeURIComponent(identity.name || sectionId)}`;
}

function buildMtprotoLink(sectionId, identity) {
  const host = getPublicHost(sectionId);
  const port = uci.get(UCI_PACKAGE, sectionId, "listen_port") || "";
  const query = encodeQuery({
    server: host,
    port,
    secret: identity.mtprotoSecret,
  });

  return `https://t.me/proxy?${query}`;
}

function buildClientLink(sectionId) {
  const protocol = getProtocol(sectionId);
  const identity = getServerIdentity(sectionId);

  if (protocol === "tailscale") {
    return "";
  }

  if (
    ((protocol === "vless" || protocol === "vmess") && !identity.uuid) ||
    (PASSWORD_PROTOCOLS.includes(protocol) && !identity.password) ||
    (protocol === "mtproto" && !identity.mtprotoSecret)
  ) {
    return "";
  }

  if (
    protocol === "vless" &&
    getEffectiveSecurity(sectionId) === "reality" &&
    (!uci.get(UCI_PACKAGE, sectionId, "reality_public_key") ||
      !getFirstListValue(sectionId, "reality_short_id"))
  ) {
    return "";
  }

  switch (protocol) {
    case "shadowsocks":
      return buildShadowsocksLink(sectionId, identity);
    case "socks":
      return buildSocksLink(sectionId, identity);
    case "vmess":
      return buildVmessLink(sectionId, identity);
    case "trojan":
      return buildVlessTrojanLink(sectionId, identity);
    case "hysteria2":
      return buildHysteria2Link(sectionId, identity);
    case "mtproto":
      return buildMtprotoLink(sectionId, identity);
    case "vless":
    default:
      return buildVlessTrojanLink(sectionId, identity);
  }
}

function svgEl(tag, attrs = {}, children = []) {
  const element = document.createElementNS("http://www.w3.org/2000/svg", tag);
  Object.entries(attrs).forEach(([key, value]) => {
    if (value != null) {
      element.setAttribute(key, `${value}`);
    }
  });
  (Array.isArray(children) ? children : [children])
    .filter(Boolean)
    .forEach((child) => element.appendChild(child));
  return element;
}

function iconSvg(name) {
  const attrs = {
    viewBox: "0 0 24 24",
    width: "16",
    height: "16",
    fill: "none",
    stroke: "currentColor",
    "stroke-width": "2",
    "stroke-linecap": "round",
    "stroke-linejoin": "round",
    "aria-hidden": "true",
    focusable: "false",
  };

  if (name === "copy") {
    return svgEl("svg", attrs, [
      svgEl("rect", {
        x: "9",
        y: "9",
        width: "13",
        height: "13",
        rx: "2",
        ry: "2",
      }),
      svgEl("path", {
        d: "M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1",
      }),
    ]);
  }

  if (name === "check") {
    return svgEl("svg", attrs, [
      svgEl("polyline", { points: "20 6 9 17 4 12" }),
    ]);
  }

  if (name === "info") {
    return svgEl("svg", attrs, [
      svgEl("circle", { cx: "12", cy: "12", r: "10" }),
      svgEl("path", { d: "M12 16v-4" }),
      svgEl("path", { d: "M12 8h.01" }),
    ]);
  }

  return svgEl("svg", attrs, [
    svgEl("rect", { x: "3", y: "3", width: "5", height: "5" }),
    svgEl("rect", { x: "16", y: "3", width: "5", height: "5" }),
    svgEl("rect", { x: "3", y: "16", width: "5", height: "5" }),
    svgEl("path", {
      d: "M16 16h1v1h-1zM20 16h1v1h-1zM16 20h1v1h-1zM20 20h1v1h-1zM18 18h1v1h-1z",
    }),
  ]);
}

function copyText(text) {
  const textarea = document.createElement("textarea");
  textarea.value = text;
  textarea.style.position = "fixed";
  textarea.style.top = "0";
  textarea.style.left = "0";
  textarea.style.opacity = "0";
  document.body.appendChild(textarea);
  textarea.select();

  try {
    document.execCommand("copy");
    main.showToast(_("Successfully copied!"), "success");
  } catch (error) {
    main.showToast(_("Failed to copy!"), "error");
    console.warn("Failed to copy server client link", error);
  }

  document.body.removeChild(textarea);
}

function renderInfoClientLink(sectionId) {
  const link = buildClientLink(sectionId);

  if (!link) {
    return E("em", {}, _("Client link is not available yet"));
  }

  const qr = qrSvgDataUri(link);
  const protocol = getProtocol(sectionId);
  const security = getEffectiveSecurity(sectionId);
  const host = getPublicHost(sectionId);
  const port = uci.get(UCI_PACKAGE, sectionId, "listen_port") || "";
  const name = getServerName(sectionId);

  const securitySuffix =
    security && security !== "none" ? ` + ${getSecurityLabel(security)}` : "";
  const protocolText = `${getProtocolLabel(protocol)}${securitySuffix}`;

  return E("div", { class: "pdk-server-info-modal__container" }, [
    // Left column: QR code
    E("div", { class: "pdk-server-info-modal__qr-col" }, [
      qr
        ? E("img", {
            class: "pdk-server-info-modal__qr-image",
            src: qr,
            alt: _("Client link QR code"),
          })
        : E("em", {}, _("QR code is too large")),
    ]),

    // Right column: Details and Copy Box
    E("div", { class: "pdk-server-info-modal__details-col" }, [
      E("div", { class: "pdk-server-info-modal__details-grid" }, [
        E("div", { class: "pdk-server-info-modal__detail-item" }, [
          E(
            "span",
            { class: "pdk-server-info-modal__detail-label" },
            _("Server name"),
          ),
          E(
            "span",
            {
              class:
                "pdk-server-info-modal__detail-value pdk-server-info-modal__detail-value--title",
            },
            name,
          ),
        ]),
        E("div", { class: "pdk-server-info-modal__detail-item" }, [
          E(
            "span",
            { class: "pdk-server-info-modal__detail-label" },
            _("Type"),
          ),
          E(
            "span",
            {
              class:
                "pdk-server-info-modal__detail-value pdk-server-info-modal__badge",
            },
            protocolText,
          ),
        ]),
        E("div", { class: "pdk-server-info-modal__detail-item" }, [
          E(
            "span",
            { class: "pdk-server-info-modal__detail-label" },
            _("Address"),
          ),
          E(
            "span",
            {
              class:
                "pdk-server-info-modal__detail-value pdk-server-info-modal__detail-value--mono",
            },
            `${host}:${port}`,
          ),
        ]),
      ]),

      E("div", { class: "pdk-server-info-modal__link-section" }, [
        E(
          "span",
          { class: "pdk-server-info-modal__detail-label" },
          _("Client link"),
        ),
        E(
          "textarea",
          {
            class: "cbi-input-textarea pdk-server-info-modal__link",
            readonly: "readonly",
            rows: 3,
            click: (ev) => ev.currentTarget.select(),
          },
          link,
        ),
        E(
          "button",
          {
            class:
              "btn cbi-button cbi-button-neutral pdk-server-info-modal__copy-btn",
            type: "button",
            click: (ev) => {
              ev.preventDefault();
              copyText(link);
            },
          },
          [iconSvg("copy"), " ", E("span", {}, _("Copy"))],
        ),
      ]),
    ]),
  ]);
}

function showServerInfoModal(sectionId) {
  ui.showModal(
    _("Server information"),
    [
      E("div", { class: "pdk-server-info-modal" }, [
        renderInfoClientLink(sectionId),
      ]),
      E("div", { class: "button-row" }, [
        E(
          "button",
          {
            class: "btn cbi-button cbi-button-neutral",
            type: "button",
            click: () => ui.hideModal(),
          },
          _("Close"),
        ),
      ]),
    ],
    "cbi-modal",
  );
}

function getServerEditButtonText() {
  const label = _("Edit rule action");

  return label === "Edit rule action" ? "Edit" : label;
}

function renderServerRowActions(sectionRef, sectionId) {
  const editLabel = getServerEditButtonText();
  const deleteLabel = _("Delete");
  const infoLabel = _("Information");
  const tdEl = E(
    "td",
    { class: "td cbi-section-table-cell nowrap cbi-section-actions" },
    E("div"),
  );
  const actionsEl = tdEl.lastElementChild;
  const actionButtons = [];

  if (getProtocol(sectionId) !== "tailscale") {
    actionButtons.push(
      E(
        "button",
        {
          title: infoLabel,
          "aria-label": infoLabel,
          class: "cbi-button center pdk-server-icon-button",
          style: "display:inline-block;",
          click: (ev) => {
            ev.preventDefault();
            ev.stopPropagation();
            showServerInfoModal(sectionId);
          },
        },
        E("span", { class: "pdk-server-icon-button__glyph" }, "\u24D8"),
      ),
    );
  }

  dom.append(actionsEl, [
    ...actionButtons,
    E(
      "button",
      {
        title: editLabel,
        class: "btn cbi-button cbi-button-edit",
        click: ui.createHandlerFn(
          sectionRef,
          "renderMoreOptionsModal",
          sectionId,
        ),
      },
      editLabel,
    ),
  ]);

  if (sectionRef.addremove) {
    dom.append(
      actionsEl,
      E(
        "button",
        {
          title: deleteLabel,
          class: "btn cbi-button cbi-button-remove",
          click: ui.createHandlerFn(sectionRef, "handleRemove", sectionId),
          disabled: sectionRef.map.readonly || null,
        },
        deleteLabel,
      ),
    );
  }

  return tdEl;
}

function validatePort(_sectionId, value) {
  const port = parseInt(value, 10);
  if (!/^[0-9]+$/.test(value) || port < 1 || port > 65535) {
    return _("Port must be between 1 and 65535");
  }
  return true;
}

function isEmptyValue(value) {
  return (
    value == null ||
    value === "" ||
    (Array.isArray(value) &&
      value.filter((item) => item != null && item !== "").length === 0)
  );
}

function validateRequired(_sectionId, value) {
  return isEmptyValue(value) ? _("This field is required") : true;
}

function validateRequiredText(_sectionId, value) {
  if (isEmptyValue(value)) {
    return _("This field is required");
  }

  return /[\u0000-\u001F\u007F]/.test(`${value}`)
    ? _("Value must not contain control characters")
    : true;
}

function isRoutingSectionAction(action) {
  return ROUTING_SECTION_ACTIONS.indexOf(`${action || ""}`) !== -1;
}

function loadRoutingSectionChoices(option) {
  const sections = option.map?.data?.state?.values?.[UCI_PACKAGE] ?? {};

  option.keylist = [];
  option.vallist = [];

  for (const sectionName in sections) {
    const section = sections[sectionName];

    if (
      section[".type"] === "section" &&
      section.enabled !== "0" &&
      isRoutingSectionAction(section.action)
    ) {
      option.keylist.push(sectionName);
      option.vallist.push(section.label || sectionName);
    }
  }

  return Promise.resolve();
}

function validateHost(_sectionId, value) {
  return isHost(value) ? true : _("Use a domain name or IPv4 address");
}

function validateOptionalHost(_sectionId, value) {
  return isEmptyValue(value) || isHost(value)
    ? true
    : _("Use a domain name or IPv4 address");
}

function validateListenAddress(_sectionId, value) {
  const address = normalizeHost(value);
  return address === "0.0.0.0" || isIpv4(address)
    ? true
    : _("Use an IPv4 listen address");
}

function validateOptionalIpv4(_sectionId, value) {
  return isEmptyValue(value) || isIpv4(normalizeHost(value))
    ? true
    : _("Use an IPv4 address");
}

function validateFilePath(_sectionId, value) {
  const path = `${value || ""}`;

  if (isEmptyValue(path)) {
    return _("This field is required");
  }

  const validation = main.validatePath(path);
  return validation.valid && path !== "/" && !path.endsWith("/")
    ? true
    : _("Specify a file path");
}

function validateTlsCertificatePath(sectionId, value) {
  const result = validateFilePath(sectionId, value);
  if (result !== true) {
    return result;
  }

  return `${value}` ===
    `${uci.get(UCI_PACKAGE, sectionId, "tls_key_path") || ""}`
    ? _("Specify different files")
    : true;
}

function validateTlsKeyPath(sectionId, value) {
  const result = validateFilePath(sectionId, value);
  if (result !== true) {
    return result;
  }

  return `${value}` ===
    `${uci.get(UCI_PACKAGE, sectionId, "tls_certificate_path") || ""}`
    ? _("Specify different files")
    : true;
}

function validateHttpUrl(_sectionId, value) {
  try {
    const url = new URL(`${value || ""}`);
    return (url.protocol === "http:" || url.protocol === "https:") &&
      isHost(url.hostname)
      ? true
      : _("Use an HTTP or HTTPS URL");
  } catch (_err) {
    return _("Use an HTTP or HTTPS URL");
  }
}

function validateDurationValue(value) {
  return /^([0-9]+(ns|us|ms|s|m|h))+$/.test(`${value || ""}`);
}

function validateRequiredDuration(_sectionId, value) {
  return validateDurationValue(value)
    ? true
    : _("Use a duration like 30s, 5m, or 1h30m");
}

function validateOptionalNonNegativeInteger(_sectionId, value) {
  return isEmptyValue(value) || /^[0-9]+$/.test(`${value}`)
    ? true
    : _("Use a non-negative integer");
}

function validateTransportPath(_sectionId, value) {
  return isEmptyValue(value) || `${value}`.startsWith("/")
    ? true
    : _("Transport path must start with /");
}

function validateOptionalHostList(_sectionId, value) {
  const values = Array.isArray(value) ? value : [value];
  const invalid = values
    .filter((item) => item != null && item !== "")
    .some((item) => !isHost(item));

  return invalid ? _("Use a domain name or IPv4 address") : true;
}

function validateGrpcServiceName(_sectionId, value) {
  return isEmptyValue(value) || /^[A-Za-z0-9_.-]+$/.test(`${value}`)
    ? true
    : _("Use letters, digits, dots, underscores, or hyphens");
}

function isIpv6Literal(value) {
  const normalized = `${value || ""}`.trim();
  return /^[0-9A-Fa-f:.]+$/.test(normalized) && normalized.includes(":");
}

function normalizeCidrOrIp(value) {
  const normalized = `${value || ""}`.trim();
  if (!normalized.includes("/") && isIpv4(normalized)) {
    return `${normalized}/32`;
  }
  if (!normalized.includes("/") && isIpv6Literal(normalized)) {
    return `${normalized}/128`;
  }
  return normalized;
}

function validateOptionalCidr(value) {
  if (isEmptyValue(value)) {
    return true;
  }

  const values = Array.isArray(value) ? value : [value];
  const invalid = values
    .filter((item) => item != null && item !== "")
    .some((item) => {
      const [address, prefix, extra] = `${item}`.split("/");
      if (extra != null || prefix == null || !/^[0-9]+$/.test(prefix)) {
        return true;
      }
      const prefixNumber = parseInt(prefix, 10);
      if (isIpv4(address)) {
        return prefixNumber < 0 || prefixNumber > 32;
      }
      if (isIpv6Literal(address)) {
        return prefixNumber < 0 || prefixNumber > 128;
      }
      return true;
    });

  return invalid ? _("Use CIDR prefixes like 192.168.1.0/24") : true;
}

function validateOptionalCidrOrIp(value) {
  if (isEmptyValue(value)) {
    return true;
  }
  const values = Array.isArray(value) ? value : [value];
  const invalid = values
    .filter((item) => item != null && item !== "")
    .some((item) => validateOptionalCidr(normalizeCidrOrIp(item)) !== true);

  return invalid
    ? _("Use CIDR prefixes or IP addresses like 192.168.1.0/24 or 192.168.1.10")
    : true;
}

function validateShortId(_sectionId, value) {
  if (isEmptyValue(value)) {
    return _("This field is required");
  }

  const values = Array.isArray(value) ? value : [value];
  const invalid = values
    .filter((item) => item != null && item !== "")
    .some((item) => !/^[0-9a-fA-F]{1,8}$/.test(`${item}`));

  if (invalid) {
    return _("Reality short ID must contain 1-8 hex digits");
  }
  return true;
}

function validateSecurity(sectionId, value) {
  const protocol = getProtocol(sectionId);
  const selectedSecurity = value || getDefaultSecurity(protocol);
  const supportedSecurity = SECURITY_BY_PROTOCOL[protocol] || ["none"];

  return supportedSecurity.includes(selectedSecurity)
    ? true
    : _("Unsupported security mode for this protocol");
}

function getWidget(sectionId, option) {
  return document.getElementById(
    `widget.cbid.${UCI_PACKAGE}.${sectionId}.${option}`,
  );
}

function getControlWidget(sectionId, option) {
  const widget = getWidget(sectionId, option);

  if (!widget) {
    return null;
  }

  if (/^(INPUT|SELECT|TEXTAREA)$/.test(widget.tagName)) {
    return widget;
  }

  return typeof widget.querySelector === "function"
    ? widget.querySelector("input:not([type='hidden']), select, textarea")
    : null;
}

function getSelectWidget(sectionId, option) {
  const widget = getControlWidget(sectionId, option);

  return widget && widget.tagName === "SELECT" ? widget : null;
}

function setWidgetValue(sectionId, option, value) {
  const widget = getControlWidget(sectionId, option);

  if (!widget) {
    uci.set(UCI_PACKAGE, sectionId, option, value);
    return;
  }

  widget.value = value;
  uci.set(UCI_PACKAGE, sectionId, option, value);
  widget.dispatchEvent(new Event("input", { bubbles: true }));
  widget.dispatchEvent(new Event("change", { bubbles: true }));
}

function renderSecurityChoices(select, protocol, selectedSecurity) {
  select.replaceChildren(
    ...(SECURITY_BY_PROTOCOL[protocol] || ["none"]).map((security) =>
      E(
        "option",
        {
          value: security,
          selected: security === selectedSecurity ? "" : null,
        },
        getSecurityLabel(security),
      ),
    ),
  );
}

function syncSecurityChoices(sectionId) {
  const protocol = getProtocol(sectionId);
  const select = getSelectWidget(sectionId, "security");
  const selectedSecurity =
    uci.get(UCI_PACKAGE, sectionId, "security") || getDefaultSecurity(protocol);
  const nextSecurity =
    validateSecurity(sectionId, selectedSecurity) === true
      ? selectedSecurity
      : getDefaultSecurity(protocol);

  if (select) {
    renderSecurityChoices(select, protocol, nextSecurity);
    if (
      Array.from(select.options).some((option) => option.value === nextSecurity)
    ) {
      select.value = nextSecurity;
    }
  }

  if (selectedSecurity !== nextSecurity) {
    uci.set(UCI_PACKAGE, sectionId, "security", nextSecurity);
  }

  if (select) {
    select.dispatchEvent(new Event("input", { bubbles: true }));
    select.dispatchEvent(new Event("change", { bubbles: true }));
  }
}

function getModalNode() {
  return document.querySelector(
    "body.modal-overlay-active > #modal_overlay > .modal.cbi-modal",
  );
}

function clearServerValidationMessage() {
  const modal = getModalNode();

  if (modal) {
    modal
      .querySelectorAll(".pdk-server-validation-summary")
      .forEach((node) => node.remove());
  }
}

function showServerValidationMessage(error) {
  const modal = getModalNode();

  if (!modal) {
    return;
  }

  clearServerValidationMessage();

  const message = error?.message || "";
  const summary = E(
    "div",
    {
      class: "alert-message warning pdk-server-validation-summary",
    },
    [
      E("strong", {}, _("Cannot save server")),
      E("div", {}, _("Fix the highlighted fields and save again.")),
      message ? E("small", {}, message) : "",
    ],
  );
  const buttonRow = modal.querySelector(".button-row");
  modal.insertBefore(summary, buttonRow || modal.firstChild);

  const invalidInput = modal.querySelector(".cbi-input-invalid");
  if (invalidInput) {
    invalidInput.scrollIntoView({ block: "center", behavior: "smooth" });
    invalidInput.focus({ preventScroll: true });
  }
}

function hasRealityKeypair(sectionId) {
  return (
    !!uci.get(UCI_PACKAGE, sectionId, "reality_private_key") &&
    !!uci.get(UCI_PACKAGE, sectionId, "reality_public_key")
  );
}

function generateRealityKeypair(sectionId) {
  return fs
    .exec("/usr/bin/podkop-plus", ["generate_reality_keypair"])
    .then((response) => {
      if ((response.code ?? 0) !== 0 || !response.stdout) {
        throw new Error(response.stderr || response.stdout || "");
      }

      const data = JSON.parse(response.stdout);
      if (!data.success || !data.private_key || !data.public_key) {
        throw new Error(data.message || "");
      }

      setWidgetValue(sectionId, "reality_private_key", data.private_key);
      setWidgetValue(sectionId, "reality_public_key", data.public_key);
    })
    .catch((error) => {
      console.warn(
        error?.message || "Failed to generate Reality key pair",
        error,
      );
    });
}

function generateRealityKeypairIfMissing(sectionId) {
  return hasRealityKeypair(sectionId)
    ? Promise.resolve()
    : generateRealityKeypair(sectionId);
}

function shouldGenerateRealityKeypair(sectionId) {
  return (
    getProtocol(sectionId) === "vless" &&
    getEffectiveSecurity(sectionId) === "reality"
  );
}

function prepareServerModal(sectionId) {
  return shouldGenerateRealityKeypair(sectionId)
    ? generateRealityKeypairIfMissing(sectionId)
    : Promise.resolve();
}

function addStreamDepends(option) {
  STREAM_PROTOCOLS.forEach((protocol) => option.depends("protocol", protocol));
}

function addPortProtocolDepends(option, singBoxExtended) {
  PORT_PROTOCOLS.forEach((protocol) => option.depends("protocol", protocol));
  if (singBoxExtended) {
    EXTENDED_PORT_PROTOCOLS.forEach((protocol) =>
      option.depends("protocol", protocol),
    );
  }
}

function addTlsDepends(option) {
  option.depends({ protocol: "vless", security: "tls" });
  option.depends({ protocol: "vmess", security: "tls" });
  option.depends({ protocol: "trojan", security: "tls" });
  option.depends("protocol", "hysteria2");
}

function addRealityDepends(option) {
  option.depends({ protocol: "vless", security: "reality" });
}

function addTailscaleDepends(option) {
  option.depends("protocol", "tailscale");
}

function addMtprotoDepends(option) {
  option.depends("protocol", "mtproto");
}

function configureServerSection(sectionRef) {
  sectionRef.sortable = false;
  sectionRef.nodescriptions = true;

  sectionRef.renderMoreOptionsModal = function (sectionId, ev) {
    this.serverEditSnapshots ??= {};
    this.serverEditSnapshots[sectionId] = captureServerEditState(sectionId);

    return prepareServerModal(sectionId).then(() =>
      form.GridSection.prototype.renderMoreOptionsModal.call(
        this,
        sectionId,
        ev,
      ),
    );
  };

  sectionRef.handleAdd = function (_ev, name) {
    const configName = this.uciconfig ?? this.map.config;
    const sectionId = this.map.data.add(configName, this.sectiontype, name);
    const mapNode = this.getPreviousModalMap();
    const prevMap = mapNode ? dom.findClassInstance(mapNode) : this.map;

    prevMap.addedSection = sectionId;
    ensureProtocolDefaults(sectionId, "vless", true);

    loadDefaultPublicHost()
      .then((host) => applyDefaultPublicHost(sectionId, host))
      .catch(() => null);

    return this.renderMoreOptionsModal(sectionId);
  };

  sectionRef.handleModalCancel = function (modalMap, ev, isSaving) {
    const sectionId = modalMap?.section;
    const snapshot = sectionId ? this.serverEditSnapshots?.[sectionId] : null;

    if (sectionId && this.serverEditSnapshots) {
      delete this.serverEditSnapshots[sectionId];
    }

    if (!isSaving) {
      restoreServerEditState(snapshot);
    }

    return form.GridSection.prototype.handleModalCancel.call(
      this,
      modalMap,
      ev,
      isSaving,
    );
  };

  sectionRef.handleModalSave = function (modalMap, ev) {
    clearServerValidationMessage();

    const mapNode = this.getActiveModalMap();
    const activeMap = dom.findClassInstance(mapNode);

    return activeMap
      .parse()
      .then(() =>
        form.GridSection.prototype.handleModalSave.call(this, modalMap, ev),
      )
      .catch((error) => showServerValidationMessage(error));
  };

  sectionRef.renderRowActions = function (sectionId) {
    return renderServerRowActions(this, sectionId);
  };
}

function createServerContent(section, options = {}) {
  injectServerStyles();
  const singBoxExtended = Boolean(options && options.singBoxExtended);

  let o = section.option(form.Flag, "enabled", _("Enable"));
  o.default = "1";
  o.rmempty = false;
  o.editable = true;
  o.width = "6rem";

  o = section.option(form.DummyValue, "_protocol_display", _("Protocol"));
  o.rawhtml = true;
  o.modalonly = false;
  o.cfgvalue = function (sectionId) {
    return getProtocolLabel(getProtocol(sectionId));
  };
  o.textvalue = function (sectionId) {
    return getProtocolLabel(getProtocol(sectionId));
  };
  o.width = "7rem";

  o = section.option(form.Value, "label", _("Server name"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequiredText;
  o.onchange = function (_ev, sectionId, value) {
    const previousLabel = getServerName(sectionId);
    const currentUsername =
      uci.get(UCI_PACKAGE, sectionId, "server_username") || "";

    uci.set(UCI_PACKAGE, sectionId, "label", value);

    if (
      getProtocol(sectionId) === "socks" &&
      (!currentUsername ||
        currentUsername === previousLabel ||
        currentUsername === sectionId)
    ) {
      const nextUsername = value || sectionId;
      uci.set(UCI_PACKAGE, sectionId, "server_username", nextUsername);
      setWidgetValue(sectionId, "server_username", nextUsername);
    }
  };

  o = section.option(form.ListValue, "protocol", _("Protocol"));
  Object.entries(getAvailableProtocolLabels(singBoxExtended)).forEach(
    ([value, label]) => {
      o.value(value, label);
    },
  );
  o.default = "vless";
  o.rmempty = false;
  o.modalonly = true;
  o.validate = validateRequired;
  o.onchange = function (_ev, sectionId, value) {
    ensureProtocolDefaults(sectionId, value, true);
    syncSecurityChoices(sectionId);
    if (value === "vless" && getEffectiveSecurity(sectionId) === "reality") {
      generateRealityKeypairIfMissing(sectionId);
    }
  };

  o = section.option(form.Value, "listen", _("Listen address"));
  o.default = "0.0.0.0";
  o.rmempty = false;
  o.modalonly = true;
  o.validate = validateListenAddress;
  addPortProtocolDepends(o, singBoxExtended);

  o = section.option(form.Value, "listen_port", _("Listen port"));
  o.default = "443";
  o.rmempty = false;
  o.modalonly = true;
  o.validate = validatePort;
  addPortProtocolDepends(o, singBoxExtended);

  o = section.option(form.Value, "public_host", _("Public host"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateHost;
  addPortProtocolDepends(o, singBoxExtended);
  o.load = function (sectionId) {
    return loadDefaultPublicHost().then((host) => {
      applyDefaultPublicHost(sectionId, host);
      return uci.get(UCI_PACKAGE, sectionId, "public_host") || host || "";
    });
  };

  o = section.option(form.ListValue, "routing_mode", _("Routing mode"));
  o.value("rules", _("Podkop Plus rules"));
  o.value("direct", _("Direct"));
  o.value("section", _("Selected section"));
  o.default = "rules";
  o.rmempty = false;
  o.modalonly = true;
  o.validate = validateRequired;

  o = section.option(form.ListValue, "routing_section", _("Routing section"));
  o.depends("routing_mode", "section");
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequired;
  o.cfgvalue = function (sectionId) {
    return uci.get(UCI_PACKAGE, sectionId, "routing_section");
  };
  o.load = function () {
    return loadRoutingSectionChoices(this);
  };

  o = section.option(form.ListValue, "security", _("Security"));
  o.value("reality", "Reality");
  o.value("tls", "TLS");
  o.value("none", _("None"));
  o.default = "reality";
  o.rmempty = false;
  o.modalonly = true;
  addStreamDepends(o);
  o.depends("protocol", "hysteria2");
  o.validate = validateSecurity;
  o.onchange = function (_ev, sectionId, value) {
    if (value === "reality") {
      generateRealityKeypairIfMissing(sectionId);
    }
  };
  {
    const originalRenderWidget = o.renderWidget;
    o.renderWidget = function (sectionId, optionIndex, cfgvalue) {
      const node = originalRenderWidget.call(
        this,
        sectionId,
        optionIndex,
        cfgvalue,
      );
      window.setTimeout(() => syncSecurityChoices(sectionId), 0);
      return node;
    };
  }

  o = section.option(form.Value, "tls_server_name", _("Server name / SNI"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateHost;
  o.load = function (sectionId) {
    const current = normalizeHost(
      uci.get(UCI_PACKAGE, sectionId, "tls_server_name"),
    );
    if (current) {
      return current;
    }

    const fallback = "www.microsoft.com";
    uci.set(UCI_PACKAGE, sectionId, "tls_server_name", fallback);
    return fallback;
  };
  addTlsDepends(o);
  addRealityDepends(o);

  o = section.option(form.MultiValue, "tls_alpn", _("ALPN"));
  o.value("h3", "h3");
  o.value("h2", "h2");
  o.value("http/1.1", "http/1.1");
  o.create = false;
  o.rmempty = true;
  o.modalonly = true;
  addTlsDepends(o);
  addRealityDepends(o);

  o = section.option(form.Value, "tls_certificate_path", _("Certificate path"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateTlsCertificatePath;
  o.load = function (sectionId) {
    const current = uci.get(UCI_PACKAGE, sectionId, "tls_certificate_path");
    if (current) {
      return current;
    }
    const value = defaultTlsCertificatePath(sectionId);
    uci.set(UCI_PACKAGE, sectionId, "tls_certificate_path", value);
    return value;
  };
  addTlsDepends(o);

  o = section.option(form.Value, "tls_key_path", _("Key path"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateTlsKeyPath;
  o.load = function (sectionId) {
    const current = uci.get(UCI_PACKAGE, sectionId, "tls_key_path");
    if (current) {
      return current;
    }
    const value = defaultTlsKeyPath(sectionId);
    uci.set(UCI_PACKAGE, sectionId, "tls_key_path", value);
    return value;
  };
  addTlsDepends(o);

  o = section.option(
    form.Value,
    "reality_handshake_server",
    _("Reality fake site"),
  );
  o.default = "www.microsoft.com";
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateHost;
  addRealityDepends(o);

  o = section.option(
    form.Value,
    "reality_handshake_server_port",
    _("Reality fake site port"),
  );
  o.default = "443";
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validatePort;
  addRealityDepends(o);

  o = section.option(
    form.Value,
    "reality_private_key",
    _("Reality private key"),
  );
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequired;
  addRealityDepends(o);

  o = section.option(form.Value, "reality_public_key", _("Reality public key"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequired;
  addRealityDepends(o);

  o = section.option(form.Value, "reality_short_id", _("Reality short ID"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateShortId;
  o.load = function (sectionId) {
    const current = getFirstListValue(sectionId, "reality_short_id");
    if (current) {
      uci.set(UCI_PACKAGE, sectionId, "reality_short_id", current);
      return current;
    }
    const value = randomHex(4);
    uci.set(UCI_PACKAGE, sectionId, "reality_short_id", value);
    return value;
  };
  addRealityDepends(o);

  o = section.option(
    form.Value,
    "reality_max_time_difference",
    _("Reality max time difference"),
  );
  o.default = "1m";
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequiredDuration;
  addRealityDepends(o);

  o = section.option(
    form.ListValue,
    "client_fingerprint",
    _("Client fingerprint"),
  );
  ["chrome", "firefox", "edge", "safari", "ios", "android", "random"].forEach(
    (value) => o.value(value, value),
  );
  o.default = "chrome";
  o.rmempty = false;
  o.modalonly = true;
  o.validate = validateRequired;
  addRealityDepends(o);

  o = section.option(form.ListValue, "transport", _("Transport"));
  o.value("tcp", "TCP");
  o.value("ws", "WebSocket");
  o.value("grpc", "gRPC");
  o.value("http", "HTTP");
  o.value("httpupgrade", "HTTPUpgrade");
  if (singBoxExtended) {
    o.value("xhttp", "XHTTP");
  }
  o.default = "tcp";
  o.rmempty = false;
  o.modalonly = true;
  addStreamDepends(o);

  o = section.option(form.Value, "transport_path", _("Transport path"));
  o.modalonly = true;
  o.validate = validateTransportPath;
  o.depends({ protocol: "vless", transport: "ws" });
  o.depends({ protocol: "vmess", transport: "ws" });
  o.depends({ protocol: "trojan", transport: "ws" });
  o.depends({ protocol: "vless", transport: "http" });
  o.depends({ protocol: "vmess", transport: "http" });
  o.depends({ protocol: "trojan", transport: "http" });
  o.depends({ protocol: "vless", transport: "httpupgrade" });
  o.depends({ protocol: "vmess", transport: "httpupgrade" });
  o.depends({ protocol: "trojan", transport: "httpupgrade" });
  if (singBoxExtended) {
    o.depends({ protocol: "vless", transport: "xhttp" });
    o.depends({ protocol: "vmess", transport: "xhttp" });
    o.depends({ protocol: "trojan", transport: "xhttp" });
  }

  o = section.option(form.Value, "transport_host", _("Transport host"));
  o.modalonly = true;
  o.validate = validateOptionalHost;
  o.depends({ protocol: "vless", transport: "ws" });
  o.depends({ protocol: "vmess", transport: "ws" });
  o.depends({ protocol: "trojan", transport: "ws" });
  o.depends({ protocol: "vless", transport: "httpupgrade" });
  o.depends({ protocol: "vmess", transport: "httpupgrade" });
  o.depends({ protocol: "trojan", transport: "httpupgrade" });
  if (singBoxExtended) {
    o.depends({ protocol: "vless", transport: "xhttp" });
    o.depends({ protocol: "vmess", transport: "xhttp" });
    o.depends({ protocol: "trojan", transport: "xhttp" });
  }

  if (singBoxExtended) {
    o = section.option(form.ListValue, "transport_xhttp_mode", _("XHTTP mode"));
    o.value("auto", "auto");
    o.value("packet-up", "packet-up");
    o.value("stream-up", "stream-up");
    o.value("stream-one", "stream-one");
    o.default = "auto";
    o.rmempty = false;
    o.modalonly = true;
    o.depends({ protocol: "vless", transport: "xhttp" });
    o.depends({ protocol: "vmess", transport: "xhttp" });
    o.depends({ protocol: "trojan", transport: "xhttp" });
  }

  o = section.option(form.DynamicList, "transport_hosts", _("HTTP hosts"));
  o.modalonly = true;
  o.validate = validateOptionalHostList;
  o.depends({ protocol: "vless", transport: "http" });
  o.depends({ protocol: "vmess", transport: "http" });
  o.depends({ protocol: "trojan", transport: "http" });

  o = section.option(form.Value, "transport_service_name", _("gRPC service"));
  o.modalonly = true;
  o.validate = validateGrpcServiceName;
  o.depends({ protocol: "vless", transport: "grpc" });
  o.depends({ protocol: "vmess", transport: "grpc" });
  o.depends({ protocol: "trojan", transport: "grpc" });

  o = section.option(form.ListValue, "shadowsocks_method", _("Method"));
  o.value("aes-128-gcm", "aes-128-gcm");
  o.value("aes-256-gcm", "aes-256-gcm");
  o.value("chacha20-ietf-poly1305", "chacha20-ietf-poly1305");
  o.default = "aes-128-gcm";
  o.rmempty = false;
  o.modalonly = true;
  o.validate = validateRequired;
  o.depends("protocol", "shadowsocks");

  o = section.option(form.Value, "server_username", _("Username"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequiredText;
  o.load = function (sectionId) {
    const current = uci.get(UCI_PACKAGE, sectionId, "server_username");
    if (current) {
      return current;
    }

    const value = getServerName(sectionId);
    uci.set(UCI_PACKAGE, sectionId, "server_username", value);
    return value;
  };
  o.depends("protocol", "socks");

  o = section.option(form.Value, "server_password", _("Password"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequiredText;
  o.load = function (sectionId) {
    const current = uci.get(UCI_PACKAGE, sectionId, "server_password");
    if (current) {
      return current;
    }

    const value = generatePassword();
    uci.set(UCI_PACKAGE, sectionId, "server_password", value);
    return value;
  };
  o.depends("protocol", "socks");

  o = section.option(form.Value, "vmess_alter_id", _("Alter ID"));
  o.default = "0";
  o.rmempty = false;
  o.modalonly = true;
  o.depends("protocol", "vmess");
  o.validate = function (_sectionId, value) {
    if (value == null || value === "") {
      return _("This field is required");
    }
    return /^[0-9]+$/.test(value) ? true : _("Use a non-negative integer");
  };

  o = section.option(form.ListValue, "vless_flow", _("VLESS flow"));
  o.value("none", _("None"));
  o.value("xtls-rprx-vision", "xtls-rprx-vision");
  o.default = "none";
  o.rmempty = false;
  o.modalonly = true;
  o.validate = validateRequired;
  o.depends("protocol", "vless");

  o = section.option(form.ListValue, "hysteria2_obfs_type", _("Obfuscation"));
  o.value("", _("None"));
  o.value("salamander", "salamander");
  o.default = "";
  o.modalonly = true;
  o.depends("protocol", "hysteria2");
  o.onchange = function (_ev, sectionId, value) {
    if (value === "salamander") {
      setDefault(sectionId, "hysteria2_obfs_password", generatePassword());
      const widget = getControlWidget(sectionId, "hysteria2_obfs_password");
      if (widget && !widget.value) {
        setWidgetValue(
          sectionId,
          "hysteria2_obfs_password",
          uci.get(UCI_PACKAGE, sectionId, "hysteria2_obfs_password"),
        );
      }
    }
  };

  o = section.option(
    form.Value,
    "hysteria2_obfs_password",
    _("Obfuscation password"),
  );
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequired;
  o.load = function (sectionId) {
    const current = uci.get(UCI_PACKAGE, sectionId, "hysteria2_obfs_password");
    if (current) {
      return current;
    }
    const value = generatePassword();
    uci.set(UCI_PACKAGE, sectionId, "hysteria2_obfs_password", value);
    return value;
  };
  o.depends({ protocol: "hysteria2", hysteria2_obfs_type: "salamander" });

  if (singBoxExtended) {
    o = section.option(form.Value, "mtproto_secret", _("MTProto secret"));
    o.modalonly = true;
    o.rmempty = false;
    o.validate = validateRequiredText;
    o.load = function (sectionId) {
      const current = uci.get(UCI_PACKAGE, sectionId, "mtproto_secret");
      if (current) {
        return current;
      }
      const value = generateMtprotoSecret();
      uci.set(UCI_PACKAGE, sectionId, "mtproto_secret", value);
      return value;
    };
    addMtprotoDepends(o);

    o = section.option(
      form.Value,
      "mtproto_concurrency",
      _("MTProto concurrency"),
    );
    o.modalonly = true;
    o.rmempty = true;
    o.validate = validateOptionalNonNegativeInteger;
    addMtprotoDepends(o);

    o = section.option(
      form.Value,
      "mtproto_domain_fronting_port",
      _("MTProto fronting port"),
    );
    o.default = "443";
    o.modalonly = true;
    o.rmempty = false;
    o.validate = validatePort;
    addMtprotoDepends(o);

    o = section.option(
      form.Value,
      "mtproto_domain_fronting_ip",
      _("MTProto fronting IP"),
    );
    o.modalonly = true;
    o.rmempty = true;
    o.validate = validateOptionalIpv4;
    addMtprotoDepends(o);

    o = section.option(
      form.Flag,
      "mtproto_domain_fronting_proxy_protocol",
      _("MTProto fronting proxy protocol"),
    );
    o.default = "0";
    o.modalonly = true;
    o.rmempty = true;
    addMtprotoDepends(o);

    o = section.option(
      form.ListValue,
      "mtproto_prefer_ip",
      _("MTProto preferred IP"),
    );
    o.value("prefer-ipv4", "prefer-ipv4");
    o.value("prefer-ipv6", "prefer-ipv6");
    o.value("only-ipv4", "only-ipv4");
    o.value("only-ipv6", "only-ipv6");
    o.default = "prefer-ipv4";
    o.rmempty = false;
    o.modalonly = true;
    o.validate = validateRequired;
    addMtprotoDepends(o);

    o = section.option(
      form.Flag,
      "mtproto_auto_update",
      _("MTProto auto update"),
    );
    o.default = "0";
    o.modalonly = true;
    o.rmempty = true;
    addMtprotoDepends(o);

    o = section.option(
      form.Flag,
      "mtproto_allow_fallback_on_unknown_dc",
      _("MTProto fallback on unknown DC"),
    );
    o.default = "0";
    o.modalonly = true;
    o.rmempty = true;
    addMtprotoDepends(o);

    o = section.option(
      form.Value,
      "mtproto_tolerate_time_skewness",
      _("MTProto time skew tolerance"),
    );
    o.default = "3s";
    o.modalonly = true;
    o.rmempty = false;
    o.validate = validateRequiredDuration;
    addMtprotoDepends(o);

    o = section.option(
      form.Value,
      "mtproto_idle_timeout",
      _("MTProto idle timeout"),
    );
    o.default = "5m";
    o.modalonly = true;
    o.rmempty = false;
    o.validate = validateRequiredDuration;
    addMtprotoDepends(o);

    o = section.option(
      form.Value,
      "mtproto_handshake_timeout",
      _("MTProto handshake timeout"),
    );
    o.default = "10s";
    o.modalonly = true;
    o.rmempty = false;
    o.validate = validateRequiredDuration;
    addMtprotoDepends(o);
  }

  o = section.option(form.Value, "tailscale_auth_key", _("Tailscale auth key"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequired;
  addTailscaleDepends(o);

  o = section.option(
    form.Value,
    "tailscale_control_url",
    _("Tailscale control URL"),
  );
  o.default = "https://controlplane.tailscale.com";
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateHttpUrl;
  addTailscaleDepends(o);

  o = section.option(form.Value, "tailscale_hostname", _("Tailscale hostname"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateHost;
  o.load = function (sectionId) {
    const current = uci.get(UCI_PACKAGE, sectionId, "tailscale_hostname");
    if (current) {
      return current;
    }
    const value = defaultTailscaleHostname(sectionId);
    uci.set(UCI_PACKAGE, sectionId, "tailscale_hostname", value);
    return value;
  };
  addTailscaleDepends(o);

  o = section.option(
    form.Flag,
    "tailscale_advertise_exit_node",
    _("Advertise exit node"),
  );
  o.default = "1";
  o.modalonly = true;
  o.rmempty = false;
  addTailscaleDepends(o);

  o = section.option(
    form.DynamicList,
    "tailscale_advertise_routes",
    _("Advertise routes"),
  );
  o.modalonly = true;
  o.rmempty = true;
  o.validate = (_sectionId, value) => validateOptionalCidrOrIp(value);
  addTailscaleDepends(o);

  o = section.option(form.Flag, "tailscale_accept_routes", _("Accept routes"));
  o.default = "0";
  o.modalonly = true;
  o.rmempty = true;
  addTailscaleDepends(o);
}

return baseclass.extend({ configureServerSection, createServerContent });
