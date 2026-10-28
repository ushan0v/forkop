// What Forkop hangs off a CBI option on top of LuCI's own members; merges into src/luci.d.ts.

import type { Annotation } from './annotations';

declare global {
  interface TextToken {
    value: string;
    start: number;
    end: number;
  }

  interface TextAnalysis {
    valid: boolean;
    message?: string;
    annotations: Annotation[];
  }

  type TextAnalyzer = (value: string) => TextAnalysis;

  type TextItemValidator = (value: string) => true | string;

  interface TextListAnalysisOptions {
    duplicateMessage?: string;
    // Two spellings of one entry (a domain with and without its leading dot), so the second is a duplicate.
    normalizeDuplicateValue?: (value: string) => string;
  }

  // Kept on the field, so configuring it again replaces the analyzer instead of stacking overlays.
  interface AnnotatedTextareaController {
    analyzer: TextAnalyzer;
    textarea: HTMLTextAreaElement;
    wrapper: HTMLElement;
    overlay: HTMLElement;
    resizeObserver?: ResizeObserver;
    update(): void;
  }

  interface HTMLTextAreaElement {
    __forkopAnnotatedTextareaController?: AnnotatedTextareaController;
  }

  type ChildSettings = Record<string, unknown>;

  type OptionValidator = (sectionId: string, value: string) => string | true;

  type ChoiceEntry = string | { value: string; label?: unknown };

  interface ChildItemOptions {
    typeName?: string;
    valueOption?: string;
    ownerOption?: string;
    createId?: (inputValue?: string, sectionId?: string) => string;
    // A single default may be a function, which derives an id or a name from the owner.
    defaults?:
      | Record<string, unknown>
      | ((inputValue: string, existing: boolean) => Record<string, unknown>);
    // The settings of an entry added but not saved, for a child created now.
    stagedSettings?: ((value: unknown) => ChildSettings | null) | null;
  }

  interface CBIOption {
    // A stored section name the choices no longer offer: see keepUnavailableSectionChoice.
    unavailableChoice?: string;

    // ------------------------------------------------ the child item list
    //
    // A dynamic list whose entries stand for uci sections of their own.

    // The uci section type each entry stands for, and the option of that section
    // holding the text the list shows.
    childType?: string;
    childValueOption?: string;
    // The option on the child that points back at its owner - "section" for a
    // section's children, "group" for the levels of a fallback group.
    ownerOption?: string;
    childOwnerId?: (sectionId: string) => string;
    removeNestedChildItems?: (itemId: string) => void;
    // For a list inside a dialog that edits a child of another section.
    parentSectionId?: ((sectionId: string) => string) | string;
    childDefaults?:
      | ChildSettings
      | ((inputValue: string, existing: boolean) => ChildSettings);
    createId?: (inputValue?: string, sectionId?: string) => string;
    // Every entry is a child section from the moment it is added, where other lists stage an entry
    // until the section is saved.
    entriesAreSections?: boolean;
    // Entries are added through a dialog rather than typed into the list.
    buttonAdd?: boolean;
    // Left out of the table load: the column renders from something other than a stored value.
    disable?: boolean;

    hasItemSettings?: (sectionId: string, value: unknown) => boolean;
    renderItemSettingsModal?: (
      sectionId: string,
      itemValue: string,
      option: CBIOption,
      widget: CBIWidget,
      item: Element | null,
      context?: ChildItemModalContext,
    ) => unknown;
    // A node rather than a string when the label carries an icon.
    renderListItemLabel?: (
      sectionId: string,
      itemId: string,
      text?: string | null,
    ) => string | Node;
    // What the child section stores, or for an unwritten entry the name its dialog holds.
    inputValueForItem?: (sectionId: string, value: unknown) => string;
    addButtonLabel?: string | ((sectionId: string) => string);
    addable?: (sectionId: string) => boolean;
    validateItemsOnSave?: (
      sectionId: string,
      values: unknown,
      option: CBIOption,
      formSectionId?: string,
    ) => true | string;
    afterMaterializeChildItems?: (sectionId: string, itemIds: string[]) => void;
    onListChange?: (sectionId: string, values: string[]) => void;

    // Unsaved entries, keyed by the text they show; two lists editing the same children share a
    // store under this key.
    pendingChildSettings?: Record<string, Record<string, ChildSettings>>;
    sharedPendingSettingsKey?: string;
    stagedChildSettings?: (
      sectionId: string,
      value: unknown,
    ) => ChildSettings | null;
    clearStagedChildSettings?: (sectionId: string) => void;
    childItemOptions?: (ownerId: string) => ChildItemOptions;
    createTypedItem?: (sectionId: string, inputValue: string) => string;

    liveDynamicListNodes?: Map<string, HTMLElement>;

    // ------------------------------------------------ local device picker
    onDeviceWidgetReady?: (sectionId: string, widget: CBIWidget) => void;
    onDeviceListChange?: (
      sectionId: string,
      value: string | string[] | null,
    ) => void;
    devices?: NetworkDevice[];
    interfaceDeviceMap?: Record<string, NetworkDevice>;
    outgoingDeviceNames?: string[];
  }

  interface ChildItemModalContext {
    adding?: boolean;
    parentSectionId?: string;
    ownerId?: string;
    [key: string]: unknown;
  }

  interface ChildItemDialogContext {
    parentSectionId: (itemId?: string) => string;
    ownerId: () => string;
    itemValue: () => string;
    listOption: CBIOption;
    validateName?: ChildItemNameValidator;
  }

  // Handed only the name: the list and entry are bound when the dialog opens, so it works for an
  // entry without a section yet.
  type ChildItemNameValidator = (value: unknown) => true | string;

  interface ChildItemDialog {
    typeName: string;
    // Absent for a child whose entry is addressed by its section id alone.
    valueOption?: string;
    ownerOption?: string;
    keys: string[];
    defaults?:
      | ChildSettings
      | ((inputValue: string, existing: boolean) => ChildSettings);
    title: (inputValue: string) => string;
    addOptions: (section: CBISection, context: ChildItemDialogContext) => void;
    validateName?: ChildItemNameValidator;
    afterSave?: (
      itemId: string,
      inputValue: string,
      settings: ChildSettings,
      existing: boolean,
    ) => void;
    itemNode?: Element | null;
    singleField?: boolean;
    saveLabel?: string;
  }

  interface StackedModalOptions {
    singleField?: boolean;
    saveLabel?: string;
    // A second way to save, beside the save button: it is handed the save and
    // decides when to run it.
    secondaryAction?: {
      label: string;
      icon?: () => SVGSVGElement;
      run: (save: () => Promise<unknown>) => void;
    };
  }

  interface WireGuardPeerObject {
    address?: unknown;
    port?: unknown;
    public_key?: unknown;
    pre_shared_key?: unknown;
    allowed_ips?: unknown;
    persistent_keepalive_interval?: unknown;
  }

  interface ImportedTunnelFields {
    tunnelId: string;
    type: CBIOption;
    amneziaEnabled: CBIOption;
    address: CBIOption;
    privateKey: CBIOption;
    listenPort: CBIOption;
    mtu: CBIOption;
    peers: CBIOption;
    amnezia: Record<string, CBIOption>;
  }

  interface CBISection {
    // Header rows are numbered as added, so a removed row never gives its number back.
    nextHeaderRowIndex?: number;
  }

  // The dynamic list asks its options what an entry is called and whether settings stand behind it.
  interface CBIWidgetOptions {
    addButtonLabel?: string;
    addable?: boolean;
    // A child item is addressed by both its section id and its name; adding it under the other
    // spelling would make two of it.
    hasEquivalentValue?: (value: string, node: HTMLElement) => boolean;
    itemLabel?: (value: string, text?: string | null) => string | Node;
    hasSettings?: (value: string) => boolean;
    createItem?: ((inputValue: string) => string) | null;
    settingsHandler?: (
      value: string,
      item: Element | null,
      widget: CBIWidget,
      context: { adding?: boolean },
    ) => void;
  }

  // LuCI builds the modal map for the one section being edited and replaces section() with that
  // section's id.
  interface CBIModalMap extends Omit<CBIMap, 'section'> {
    section: string;
  }

  interface CBIMap {
    addedSection?: string;
  }

  interface CBIWidget {
    settingsButtonResizeObserver?: ResizeObserver | null;
  }

  interface Element {
    fkpDynamicListSettingsButton?: HTMLElement;
  }
}

export {};
