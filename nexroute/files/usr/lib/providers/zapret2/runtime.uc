#!/usr/bin/env ucode

let runtime = require("providers.nfqueue.runtime");
let provider = require("providers.zapret2.common");

runtime.run(provider, ARGV);
