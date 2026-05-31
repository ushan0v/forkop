import { onMount, preserveScrollForPage } from '../../../helpers';
import { PODKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT } from '../../../constants';
import { normalizeCompiledVersion } from '../../../helpers/normalizeCompiledVersion';
import { showToast } from '../../../helpers/showToast';
import {
  renderRotateCcwIcon24,
  renderSearchIcon24,
  renderXIcon24,
} from '../../../icons';
import { renderButton } from '../../../partials';
import { PodkopShellMethods } from '../../methods';
import { logger, store, StoreType } from '../../services';
import { ensureSystemInfo } from '../../services/systemInfo.service';
import { Podkop } from '../../types';

type UpdatesActionKey = keyof StoreType['updatesActions'];
type UpdateStatus =
  StoreType['updatesChecks'][Podkop.ComponentName]['status'];

interface ComponentActionButton {
  key: UpdatesActionKey;
  text: string;
  icon: () => SVGSVGElement;
  component: Podkop.ComponentName;
  action: Podkop.ComponentAction;
}

interface ComponentCard {
  title: string;
  version: string;
  releaseUrl?: string;
  tag?: {
    label: string;
    kind: 'neutral' | 'success' | 'warning';
  };
  actions: ComponentActionButton[];
}

let updatesLifecycleRegistered = false;
let updatesControllerInitialized = false;
let updatesMounted = false;

function isNotInstalled(version: string | undefined) {
  return !version || version === 'not installed';
}

function getCheckTag(component: Podkop.ComponentName): ComponentCard['tag'] {
  const status = store.get().updatesChecks[component].status;

  if (!status) {
    return undefined;
  }

  if (status === 'latest') {
    return { label: _('Latest'), kind: 'success' };
  }

  if (status === 'outdated') {
    return { label: _('Outdated'), kind: 'warning' };
  }

  return { label: _('Dev'), kind: 'neutral' };
}

function shouldShowInstallAfterCheck(component: Podkop.ComponentName) {
  const status = store.get().updatesChecks[component].status;

  return status === 'outdated' || status === 'dev';
}

function getInstallActionText(component: Podkop.ComponentName) {
  const checkResult = store.get().updatesChecks[component];

  if (shouldShowInstallAfterCheck(component) && checkResult.latest_version) {
    return _('Install %s').replace('%s', checkResult.latest_version);
  }

  return _('Install');
}

function getGitHubReleaseUrl(component: Podkop.ComponentName) {
  const checkResult = store.get().updatesChecks[component];

  if (!shouldShowInstallAfterCheck(component) || !checkResult.release_url) {
    return undefined;
  }

  return checkResult.release_url;
}

function isAnyActionLoading() {
  return Object.values(store.get().updatesActions).some((item) => item.loading);
}

function isSystemInfoLoading() {
  const systemInfo = store.get().diagnosticsSystemInfo;

  return systemInfo.loading || !systemInfo.loaded;
}

function setActionLoading(action: UpdatesActionKey, loading: boolean) {
  const updatesActions = store.get().updatesActions;

  store.set({
    updatesActions: {
      ...updatesActions,
      [action]: { loading },
    },
  });
}

function setCheckResult(
  component: Podkop.ComponentName,
  status: UpdateStatus,
  latestVersion: string,
  releaseUrl: string = '',
) {
  const updatesChecks = store.get().updatesChecks;

  store.set({
    updatesChecks: {
      ...updatesChecks,
      [component]: {
        status,
        latest_version: latestVersion,
        release_url: releaseUrl,
      },
    },
  });
}

function resetCheckResult(component: Podkop.ComponentName) {
  setCheckResult(component, null, '');
}

function getExpectedLatestVersionForAction(button: ComponentActionButton) {
  if (button.component !== 'podkop' || button.action !== 'install') {
    return undefined;
  }

  return store.get().updatesChecks[button.component].latest_version || undefined;
}

