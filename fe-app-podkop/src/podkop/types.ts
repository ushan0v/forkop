// eslint-disable-next-line @typescript-eslint/no-namespace
export namespace ClashAPI {
  interface ProxyHistoryEntry {
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
  // check_inbounds_config   Check whether enabled server inbounds are configured
  // check_inbounds          Check server inbounds from the Servers tab
  // check_logs              Show podkop logs from system journal
  // check_sing_box_logs     Show sing-box logs
  // check_fakeip            Test sing-box FakeIP DNS
  // clash_api               Clash API interface for managing proxies and groups
  // show_config             Display current podkop configuration
  // show_version            Show podkop version
  // show_sing_box_config    Show sing-box configuration
  // show_sing_box_version   Show sing-box version
  // get_status              Get podkop service status
  // get_sing_box_status     Get sing-box service status
  // get_ui_capabilities     Get lightweight UI capabilities
  // check_dns_available     Check DNS server availability
  // global_check            Run global system check

  export enum AvailableMethods {
    CHECK_DNS_AVAILABLE = 'check_dns_available',
    CHECK_FAKEIP = 'check_fakeip',
    CHECK_NFT_RULES = 'check_nft_rules',
    CHECK_ZAPRET_RUNTIME = 'check_zapret_runtime',
    CHECK_ZAPRET2_RUNTIME = 'check_zapret2_runtime',
    CHECK_BYEDPI_RUNTIME = 'check_byedpi_runtime',
    CHECK_INBOUNDS_CONFIG = 'check_inbounds_config',
    GET_STATUS = 'get_status',
    GET_OUTBOUND_LINK = 'get_outbound_link',
    GET_OUTBOUND_LINK_STATES = 'get_outbound_link_states',
    GET_OUTBOUND_METADATA = 'get_outbound_metadata',
    GET_SUBSCRIPTION_METADATA = 'get_subscription_metadata',
    CHECK_SING_BOX = 'check_sing_box',
    CHECK_INBOUNDS = 'check_inbounds',
    GET_SING_BOX_STATUS = 'get_sing_box_status',
    GET_ZAPRET_STATUS = 'get_zapret_status',
    GET_ZAPRET2_STATUS = 'get_zapret2_status',
    GET_BYEDPI_STATUS = 'get_byedpi_status',
    CLASH_API = 'clash_api',
    ENABLE = 'enable',
    DISABLE = 'disable',
    GLOBAL_CHECK = 'global_check',
    SHOW_SING_BOX_CONFIG = 'show_sing_box_config',
    CHECK_LOGS = 'check_logs',
    CHECK_SING_BOX_LOGS = 'check_sing_box_logs',
    GET_SYSTEM_INFO = 'get_system_info',
    GET_SERVER_CAPABILITIES = 'get_server_capabilities',
    GET_UI_CAPABILITIES = 'get_ui_capabilities',
    GET_UI_STATE = 'get_ui_state',
    SERVICE_ACTION_ASYNC = 'service_action_async',
    SERVICE_ACTION_STATUS = 'service_action_status',
    LATENCY_TEST_ASYNC = 'latency_test_async',
    LATENCY_TEST_STATUS = 'latency_test_status',
    UI_ACTION_ACK = 'ui_action_ack',
    COMPONENT_ACTION_ASYNC = 'component_action_async',
    COMPONENT_ACTION_STATUS = 'component_action_status',
    SUBSCRIPTION_UPDATE_ASYNC = 'subscription_update_async',
    SUBSCRIPTION_UPDATE_STATUS = 'subscription_update_status',
  }

  export enum AvailableClashAPIMethods {
    GET_PROXIES = 'get_proxies',
    GET_CONNECTIONS = 'get_connections',
    GET_PROXY_LATENCY = 'get_proxy_latency',
    GET_PROXY_LATENCIES = 'get_proxy_latencies',
    GET_GROUP_LATENCY = 'get_group_latency',
    SET_GROUP_PROXY = 'set_group_proxy',
    CLOSE_CONNECTION = 'close_connection',
    CLOSE_ALL_CONNECTIONS = 'close_all_connections',
  }

