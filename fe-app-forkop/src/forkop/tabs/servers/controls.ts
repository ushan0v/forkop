import { FORKOP_UCI_PACKAGE } from '../../../constants';
import { showToast } from '../../../helpers/showToast';
import { CAMOUFLAGE_SITES, STYLE_ID } from './constants';
import { randomItem } from './credentials';
import { iconSvg } from './details';
import { option, widgetNode } from './formValues';
import {
  getEffectiveSecurity,
  getProtocol,
  securitiesFor,
  securityCoreFeature,
  securityLabel,
  vlessEncryptionAuth,
} from './protocols';
import { E } from '../../../helpers/element';
import {
  coreHas,
  missingCoreFeatureNote,
} from '../../services/coreFeatures.service';

export function injectServerStyles() {
  if (document.getElementById(STYLE_ID)) {
    return;
  }

  document.head.appendChild(
    E(
      'style',
      { id: STYLE_ID },
      [
        // Without the box of LuCI's frame div the theme sizes the field against the row, as it does
        // a bare field: its fixed width on a wide screen, the whole row on a phone.
        '.fkp-generate-row{column-gap:4px;display:flex}',
        '.fkp-generate-row > :first-child{display:contents}',
        '.fkp-generate-row > :first-child > *{min-inline-size:0}',
        // The theme leaves a password's reveal button more room than it takes.
        '.fkp-generate-row .control-group > input{flex-grow:1}',
        '.fkp-generate-row > .fkp-generate{align-items:center;box-sizing:border-box;display:inline-flex;flex:none;inline-size:2.5em !important;justify-content:center;line-height:1;margin:0 !important;min-block-size:0;min-inline-size:0;padding:0 !important;float:none !important;user-select:none}',
        '.fkp-generate-row > .fkp-generate > svg{display:block}',
        `#cbi-${FORKOP_UCI_PACKAGE}-server > h3:nth-child(1){display:none}`,
        '.fkp-server-info > svg{vertical-align:middle}',
      ].join('\n'),
    ),
  );
}

function widgetElement(node: HTMLElement): CBIWidget | null {
  const instance = dom.findClassInstance(node) as CBIWidget | null;
  return instance && typeof instance.setValue === 'function' ? instance : null;
}

function controlOf(node: HTMLElement | null): HTMLElement | null {
  if (!node) {
    return null;
  }
  if (/^(INPUT|SELECT|TEXTAREA)$/.test(node.tagName)) {
    return node;
  }
  return typeof node.querySelector === 'function'
    ? (node.querySelector(
        "input:not([type='hidden']), select, textarea",
      ) as HTMLElement | null)
    : null;
}

function renderGenerateButton(label: string, readonly: unknown) {
  return E(
    'button',
    {
      class: 'btn cbi-button cbi-button-neutral fkp-generate',
      type: 'button',
      title: label,
      'aria-label': label,
      disabled: readonly ? '' : null,
    },
    iconSvg('generate'),
  );
}

// A field no loader fills stays empty until its button is pressed, and the validator asks for it.
export function addGenerateButton(
  optionRef: CBIOption,
  generate: (sectionId: string, current?: unknown) => string | null | undefined,
  title?: string,
) {
  const renderWidget = optionRef.renderWidget;

  optionRef.renderWidget = function (
    sectionId: string,
    optionIndex: string,
    cfgvalue: unknown,
  ) {
    const node = renderWidget.call(
      this,
      sectionId,
      optionIndex,
      cfgvalue,
    ) as HTMLElement;
    const label = title || _('Generate');
    const readonly = this.readonly != null ? this.readonly : this.map.readonly;
    const button = renderGenerateButton(label, readonly);

    button.addEventListener('click', (ev) => {
      ev.preventDefault();
      ev.stopPropagation();

      if (readonly) {
        return;
      }

      const element = widgetElement(node);
      const next = generate(sectionId, element ? element.getValue() : null);

      if (next == null) {
        return;
      }
      if (element) {
        element.setValue(next);
        // Validated like a typed value, so the invalid mark clears.
        if (typeof element.triggerValidation === 'function') {
          element.triggerValidation();
        }
      }
      controlOf(node)?.dispatchEvent(new Event('change', { bubbles: true }));
    });

    return E('div', { class: 'fkp-generate-row' }, [node, button]);
  };
}

