"use strict";
"require baseclass";
"require form";
"require ui";
"require uci";
"require fs";
"require view.forkop.main as main";

function createUpdatesContent(section) {
  const o = section.option(form.DummyValue, "_mount_node");
  o.rawhtml = true;
  o.cfgvalue = () => {
    main.UpdatesTab.initController();
    return main.UpdatesTab.render();
  };
}

const EntryPoint = {
  createUpdatesContent,
};

return baseclass.extend(EntryPoint);