function getCheckToastMessage(status: UpdateStatus) {
  if (status === 'outdated') {
    return _('Update is available');
  }

  if (status === 'dev') {
    return _('Installed version is newer than release');
  }

  return _('Latest version is installed');
}

async function refreshSystemInfoAfterMutation() {
  await ensureSystemInfo({ force: true, silent: true });
}

function notifyActionProvidersAvailabilityChanged(
  systemInfo: StoreType['diagnosticsSystemInfo'],
) {
  if (typeof window === 'undefined' || typeof CustomEvent === 'undefined') {
    return;
  }

  window.dispatchEvent(
    new CustomEvent(PODKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT, {
      detail: {
        zapretInstalled: Boolean(systemInfo.zapret_installed),
        byedpiInstalled: Boolean(systemInfo.byedpi_installed),
      },
    }),
  );
}

function reloadPageAfterPodkopUpdate() {
  window.setTimeout(() => {
    window.location.reload();
  }, 1200);
}

function patchSystemInfoAfterMutation(result: Podkop.ComponentActionResult) {
  const systemInfo = store.get().diagnosticsSystemInfo;
  const nextSystemInfo = { ...systemInfo, loading: false, loaded: true };
  const version =
    result.current_version || result.latest_version || _('unknown');

  if (result.component === 'podkop' && result.action === 'install') {
    nextSystemInfo.podkop_version = version;
  }

  if (result.component === 'sing_box') {
    nextSystemInfo.sing_box_version = version;

    if (result.action === 'install_extended') {
      nextSystemInfo.sing_box_extended = 1;
    }

    if (result.action === 'install_stable') {
      nextSystemInfo.sing_box_extended = 0;
    }
  }

  if (result.component === 'zapret') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.zapret_installed = 0;
      nextSystemInfo.zapret_version = 'not installed';
    } else {
      nextSystemInfo.zapret_installed = 1;
      nextSystemInfo.zapret_version = version;
    }
  }

  if (result.component === 'byedpi') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.byedpi_installed = 0;
      nextSystemInfo.byedpi_version = 'not installed';
    } else {
      nextSystemInfo.byedpi_installed = 1;
      nextSystemInfo.byedpi_version = version;
    }
  }

  store.set({
    diagnosticsSystemInfo: nextSystemInfo,
  });

  if (result.component === 'zapret' || result.component === 'byedpi') {
    notifyActionProvidersAvailabilityChanged(nextSystemInfo);
  }
}

async function handleComponentAction(button: ComponentActionButton) {
  if (isAnyActionLoading()) {
    return;
  }

  setActionLoading(button.key, true);

  try {
    const response = await PodkopShellMethods.componentAction(
      button.component,
      button.action,
      getExpectedLatestVersionForAction(button),
    );

    if (!response.success) {
      setActionLoading(button.key, false);
      showToast(response.error || _('Failed to execute'), 'error');
      return;
    }

    const result = response.data;

    if (button.action === 'check_update') {
      const status = result.status || null;

      if (status === 'latest' || status === 'outdated' || status === 'dev') {
        setCheckResult(
          button.component,
          status,
          result.latest_version || '',
          result.release_url || '',
        );
      }

      setActionLoading(button.key, false);
      showToast(getCheckToastMessage(status), 'success');
      return;
    }

    if (button.action === 'install' || button.action.startsWith('install_')) {
      setCheckResult(button.component, 'latest', result.latest_version || '');
    } else {
      resetCheckResult(button.component);
    }

    patchSystemInfoAfterMutation(result);
    setActionLoading(button.key, false);

    if (result.component === 'podkop' && result.action === 'install') {
      if (result.message) {
        showToast(result.message, 'success', 1200);
      }

      reloadPageAfterPodkopUpdate();
      return;
    }

    if (result.message) {
      showToast(result.message, 'success');
    }

    void refreshSystemInfoAfterMutation();
  } catch (error) {
    logger.error('[UPDATES]', 'handleComponentAction failed', error);
    setActionLoading(button.key, false);
    showToast(_('Failed to execute'), 'error');
  }
}