function getSelectWidget(
  sectionId: string,
  name: string,
): HTMLSelectElement | null {
  const node = widgetNode(sectionId, name);

  if (!node) {
    return null;
  }
  if (node.tagName === 'SELECT') {
    return node as HTMLSelectElement;
  }

  return typeof node.querySelector === 'function'
    ? node.querySelector('select')
    : null;
}

// LuCI's depends() cannot tie the security modes to the protocol, so the choices are rebuilt on
// every change; the handler runs before the form sees the new value, so it is handed over.
export function syncSecurityChoices(
  sectionId: string,
  protocol?: unknown,
  reset?: boolean,
) {
  const select = getSelectWidget(sectionId, 'security');
  const stored = select ? select.value : option(sectionId, 'security');
  // A mode the installed core lacks stays only for the server that has it, so its save is refused
  // by name.
  const allowed = securitiesFor(protocol || getProtocol(sectionId)).filter(
    (security: string) => {
      const feature = securityCoreFeature(security);
      return !feature || coreHas(feature) || (!reset && security === stored);
    },
  );
  // A protocol change starts from that protocol's best mode.
  const next = !reset && allowed.includes(stored) ? stored : allowed[0];

  if (!select) {
    if (stored !== next) {
      uci.set(FORKOP_UCI_PACKAGE, sectionId, 'security', next);
    }
    return;
  }

  select.replaceChildren(
    ...allowed.map((security: string) => {
      const feature = securityCoreFeature(security);
      return E(
        'option',
        { value: security, selected: security === next ? '' : undefined },
        !feature || coreHas(feature)
          ? securityLabel(security)
          : `${securityLabel(security)} (${missingCoreFeatureNote(feature)})`,
      );
    }),
  );
  select.value = next;
  select.dispatchEvent(new Event('change', { bubbles: true }));
}

// Picked once per dialog, so the SNI keeps the offered domain across loads.
const camouflageChoice = new Map<string, string>();

export function camouflageSite(sectionId: string, reroll?: boolean) {
  if (reroll || !camouflageChoice.has(sectionId)) {
    camouflageChoice.set(sectionId, randomItem(CAMOUFLAGE_SITES));
  }
  return camouflageChoice.get(sectionId);
}

// The widget wins over the stored value while the dialog is open; without one the write goes to
// the configuration.
export function applyFieldValue(
  sectionId: string,
  name: string,
  value: UciValue,
) {
  const node = widgetNode(sectionId, name);
  const element = node ? widgetElement(node) : null;

  if (!element) {
    uci.set(FORKOP_UCI_PACKAGE, sectionId, name, value);
    return;
  }

  element.setValue(value);
  if (typeof element.triggerValidation === 'function') {
    element.triggerValidation();
  }
  controlOf(node)?.dispatchEvent(new Event('change', { bubbles: true }));
}

// Both fields load separately but must hold halves of one pair.
const pendingKeypairs = new Map();

export function realityKeypair(sectionId: string) {
  if (getEffectiveSecurity(sectionId) !== 'reality') {
    return Promise.resolve(null);
  }
  return sharedRealityKeypair(sectionId);
}

// A server that turns to Reality in the dialog gets its pair as one opened on it does, through
// the same request when both happen at once.
export function applyRealityKeypair(sectionId: string) {
  return sharedRealityKeypair(sectionId).then(
    (pair: { private_key: string; public_key: string } | null) => {
      if (!pair) {
        return;
      }
      [
        ['reality_private_key', pair.private_key],
        ['reality_public_key', pair.public_key],
      ].forEach(([name, value]) => applyFieldValue(sectionId, name, value));
    },
  );
}