  export interface Outbound {
    code: string;
    displayName: string;
    latency: number;
    type: string;
    selected: boolean;
    link?: string;
    canCopyLink?: boolean;
    country?: string;
    runtimeAvailable?: boolean;
    urlTestInfo?: UrlTestInfo;
  }

  export interface UrlTestMember {
    code: string;
    displayName: string;
    latency: number;
    type: string;
    selected: boolean;
    link?: string;
    canCopyLink?: boolean;
    country?: string;
  }

  export interface UrlTestInfo {
    code: string;
    displayName: string;
    selectedCode?: string;
    selectedName?: string;
    url?: string;
    interval?: string;
    tolerance?: string | number;
    idleTimeout?: string;
    interruptExistConnections?: boolean;
    outbounds: UrlTestMember[];
  }

  export interface OutboundGroup {
    withTagSelect: boolean;
    code: string;
    sectionName: string;
    displayName: string;
    action?: ConfigSection['action'];
    latencyTestCode?: string;
    latencyTestCodes?: string[];
    latencyTestTimeout?: string;
    proxyConfigType?: ProxyConfigType;
    subscriptionSourceCount?: number;
    subscriptionMetadata?: SubscriptionMetadata[];
    outbounds: Outbound[];
  }

  export interface LatencyActionProgress {
    completed: number;
    total: number;
    failed?: number;
  }

  interface SubscriptionTraffic {
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
    sourceIndex?: number;
    sourceSection?: string;
  }

  type RuleAction =
    | 'connection'
    | 'proxy'
    | 'outbound'
    | 'vpn'
    | 'bypass'
    | 'block'
    | 'zapret'
    | 'zapret2'
    | 'byedpi';
  type LegacyConnectionType = 'proxy' | 'vpn' | 'block' | 'exclusion';
  type ProxyConfigType =
    | 'urltest'
    | 'selector'
    | 'url'
    | 'outbound'
    | 'interface'
    | 'subscription';

  export interface ConfigSection {
    '.name': string;
    '.type':
      | 'settings'
      | 'rule'
      | 'node'
      | 'ruleset'
      | 'section'
      | 'server'
      | 'connection_url'
      | 'subscription_url'
      | 'section_interface'
      | 'urltest';
    label?: string;
    enabled?: string;
    action?: RuleAction;
    connection_type?: LegacyConnectionType;
    proxy_config_type?: ProxyConfigType;
    node?: string;
    rule_set?: string[];
    rule_set_with_subnets?: string[];
    domain_ip_lists?: string[];
    ports?: string[];
    update_interval?: string;
    proxy_string?: string;
    nfqws_opt?: string;
    nfqws2_opt?: string;
    byedpi_cmd_opts?: string;
    cmd_opts?: string;
    selector_proxy_links?: string[];
    subscription_urls?: string[];
    interfaces?: string[];
    outbound_jsons?: string[];
    connection_url_settings?: string;
    subscription_url_settings?: string;
    interface_settings?: string;
    urltests?: string[];
    urltest_settings?: string;
    urltest_proxy_links?: string[];
    subscription_url?: string;
    subscription_user_agent?: string;
    subscription_update_enabled?: '0' | '1';
    subscription_update_interval?: string;
    subscription_update_interval_disabled?: '0' | '1';
    urltest_enabled?: '0' | '1';
    sort_by_latency?: '0' | '1';
    urltest_check_interval_disabled?: '0' | '1';
    detect_server_country?: '0' | '1' | 'flag_emoji' | 'country_is';
    urltest_filter_mode?: 'disabled' | 'exclude' | 'include' | 'mixed';
    urltest_hide_filtered_outbounds?: '0' | '1';
    urltest_exclude_countries?: string[];
    urltest_exclude_outbounds?: string[];
    urltest_exclude_regex?: string[];
    urltest_include_countries?: string[];
    urltest_include_outbounds?: string[];
    urltest_include_regex?: string[];
    outbound_json?: string;
    interface?: string;
    section?: string;
    id?: string;
    url?: string;
    name?: string;
    display_name?: string;
    check_interval?: string;
    tolerance?: string;
    testing_url?: string;
    idle_timeout?: string;
    interrupt_exist_connections?: '0' | '1';
    pin_dashboard?: '0' | '1';
    hide_added_outbounds?: '0' | '1';
    filter_mode?: 'disabled' | 'exclude' | 'include' | 'mixed';
    include_countries?: string[];
    include_outbounds?: string[];
    include_regex?: string[];
    exclude_countries?: string[];
    exclude_outbounds?: string[];
    exclude_regex?: string[];
    outbound_detour_enabled?: '0' | '1';
    outbound_detour_section?: string;
    enable_udp_over_tcp?: '0' | '1';
    download_via_proxy_enabled?: '0' | '1';
    download_via_proxy_section?: string;
    user_agent?: string;
    hwid?: string;
    show_dashboard_metadata?: '0' | '1';
    hide_urltest_group_outbounds?: '0' | '1';
    hide_detour_outbounds?: '0' | '1';
    domain_resolver_enabled?: '0' | '1';
    domain_resolver_dns_type?: string;
    domain_resolver_dns_server?: string;
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
    dont_touch_dhcp: 0 | 1;
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

