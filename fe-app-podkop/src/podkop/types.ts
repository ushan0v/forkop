// eslint-disable-next-line @typescript-eslint/no-namespace
export namespace ClashAPI {
  export interface ProxyHistoryEntry {
    time: string;
    delay: number;
  }

  export interface ProxyBase {
    type: string;
    name: string;
    udp: boolean;
    history: ProxyHistoryEntry[];
    now?: string;
    all?: string[];
  }

  export interface Proxies {
    proxies: Record<string, ProxyBase>;
  }
}

// eslint-disable-next-line @typescript-eslint/no-namespace
export namespace Podkop {
  // Available commands:
  // start                   Start podkop service
  // stop                    Stop podkop service
  // reload                  Reload podkop configuration
  // restart                 Restart podkop service
  // enable                  Enable podkop autostart
  // disable                 Disable podkop autostart
  // uninstall               Remove podkop files installed outside opkg/apk
  // main                    Run main podkop process
  // list_update             Update domain lists
  // check_proxy             Check proxy connectivity
  // check_nft               Check NFT rules
  // check_nft_rules         Check NFT rules status
  // check_sing_box          Check sing-box installation and status
  // check_logs              Show podkop logs from system journal
  // check_sing_box_logs     Show sing-box logs
  // check_fakeip            Test sing-box FakeIP DNS
  // clash_api               Clash API interface for managing proxies and groups
  // show_config             Display current podkop configuration
  // show_version            Show podkop version
  // show_sing_box_config    Show sing-box configuration
  // show_sing_box_version   Show sing-box version
  // show_system_info        Show system information
  // get_status              Get podkop service status
  // get_sing_box_status     Get sing-box service status
  // check_dns_available     Check DNS server availability
  // global_check            Run global system check

  export enum AvailableMethods {
    CHECK_DNS_AVAILABLE = 'check_dns_available',
    CHECK_FAKEIP = 'check_fakeip',
    CHECK_NFT_RULES = 'check_nft_rules',
    CHECK_ZAPRET_RUNTIME = 'check_zapret_runtime',
    GET_STATUS = 'get_status',
    GET_OUTBOUND_LINK = 'get_outbound_link',
    GET_SUBSCRIPTION_METADATA = 'get_subscription_metadata',
    CHECK_SING_BOX = 'check_sing_box',
    GET_SING_BOX_STATUS = 'get_sing_box_status',
    GET_ZAPRET_STATUS = 'get_zapret_status',
    CLASH_API = 'clash_api',
    RESTART = 'restart',
    START = 'start',
    STOP = 'stop',
    ENABLE = 'enable',
    DISABLE = 'disable',
    GLOBAL_CHECK = 'global_check',
    SHOW_SING_BOX_CONFIG = 'show_sing_box_config',
    CHECK_LOGS = 'check_logs',
    CHECK_SING_BOX_LOGS = 'check_sing_box_logs',
    GET_SYSTEM_INFO = 'get_system_info',
    SUBSCRIPTION_UPDATE = 'subscription_update',
  }

  export enum AvailableClashAPIMethods {
    GET_PROXIES = 'get_proxies',
    GET_PROXY_LATENCY = 'get_proxy_latency',
    GET_GROUP_LATENCY = 'get_group_latency',
    SET_GROUP_PROXY = 'set_group_proxy',
  }

  export interface Outbound {
    code: string;
    displayName: string;
    latency: number;
    type: string;
    selected: boolean;
    link?: string;
    canCopyLink?: boolean;
  }

  export interface OutboundGroup {
    withTagSelect: boolean;
    code: string;
    sectionName: string;
    displayName: string;
    proxyConfigType?: ProxyConfigType;
    subscriptionMetadata?: SubscriptionMetadata;
    outbounds: Outbound[];
  }

  export interface SubscriptionTraffic {
    upload?: number;
    download?: number;
    used?: number;
    total?: number;
    remaining?: number;
    isUnlimited?: boolean;
  }

  export interface SubscriptionMetadata {
    version?: number;
    title?: string;
    traffic?: SubscriptionTraffic;
    expire?: number;
    refillDate?: number;
    webPageUrl?: string;
    supportUrl?: string;
    announce?: string;
    announceUrl?: string;
    fileName?: string;
  }

  export type RuleAction = 'proxy' | 'vpn' | 'direct' | 'block' | 'zapret';
  export type LegacyConnectionType = 'proxy' | 'vpn' | 'block' | 'exclusion';
  export type ProxyConfigType =
    | 'urltest'
    | 'selector'
    | 'url'
    | 'outbound'
    | 'interface'
    | 'subscription';

