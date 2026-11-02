// A stand-in for LuCI's form.js, enough to build a view's real options and run a save over them.
// The parse() and depends() rules are copied from /www/luci-static/resources/form.js; keep them in
// step with LuCI:
//
//   AbstractValue.parse   active and empty      -> remove when rmempty/optional
//                         active, value=default -> the same, in LuCI since 2026-05 (not in 24.10
//                                                  or 25.12): createHarness's dropDefaults
//                         active and changed    -> write
//                         hidden                -> remove unless retain
//   FlagValue.parse       active, value=default -> remove when rmempty/optional
//                         active, otherwise     -> write
//                         hidden                -> remove unless retain
//   Map.isDependencySatisfied  the depends() evaluator, verbatim
import { webcrypto } from 'crypto';
import { loadBundle } from './bundle.js';

/* --------------------------------------------------------- class machinery */

// LuCI's baseclass: Class.extend(props) subclasses, this.super(method, args) walks up the chain
// with a per-method stack, so a super inside a super goes one further up.
function makeClass(name, init, parent) {
  function Ctor(...args) {
    const chain = [];
    for (let c = Ctor; c; c = c.__parent__) chain.unshift(c.__init__);
    let level = chain.length - 1;
    const superStacks = {};
    this.super = (method, superArgs) => {
      if (method === '__init__') {
        level -= 1;
        const fn = chain[level];
        const out = fn ? fn.apply(this, superArgs || []) : undefined;
        level += 1;
        return out;
      }
      const stack = (superStacks[method] ??= []);
      let proto = Object.getPrototypeOf(
        stack.length ? stack[0] : Object.getPrototypeOf(this),
      );
      while (
        proto != null &&
        !Object.prototype.hasOwnProperty.call(proto, method)
      ) {
        proto = Object.getPrototypeOf(proto);
      }
      if (proto == null) return null;
      const member = proto[method];
      if (superArgs === undefined) return member;
      if (typeof member !== 'function') {
        throw new ReferenceError(`${method} is not a function in base class`);
      }
      stack.unshift(proto);
      try {
        return member.apply(
          this,
          Array.isArray(superArgs) ? superArgs : [superArgs],
        );
      } finally {
        stack.shift();
      }
    };
    const last = chain[chain.length - 1];
    if (last) last.apply(this, args);
  }
  Ctor.prototype = Object.create(parent ? parent.prototype : Object.prototype);
  Ctor.prototype.constructor = Ctor;
  Ctor.prototype.__name__ = name;
  Ctor.__init__ = init;
  Ctor.__parent__ = parent || null;
  Ctor.extend = function (props) {
    const Sub = makeClass(props.__name__ || name, props.__init__ || init, Ctor);
    Object.assign(Sub.prototype, props);
    Sub.prototype.constructor = Sub;
    return Sub;
  };
  return Ctor;
}

/* ---------------------------------------------------- LuCI value comparison */

function isEqual(x, y) {
  if (typeof y === 'object' && y instanceof RegExp)
    return x == null ? false : y.test(x);
  if (x != null && y != null && typeof x !== typeof y) return false;
  if ((x == null && y != null) || (x != null && y == null)) return false;
  if (Array.isArray(x)) {
    if (x.length !== y.length) return false;
    for (let i = 0; i < x.length; i++) if (!isEqual(x[i], y[i])) return false;
  } else if (typeof x === 'object') {
    for (const k in x) {
      if (
        Object.prototype.hasOwnProperty.call(x, k) &&
        !Object.prototype.hasOwnProperty.call(y, k)
      ) {
        return false;
      }
    }
    for (const k in y) {
      if (Object.prototype.hasOwnProperty.call(y, k) && !isEqual(x[k], y[k]))
        return false;
    }
  } else if (x !== y) {
    return false;
  }
  return true;
}

function isContained(x, y) {
  if (Array.isArray(x)) return x.indexOf(y) !== -1;
  if (typeof x === 'string') return x.split(/\s+/).indexOf(y) !== -1;
  return false;
}

/* ------------------------------------------------------------------ the DOM */