  export interface InboundCheckItem {
    section: string;
    label: string;
    protocol: string;
    routing_mode: string;
    tag: string;
    listen: string;
    listen_port: number;
    public_host: string;
    public_host_ips: string;
    expected_type: string;
    required_proto: string;
    runtime_exists: 0 | 1;
    runtime_type: string;
    runtime_listen: string;
    runtime_port: number;
    runtime_ok: 0 | 1;
    listening: -1 | 0 | 1;
    firewall_required: 0 | 1;
    firewall_open: -1 | 0 | 1;
    port_conflict: 0 | 1;
    port_conflict_owners: string;
    routes_configured: 0 | 1;
    public_host_resolved: -1 | 0 | 1;
    public_host_public: -1 | 0 | 1;
    public_host_matches_wan: -1 | 0 | 1;
  }

  export interface InboundsCheckResult {
    enabled_count: number;
    config_path: string;
    wan_ip: string;
    wan_public: 0 | 1;
    items: InboundCheckItem[];
  }

  export interface InboundsConfigCheckResult {
    enabled_count: number;
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
  }

  export interface GetOutboundLink {
    link: string;
  }

  export type GetOutboundLinkStates = Record<string, boolean>;

  export interface GetOutboundMetadata {
    names?: Record<string, string>;
    countries?: Record<string, string>;
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
    sing_box_extended: 0 | 1;
    sing_box_tiny: 0 | 1;
    sing_box_compressed: 0 | 1;
    sing_box_tailscale: 0 | 1;
    zapret_version: string;
    zapret_installed: 0 | 1;
    zapret2_version: string;
    zapret2_installed: 0 | 1;
    byedpi_version: string;
    byedpi_installed: 0 | 1;
    openwrt_version: string;
    device_model: string;
    generated_at?: number;
  }

  export interface GetServerCapabilities {
    sing_box_extended: 0 | 1;
    sing_box_tiny: 0 | 1;
    sing_box_tailscale: 0 | 1;
  }

  export interface GetUiCapabilities {
    sing_box_extended: 0 | 1;
    sing_box_tiny: 0 | 1;
    sing_box_compressed: 0 | 1;
    sing_box_tailscale: 0 | 1;
    zapret_installed: 0 | 1;
    zapret2_installed: 0 | 1;
    byedpi_installed: 0 | 1;
    server_inbounds_enabled_count: number;
  }

  export type ServiceAction = 'start' | 'stop' | 'restart' | 'reload';

