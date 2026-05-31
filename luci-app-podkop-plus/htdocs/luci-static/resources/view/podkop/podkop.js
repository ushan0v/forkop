"use strict";
"require view";
"require form";
"require baseclass";
"require uci";
"require ui";
"require view.podkop_plus.main as main";

// Global settings
"require view.podkop_plus.settings as settings";

// Sections
"require view.podkop_plus.section as section";

// Server
"require view.podkop_plus.server as server";

// Dashboard
"require view.podkop_plus.dashboard as dashboard";

// Monitoring
"require view.podkop_plus.monitoring as monitoring";

// Diagnostic
"require view.podkop_plus.diagnostic as diagnostic";

// Updates
"require view.podkop_plus.updates as updates";

const UCI_PACKAGE = main.PODKOP_UCI_PACKAGE;
const CBI_PREFIX = UCI_PACKAGE;

function renderSectionAdd(sectionRef, extra_class) {
  const el = form.GridSection.prototype.renderSectionAdd.apply(sectionRef, [
    extra_class,
  ]);
  const nameEl = el.querySelector(".cbi-section-create-name");

  ui.addValidator(
    nameEl,
    "uciname",
    true,
    (value) => {
      const button = el.querySelector(".cbi-section-create > .cbi-button-add");
      const uciconfig = sectionRef.uciconfig || sectionRef.map.config;

      if (!value) {
        button.disabled = true;
        return true;
      }

      if (uci.get(uciconfig, value)) {
        button.disabled = true;
        return _("Expecting: %s").format(_("unique UCI identifier"));
      }

      button.disabled = null;
      return true;
    },
    "blur",
    "keyup",
  );

  return el;
}

function getRuleEditButtonText() {
  const label = _("Edit rule action");

  return label === "Edit rule action" ? "Edit" : label;
}

function configureGridSection(sectionRef, type, title, addTitle) {
  sectionRef.anonymous = false;
  sectionRef.addremove = true;
  sectionRef.sortable = true;
  sectionRef.rowcolors = true;
  sectionRef.nodescriptions = true;
  sectionRef.modaltitle = function (section_id) {
    const label = uci.get(UCI_PACKAGE, section_id, "label");
    return section_id ? `${title}: ${label || section_id}` : addTitle;
  };
  sectionRef.sectiontitle = function (section_id) {
    return uci.get(UCI_PACKAGE, section_id, "label") || section_id;
  };
  sectionRef.renderSectionAdd = function (extra_class) {
    return renderSectionAdd(sectionRef, extra_class);
  };

  if (type === "section") {
    sectionRef.renderRowActions = function (section_id) {
      return form.TableSection.prototype.renderRowActions.call(
        this,
        section_id,
        getRuleEditButtonText(),
      );
    };
  }
}