class FakeNode {
  constructor(tag, attrs) {
    this.tag = tag;
    this.attrs = attrs || {};
    this.childNodes = [];
    this.parentNode = null;
    this.textContent = '';
    const classes = new Set();
    this.classList = {
      add: (c) => classes.add(c),
      remove: (c) => classes.delete(c),
      contains: (c) => classes.has(c),
    };
  }
  getAttribute(name) {
    return this.attrs[name] ?? null;
  }
  setAttribute(name, value) {
    this.attrs[name] = value;
  }
  appendChild(node) {
    this.childNodes.push(node);
    if (node instanceof FakeNode) node.parentNode = this;
    return node;
  }
  append(...nodes) {
    nodes.forEach((node) => this.appendChild(node));
  }
  replaceChildren(...nodes) {
    [...this.childNodes].forEach((node) => this.removeChild(node));
    this.append(...nodes);
  }
  removeChild(node) {
    this.childNodes = this.childNodes.filter((child) => child !== node);
    if (node instanceof FakeNode) node.parentNode = null;
  }
  remove() {
    this.parentNode?.removeChild(this);
  }
  insertBefore(node) {
    return this.appendChild(node);
  }
  querySelector() {
    return null;
  }
  querySelectorAll() {
    return [];
  }
  insertAdjacentHTML() {}
  get nextElementSibling() {
    return null;
  }
}

function E(tag, attrs, children) {
  const isAttrs = attrs && typeof attrs === 'object' && !Array.isArray(attrs);
  const node = new FakeNode(
    typeof tag === 'string' ? tag : 'span',
    isAttrs ? attrs : {},
  );
  const kids = Array.isArray(attrs) ? attrs : children;
  if (Array.isArray(kids)) {
    kids.forEach((kid) => {
      if (kid instanceof FakeNode) node.appendChild(kid);
      else if (typeof kid === 'string') node.textContent += kid;
    });
  }
  return node;
}

/* ------------------------------------------------------------------- config */

class JSONConfig {
  constructor(data) {
    this.data = JSON.parse(JSON.stringify(data));
  }
  get(pkg, sid, opt) {
    const section = this.data[sid];
    if (!section) return null;
    if (opt == null) return section;
    return section[opt] === undefined ? null : section[opt];
  }
  set(pkg, sid, opt, val) {
    this.data[sid] ??= {};
    this.data[sid][opt] = val;
  }
  unset(pkg, sid, opt) {
    if (this.data[sid]) delete this.data[sid][opt];
  }
  sections() {
    return Object.entries(this.data).map(([name, section]) => ({
      '.name': name,
      ...section,
    }));
  }
  add(pkg, type, name) {
    this.data[name] = {};
    return name;
  }
  remove() {}
}

/* -------------------------------------------------------------------- forms */

