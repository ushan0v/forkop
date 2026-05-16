import { getCheckTitle } from '../helpers/getCheckTitle';

export enum DIAGNOSTICS_CHECKS {
  DNS = 'DNS',
  SINGBOX = 'SINGBOX',
  NFT = 'NFT',
  ZAPRET = 'ZAPRET',
  BYEDPI = 'BYEDPI',
  FAKEIP = 'FAKEIP',
  OUTBOUNDS = 'OUTBOUNDS',
}

export const DIAGNOSTICS_CHECKS_MAP: Record<
  DIAGNOSTICS_CHECKS,
  { order: number; title: string; code: DIAGNOSTICS_CHECKS }
> = {
  [DIAGNOSTICS_CHECKS.DNS]: {
    order: 1,
    title: getCheckTitle('DNS'),
    code: DIAGNOSTICS_CHECKS.DNS,
  },
  [DIAGNOSTICS_CHECKS.SINGBOX]: {
    order: 2,
    title: getCheckTitle('Sing-box'),
    code: DIAGNOSTICS_CHECKS.SINGBOX,
  },
  [DIAGNOSTICS_CHECKS.NFT]: {
    order: 3,
    title: getCheckTitle('Nftables'),
    code: DIAGNOSTICS_CHECKS.NFT,
  },
  [DIAGNOSTICS_CHECKS.ZAPRET]: {
    order: 4,
    title: getCheckTitle('Zapret'),
    code: DIAGNOSTICS_CHECKS.ZAPRET,
  },
  [DIAGNOSTICS_CHECKS.BYEDPI]: {
    order: 5,
    title: getCheckTitle('ByeDPI'),
    code: DIAGNOSTICS_CHECKS.BYEDPI,
  },
  [DIAGNOSTICS_CHECKS.OUTBOUNDS]: {
    order: 6,
    title: getCheckTitle('Outbounds'),
    code: DIAGNOSTICS_CHECKS.OUTBOUNDS,
  },
  [DIAGNOSTICS_CHECKS.FAKEIP]: {
    order: 7,
    title: getCheckTitle('FakeIP'),
    code: DIAGNOSTICS_CHECKS.FAKEIP,
  },
};
