// language=CSS
import { PODKOP_CBI_PREFIX } from '../../../constants';

export const styles = `
#cbi-${PODKOP_CBI_PREFIX}-monitoring-_mount_node {
    margin: 16px 0 22px;
    padding: 0;
}

#cbi-${PODKOP_CBI_PREFIX}-monitoring-_mount_node > .cbi-value-title {
    display: none;
}

#cbi-${PODKOP_CBI_PREFIX}-monitoring-_mount_node > .cbi-value-field {
    margin-left: 0;
    width: 100%;
}

#cbi-${PODKOP_CBI_PREFIX}-monitoring-_mount_node > div {
    width: 100%;
}

#cbi-${PODKOP_CBI_PREFIX}-monitoring > h3 {
    display: none;
}

.pdk_monitoring-page {
    --pdk-monitoring-control-height: 34px;
    --pdk-monitoring-divider-color: rgba(127, 127, 127, 0.22);
    --pdk-monitoring-soft-bg: rgba(127, 127, 127, 0.08);
    --pdk-monitoring-soft-bg-hover: rgba(127, 127, 127, 0.14);

    width: 100%;
    min-width: 0;
}

.pdk_monitoring-page__panel {
    margin-top: 0;
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    padding: 10px;
    box-sizing: border-box;
    width: 100%;
    min-width: 0;
}

.pdk_monitoring-page .btn.pdk_monitoring-page__icon-button {
    width: var(--pdk-monitoring-control-height);
    height: var(--pdk-monitoring-control-height);
    min-width: var(--pdk-monitoring-control-height);
    min-height: var(--pdk-monitoring-control-height);
    padding: 0;
    box-sizing: border-box;
    display: flex;
    align-items: center;
    justify-content: center;
    flex: 0 0 auto;
    line-height: 1;
    margin: 0;
    border: 1px solid var(--pdk-monitoring-divider-color) !important;
    border-radius: 4px;
    background: var(--pdk-monitoring-soft-bg) !important;
    color: var(--text-color-medium) !important;
    box-shadow: none;
}

.pdk_monitoring-page .btn.pdk_monitoring-page__icon-button:hover:not(:disabled) {
    background: var(--pdk-monitoring-soft-bg-hover) !important;
    color: var(--text-color-high) !important;
}

.pdk_monitoring-page .btn.pdk_monitoring-page__icon-button--active {
    background: rgba(25, 118, 210, 0.16) !important;
    color: var(--primary-color-high, #1976d2) !important;
}

.pdk_monitoring-page .btn.pdk_monitoring-page__icon-button:disabled {
    opacity: 0.45;
    cursor: not-allowed;
}

.pdk_monitoring-page__icon-button svg,
.pdk_monitoring-page__row-action svg {
    width: 16px;
    height: 16px;
    display: block;
    flex: 0 0 auto;
}

.pdk_monitoring-page__controls {
    display: grid;
    grid-template-columns: auto minmax(0, 1fr) auto;
    align-items: center;
    justify-content: stretch;
    gap: 10px;
    width: 100%;
    min-width: 0;
}

.pdk_monitoring-page__actions {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 10px;
    min-width: 0;
}

.pdk_monitoring-page__tabs {
    display: inline-flex;
    align-items: center;
    gap: 2px;
    width: max-content;
    padding: 2px;
    border: 1px solid var(--pdk-monitoring-divider-color);
    border-radius: 6px;
    background: var(--pdk-monitoring-soft-bg);
    box-sizing: border-box;
}

.pdk_monitoring-page .btn.pdk_monitoring-page__tab {
    height: calc(var(--pdk-monitoring-control-height) - 6px);
    min-height: calc(var(--pdk-monitoring-control-height) - 6px);
    margin: 0;
    padding: 0 12px;
    border: 0 !important;
    border-radius: 4px;
    background: transparent !important;
    color: var(--text-color-medium) !important;
    box-shadow: none;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    font-weight: 600;
    line-height: 1;
}

.pdk_monitoring-page .btn.pdk_monitoring-page__tab:hover {
    background: var(--pdk-monitoring-soft-bg-hover) !important;
    color: var(--text-color-high) !important;
}

.pdk_monitoring-page .btn.pdk_monitoring-page__tab--active {
    background: rgba(25, 118, 210, 0.16) !important;
    color: var(--primary-color-high, #1976d2) !important;
    font-weight: 700;
}

.pdk_monitoring-page__tab-label {
    display: inline-block;
}

.pdk_monitoring-page__tab-badge {
    min-width: 18px;
    height: 18px;
    padding: 0 6px;
    border-radius: 999px;
    background: rgba(127, 127, 127, 0.22);
    color: var(--text-color-medium);
    display: inline-flex;
    align-items: center;
    justify-content: center;
    box-sizing: border-box;
    font-size: 12px;
    font-weight: 700;
    line-height: 1;
}

.pdk_monitoring-page__tab--active .pdk_monitoring-page__tab-badge {
    background: rgba(25, 118, 210, 0.22);
    color: var(--primary-color-high, #1976d2);
}

.pdk_monitoring-page__filters {
    display: grid;
    grid-template-columns: minmax(150px, 220px) minmax(200px, 320px);
    align-items: center;
    justify-content: flex-end;
    gap: 10px;
    min-width: 0;
}

.pdk_monitoring-page__device-filter {
    width: 100%;
    min-width: 0;
    height: var(--pdk-monitoring-control-height) !important;
    min-height: var(--pdk-monitoring-control-height) !important;
    padding-top: 0 !important;
    padding-bottom: 0 !important;
    margin: 0 !important;
    box-sizing: border-box;
    line-height: calc(var(--pdk-monitoring-control-height) - 2px) !important;
}

.pdk_monitoring-page__search {
    position: relative;
    display: flex;
    align-items: center;
    width: 100%;
    min-width: 0;
    height: var(--pdk-monitoring-control-height);
    margin: 0;
}

.pdk_monitoring-page__search-icon {
    position: absolute;
    left: 8px;
    width: 16px;
    height: 16px;
    color: var(--text-color-medium);
    pointer-events: none;
}

.pdk_monitoring-page__search-icon svg {
    width: 16px;
    height: 16px;
    display: block;
}

.pdk_monitoring-page__search-input {
    width: 100%;
    height: var(--pdk-monitoring-control-height) !important;
    min-height: var(--pdk-monitoring-control-height) !important;
    padding-left: 30px !important;
    padding-top: 0 !important;
    padding-bottom: 0 !important;
    margin: 0 !important;
    box-sizing: border-box;
    line-height: calc(var(--pdk-monitoring-control-height) - 2px) !important;
}

.pdk_monitoring-page__body {
    margin-top: 10px;
    width: 100%;
    min-width: 0;
}

.pdk_monitoring-page__table-wrap {
    width: 100%;
    overflow-x: auto;
}

.pdk_monitoring-page__table {
    width: 100%;
    min-width: 840px;
    table-layout: fixed;
    border-collapse: collapse;
    border-spacing: 0;
}

.pdk_monitoring-page__table th,
.pdk_monitoring-page__table td {
    padding: 8px 6px;
    border-bottom: 1px solid var(--pdk-monitoring-divider-color);
    box-sizing: border-box;
    text-align: center;
    vertical-align: middle;
    overflow: hidden;
    white-space: nowrap;
}

.pdk_monitoring-page__table th {
    color: var(--text-color-medium);
    font-weight: 700;
    white-space: nowrap;
    border-bottom-color: rgba(127, 127, 127, 0.32);
}

.pdk_monitoring-page__table th:nth-child(1) {
    width: 28%;
}

.pdk_monitoring-page__table th:nth-child(2) {
    width: 6%;
}

.pdk_monitoring-page__table th:nth-child(3) {
    width: 16%;
}

.pdk_monitoring-page__table th:nth-child(4) {
    width: 8%;
}

.pdk_monitoring-page__table th:nth-child(5) {
    width: 9.5%;
}

.pdk_monitoring-page__table th:nth-child(6) {
    width: 8.5%;
}

.pdk_monitoring-page__table th:nth-child(7) {
    width: 16%;
}

.pdk_monitoring-page__table th:nth-child(8) {
    width: 8%;
}

.pdk_monitoring-page__table tbody tr:last-child td {
    border-bottom: 0;
}

.pdk_monitoring-page__value {
    display: block;
    max-width: 100%;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    text-align: center;
    line-height: 1.3;
    color: var(--text-color-high);
    user-select: text;
}

.pdk_monitoring-page__source-value {
    display: flex;
    align-items: baseline;
    justify-content: center;
    gap: 5px;
}

.pdk_monitoring-page__source-name {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.pdk_monitoring-page__source-ip {
    flex: 0 1 auto;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--text-color-medium);
    font-size: 12px;
}

.pdk_monitoring-page__source-value--ip-only {
    color: var(--text-color-medium);
}

.pdk_monitoring-page__cell-main {
    color: var(--text-color-high);
    font-weight: 600;
    line-height: 1.25;
}

.pdk_monitoring-page__cell-secondary {
    margin-top: 2px;
    color: var(--text-color-medium);
    font-size: 12px;
    line-height: 1.25;
}

.pdk_monitoring-page__route {
    font-weight: 600;
}

.pdk_monitoring-page__network {
    text-transform: lowercase;
}

.pdk_monitoring-page .btn.pdk_monitoring-page__row-action {
    width: 28px;
    height: 28px;
    min-width: 28px;
    min-height: 28px;
    padding: 0;
    box-sizing: border-box;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    line-height: 1;
    margin: 0;
    border: 0 !important;
    border-radius: 999px;
    background: transparent !important;
    color: var(--text-color-medium) !important;
    box-shadow: none;
    cursor: pointer;
}

.pdk_monitoring-page .btn.pdk_monitoring-page__row-action:hover:not(:disabled) {
    background: var(--pdk-monitoring-soft-bg-hover) !important;
    color: var(--text-color-high) !important;
}

.pdk_monitoring-page .btn.pdk_monitoring-page__row-action:disabled {
    opacity: 0.45;
    cursor: wait;
}

.pdk_monitoring-page__row--closing {
    opacity: 0.55;
}

.pdk_monitoring-page__state {
    min-height: 90px;
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--text-color-medium);
    text-align: center;
    box-sizing: border-box;
}

.pdk_monitoring-page__state-cell {
    padding: 0 !important;
}

.pdk_monitoring-page__state--error {
    color: var(--error-color-medium, #d32f2f);
}

@media (max-width: 900px) {
    .pdk_monitoring-page__controls {
        grid-template-columns: 1fr auto;
    }

    .pdk_monitoring-page__tabs {
        grid-column: 1 / -1;
    }

    .pdk_monitoring-page__filters {
        grid-template-columns: minmax(150px, 220px) minmax(180px, 320px);
        justify-content: stretch;
    }

    .pdk_monitoring-page__device-filter,
    .pdk_monitoring-page__search {
        max-width: none;
    }

    .pdk_monitoring-page__table {
        min-width: 0;
    }

    .pdk_monitoring-page__table thead {
        display: none;
    }

    .pdk_monitoring-page__table,
    .pdk_monitoring-page__table tbody,
    .pdk_monitoring-page__table tr,
    .pdk_monitoring-page__table td {
        display: block;
        width: 100%;
    }

    .pdk_monitoring-page__table tr {
        border: 1px var(--background-color-low, lightgray) solid;
        border-radius: 4px;
        padding: 8px;
        box-sizing: border-box;
        margin-bottom: 8px;
    }

    .pdk_monitoring-page__table td {
        display: grid;
        grid-template-columns: minmax(92px, 34%) minmax(0, 1fr);
        gap: 8px;
        border: 0;
        border-bottom: 1px solid var(--pdk-monitoring-divider-color);
        padding: 4px 0;
        box-sizing: border-box;
        text-align: left;
    }

    .pdk_monitoring-page__table td::before {
        content: attr(data-label);
        color: var(--text-color-medium);
        font-weight: 700;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
    }

    .pdk_monitoring-page__table td:last-child {
        grid-template-columns: minmax(92px, 34%) minmax(0, 1fr);
        align-items: center;
        border-bottom: 0;
    }

    .pdk_monitoring-page__value {
        text-align: right;
    }

    .pdk_monitoring-page__source-value {
        justify-content: flex-end;
    }

    .pdk_monitoring-page__state-row td::before {
        display: none;
    }
}

@media (max-width: 520px) {
    .pdk_monitoring-page__controls,
    .pdk_monitoring-page__filters {
        align-items: stretch;
    }

    .pdk_monitoring-page__tabs,
    .pdk_monitoring-page__filters,
    .pdk_monitoring-page__device-filter,
    .pdk_monitoring-page__search {
        width: 100%;
    }

    .pdk_monitoring-page__controls,
    .pdk_monitoring-page__filters {
        grid-template-columns: 1fr;
    }

    .pdk_monitoring-page__tabs {
        display: grid;
        grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
        width: 100%;
    }

    .pdk_monitoring-page__table td {
        grid-template-columns: 1fr;
        gap: 2px;
    }

    .pdk_monitoring-page__value {
        text-align: left;
    }

    .pdk_monitoring-page__source-value {
        justify-content: flex-start;
    }
}
`;