function buildForm(uciData, dropDefaults) {
  const droppedAtDefault = (option, fval) =>
    dropDefaults &&
    fval == option.default &&
    (option.optional || option.rmempty);

  const AbstractValue = makeClass(
    'CBI.AbstractValue',
    function (map, section, option, ...rest) {
      this.map = map;
      this.section = section;
      this.option = option;
      this.title = rest[0];
      this.description = rest[1];
      this.config = map.config;
      this.deps = [];
      this.data = {};
      this.rmempty = true;
      this.default = null;
      this.size = null;
      this.optional = false;
      this.retain = false;
    },
  );

  Object.assign(AbstractValue.prototype, {
    depends(field, value) {
      this.deps.push(typeof field === 'string' ? { [field]: value } : field);
    },
    value(key, title) {
      this.keylist ??= [];
      this.vallist ??= [];
      this.keylist.push(key);
      this.vallist.push(title);
    },
    load(sid) {
      return this.map.data.get(
        this.map.config,
        this.ucisection ?? sid,
        this.ucioption ?? this.option,
      );
    },
    cfgvalue(sid, setValue) {
      if (arguments.length === 2) {
        this.data[sid] = setValue;
        return undefined;
      }
      return this.data[sid];
    },
    widgetValue(sid) {
      const cval = this.cfgvalue(sid);
      return cval != null ? cval : this.default;
    },
    formvalue(sid) {
      const value = this.widgetValue(sid);
      return value == null ? null : value;
    },
    checkDepends(sid) {
      return this.map.isDependencySatisfied(this.deps, this.map.config, sid);
    },
    isActive(sid) {
      return this.checkDepends(sid);
    },
    isValid() {
      return true;
    },
    triggerValidation() {},
    stripTags(value) {
      return `${value ?? ''}`;
    },
    write(sid, value) {
      this.map.data.set(
        this.map.config,
        this.ucisection ?? sid,
        this.ucioption ?? this.option,
        value,
      );
    },
    remove(sid) {
      const opt = this.ucioption ?? this.option;
      for (const sibling of this.section.children) {
        if (sibling === this || sibling.ucioption == null) continue;
        if ((sibling.ucioption ?? sibling.option) !== opt) continue;
        if (!sibling.isActive(sid)) continue;
        return;
      }
      this.map.data.unset(this.map.config, this.ucisection ?? sid, opt);
    },
    parse(sid) {
      if (this.isActive(sid)) {
        const cval = this.cfgvalue(sid);
        const fval = this.formvalue(sid);
        if (fval == null || fval === '' || droppedAtDefault(this, fval)) {
          if (this.rmempty || this.optional)
            return Promise.resolve(this.remove(sid));
          return Promise.reject(
            new TypeError(`Option "${this.option}" must not be empty.`),
          );
        }
        if (this.forcewrite || !isEqual(cval, fval)) {
          return Promise.resolve(this.write(sid, fval));
        }
        return Promise.resolve();
      }
      if (!this.retain) return Promise.resolve(this.remove(sid));
      return Promise.resolve();
    },
  });

  const Value = AbstractValue.extend({ __name__: 'CBI.Value' });
  // A <select> hands back only its own options: a stored value not among them leaves nothing
  // selected, and the browser falls back to the first option, which the save then writes.
  const ListValue = Value.extend({
    __name__: 'CBI.ListValue',
    formvalue(sid) {
      const value = this.widgetValue(sid);
      const keys = (this.keylist || []).map((key) => `${key ?? ''}`);
      if (!keys.length) return value == null ? null : value;
      if (keys.includes(`${value ?? ''}`)) return `${value ?? ''}`;
      return this.optional || keys.includes('') ? '' : keys[0];
    },
  });
  const DynamicList = Value.extend({
    __name__: 'CBI.DynamicList',
    formvalue(sid) {
      const value = this.widgetValue(sid);
      if (value == null) return [];
      return (Array.isArray(value) ? value : [value]).filter(
        (item) => `${item ?? ''}` !== '',
      );
    },
    parse(sid) {
      if (this.isActive(sid)) {
        const cval = this.cfgvalue(sid);
        const fval = this.formvalue(sid);
        if (fval == null || fval.length === 0 || droppedAtDefault(this, fval)) {
          if (this.rmempty || this.optional)
            return Promise.resolve(this.remove(sid));
          return Promise.reject(
            new TypeError(`Option "${this.option}" must not be empty.`),
          );
        }
        if (this.forcewrite || !isEqual(cval, fval)) {
          return Promise.resolve(this.write(sid, fval));
        }
        return Promise.resolve();
      }
      if (!this.retain) return Promise.resolve(this.remove(sid));
      return Promise.resolve();
    },
  });
  const MultiValue = DynamicList.extend({ __name__: 'CBI.MultiValue' });
  const TextValue = Value.extend({ __name__: 'CBI.TextValue' });
  const DummyValue = Value.extend({ __name__: 'CBI.DummyValue' });
  const ButtonValue = Value.extend({
    __name__: 'CBI.ButtonValue',
    parse() {
      return Promise.resolve();
    },
  });
  const FlagValue = Value.extend({
    __name__: 'CBI.FlagValue',
    __init__(...args) {
      this.super('__init__', args);
      this.enabled = '1';
      this.disabled = '0';
      this.default = this.disabled;
    },
    formvalue(sid) {
      return `${this.widgetValue(sid) ?? ''}` === this.enabled
        ? this.enabled
        : this.disabled;
    },
    parse(sid) {
      if (this.isActive(sid)) {
        const fval = this.formvalue(sid);
        if (fval == this.default && (this.optional || this.rmempty)) {
          return Promise.resolve(this.remove(sid));
        }
        return Promise.resolve(this.write(sid, fval));
      }
      if (!this.retain) return Promise.resolve(this.remove(sid));
      return Promise.resolve();
    },
  });

  const AbstractSection = makeClass(
    'CBI.AbstractSection',
    function (map, sectionType, ...rest) {
      this.map = map;
      this.config = map.config;
      this.sectiontype = sectionType;
      this.title = rest[0];
      this.description = rest[1];
      this.children = [];
      this.tabs = [];
    },
  );
  Object.assign(AbstractSection.prototype, {
    cfgsections() {
      return [this.section ?? 'settings'];
    },
    option(Cls, name, ...rest) {
      const option = new Cls(this.map, this, name, ...rest);
      this.children.push(option);
      return option;
    },
    tab(name, title) {
      this.tabs.push({ name, title, children: [] });
      this.tabs[name] = this.tabs[this.tabs.length - 1];
    },
    taboption(tabName, Cls, name, ...rest) {
      const option = this.option(Cls, name, ...rest);
      option.tab = tabName;
      return option;
    },
    load() {
      const tasks = [];
      for (const sid of this.cfgsections()) {
        for (const child of this.children) {
          tasks.push(
            Promise.resolve(child.load(sid)).then((value) =>
              child.cfgvalue(sid, value),
            ),
          );
        }
      }
      return Promise.all(tasks);
    },
    parse() {
      const tasks = [];
      for (const sid of this.cfgsections()) {
        for (const child of this.children) tasks.push(child.parse(sid));
      }
      return Promise.all(tasks);
    },
  });
  const NamedSection = AbstractSection.extend({
    __name__: 'CBI.NamedSection',
    __init__(map, section, ...rest) {
      this.super('__init__', [map, section, ...rest]);
      this.section = section;
    },
    cfgsections() {
      return [this.section];
    },
  });
  const TypedSection = AbstractSection.extend({ __name__: 'CBI.TypedSection' });
  const TableSection = TypedSection.extend({ __name__: 'CBI.TableSection' });
  const GridSection = TableSection.extend({ __name__: 'CBI.GridSection' });

  const CBIMap = makeClass('CBI.Map', function (config, ...rest) {
    this.config = config;
    this.data = uciData;
    this.title = rest[0];
    this.description = rest[1];
    this.children = [];
  });
  Object.assign(CBIMap.prototype, {
    section(Cls, ...args) {
      const section = new Cls(this, ...args);
      this.children.push(section);
      CBIMap.declaredSectionTypes.push(section.sectiontype);
      return section;
    },
    lookupOption(name, sid) {
      for (const section of this.children) {
        for (const option of section.children) {
          if (option.option === name) return [option, sid];
        }
      }
      return null;
    },
    isDependencySatisfied(depends, configName, sectionId) {
      let def = false;
      if (!Array.isArray(depends) || !depends.length) return true;
      for (let i = 0; i < depends.length; i++) {
        let istat = true;
        const reverse = depends[i]['!reverse'];
        const contains = depends[i]['!contains'];
        for (const dep in depends[i]) {
          if (dep === '!reverse' || dep === '!contains') continue;
          if (dep === '!default') {
            def = true;
            istat = false;
          } else {
            const res = this.lookupOption(dep, sectionId, configName);
            const val =
              res && res[0].isActive(res[1]) ? res[0].formvalue(res[1]) : null;
            const equal = contains
              ? isContained(val, depends[i][dep])
              : isEqual(val, depends[i][dep]);
            istat = istat && equal;
          }
        }
        if (istat ^ reverse) return true;
      }
      return def;
    },
    checkDepends() {},
    findElement() {
      return null;
    },
    load() {
      return Promise.all(this.children.map((section) => section.load()));
    },
    render() {
      return this.load().then(() => new FakeNode('div'));
    },
    parse() {
      return Promise.all(this.children.map((section) => section.parse()));
    },
  });
  CBIMap.declaredSectionTypes = [];

  const JSONMap = CBIMap.extend({
    __name__: 'CBI.JSONMap',
    __init__(data, ...rest) {
      this.super('__init__', ['json', ...rest]);
      this.config = 'json';
      this.data = new JSONConfig(data);
    },
  });

  return {
    Map: CBIMap,
    JSONMap,
    NamedSection,
    TypedSection,
    TableSection,
    GridSection,
    Value,
    ListValue,
    DynamicList,
    MultiValue,
    TextValue,
    DummyValue,
    Flag: FlagValue,
    Button: ButtonValue,
  };
}

