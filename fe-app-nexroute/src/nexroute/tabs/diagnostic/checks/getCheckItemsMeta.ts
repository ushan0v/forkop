import { IDiagnosticsChecksItem } from '../../../services';

export function getCheckItemsMeta(items: IDiagnosticsChecksItem[]): {
  description: string;
  state: 'warning' | 'success' | 'error';
} {
  if (items.some((item) => item.state === 'error')) {
    return {
      state: 'error',
      description: _('Checks failed'),
    };
  }

  if (items.some((item) => item.state === 'warning')) {
    return {
      state: 'warning',
      description: _('Issues detected'),
    };
  }

  return {
    state: 'success',
    description: _('Checks passed'),
  };
}