  export interface UiActionStartResult {
    success: boolean;
    job_id: string;
    message: string;
  }

  export interface UiActionState {
    success: boolean;
    running?: boolean;
    kind?: string;
    message?: string;
    pid?: string | null;
    started_at?: number;
    updated_at?: number | null;
    exit_code?: number | null;
    job_id?: string;
  }

  export interface ServiceActionState extends UiActionState {
    kind: 'service';
    action: ServiceAction;
    source?: string;
  }

  export interface LatencyActionState extends UiActionState {
    kind: 'latency';
    latency_type: 'group' | 'proxy' | 'proxy_list';
    section: string;
    tag: string;
    progress?: LatencyActionProgress;
  }

  export interface UiState {
    service: {
      podkop: GetStatus;
      sing_box: GetSingBoxStatus;
    };
    capabilities: GetUiCapabilities;
    actions: {
      service: ServiceActionState[];
      latency: LatencyActionState[];
      component: ComponentActionResult[];
      subscription: SubscriptionUpdateJobState[];
    };
  }

  export type ComponentName =
    | 'podkop'
    | 'sing_box'
    | 'zapret'
    | 'zapret2'
    | 'byedpi';

  export type ComponentAction =
    | 'check_update'
    | 'install'
    | 'remove'
    | 'install_extended'
    | 'install_extended_compressed'
    | 'install_tiny'
    | 'install_stable';

  export interface ComponentActionResult {
    success: boolean;
    running?: boolean;
    kind?: 'component';
    job_id?: string;
    component: ComponentName;
    action: ComponentAction;
    message: string;
    current_version: string;
    latest_version: string;
    release_url?: string;
    changed: boolean;
    status?: 'latest' | 'outdated' | 'dev' | '';
    pid?: string | null;
    started_at?: number;
    updated_at?: number | null;
    exit_code?: number | null;
  }

  export type ComponentActionStartResult = UiActionStartResult;

  export type SubscriptionUpdateStartResult = UiActionStartResult;

  export interface SubscriptionUpdateJobState extends UiActionState {
    kind?: 'subscription';
    success: boolean;
    running?: boolean;
    message?: string;
    section?: string;
    source_index?: string;
    pid?: string | null;
    started_at?: number;
    exit_code?: number | null;
    updated_at?: number | null;
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
    restart_count: number;
    runtime_unstable: 0 | 1;
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

  export interface GetZapret2Status {
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
    ready: 0 | 1;
    conflict: 0 | 1;
    outbounds_configured: 0 | 1;
    routes_configured: 0 | 1;
    status_message: string;
  }

  export interface Zapret2CheckResult {
    zapret2_installed: 0 | 1;
    zapret2_package_installed: 0 | 1;
    zapret2_provider_path: string;
  }

  export interface GetByedpiStatus {
    installed: 0 | 1;
    package_installed: 0 | 1;
    provider_available: 0 | 1;
    provider_path: string;
    version: string;
    configured: 0 | 1;
    enabled_rule_count: number;
    expected_process_count: number;
    running_process_count: number;
    supervisor_process_count: number;
    restart_count: number;
    runtime_unstable: 0 | 1;
    standalone_service_enabled: 0 | 1;
    standalone_service_running: 0 | 1;
    listen_address: string;
    port_base: number;
    outbounds_configured: 0 | 1;
    routes_configured: 0 | 1;
    ready: 0 | 1;
    conflict: 0 | 1;
    status_message: string;
  }

  export interface ByedpiCheckResult {
    byedpi_installed: 0 | 1;
    byedpi_package_installed: 0 | 1;
    byedpi_provider_path: string;
  }

  export interface GetClashApiProxyLatency {
    delay: number;
    message?: string;
  }

  export interface GetClashApiProxyLatencies {
    success: boolean;
    count: number;
    failed: boolean;
  }

  export type GetClashApiGroupLatency = Record<string, number>;
}
