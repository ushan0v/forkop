import { renderButton } from '../../../../partials';
import { renderSearchIcon24 } from '../../../../icons';

interface IRenderDiagnosticRunActionProps {
  loading: boolean;
  disabled?: boolean;
  click: () => void;
}

export function renderRunAction({
  loading,
  disabled,
  click,
}: IRenderDiagnosticRunActionProps) {
  return E('div', { class: 'fkp_diagnostic-page__run_check_wrapper' }, [
    renderButton({
      text: _('Run Diagnostic'),
      onClick: click,
      icon: renderSearchIcon24,
      loading,
      disabled,
      classNames: ['cbi-button-apply'],
    }),
  ]);
}
