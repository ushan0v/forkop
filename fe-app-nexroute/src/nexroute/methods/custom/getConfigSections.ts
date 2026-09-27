import { Forkop } from '../../types';
import { FORKOP_UCI_PACKAGE } from '../../../constants';

export async function getConfigSections(): Promise<Forkop.ConfigSection[]> {
  return uci
    .load(FORKOP_UCI_PACKAGE)
    .then(() => uci.sections(FORKOP_UCI_PACKAGE));
}
