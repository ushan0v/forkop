"use strict";
"require baseclass";
"require form";
"require view.forkop.local_devices as localDevices";
"require view.forkop.main as main";

function createMonitoringContent(section) {
  const o = section.option(form.DummyValue, "_mount_node");
  o.rawhtml = true;
  o.cfgvalue = () => {
    main.MonitoringTab.initController({
      loadLocalDeviceChoices: localDevices.loadLocalDeviceChoices,
    });
    return main.MonitoringTab.render();
  };
}

const EntryPoint = {
  createMonitoringContent,
};

return baseclass.extend(EntryPoint);