  export interface ConfigSection {
    '.name': string;
    '.type': 'settings' | 'rule' | 'node' | 'ruleset' | 'section';
    label?: string;
    enabled?: string;
    action?: RuleAction;
    connection_type?: LegacyConnectionType;
    proxy_config_type?: ProxyConfigType;
    node?: string;
    rule_set?: string[];
    rule_set_with_subnets?: string[];
    domain_ip_lists?: string[];
    update_interval?: string;
    proxy_string?: string;
    nfqws_opt?: string;
    selector_proxy_links?: string[];
    urltest_proxy_links?: string[];
    subscription_url?: string;
    subscription_user_agent?: string;
    subscription_update_interval?: string;
    subscription_update_interval_disabled?: '0' | '1';
    subscription_group_by_countries?: '0' | '1';
    urltest_check_interval_disabled?: '0' | '1';
    outbound_json?: string;
    interface?: string;
    yacd_secret_key?: string;
  }

  export interface MethodSuccessResponse<T> {
    success: true;
    data: T;
  }

  export interface MethodFailureResponse {
    success: false;
    error: string;
  }

  export type MethodResponse<T> =
    | MethodSuccessResponse<T>
    | MethodFailureResponse;

  export interface DnsCheckResult {
    dns_type: 'udp' | 'doh' | 'dot';
    dns_server: string;
    dns_status: 0 | 1;
    dns_on_router: 0 | 1;
    bootstrap_dns_server: string;
    bootstrap_dns_status: 0 | 1;
    dhcp_config_status: 0 | 1;
  }

  export interface NftRulesCheckResult {
    table_exist: 0 | 1;
    rules_mangle_exist: 0 | 1;
    rules_mangle_counters: 0 | 1;
    rules_mangle_output_exist: 0 | 1;
    rules_mangle_output_counters: 0 | 1;
    rules_proxy_exist: 0 | 1;
    rules_proxy_counters: 0 | 1;
    rules_other_mark_exist: 0 | 1;
  }

  export interface SingBoxCheckResult {
    sing_box_installed: 0 | 1;
    sing_box_version_ok: 0 | 1;
    sing_box_service_exist: 0 | 1;
    sing_box_autostart_disabled: 0 | 1;
    sing_box_process_running: 0 | 1;
    sing_box_ports_listening: 0 | 1;
  }

  export interface FakeIPCheckResult {
    fakeip: boolean;
    IP: string;
  }

  export interface GetStatus {
    running: number;
    enabled: number;
    status: string;
    dns_configured?: number;
    lifecycle_state?: string;
    lifecycle_action?: string;
    lifecycle_busy?: number;
    lifecycle_updated_at?: number;
    lifecycle_pid?: number;
  }

  export interface GetOutboundLink {
    link: string;
  }

  export interface GetSingBoxStatus {
    running: number;
    enabled: number;
    status: string;
  }

  export interface GetSystemInfo {
    podkop_version: string;
    podkop_latest_version: string;
    luci_app_version: string;
    sing_box_version: string;
    zapret_version: string;
    zapret_installed: 0 | 1;
    openwrt_version: string;
    device_model: string;
    generated_at?: number;
  }

  export interface GetZapretStatus {
    installed: 0 | 1;
    package_installed: 0 | 1;
    provider_available: 0 | 1;
    provider_path: string;
    files_available: 0 | 1;
    ipset_available: 0 | 1;
    version: string;
    configured: 0 | 1;
    enabled_rule_count: number;
    expected_process_count: number;
    running_process_count: number;
    supervisor_process_count: number;
    standalone_service_enabled: 0 | 1;
    standalone_service_running: 0 | 1;
    standalone_config_present: 0 | 1;
    standalone_conflict: 0 | 1;
    luci_app_installed: 0 | 1;
    queue_base: number;
    queue_range_end: number;
    queue_overlap: 0 | 1;
    legacy_runtime_present: 0 | 1;
    ready: 0 | 1;
    conflict: 0 | 1;
    status_message: string;
  }

  export interface ZapretCheckResult {
    zapret_installed: 0 | 1;
    zapret_package_installed: 0 | 1;
    zapret_provider_path: string;
  }

  export interface GetClashApiProxyLatency {
    delay: number;
    message?: string;
  }

  export type GetClashApiGroupLatency = Record<string, number>;
}
