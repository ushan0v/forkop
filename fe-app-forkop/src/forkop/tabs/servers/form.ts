import { injectServerStyles } from './controls';
import { addClientListOption } from './form/clients';
import {
  addIdentityOptions,
  addJsonInboundOptions,
  addListenerOptions,
  addTailscaleOptions,
} from './form/identity';
import {
  addHysteria2Options,
  addMixedOptions,
  addProtocolOptions,
  addShadowsocksOptions,
  addTuicOptions,
} from './form/protocol';
import {
  addMultiplexOptions,
  addSecurityOptions,
  addTransportOptions,
  addVlessEncryptionOptions,
} from './form/security';
import { addOpenVPNServerOptions } from './form/openvpn';
import { addTunnelOptions } from './form/tunnel';
import { addAmneziaServerOptions } from './form/amnezia';
import { addRoutingOptions } from './routing';

export function createServerContent(section: CBISection) {
  injectServerStyles();

  // The cipher and the authentication switch come before the client list: they decide what a client needs.
  addIdentityOptions(section);
  addTailscaleOptions(section);
  addJsonInboundOptions(section);
  addListenerOptions(section);
  addOpenVPNServerOptions(section);
  addTunnelOptions(section);
  addShadowsocksOptions(section);
  addMixedOptions(section);
  addClientListOption(section);
  addRoutingOptions(section);
  addAmneziaServerOptions(section);
  addSecurityOptions(section);
  addVlessEncryptionOptions(section);
  addTransportOptions(section);
  addMultiplexOptions(section);
  addHysteria2Options(section);
  addTuicOptions(section);
  addProtocolOptions(section);
}