function getPrimaryUpdateAction(
  component: Podkop.ComponentName,
  checkKey: UpdatesActionKey,
  installKey: UpdatesActionKey,
): ComponentActionButton {
  if (shouldShowInstallAfterCheck(component)) {
    return {
      key: installKey,
      text: getInstallActionText(component),
      icon: renderRotateCcwIcon24,
      component,
      action: 'install',
    };
  }

  return {
    key: checkKey,
    text: _('Check update'),
    icon: renderSearchIcon24,
    component,
    action: 'check_update',
  };
}

function getComponentCards(): ComponentCard[] {
  const systemInfo = store.get().diagnosticsSystemInfo;
  const systemInfoLoading = isSystemInfoLoading();
  const zapretInstalled = Boolean(systemInfo.zapret_installed);
  const byedpiInstalled = Boolean(systemInfo.byedpi_installed);
  const singBoxInstallAction: ComponentActionButton =
    systemInfo.sing_box_extended
      ? {
          key: 'singBoxInstallStable',
          text: _('Install stable'),
          icon: renderRotateCcwIcon24,
          component: 'sing_box',
          action: 'install_stable',
        }
      : {
          key: 'singBoxInstallExtended',
          text: _('Install extended'),
          icon: renderRotateCcwIcon24,
          component: 'sing_box',
          action: 'install_extended',
        };

  return [
    {
      title: 'Podkop Plus',
      version: normalizeCompiledVersion(systemInfo.podkop_version),
      releaseUrl: getGitHubReleaseUrl('podkop'),
      tag: getCheckTag('podkop'),
      actions: [
        getPrimaryUpdateAction('podkop', 'podkopCheck', 'podkopInstall'),
      ],
    },
    {
      title: 'Sing-box',
      version: isNotInstalled(systemInfo.sing_box_version)
        ? _('Not installed')
        : systemInfo.sing_box_version,
      releaseUrl: getGitHubReleaseUrl('sing_box'),
      tag: getCheckTag('sing_box'),
      actions: [
        getPrimaryUpdateAction(
          'sing_box',
          'singBoxCheck',
          'singBoxInstall',
        ),
        singBoxInstallAction,
      ],
    },
    {
      title: 'Zapret',
      version: systemInfoLoading
        ? 'loading'
        : zapretInstalled
          ? systemInfo.zapret_version
          : _('Not installed'),
      releaseUrl: getGitHubReleaseUrl('zapret'),
      tag: zapretInstalled ? getCheckTag('zapret') : undefined,
      actions: zapretInstalled
        ? [
            getPrimaryUpdateAction('zapret', 'zapretCheck', 'zapretInstall'),
            {
              key: 'zapretRemove',
              text: _('Remove'),
              icon: renderXIcon24,
              component: 'zapret',
              action: 'remove',
            },
          ]
        : [
            {
              key: 'zapretInstall',
              text: _('Install'),
              icon: renderRotateCcwIcon24,
              component: 'zapret',
              action: 'install',
            },
          ],
    },
    {
      title: 'ByeDPI',
      version: systemInfoLoading
        ? 'loading'
        : byedpiInstalled
          ? systemInfo.byedpi_version
          : _('Not installed'),
      releaseUrl: getGitHubReleaseUrl('byedpi'),
      tag: byedpiInstalled ? getCheckTag('byedpi') : undefined,
      actions: byedpiInstalled
        ? [
            getPrimaryUpdateAction('byedpi', 'byedpiCheck', 'byedpiInstall'),
            {
              key: 'byedpiRemove',
              text: _('Remove'),
              icon: renderXIcon24,
              component: 'byedpi',
              action: 'remove',
            },
          ]
        : [
            {
              key: 'byedpiInstall',
              text: _('Install'),
              icon: renderRotateCcwIcon24,
              component: 'byedpi',
              action: 'install',
            },
          ],
    },
  ];
}