const EntryPoint = {
  async render() {
    main.injectGlobalStyles();
    const uiCapabilities = {
      loaded: false,
      singBoxExtended: false,
      zapretInstalled: false,
      byedpiInstalled: false,
      serverInboundsEnabledCount: -1,
    };
    let uiCapabilitiesPromise = null;
    let serverSectionRef = null;

    const applyUiCapabilities = function () {
      if (serverSectionRef) {
        server.applyServerCapabilities(serverSectionRef, uiCapabilities);
      }

      if (typeof window !== "undefined") {
        window.dispatchEvent(
          new CustomEvent(main.PODKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT, {
            detail: {
              zapretInstalled: uiCapabilities.zapretInstalled,
              byedpiInstalled: uiCapabilities.byedpiInstalled,
            },
          }),
        );
      }

      if (main.store && typeof main.store.set === "function") {
        const currentSystemInfo = main.store.get().diagnosticsSystemInfo;
        main.store.set({
          diagnosticsSystemInfo: {
            ...currentSystemInfo,
            providerInfoLoaded: true,
            sing_box_extended: uiCapabilities.singBoxExtended ? 1 : 0,
            zapret_installed: uiCapabilities.zapretInstalled ? 1 : 0,
            byedpi_installed: uiCapabilities.byedpiInstalled ? 1 : 0,
            server_inbounds_enabled_count:
              uiCapabilities.serverInboundsEnabledCount,
            zapret_version: uiCapabilities.zapretInstalled
              ? currentSystemInfo.zapret_version
              : "not installed",
            byedpi_version: uiCapabilities.byedpiInstalled
              ? currentSystemInfo.byedpi_version
              : "not installed",
          },
        });
      }
    };

    const updateUiCapabilities = function (data) {
      uiCapabilities.loaded = true;
      uiCapabilities.singBoxExtended = Boolean(
        Number(data?.sing_box_extended) === 1,
      );
      uiCapabilities.zapretInstalled = Boolean(
        Number(data?.zapret_installed) === 1,
      );
      uiCapabilities.byedpiInstalled = Boolean(
        Number(data?.byedpi_installed) === 1,
      );
      const serverInboundsEnabledCount =
        typeof data?.server_inbounds_enabled_count !== "undefined"
          ? Number(data.server_inbounds_enabled_count)
          : -1;
      uiCapabilities.serverInboundsEnabledCount = Number.isFinite(
        serverInboundsEnabledCount,
      )
        ? serverInboundsEnabledCount
        : -1;

      applyUiCapabilities();

      return uiCapabilities;
    };

    const loadFallbackUiCapabilities = function () {
      return Promise.allSettled([
        main.PodkopShellMethods.getServerCapabilities(),
        main.PodkopShellMethods.checkZapretRuntime(),
        main.PodkopShellMethods.checkByedpiRuntime(),
        main.PodkopShellMethods.checkInboundsConfig(),
      ]).then(
        ([
          serverCapabilitiesResult,
          zapretRuntimeResult,
          byedpiRuntimeResult,
          inboundsConfigResult,
        ]) => {
          const serverCapabilities =
            serverCapabilitiesResult.status === "fulfilled"
              ? serverCapabilitiesResult.value
              : null;
          const zapretRuntime =
            zapretRuntimeResult.status === "fulfilled"
              ? zapretRuntimeResult.value
              : null;
          const byedpiRuntime =
            byedpiRuntimeResult.status === "fulfilled"
              ? byedpiRuntimeResult.value
              : null;
          const inboundsConfig =
            inboundsConfigResult.status === "fulfilled"
              ? inboundsConfigResult.value
              : null;

          return updateUiCapabilities({
            sing_box_extended:
              serverCapabilities?.success &&
              Number(serverCapabilities.data?.sing_box_extended) === 1
                ? 1
                : 0,
            zapret_installed:
              zapretRuntime?.success &&
              Number(zapretRuntime.data?.zapret_installed) === 1
                ? 1
                : 0,
            byedpi_installed:
              byedpiRuntime?.success &&
              Number(byedpiRuntime.data?.byedpi_installed) === 1
                ? 1
                : 0,
            server_inbounds_enabled_count:
              inboundsConfig?.success &&
              typeof inboundsConfig.data?.enabled_count !== "undefined"
                ? inboundsConfig.data.enabled_count
                : -1,
          });
        },
      );
    };

    const loadUiCapabilities = function () {
      if (uiCapabilities.loaded) {
        return Promise.resolve(uiCapabilities);
      }

      if (uiCapabilitiesPromise) {
        return uiCapabilitiesPromise;
      }

      uiCapabilitiesPromise = main.PodkopShellMethods.getUiCapabilities()
        .then((response) => {
          if (!response?.success) {
            throw new Error("UI capabilities request failed");
          }

          return updateUiCapabilities(response.data);
        })
        .catch((error) => {
          console.warn("Failed to load Podkop Plus UI capabilities", error);
          return loadFallbackUiCapabilities();
        })
        .finally(() => {
          uiCapabilitiesPromise = null;
        });

      return uiCapabilitiesPromise;
    };
    let initialUiDataPromise = null;
    const loadInitialUiData = function () {
      if (initialUiDataPromise) {
        return initialUiDataPromise;
      }

      initialUiDataPromise = loadUiCapabilities()
        .then(() => {
          if (typeof server.preloadServerModalData === "function") {
            return server.preloadServerModalData();
          }
          return null;
        })
        .catch(() => null)
        .finally(() => {
          initialUiDataPromise = null;
        });

      return initialUiDataPromise;
    };

    const podkopMap = new form.Map(
      UCI_PACKAGE,
      _("Podkop Plus Settings"),
      _("Configuration for Podkop Plus service"),
    );
    podkopMap.tabbed = true;

    const rulesSection = podkopMap.section(
      form.GridSection,
      "section",
      _("Sections"),
      _("Drag rows to change priority. The rule at the top is checked first."),
    );
    configureGridSection(
      rulesSection,
      "section",
      _("Section"),
      _("Add a section"),
    );
    section.configureSectionSection(rulesSection, {
      loadActionProvidersAvailability: loadUiCapabilities,
    });
    section.createSectionContent(rulesSection);

    const serverSection = podkopMap.section(
      form.GridSection,
      "server",
      _("Servers"),
      _("Accept external proxy connections and route them with sing-box."),
    );
    configureGridSection(
      serverSection,
      "server",
      _("Server"),
      _("Add a server inbound"),
    );
    serverSectionRef = serverSection;
    server.configureServerSection(serverSection, {
      loadCapabilities: loadUiCapabilities,
    });
    server.createServerContent(serverSection, uiCapabilities);

    const settingsSection = podkopMap.section(
      form.TypedSection,
      "settings",
      _("Settings"),
    );
    settingsSection.anonymous = true;
    settingsSection.addremove = false;
    settingsSection.cfgsections = function () {
      return ["settings"];
    };
    settings.createSettingsContent(settingsSection);

    const diagnosticSection = podkopMap.section(
      form.TypedSection,
      "diagnostic",
      _("Diagnostics"),
    );
    diagnosticSection.anonymous = true;
    diagnosticSection.addremove = false;
    diagnosticSection.cfgsections = function () {
      return ["diagnostic"];
    };
    diagnostic.createDiagnosticContent(diagnosticSection);

    const dashboardSection = podkopMap.section(
      form.TypedSection,
      "dashboard",
      _("Dashboard"),
    );
    dashboardSection.anonymous = true;
    dashboardSection.addremove = false;
    dashboardSection.cfgsections = function () {
      return ["dashboard"];
    };
    dashboard.createDashboardContent(dashboardSection);

    const monitoringSection = podkopMap.section(
      form.TypedSection,
      "monitoring",
      _("Monitoring"),
    );
    monitoringSection.anonymous = true;
    monitoringSection.addremove = false;
    monitoringSection.cfgsections = function () {
      return ["monitoring"];
    };
    monitoring.createMonitoringContent(monitoringSection);

    const updatesSection = podkopMap.section(
      form.TypedSection,
      "updates",
      _("Updates"),
    );
    updatesSection.anonymous = true;
    updatesSection.addremove = false;
    updatesSection.cfgsections = function () {
      return ["updates"];
    };
    updates.createUpdatesContent(updatesSection);

    const rendered = await podkopMap.render();
    main.coreService({
      waitForLogWatcherStart: loadInitialUiData,
      logWatcherStartDelayMs: 5000,
    });
    window.setTimeout(() => {
      loadInitialUiData().catch(() => null);
    }, 0);

    return rendered;
  },
};

return view.extend(EntryPoint);
