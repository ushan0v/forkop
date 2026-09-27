const FLAG_EMOJI_PATTERN =
  /([\u{1f1e6}-\u{1f1ff}]{2}|\u{1f3f4}[\u{e0061}-\u{e007a}]+\u{e007f})/gu;
const EXACT_FLAG_EMOJI_PATTERN =
  /^([\u{1f1e6}-\u{1f1ff}]{2}|\u{1f3f4}[\u{e0061}-\u{e007a}]+\u{e007f})$/u;

export function renderFlagEmojis(value: string): (HTMLElement | string)[] {
  return value
    .split(FLAG_EMOJI_PATTERN)
    .filter(Boolean)
    .map((part) =>
      EXACT_FLAG_EMOJI_PATTERN.test(part)
        ? E(
            'span',
            { class: 'fkp_dashboard-page__flag-emoji' },
            part,
          )
        : part,
    );
}
