import { logger } from './logger.service';

type LogFetcher = () => Promise<string> | string;

interface NexrouteLogWatcherOptions {
  intervalMs?: number;
  onNewLog?: (line: string) => void;
  maxTrackedLines?: number;
}

export class NexrouteLogWatcher {
  private static instance: NexrouteLogWatcher;
  private fetcher?: LogFetcher;
  private onNewLog?: (line: string) => void;
  private intervalMs = 5000;
  private lastLines = new Set<string>();
  private maxTrackedLines = 500;
  private timer?: ReturnType<typeof setInterval>;
  private running = false;
  private paused = false;
  private checking = false;

  private constructor() {
    if (typeof document !== 'undefined') {
      document.addEventListener('visibilitychange', () => {
        if (document.hidden) this.pause();
        else this.resume();
      });
    }
  }

  static getInstance(): NexrouteLogWatcher {
    if (!NexrouteLogWatcher.instance) {
      NexrouteLogWatcher.instance = new NexrouteLogWatcher();
    }
    return NexrouteLogWatcher.instance;
  }

  init(fetcher: LogFetcher, options?: NexrouteLogWatcherOptions): void {
    this.fetcher = fetcher;
    this.onNewLog = options?.onNewLog;
    this.intervalMs = options?.intervalMs ?? 5000;
    this.maxTrackedLines = options?.maxTrackedLines ?? 500;
    this.lastLines = new Set();
    logger.info(
      '[NexrouteLogWatcher]',
      `initialized (interval: ${this.intervalMs}ms)`,
    );
  }

  private normalizeLines(raw: string): string[] {
    return raw.split('\n').filter(Boolean).slice(-this.maxTrackedLines);
  }

  async checkOnce(): Promise<void> {
    if (!this.fetcher) {
      logger.warn('[NexrouteLogWatcher]', 'fetcher not found');
      return;
    }

    if (this.paused) {
      logger.debug('[NexrouteLogWatcher]', 'skipped check — tab not visible');
      return;
    }

    if (this.checking) {
      logger.debug(
        '[NexrouteLogWatcher]',
        'skipped check — previous check is running',
      );
      return;
    }

    this.checking = true;

    try {
      const raw = await this.fetcher();
      const lines = this.normalizeLines(raw);

      for (const line of lines) {
        if (this.lastLines.has(line)) {
          continue;
        }

        this.lastLines.add(line);
        this.onNewLog?.(line);
      }

      if (this.lastLines.size > this.maxTrackedLines) {
        this.lastLines = new Set(
          Array.from(this.lastLines).slice(-this.maxTrackedLines),
        );
      }
    } catch (err) {
      logger.error('[NexrouteLogWatcher]', 'failed to read logs:', err);
    } finally {
      this.checking = false;
    }
  }

  start(): void {
    if (this.running) return;
    if (!this.fetcher) {
      logger.warn('[NexrouteLogWatcher]', 'attempted to start without fetcher');
      return;
    }

    this.running = true;
    void this.checkOnce();
    this.timer = setInterval(() => this.checkOnce(), this.intervalMs);
    logger.info(
      '[NexrouteLogWatcher]',
      `started (interval: ${this.intervalMs}ms)`,
    );
  }

  stop(): void {
    if (!this.running) return;
    this.running = false;
    if (this.timer) clearInterval(this.timer);
    logger.info('[NexrouteLogWatcher]', 'stopped');
  }

  pause(): void {
    if (!this.running || this.paused) return;
    this.paused = true;
    logger.info('[NexrouteLogWatcher]', 'paused (tab not visible)');
  }

  resume(): void {
    if (!this.running || !this.paused) return;
    this.paused = false;
    logger.info('[NexrouteLogWatcher]', 'resumed (tab active)');
    void this.checkOnce();
  }

  reset(): void {
    this.lastLines = new Set();
    this.checking = false;
    logger.info('[NexrouteLogWatcher]', 'log history reset');
  }
}
