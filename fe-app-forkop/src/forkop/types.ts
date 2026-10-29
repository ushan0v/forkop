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
    url?: string;
    interval?: string;
    idle_timeout?: string;
    groups?: Array<{
      outbounds?: string[];
    }>;
    fixed?: string;
  }

  export interface Proxies {
    proxies: Record<string, ProxyBase>;
  }

  export interface ProxyProvider {
    type: string;
    vehicleType: string;
    name: string;
    proxies: ProxyBase[];
    updatedAt?: string;
    subscriptionInfo?: {
      Upload?: number;
      Download?: number;
      Total?: number;
      Expire?: number;
      upload?: number;
      download?: number;
      total?: number;
      expire?: number;
    };
    subscriptionMetadata?: {
      title?: string;
      webPageUrl?: string;
      supportUrl?: string;
      announce?: string;
      announceUrl?: string;
      refillDate?: number;
      fileName?: string;
    };
    // Every server the provider's name filters chose from, without the provider prefix.
    filterCandidates: string[];
  }

  export interface ProxyProviders {
    providers: Record<string, ProxyProvider>;
  }

  export interface TailscalePeer {
    name: string;
    dnsName?: string;
    addresses: string[];
    // What the tailnet reaches through this device, exit routes aside.
    subnets?: string[];
    online: boolean;
    lastSeen?: number;
    exitNodeOption: boolean;
    // The device the endpoint sends internet traffic through now.
    exitNode: boolean;
  }

  export interface TailscaleEndpoint {
    tag: string;
    state: string;
    authURL?: string;
    connected: boolean;
    name?: string;
    dnsName?: string;
    tailnet?: string;
    addresses: string[];
    keyExpiry?: number;
    // The exit node the endpoint's settings name, a device name or an address.
    exitNode?: string;
    advertisesExitNode: boolean;
    exitNodeApproved: boolean;
    routes: Array<{ prefix: string; approved: boolean }>;
    health: string[];
    peers: TailscalePeer[];
  }

  export interface Tailscale {
    endpoints: TailscaleEndpoint[];
  }

  // A disco ping's round trip in milliseconds.
  export interface TailscalePong {
    latency: number;
  }
}

// eslint-disable-next-line @typescript-eslint/no-namespace
export namespace Forkop {
  // Subset of the Forkop CLI this app drives. `forkop` without arguments
  // prints the authoritative command list, so it is not duplicated here.
  export enum AvailableMethods {
    CHECK_SERVICE = 'check_service',
    CHECK_DNS = 'check_dns',
    CHECK_TRAFFIC = 'check_traffic',
    CHECK_SERVERS = 'check_servers',
    REPORT = 'report',
    CLASH_API = 'clash_api',
    CLASH_SUMMARY = 'clash_summary',
    ENABLE = 'enable',
    DISABLE = 'disable',
    SHOW_CONFIG = 'show_config',
    CHECK_LOGS = 'check_logs',
    GET_SYSTEM_INFO = 'get_system_info',
    GET_UI_STATE = 'get_ui_state',
    GET_CORE_FEATURES = 'get_core_features',
    SERVICE_ACTION_ASYNC = 'service_action_async',
    UI_ACTION_ACK = 'ui_action_ack',
    INSTALLER_START = 'installer_start',
    INSTALLER_STATUS = 'installer_status',
    INSTALLER_LOG = 'installer_log',
  }

  export interface Outbound {
    code: string;
    displayName: string;
    latency: number;
    type: string;
    selected: boolean;
    link?: string;
    canCopyLink?: boolean;
    subscriptionTag?: string;
    urlTestInfo?: UrlTestInfo;
    fallbackInfo?: FallbackInfo;
  }

  export interface UrlTestMember {
    code: string;
    displayName: string;
    latency: number;
    type: string;
    selected: boolean;
    subscriptionTag?: string;
  }

  export interface UrlTestInfo {
    code: string;
    displayName: string;
    selectedCode?: string;
    selectedName?: string;
    url?: string;
    expectedStatus?: string;
    interval?: string;
    tolerance?: string | number;
    idleTimeout?: string;
    interruptExistConnections?: boolean;
    outbounds: UrlTestMember[];
  }

  export interface FallbackMember extends UrlTestMember {
    levelIndex: number;
    levelName: string;
    levelId?: string;
    pinned: boolean;
  }

  export interface FallbackInfo {
    code: string;
    displayName: string;
    selectedCode?: string;
    selectedName?: string;
    healthCheckUrl?: string;
    healthCheckInterval?: string;
    healthCheckTimeout?: string;
    attemptTimeout?: string;
    expectedStatus?: string;
    idleTimeout?: string;
    interruptExistConnections?: boolean;
    outbounds: FallbackMember[];
  }

