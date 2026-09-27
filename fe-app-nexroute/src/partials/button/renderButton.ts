import { insertIf } from '../../helpers';
import { renderLoaderCircleIcon24 } from '../../icons';

interface IRenderButtonProps {
  classNames?: string[];
  disabled?: boolean;
  loading?: boolean;
  icon?: () => SVGSVGElement;
  onClick: () => void;
  text: string;
}

export function renderButton({
  classNames = [],
  disabled,
  loading,
  onClick,
  text,
  icon,
}: IRenderButtonProps) {
  const hasIcon = !!loading || !!icon;

  function getWrappedIcon() {
    const iconWrap = E('span', {
      class: 'fkp-partial-button__icon',
    });

    if (loading) {
      iconWrap.appendChild(renderLoaderCircleIcon24());

      return iconWrap;
    }

    if (icon) {
      iconWrap.appendChild(icon());

      return iconWrap;
    }

    return iconWrap;
  }

  function getClass() {
    return [
      'btn',
      'fkp-partial-button',
      ...insertIf(Boolean(disabled), ['fkp-partial-button--disabled']),
      ...insertIf(Boolean(loading), ['fkp-partial-button--loading']),
      ...insertIf(Boolean(hasIcon), ['fkp-partial-button--with-icon']),
      ...classNames,
    ]
      .filter(Boolean)
      .join(' ');
  }

  function getDisabled() {
    if (loading || disabled) {
      return true;
    }

    return undefined;
  }

  return E(
    'button',
    {
      type: 'button',
      class: getClass(),
      disabled: getDisabled(),
      click: onClick,
    },
    [...insertIf(hasIcon, [getWrappedIcon()]), E('span', {}, text)],
  );
}
