import { Nexroute } from '../../types';
import { NEXROUTE_UCI_PACKAGE } from '../../../constants';

export async function getConfigSections(): Promise<Nexroute.ConfigSection[]> {
  return uci
    .load(NEXROUTE_UCI_PACKAGE)
    .then(() => uci.sections(NEXROUTE_UCI_PACKAGE));
}