function sharedRealityKeypair(sectionId: string) {
  if (!pendingKeypairs.has(sectionId)) {
    pendingKeypairs.set(
      sectionId,
      generateRealityKeypair(sectionId).finally(() =>
        window.setTimeout(() => pendingKeypairs.delete(sectionId), 0),
      ),
    );
  }
  return pendingKeypairs.get(sectionId);
}

function generateRealityKeypair(_sectionId: string) {
  return requestKeypair(
    ['generate_reality_keypair'],
    _('Could not generate a Reality key pair'),
  );
}

function requestKeypair(args: string[], failure: string) {
  return fs
    .exec('/usr/bin/forkop', args)
    .then((response) => {
      if ((response.code ?? 0) !== 0 || !response.stdout) {
        throw new Error(response.stderr || response.stdout || '');
      }

      const data = JSON.parse(response.stdout);
      if (!data.success || !data.private_key || !data.public_key) {
        throw new Error(data.message || '');
      }

      return data;
    })
    .catch((error) => {
      console.warn(error?.message || `Failed to run ${args[0]}`);
      showToast(failure, 'error');
      return null;
    });
}

// Writes both halves of a pair of the given kind: a key of the other kind is refused.
export function applyVlessEncryptionKeypair(sectionId: string, kind: string) {
  return requestKeypair(
    ['generate_vless_encryption_keypair', kind],
    _('Could not generate a VLESS Encryption key pair'),
  ).then((pair) => {
    if (!pair) {
      return;
    }
    [
      ['vless_encryption_private_key', pair.private_key],
      ['vless_encryption_public_key', pair.public_key],
    ].forEach(([name, value]) => applyFieldValue(sectionId, name, value));
  });
}

export function addVlessEncryptionKeypairButton(optionRef: CBIOption) {
  addIssueButton(optionRef, _('Generate a key pair'), (sectionId: string) =>
    applyVlessEncryptionKeypair(sectionId, vlessEncryptionAuth(sectionId)),
  );
}

function addIssueButton(
  optionRef: CBIOption,
  label: string,
  request: (sectionId: string, node: HTMLElement) => Promise<unknown>,
) {
  const renderWidget = optionRef.renderWidget;

  optionRef.renderWidget = function (
    sectionId: string,
    optionIndex: string,
    cfgvalue: unknown,
  ) {
    const node = renderWidget.call(
      this,
      sectionId,
      optionIndex,
      cfgvalue,
    ) as HTMLElement;
    const readonly = this.readonly != null ? this.readonly : this.map.readonly;
    const button = renderGenerateButton(label, readonly);

    button.addEventListener('click', (ev) => {
      ev.preventDefault();

      if (readonly) {
        return;
      }

      button.disabled = true;
      request(sectionId, node)
        .catch((error: Error) => {
          console.warn(error?.message || 'Failed to issue the file');
        })
        .finally(() => {
          button.disabled = readonly ? true : false;
        });
    });

    return E('div', { class: 'fkp-generate-row' }, [node, button]);
  };
}

// Writes both halves: the button sits on the private key and fills in the public one.
export function addRealityKeypairButton(optionRef: CBIOption) {
  addIssueButton(optionRef, _('Generate a key pair'), (sectionId: string) =>
    generateRealityKeypair(sectionId).then((pair) => {
      if (!pair) {
        return;
      }
      [
        ['reality_private_key', pair.private_key],
        ['reality_public_key', pair.public_key],
      ].forEach(([name, value]) => applyFieldValue(sectionId, name, value));
    }),
  );
}

// LuCI compares an untouched field with what load() returned and skips it on save; forcewrite
// makes an autofilled value reach the configuration.
export function autofill(option: CBIOption, loader: CBIOption['load']) {
  option.forcewrite = true;
  option.load = loader;
}