  export interface OutboundGroup {
    withTagSelect: boolean;
    code: string;
    sectionName: string;
    displayName: string;
    action?: ConfigSection['action'];
    proxyConfigType?: ProxyConfigType;
    subscriptionSourceCount?: number;
    subscriptionProviderTags?: string[];
    subscriptionMetadata?: SubscriptionMetadata[];
    outbounds: Outbound[];
  }

  // A server hosted on the router, as the applied configuration has it; the core
  // reports a client by its user or, without one, by the address it connects from.
  export interface DashboardServer {
    sectionName: string;
    tag: string;
    protocol: string;
    port: string;
    clients: DashboardServerClient[];
  }

  export interface DashboardServerClient {
    sectionName: string;
    name: string;
    users: string[];
    addresses: string[];
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
    subscriptionTag?: string;
    traffic?: SubscriptionTraffic;
    expire?: number;
    refillDate?: number;
    // Epoch seconds of the core's last successful download or not-modified answer.
    updatedAt?: number;
    webPageUrl?: string;
    supportUrl?: string;
    announce?: string;
    announceUrl?: string;
    fileName?: string;
    sourceIndex?: number;
    sourceSection?: string;
  }

  type RuleAction = 'connection' | 'bypass' | 'block';
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
      | 'server_client'
      | 'subscription_url'
      | 'section_interface'
      | 'connection_link'
      | 'urltest'
      | 'fallback_group'
      | 'fallback_level'
      | 'tunnel'
      | 'tunnel_peer';
    label?: string;
    enabled?: string;
    action?: RuleAction;
    node?: string;
    community_lists?: string[];
    rule_set?: string[];
    rule_set_with_subnets?: string[];
    ports?: string[];
    update_interval?: string;
    connection_links?: Array<{ name: string; uri: string }>;
    subscriptions?: Array<{
      tag: string;
      show_dashboard_metadata?: '0' | '1';
    }>;
    interfaces?: string[];
    tunnels?: string[];
    outbound_jsons?: string[];
    urltests?: string[];
    urltest_settings?: string;
    fallback_groups?: string[];
    fallback_group_settings?: string;
    subscription_update_enabled?: '0' | '1';
    subscription_update_interval?: string;
    urltest_server_filter_mode?: 'all' | 'exclude' | 'include';
    urltest_exclude_outbounds?: string[];
    urltest_exclude_regex?: string | string[];
    urltest_include_outbounds?: string[];
    urltest_include_regex?: string | string[];
    section?: string;
    protocol?: string;
    server?: string;
    wireguard_address?: string | string[];
    listen_port?: string;
    id?: string;
    url?: string;
    uri?: string;
    name?: string;
    display_name?: string;
    check_interval?: string;
    tolerance?: string;
    testing_url?: string;
    idle_timeout?: string;
    interrupt_exist_connections?: '0' | '1';
    server_filter_mode?: 'all' | 'exclude' | 'include' | 'direct';
    include_outbounds?: string[];
    include_regex?: string | string[];
    exclude_outbounds?: string[];
    exclude_regex?: string | string[];
    group?: string;
    order?: string;
    health_check_url?: string;
    health_check_interval?: string;
    health_check_timeout?: string;
    attempt_timeout?: string;
    expected_status?: string;
    country?: string[];
    server_name?: string[];
    regex?: string[];
    detour_section?: string;
    download_via_proxy_enabled?: '0' | '1';
    download_via_proxy_section?: string;
    user_agent?: string;
    header?: string[];
    show_dashboard_metadata?: '0' | '1';
    tag?: string;
    yacd_secret_key?: string;
    latency_test_url?: string;
  }

  export interface MethodSuccessResponse<T> {
    success: true;
    data: T;
  }

  export interface MethodFailureResponse {
    success: false;
    error: string;
    // The HTTP status the Clash API answered a failed request with; absent when
    // it gave no answer at all.
    status?: number;
  }

  export type MethodResponse<T> =
    | MethodSuccessResponse<T>
    | MethodFailureResponse;

  export interface ServiceCheckResult {
    running: boolean;
    // Seconds the core has run, -1 when it does not.
    uptime: number;
    // The error logged since the last start or stop that went through.
    last_error: string;
    // The core as its binary reports itself: `binary` its version, `version` that version when it
    // is sing-box-forkop's, the package's variant while the binary is that build, and why Forkop
    // cannot run on it.
    core: {
      installed: boolean;
      binary: string;
      version: string;
      variant: string;
      outdated: boolean;
      required: string;
      problem: string;
    };
    foreign_sing_box: number[];
    conflicts: Array<{ table: string; kind: 'tproxy' | 'dns' }>;
    memory: { total_kb: number; available_kb: number };
    router_uptime: number;
  }

  export interface DnsQueryResult {
    answered: boolean;
    status: string;
    ms: number;
  }

  export interface DnsCheckResult {
    main: DnsQueryResult & { servers: string };
    bootstrap: {
      servers: string;
      host: string;
      answered: boolean;
      ms: number;
    } | null;
    local: DnsQueryResult;
  }

  export interface TrafficCheckResult {
    router: {
      excluded: boolean;
      dns_fakeip: boolean;
      answered: boolean;
      fakeip: boolean;
      ip: string;
    };
    exit: { section: string; answered: boolean; ip: string } | null;
  }

  export interface ServerCheckItem {
    label: string;
    protocol: string;
    port: number;
    transports: string;
    runtime: boolean;
    listening: boolean;
    owners: string;
    exposed: boolean;
    // Whether Forkop is asked to open the port in the firewall.
    open_firewall: boolean;
    firewall_open: boolean;
    public_host: string;
    public_ips: string;
    resolved: -1 | 0 | 1;
    public: -1 | 0 | 1;
    matches_wan: -1 | 0 | 1;
  }

  // A Tailscale server listens on nothing; the core reports its state in the tailnet.
  export interface TailscaleServerCheckItem {
    label: string;
    protocol: 'tailscale';
    runtime: boolean;
    state: string;
    connected: boolean;
    name: string;
    exit_node_pending: boolean;
    pending_routes: string;
    key_expired: boolean;
  }

  export interface ServersCheckResult {
    wan: string;
    // The only WAN address is the provider's shared one.
    behind_cgnat: boolean;
    items: Array<ServerCheckItem | TailscaleServerCheckItem>;
  }

  export interface ReportAttachments {
    checks: string;
    log: string;
    forkop_config: string;
    nftables: string;
    ip_rules: string;
  }

  export interface FakeIPCheckResult {
    fakeip: boolean;
    IP: string;
  }

  // `status` is what the service is, `busy` what is being done to it; an apply leaves it running.
  export type ServiceBusy = 'start' | 'stop' | 'restart' | 'apply' | 'install';

  export type InstallerAction = 'update' | 'variant' | 'uninstall';

  // A run of install.sh as service/installer.uc reports it, with its output from `offset` on.
  export interface InstallerSnapshot {
    id: string;
    action?: InstallerAction;
    variant?: string | null;
    purge?: boolean;
    interactive?: boolean;
    running: boolean;
    exit?: number | null;
    interrupted?: boolean;
    stop_requested?: boolean;
    changed?: boolean;
    started_at?: number | null;
    finished_at?: number | null;
    // install.sh wrote its log during this run
    log?: boolean;
    offset?: number;
    next?: number;
    data?: string;
  }

  export interface InstallerStartResult {
    id: string;
    started: boolean;
  }

  export interface GetStatus {
    running: number;
    enabled: number;
    status: string;
    busy?: ServiceBusy | null;
    // Seconds the running operation has gone on, 0 when none; elapsed, so no clock comparison is needed.
  }

  export interface GetSingBoxStatus {
    running: number;
    enabled: number;
    status: string;
  }

  // Processor time and start in kernel ticks, anonymous memory, and the reading's moment on the
  // router's monotonic clock, which counts from boot like the start.
  export type CoreUsage =
    | { running: false }
    | {
        running: true;
        started: number;
        cpu_ticks: number;
        memory_kb: number;
        cpus: number;
        clock_ms: number;
      };

  export interface GetSystemInfo {
    forkop_version: string;
    luci_app_version: string;
    sing_box_version: string;
    sing_box_variant?: string;
    openwrt_version: string;
    device_model: string;
    generated_at?: number;
  }

  // What the installed sing-box can do, from the tags it was built with
  // (singbox/features.uc). Unknown without a core to ask.
  export interface CoreFeatures {
    known: boolean;
    tags: string[];
    features: Record<string, { available: boolean; tags: string[] }>;
    types: Record<'outbound' | 'inbound' | 'endpoint', Record<string, string>>;
    links: Record<string, string>;
  }

  export interface GetUiCapabilities {
    server_inbounds_enabled_count: number;
    sections_enabled_count: number;
    core?: CoreFeatures;
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

  export interface UiState {
    service: {
      forkop: GetStatus;
      sing_box: GetSingBoxStatus;
    };
    capabilities: GetUiCapabilities;
    actions: {
      service: ServiceActionState[];
    };
  }

  export interface GetClashApiProxyLatency {
    delay: number;
    message?: string;
  }

  export interface GetClashApiProxyLink {
    url: string;
  }

  // One address family of an outbound's exit: the address and country Cloudflare saw, or why
  // the family gave no answer.
  export interface ClashApiExitAddress {
    address?: string;
    country?: string;
    error?: string;
  }

  export interface GetClashApiProxyExit {
    // The outbound the request left through: a group's current choice, followed down.
    outbound: string;
    ipv4: ClashApiExitAddress;
    ipv6: ClashApiExitAddress;
  }

  export type GetClashApiGroupLatency = Record<string, number>;

  export interface ClashApiResponse {
    status: number;
    body: string;
  }

  export interface ClashConnectionsSummary {
    downloadTotal: number;
    uploadTotal: number;
    connections: number;
  }
}
