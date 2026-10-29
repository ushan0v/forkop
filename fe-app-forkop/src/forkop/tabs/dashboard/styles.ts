// language=CSS
import {
  FORKOP_UCI_PACKAGE as FORKOP_CBI_PREFIX,
  MONOSPACE_FONT,
} from '../../../constants';

export const styles = `
@font-face {
    font-family: "Twemoji Country Flags";
    src: url("/luci-static/resources/view/forkop/fonts/TwemojiCountryFlags.woff2") format("woff2");
    font-display: swap;
    font-style: normal;
    font-weight: normal;
    unicode-range: U+1F1E6-1F1FF, U+1F3F4, U+E0062-E0063, U+E0065, U+E0067, U+E006C, U+E006E, U+E0073-E0074, U+E0077, U+E007F;
}

#cbi-${FORKOP_CBI_PREFIX}-dashboard-_mount_node,
.fkp_dashboard-page {
    box-sizing: border-box;
    width: 100% !important;
    min-width: 0 !important;
    max-width: 100% !important;
}

/* A DummyValue's value sits in an <output> inside the theme's flex row; this makes the page
fill the column. */
#cbi-${FORKOP_CBI_PREFIX}-dashboard-_mount_node {
    display: block !important;
}

#cbi-${FORKOP_CBI_PREFIX}-dashboard > h3 {
    display: none;
}

/* Columns follow the page's width, not the window's: a theme sidebar leaves far less. */
.fkp_dashboard-page {
    width: 100%;
    container-type: inline-size;
}

.fkp_dashboard-page__content {
    --dashboard-grid-columns: 1;
    --dashboard-grid-min-width: 0;
    --dashboard-widget-columns: 2;
}

@container (min-width: 480px) {
    .fkp_dashboard-page__content {
        --dashboard-grid-columns: 2;
        --dashboard-grid-min-width: 180px;
    }
}

@container (min-width: 750px) {
    .fkp_dashboard-page__content {
        --dashboard-grid-columns: 4;
        --dashboard-widget-columns: 4;
    }
}

.fkp_dashboard-page__widgets-section {
    margin-top: 10px;
    display: grid;
    grid-template-columns: repeat(var(--dashboard-widget-columns), minmax(0, 1fr));
    grid-gap: 10px;
}

.fkp_dashboard-page__widgets-section__item {
    box-sizing: border-box;
    height: 100%;
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    padding: 10px;
    min-width: 0;
}

.fkp_dashboard-page__toolbar {
    margin-top: 10px;
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
}

/* A header band in the outline's colour marks where each section starts. */
.fkp_dashboard-page__outbound-section {
    margin-top: 12px;
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
}

.fkp_dashboard-page__outbound-section__title-section {
    position: relative;
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 6px 10px;
    min-width: 0;
    padding: 6px 8px 6px 10px;
    background: var(--background-color-low, lightgray);
}

.fkp_dashboard-page__outbound-section__title-section--foldable {
    cursor: pointer;
}

.fkp_dashboard-page__outbound-section__heading {
    flex: 1 1 auto;
    display: flex;
    align-items: center;
    gap: 4px 10px;
    min-width: 0;
}

.fkp_dashboard-page__outbound-section__title-section__title {
    color: var(--text-color-highest, inherit);
    font-size: 1.15em;
    font-weight: 700;
    line-height: 1.3;
    min-width: 0;
    overflow-wrap: anywhere;
}

.fkp_dashboard-page__outbound-section__current {
    display: inline-flex;
    align-items: baseline;
    gap: 6px;
    min-width: 0;
    padding-left: 10px;
    border-left: 1px solid var(--border-color-high, color-mix(in srgb, currentColor 30%, transparent));
    color: var(--text-color-medium, inherit);
    line-height: 1.3;
}

.fkp_dashboard-page__outbound-section__current-name {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.fkp_dashboard-page__outbound-section__title-section__actions {
    display: flex;
    align-items: center;
    justify-content: flex-start;
    flex-wrap: wrap;
    gap: 6px;
    flex: 0 0 auto;
    max-width: 100%;
}

.fkp_dashboard-page .btn.fkp_dashboard-page__outbound-section__sort-by-latency,
.fkp_dashboard-page .btn.dashboard-sections-grid-item-test-latency {
    width: 28px;
    height: 28px;
    min-width: 28px;
    min-height: 28px;
    padding: 0;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex: 0 0 auto;
}

.fkp_dashboard-page__outbound-section__sort-by-latency svg,
.fkp_dashboard-page .btn.fkp_dashboard-page__outbound-section__exit svg,
.fkp_dashboard-page .btn.dashboard-sections-grid-item-test-latency svg {
    width: 15px;
    height: 15px;
    display: block;
}

.fkp_dashboard-page .btn.fkp_dashboard-page__outbound-section__sort-by-latency--active {
    background: color-mix(in srgb, currentColor 14%, transparent) !important;
}

/* A quiet icon after the section's choice, drawn like the fold chevron. */
.fkp_dashboard-page .btn.fkp_dashboard-page__outbound-section__exit {
    width: 24px;
    height: 24px;
    min-width: 24px;
    min-height: 24px;
    margin-left: -4px;
    padding: 0;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex: 0 0 auto;
    background: transparent !important;
    border: none !important;
    border-radius: 4px;
    box-shadow: none !important;
    color: inherit;
    opacity: 0.55;
    transition: opacity 0.15s ease;
}

.fkp_dashboard-page .btn.fkp_dashboard-page__outbound-section__exit:hover,
.fkp_dashboard-page .btn.fkp_dashboard-page__outbound-section__exit:focus-visible,
.fkp_dashboard-page .btn.fkp_dashboard-page__outbound-section__exit--open {
    opacity: 1;
}

.fkp_dashboard-page .btn.fkp_dashboard-page__outbound-section__exit:hover,
.fkp_dashboard-page .btn.fkp_dashboard-page__outbound-section__exit--open {
    background: color-mix(in srgb, currentColor 14%, transparent) !important;
}

/* Hangs from the left end of the header band, under the node it describes, as a theme's open
dropdown does; it carries the section's own outline and header band. */
.fkp_dashboard-page__exit-panel {
    position: absolute;
    top: calc(100% + 4px);
    left: 8px;
    z-index: 20;
    box-sizing: border-box;
    width: 320px;
    max-width: calc(100% - 16px);
    padding: 0 12px 10px;
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    background: var(--background-color-high, Canvas);
    box-shadow: 0 6px 18px rgba(0, 0, 0, 0.18);
    color: var(--text-color-high, inherit);
    cursor: default;
    line-height: 1.35;
}

.fkp_dashboard-page__exit-panel__header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    margin: 0 -12px 10px;
    padding: 6px 6px 6px 12px;
    background: var(--background-color-low, lightgray);
}

.fkp_dashboard-page__exit-panel__heading {
    display: flex;
    flex-direction: column;
    min-width: 0;
}

.fkp_dashboard-page__exit-panel__caption {
    color: var(--text-color-medium, inherit);
    font-size: 0.85em;
}

.fkp_dashboard-page__exit-panel__node {
    color: var(--text-color-highest, inherit);
    font-weight: 700;
    overflow-wrap: anywhere;
}

.fkp_dashboard-page .btn.fkp_dashboard-page__exit-panel__icon-button {
    width: 26px;
    height: 26px;
    min-width: 26px;
    min-height: 26px;
    padding: 0;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex: 0 0 auto;
}

.fkp_dashboard-page__exit-panel__icon-button svg {
    width: 14px;
    height: 14px;
    display: block;
}

.fkp_dashboard-page__exit-panel__facts {
    display: grid;
    grid-template-columns: auto minmax(0, 1fr);
    align-items: center;
    gap: 6px 16px;
    margin: 0;
    transition: opacity 0.15s ease;
}

.fkp_dashboard-page__exit-panel__facts--stale {
    opacity: 0.5;
}

.fkp_dashboard-page__exit-panel__facts > dt {
    margin: 0;
    color: var(--text-color-medium, inherit);
    font-weight: normal;
}

.fkp_dashboard-page__exit-panel__facts > dd {
    display: flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
    min-height: 26px;
    margin: 0;
}

.fkp_dashboard-page__exit-panel__address {
    flex: 1 1 auto;
    min-width: 0;
    color: var(--text-color-highest, inherit);
    font-family: ${MONOSPACE_FONT};
    font-size: 1.05em;
    overflow-wrap: anywhere;
    user-select: all;
}

.fkp_dashboard-page__exit-panel__missing,
.fkp_dashboard-page__exit-panel__family-note {
    color: var(--text-color-medium, inherit);
}

.fkp_dashboard-page__exit-panel__missing[title] {
    cursor: help;
    text-decoration: underline dotted;
    text-underline-offset: 3px;
}

.fkp_dashboard-page__exit-panel__family-note {
    margin-left: 6px;
}

.fkp_dashboard-page__exit-panel__country {
    display: inline-flex;
    align-items: baseline;
    gap: 6px;
}

.fkp_dashboard-page__exit-panel__footer {
    margin-top: 10px;
    padding-top: 8px;
    border-top: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.25));
    font-size: 0.9em;
}

.fkp_dashboard-page__exit-panel__footer a {
    color: var(--primary-color-high, #337ab7);
}

.fkp_dashboard-page__exit-panel__status {
    display: flex;
    align-items: center;
    gap: 8px;
    min-height: 26px;
    color: var(--text-color-medium, inherit);
}

.fkp_dashboard-page__exit-panel__status svg {
    width: 16px;
    height: 16px;
    flex: 0 0 auto;
}

.fkp_dashboard-page__exit-panel__status--error {
    color: var(--error-color-medium, red);
    overflow-wrap: anywhere;
}

.fkp_dashboard-page .btn.fkp_dashboard-page__outbound-section__collapse {
    width: 22px;
    height: 22px;
    min-width: 22px;
    min-height: 22px;
    margin: 0 -6px 0 -6px;
    padding: 0;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex: 0 0 auto;
    background: transparent !important;
    border: none !important;
    box-shadow: none !important;
    color: inherit;
    opacity: 0.55;
    transition: opacity 0.15s ease;
}

.fkp_dashboard-page__outbound-section__title-section--foldable:hover .btn.fkp_dashboard-page__outbound-section__collapse,
.fkp_dashboard-page .btn.fkp_dashboard-page__outbound-section__collapse:focus-visible {
    opacity: 1;
}

.fkp_dashboard-page__outbound-section__collapse svg {
    width: 16px;
    height: 16px;
    display: block;
    transform: rotate(180deg);
    transition: transform 0.15s ease;
}

.fkp_dashboard-page__outbound-section__collapse--collapsed svg {
    transform: rotate(90deg);
}

.fkp_dashboard-page .btn.dashboard-sections-grid-item-test-latency[disabled] {
    cursor: not-allowed;
    opacity: 0.65;
}

.fkp_dashboard-page__outbound-grid {
    padding: 10px;
    display: grid;
    grid-template-columns: repeat(var(--dashboard-grid-columns), minmax(var(--dashboard-grid-min-width), 1fr));
    grid-gap: 8px;
}

.fkp_dashboard-page__subscription-meta {
    grid-column: 1 / -1;
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    padding: 8px 10px;
    background: var(--background-color-high, transparent);
}

.fkp_dashboard-page__subscription-meta__main {
    display: flex;
    align-items: center;
    gap: 6px 10px;
    min-width: 0;
}

/* The facts wrap when the row is short of room; the name keeps its words on one line. */
.fkp_dashboard-page__subscription-meta__name {
    flex: 0 0 auto;
    display: flex;
    align-items: center;
    gap: 0.4rem;
    min-width: 0;
    max-width: min(36ch, 40%);
}

.fkp_dashboard-page__subscription-meta__heading {
    flex: 0 0 auto;
    color: var(--text-color-high);
    font-weight: 700;
    line-height: 1.25;
    white-space: nowrap;
}

/* The tag's own right margin is for node names; here the flex gap separates it. */
.fkp_dashboard-page__subscription-meta__heading
    .fkp_dashboard-page__outbound-grid__item__subscription-tag {
    margin-right: 0;
}

.fkp_dashboard-page__subscription-meta__title {
    min-width: 0;
    color: var(--text-color-high);
    font-weight: 700;
    line-height: 1.25;
    overflow-wrap: anywhere;
}

.fkp_dashboard-page__subscription-meta__facts {
    flex: 0 1 auto;
    min-width: 0;
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 5px 12px;
}

.fkp_dashboard-page__subscription-meta__fact {
    display: flex;
    align-items: baseline;
    gap: 4px;
    min-width: 0;
    line-height: 1.25;
}

.fkp_dashboard-page__subscription-meta__fact-key {
    color: var(--text-color-medium);
    font-size: 12px;
    white-space: nowrap;
}

.fkp_dashboard-page__subscription-meta__fact-value {
    color: var(--text-color-high);
    font-weight: 600;
    overflow-wrap: anywhere;
}

.fkp_dashboard-page__subscription-meta__actions {
    flex: 0 0 auto;
    display: flex;
    justify-content: flex-start;
    gap: 8px;
}

.fkp_dashboard-page__subscription-meta__action {
    color: var(--text-color-medium, #888);
    font-size: 12px;
    text-decoration: none;
    transition: color 0.15s ease;
}

.fkp_dashboard-page__subscription-meta__action:hover,
.fkp_dashboard-page__subscription-meta__action:focus-visible {
    color: var(--primary-color-high, #337ab7);
    text-decoration: underline;
    text-underline-offset: 3px;
}

.fkp_dashboard-page__subscription-meta__updated {
    margin-left: auto;
    color: var(--text-color-medium, #888);
    font-size: 12px;
    white-space: nowrap;
}

.fkp_dashboard-page__subscription-meta__announce {
    margin: 6px 0 0;
    border-left: 2px solid var(--primary-color-low, dodgerblue);
    border-radius: 0 3px 3px 0;
    padding: 4px 8px;
    background: color-mix(in srgb, var(--background-color-low, rgba(0, 0, 0, 0.04)) 55%, transparent);
    color: var(--text-color-medium);
    font-style: italic;
    line-height: 1.25;
    overflow-wrap: anywhere;
}

@container (max-width: 639px) {
    .fkp_dashboard-page__subscription-meta__main {
        align-items: flex-start;
        flex-wrap: wrap;
    }

    .fkp_dashboard-page__subscription-meta__name {
        order: 1;
    }

    .fkp_dashboard-page__subscription-meta__actions,
    .fkp_dashboard-page__subscription-meta__updated {
        order: 2;
    }

    .fkp_dashboard-page__subscription-meta__facts {
        order: 3;
        flex-basis: 100%;
    }

    .fkp_dashboard-page__subscription-meta__name {
        max-width: calc(100% - 42px);
    }
}

.fkp_dashboard-page__outbound-grid__item {
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    padding: 8px 10px;
    transition: border 0.2s ease;
    min-width: 0;
    position: relative;
    display: flex;
    flex-direction: column;
}

.fkp_dashboard-page__outbound-grid__item--selectable {
    cursor: pointer;
}

.fkp_dashboard-page__outbound-grid__item--selectable:hover {
    border-color: var(--primary-color-high, dodgerblue);
}

.fkp_dashboard-page__outbound-grid__item--active {
    border-color: var(--success-color-medium, green);
}

.fkp_dashboard-page__outbound-grid__item--disabled {
    cursor: default;
}

.fkp_dashboard-page__outbound-grid__item__header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 8px;
}

.fkp_dashboard-page__outbound-grid__item__header b {
    min-width: 0;
    line-height: 1.25;
    overflow-wrap: anywhere;
}

.fkp_dashboard-page__outbound-grid__item__subscription-tag {
  display: inline-block;
  margin-right: 0.4rem;
  padding: 0.1rem 0.35rem;
  border-radius: 0.25rem;
  font-size: 0.72rem;
  font-weight: 400;
  line-height: 1.2;
  vertical-align: 0.08rem;
}

.fkp_dashboard-page .btn.fkp_dashboard-page__outbound-grid__item__copy-button {
    width: 22px;
    height: 22px;
    min-width: 22px;
    min-height: 22px;
    padding: 1px;
    box-sizing: border-box;
    display: flex;
    align-items: center;
    justify-content: center;
    flex: 0 0 auto;
    line-height: 1;
}

.fkp_dashboard-page__outbound-grid__item__copy-button svg {
    width: 13px;
    height: 13px;
    display: block;
    flex: 0 0 auto;
}

.fkp_dashboard-page__outbound-grid__item__footer {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(42px, max-content);
    align-items: center;
    gap: 8px;
    margin-top: auto;
    padding-top: 6px;
}

.fkp_dashboard-page__outbound-grid__item__type {
    min-width: 0;
    overflow-wrap: anywhere;
    color: var(--text-color-medium, inherit);
}

.fkp_dashboard-page .btn.fkp_dashboard-page__outbound-grid__item__latency {
    background: transparent !important;
    border: none !important;
    box-shadow: none !important;
    padding: 0 !important;
    margin-right: 0 !important;
    text-decoration: none !important;
    font: inherit;
    line-height: inherit;
    justify-self: end;
    display: inline-flex;
    align-items: center;
    justify-content: flex-end;
    gap: 4px;
    cursor: pointer;
    transition: color 0.15s ease, opacity 0.15s ease !important;
}

.fkp_dashboard-page .btn.fkp_dashboard-page__outbound-grid__item__latency:hover,
.fkp_dashboard-page .btn.fkp_dashboard-page__outbound-grid__item__latency:focus-visible {
    background: transparent !important;
    color: var(--primary-color-high, #337ab7) !important;
}

.fkp_dashboard-page__outbound-grid__item__latency {
    min-width: 42px;
    justify-self: end;
    text-align: right;
}

.fkp_dashboard-page__outbound-grid__item__latency svg {
    width: 14px;
    height: 14px;
    flex: 0 0 auto;
}

.fkp_dashboard-page__outbound-grid__item__latency--empty {
    color: var(--primary-color-low, lightgray);
}

.fkp_dashboard-page__outbound-grid__item__latency--green {
    color: var(--success-color-medium, green);
}

.fkp_dashboard-page .btn.fkp_dashboard-page__outbound-grid__item__latency--green:hover,
.fkp_dashboard-page .btn.fkp_dashboard-page__outbound-grid__item__latency--green:focus-visible {
    opacity: 0.7 !important;
    color: var(--success-color-medium, green) !important;
}

.fkp_dashboard-page__outbound-grid__item__latency--yellow {
    color: var(--warn-color-medium, orange);
}

.fkp_dashboard-page .btn.fkp_dashboard-page__outbound-grid__item__latency--yellow:hover,
.fkp_dashboard-page .btn.fkp_dashboard-page__outbound-grid__item__latency--yellow:focus-visible {
    opacity: 0.7 !important;
    color: var(--warn-color-medium, orange) !important;
}

.fkp_dashboard-page__outbound-grid__item__latency--red {
    color: var(--error-color-medium, red);
}

.fkp_dashboard-page .btn.fkp_dashboard-page__outbound-grid__item__latency--red:hover,
.fkp_dashboard-page .btn.fkp_dashboard-page__outbound-grid__item__latency--red:focus-visible {
    opacity: 0.7 !important;
    color: var(--error-color-medium, red) !important;
}

.fkp_dashboard-page__urltest-details {
    box-sizing: border-box;
    width: min(760px, calc(100vw - 56px));
    max-width: 100%;
    padding-top: 10px;
}

.fkp_dashboard-page__urltest-details__params {
    display: grid;
    grid-template-columns: minmax(120px, max-content) minmax(0, 1fr);
    gap: 8px 16px;
    margin: 0 0 18px;
}

.fkp_dashboard-page__urltest-details__param {
    display: contents;
}

.fkp_dashboard-page__urltest-details__param dt {
    color: var(--text-color-medium, #666);
    line-height: 1.35;
}

.fkp_dashboard-page__urltest-details__param dd {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
    margin: 0;
}

.fkp_dashboard-page__urltest-details__param dd span {
    min-width: 0;
    overflow-wrap: anywhere;
}

.fkp_dashboard-page__urltest-details__url {
    min-width: 0;
    color: var(--primary-color-high, #337ab7);
    text-decoration: none;
    overflow-wrap: anywhere;
}

.fkp_dashboard-page__urltest-details__url:hover {
    text-decoration: underline;
}

.fkp_dashboard-page__urltest-details__selected-value {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
    max-width: 100%;
    padding: 0;
    border: 0;
    color: inherit;
    background: transparent;
    box-sizing: border-box;
    line-height: 1.3;
}

.fkp_dashboard-page__urltest-details__selected-name {
    min-width: 0;
    font-weight: 600;
    overflow-wrap: anywhere;
}

.fkp_dashboard-page__urltest-details__selected-type {
    color: var(--text-color-medium, #666);
}

.fkp_dashboard-page__urltest-details__outbounds-title {
    margin-bottom: 8px;
    font-weight: 600;
}

.fkp_dashboard-page__urltest-details__table {
    display: grid;
    gap: 6px;
    width: calc(100% + 14px);
    box-sizing: border-box;
    max-height: min(46vh, 460px);
    overflow-x: hidden;
    overflow-y: auto;
    padding-right: 14px;
    scrollbar-gutter: auto;
}

/* Name and latency side by side while both fit, stacked when they do not; each row decides by
its own name's length. */
.fkp_dashboard-page__urltest-details__row {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    column-gap: 8px;
    width: 100%;
    min-width: 0;
    padding: 7px 8px;
    box-sizing: border-box;
    border: 1px solid transparent;
    border-bottom: 1px solid var(--border-color-low, #eee);
    border-radius: 4px;
}

.fkp_dashboard-page__urltest-details__row--active {
    border-color: var(--success-color-low, #2d7d46);
    background: transparent;
}

.fkp_dashboard-page__urltest-details__row--selectable {
    cursor: pointer;
}

.fkp_dashboard-page__urltest-details__row--selectable:hover,
.fkp_dashboard-page__urltest-details__row--selectable:focus-visible {
    border-color: var(--primary-color-high, dodgerblue);
    outline: none;
}

.fkp_dashboard-page__urltest-details__row--busy {
    cursor: progress;
    opacity: 0.6;
}

.fkp_dashboard-page__urltest-details__row-pin {
    display: inline-flex;
    align-items: center;
    flex: none;
    color: var(--success-color-medium, green);
}

.fkp_dashboard-page__urltest-details__row-pin svg {
    width: 14px;
    height: 14px;
}

.fkp_dashboard-page__urltest-details__hint {
    margin-bottom: 6px;
    color: var(--text-color-medium, #666);
    font-size: 12px;
    line-height: 1.35;
}

.fkp_dashboard-page__urltest-details__row-name,
.fkp_dashboard-page__urltest-details__row-meta {
    display: flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
    line-height: 1.3;
}

.fkp_dashboard-page__urltest-details__row-name {
    flex: 1 1 auto;
    flex-wrap: wrap;
}

.fkp_dashboard-page__urltest-details__row-meta {
    flex: 0 0 auto;
    margin-left: auto;
}

.fkp_dashboard-page__urltest-details__row-name b {
    min-width: 0;
    overflow-wrap: anywhere;
    line-height: 1.3;
}

.fkp_dashboard-page__urltest-details__fallback-name {
    display: inline-flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 2px 0;
}

.fkp_dashboard-page__urltest-details__fallback-level {
    margin-right: 8px;
    padding: 2px 6px;
    border-radius: 4px;
    font-size: 11px;
    font-weight: 400;
}

.fkp_dashboard-page__outbound-grid__item__subscription-tag,
.fkp_dashboard-page__urltest-details__fallback-level {
    color: var(--text-color-medium);
    background: var(--background-color-low);
}

.fkp_dashboard-page__flag-emoji {
    font-family: "Twemoji Country Flags";
    font-style: normal;
    font-weight: normal;
}

.fkp_dashboard-page__urltest-details__fallback-node {
    color: var(--text-color-high, #fff);
    font-weight: 600;
}

.fkp_dashboard-page__urltest-details__row-type,
.fkp_dashboard-page__urltest-details__row-meta {
    color: var(--text-color-medium, #666);
}

.fkp_dashboard-page__urltest-details__row-type {
    white-space: nowrap;
    line-height: 1.3;
}

.fkp_dashboard-page__urltest-details__row-meta {
    justify-content: flex-end;
    white-space: nowrap;
}

.fkp_dashboard-page__urltest-details__empty {
    margin-top: 4px;
    padding: 24px 0;
    border: 1px dashed var(--border-color-high, #555);
    border-radius: 4px;
    color: var(--text-color-medium, #888);
    background: rgba(128, 128, 128, 0.02);
    font-style: italic;
    text-align: center;
}

.fkp_dashboard-page__urltest-details__footer {
    display: flex;
    justify-content: flex-start;
    margin-top: 14px;
}

/* Too narrow for the two-column parameter list. */
.fkp_dashboard-page__server-client__status {
    flex: 0 0 auto;
    color: var(--text-color-medium, inherit);
    white-space: nowrap;
}

.fkp_dashboard-page__server-client__status--online {
    color: var(--success-color-medium, green);
}

.fkp_dashboard-page__server-client__speed {
    justify-self: end;
    text-align: right;
    white-space: pre;
}

.fkp_dashboard-page__server-client__empty {
    padding: 10px;
    color: var(--text-color-medium, inherit);
}

@media (max-width: 560px) {
    .fkp_dashboard-page__urltest-details__params {
        grid-template-columns: 1fr;
    }
}

`;