/* ----------------------------------------------------------------- harness */

export function createHarness(
  packageName = 'forkop',
  { dropDefaults = false } = {},
) {
  const messages = [];

  const store = new Map();
  const operations = [];
  let anonymous = 0;
  const uci = {
    sections(pkg, type, cb) {
      const list = Array.from(store.values()).filter(
        (section) => !type || section['.type'] === type,
      );
      if (cb) list.forEach(cb);
      return list;
    },
    get(pkg, sid, opt) {
      const section = store.get(sid);
      if (!section) return null;
      if (opt == null) return section;
      return Object.prototype.hasOwnProperty.call(section, opt)
        ? section[opt]
        : null;
    },
    set(pkg, sid, opt, val) {
      const section = store.get(sid);
      if (!section) return;
      if (!isEqual(section[opt] ?? null, val ?? null)) {
        operations.push(`set ${sid}.${opt}=${JSON.stringify(val)}`);
      }
      section[opt] = val;
    },
    unset(pkg, sid, opt) {
      const section = store.get(sid);
      if (!section) return;
      if (Object.prototype.hasOwnProperty.call(section, opt)) {
        operations.push(`del ${sid}.${opt}`);
      }
      delete section[opt];
    },
    add(pkg, type, name) {
      const sid = name || `cfg${(anonymous += 1)}`;
      if (store.has(sid)) return null;
      store.set(sid, { '.name': sid, '.type': type });
      operations.push(`add ${type} ${sid}`);
      return sid;
    },
    remove(pkg, sid) {
      if (store.has(sid))
        operations.push(`remove ${store.get(sid)['.type']} ${sid}`);
      store.delete(sid);
    },
    get_first() {
      return null;
    },
    load() {
      return Promise.resolve();
    },
  };
  const uciData = {
    get: (...args) => uci.get(...args),
    set: (...args) => uci.set(...args),
    unset: (...args) => uci.unset(...args),
    sections: (...args) => uci.sections(...args),
    // Views may read the loaded package from state.values, as LuCI's uci module keeps it.
    get state() {
      const values = {};
      for (const [sid, section] of store) values[sid] = section;
      return { values: { [packageName]: values } };
    },
  };

  const form = buildForm(uciData, dropDefaults);

  const modal = new FakeNode('div');
  const activeMap = new FakeNode('div');
  const buttonRow = new FakeNode('div');
  const heading = new FakeNode('h4');
  new FakeNode('div').appendChild(activeMap);
  modal.querySelector = (selector) => {
    if (selector.startsWith('.cbi-map')) return activeMap;
    if (selector.startsWith('div.button-row')) return buttonRow;
    if (selector === 'h4') return heading;
    return null;
  };

  const documentStub = {
    // Hidden, so the polling services the page starts stand down instead of running against stubs.
    visibilityState: 'hidden',
    querySelector: (selector) =>
      selector === '#modal_overlay > .modal.cbi-modal' ? modal : null,
    querySelectorAll: () => [],
    getElementById: () => null,
    createElement: (tag) => new FakeNode(tag),
    createElementNS: (_ns, tag) => new FakeNode(tag),
    head: new FakeNode('head'),
    body: new FakeNode('body'),
    documentElement: new FakeNode('html'),
    addEventListener() {},
    removeEventListener() {},
  };

  const L = {
    bind: (fn, self, ...bound) => fn.bind(self, ...bound),
    resource: (...parts) => parts.join('/'),
    toArray(value) {
      if (value == null) return [];
      if (Array.isArray(value)) return value;
      if (typeof value === 'object') return [value];
      const text = String(value).trim();
      return text === '' ? [] : text.split(/\s+/);
    },
    error(kind, message) {
      throw new Error(`${kind}: ${message}`);
    },
  };

  const notifications = [];

  const commands = {
    generate_reality_keypair: () =>
      Promise.resolve({
        code: 0,
        stdout: JSON.stringify({
          success: true,
          private_key: 'wIWKZmAoiFsYIPFCwG8FRPHKn0P6PLh0hbBjPfKgpU0',
          public_key: 'SSw7I859PPdN4DQ7fxV9fobXM61Ms3mqZRlIY1aJvHQ',
        }),
      }),
  };

  const moduleGlobals = {
    form,
    ui: {
      DynamicList: makeClass('ui.DynamicList', function () {}),
      addNotification(title, body, kind) {
        notifications.push({ title, text: body?.textContent ?? '', kind });
      },
    },
    uci,
    fs: {
      read: () => Promise.resolve(''),
      exec: (command, args) => {
        const answer = commands[`${args?.[0] ?? ''}`];
        return answer ? answer(args) : Promise.resolve({});
      },
    },
    network: { getDevices: () => Promise.resolve([]) },
    widgets: { DeviceSelect: form.MultiValue, NetworkSelect: form.MultiValue },
    L,
    E,
    document: documentStub,
    window: {
      crypto: webcrypto,
      setTimeout,
      clearTimeout,
      addEventListener() {},
      removeEventListener() {},
      dispatchEvent() {},
      location: {
        hostname: 'router.lan',
        href: 'http://router.lan/',
        protocol: 'http:',
      },
    },
    poll: { add() {}, remove() {} },
    dom: { content() {}, append() {} },
    rpc: { declare: () => () => Promise.resolve({}) },
    console: {
      log: (...args) => messages.push(args.join(' ')),
      info: (...args) => messages.push(args.join(' ')),
      warn: (...args) => messages.push(args.join(' ')),
      error: (...args) => messages.push(args.join(' ')),
    },
  };

  const bundle = loadBundle(moduleGlobals);

  const main = new Proxy(
    Object.assign({}, bundle, {
      store: {},
      ForkopShellMethods: new Proxy(
        {},
        { get: () => () => Promise.resolve({}) },
      ),
    }),
    {
      get: (target, prop) =>
        prop in target
          ? target[prop]
          : () => (/^validate/.test(prop) ? { valid: true } : ''),
    },
  );

  const dialogMaps = [];
  const OriginalJSONMap = form.JSONMap;
  form.JSONMap = OriginalJSONMap.extend({
    __init__(...args) {
      this.super('__init__', args);
      dialogMaps.push(this);
    },
  });

  // Returns the dialog's map and its Save. save() answers whether the dialog closed: a refused save
  // throws inside onSave, which the stacked dialog swallows, so by its writes alone it looks clean.
  async function openDialog(option, ownerId, itemValue, context = {}) {
    return openDialogWith(
      () =>
        option.renderItemSettingsModal(
          ownerId,
          itemValue,
          option,
          null,
          null,
          context,
        ),
      `dialog for ${option.option}`,
    );
  }

  const buttonsIn = (nodes) =>
    nodes.flatMap((node) =>
      node instanceof FakeNode
        ? [...(node.attrs.click ? [node] : []), ...buttonsIn(node.childNodes)]
        : [],
    );

  async function openDialogWith(open, label = 'dialog') {
    const buttons = [];
    const originalAppend = buttonRow.append.bind(buttonRow);
    buttonRow.append = (...nodes) => {
      buttons.push(...buttonsIn(nodes));
      return originalAppend(...nodes);
    };
    const first = dialogMaps.length;
    try {
      await open();
    } finally {
      buttonRow.append = originalAppend;
    }
    const saveButton =
      buttons.find((node) =>
        `${node.attrs.class ?? ''}`.includes('cbi-button-positive'),
      ) ?? buttons[buttons.length - 1];
    if (!saveButton) throw new Error(`${label} did not open`);
    const openTitles = heading.childNodes.length;
    const title = heading.childNodes[heading.childNodes.length - 1];
    return {
      map: dialogMaps[first],
      title: `${title?.textContent ?? ''}`.replace(/^ » /, ''),
      save: async () => {
        await saveButton.attrs.click();
        return { saved: heading.childNodes.length < openTitles };
      },
    };
  }

  const toasts = () =>
    documentStub.body.childNodes
      .filter((node) => node.className === 'toast-container')
      .flatMap((container) =>
        container.childNodes.map((toast) => toast.textContent),
      );

  return {
    bundle: main,
    form,
    uci,
    store,
    operations,
    messages,
    commands,
    notifications,
    openDialog,
    openDialogWith,
    toasts,
  };
}