function renderComponentTag(card: ComponentCard) {
  if (!card.tag) {
    return null;
  }

  return E(
    'span',
    {
      class: [
        'pdk_updates-page__component__tag',
        card.tag.kind === 'success'
          ? 'pdk_updates-page__component__tag--success'
          : '',
        card.tag.kind === 'warning'
          ? 'pdk_updates-page__component__tag--warning'
          : '',
      ]
        .filter(Boolean)
        .join(' '),
    },
    card.tag.label,
  );
}

function renderComponentCard(card: ComponentCard) {
  const updatesActions = store.get().updatesActions;
  const anyActionLoading = isAnyActionLoading();
  const systemInfoLoading = isSystemInfoLoading();
  const tag = renderComponentTag(card);
  const headerChildren: Node[] = [
    E('b', { class: 'pdk_updates-page__component__title' }, card.title),
  ];
  const statusChildren: Node[] = [];

  if (card.releaseUrl) {
    statusChildren.push(
      E(
        'a',
        {
          class: 'pdk_updates-page__component__release-link',
          href: card.releaseUrl,
          target: '_blank',
          rel: 'noopener noreferrer',
        },
        _('Latest release'),
      ),
    );
  }

  if (tag) {
    statusChildren.push(tag);
  }

  if (statusChildren.length > 0) {
    headerChildren.push(
      E(
        'div',
        { class: 'pdk_updates-page__component__status' },
        statusChildren,
      ),
    );
  }

  return E('div', { class: 'pdk_updates-page__component' }, [
    E(
      'div',
      { class: 'pdk_updates-page__component__header' },
      headerChildren,
    ),
    E('div', { class: 'pdk_updates-page__component__version' }, [
      E(
        'span',
        { class: 'pdk_updates-page__component__version__label' },
        _('Version'),
      ),
      E(
        'span',
        { class: 'pdk_updates-page__component__version__value' },
        card.version,
      ),
    ]),
    E(
      'div',
      { class: 'pdk_updates-page__component__actions' },
      card.actions.map((action) => {
        const loading = updatesActions[action.key].loading;

        return renderButton({
          text: action.text,
          icon: action.icon,
          loading,
          disabled: systemInfoLoading || (anyActionLoading && !loading),
          onClick: () => void handleComponentAction(action),
        });
      }),
    ),
  ]);
}

function renderUpdatesComponents() {
  const container = document.getElementById('pdk_updates-components');

  if (!container) {
    return;
  }

  const renderedComponents = getComponentCards().map(renderComponentCard);

  return preserveScrollForPage(() => {
    container.replaceChildren(...renderedComponents);
  });
}

function onStoreUpdate(
  _next: StoreType,
  _prev: StoreType,
  diff: Partial<StoreType>,
) {
  if (diff.diagnosticsSystemInfo || diff.updatesActions || diff.updatesChecks) {
    renderUpdatesComponents();
  }
}

function onPageMount() {
  onPageUnmount();

  updatesMounted = true;
  store.subscribe(onStoreUpdate);
  renderUpdatesComponents();
  void ensureSystemInfo();
}

function onPageUnmount() {
  updatesMounted = false;
  store.unsubscribe(onStoreUpdate);
}

function registerLifecycleListeners() {
  if (updatesLifecycleRegistered) {
    return;
  }

  updatesLifecycleRegistered = true;

  store.subscribe((next, prev, diff) => {
    if (
      diff.tabService &&
      next.tabService.current !== prev.tabService.current
    ) {
      const isUpdatesVisible = next.tabService.current === 'updates';

      if (isUpdatesVisible) {
        return onPageMount();
      }

      if (updatesMounted) {
        return onPageUnmount();
      }
    }
  });
}

export async function initController(): Promise<void> {
  if (updatesControllerInitialized) {
    return;
  }

  updatesControllerInitialized = true;

  onMount('updates-status').then(() => {
    logger.debug('[UPDATES]', 'initController', 'onMount');
    registerLifecycleListeners();
    if (store.get().tabService.current === 'updates') {
      onPageMount();
    }
  });
}
