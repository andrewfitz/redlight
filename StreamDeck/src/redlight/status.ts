import { RedlightClient } from "./client.js";
import type { Status } from "./types.js";

export type StatusListener = (status: Status) => void;

export class StatusStore {
  private readonly client: RedlightClient;
  private readonly listeners = new Set<StatusListener>();
  private timer?: NodeJS.Timeout;
  private refreshing?: Promise<Status>;
  private visible = 0;
  private currentStatus: Status = { running: false };
  private error?: Error;
  private operationVersion = 0;

  constructor(client = new RedlightClient()) {
    this.client = client;
  }

  get status(): Status { return this.currentStatus; }
  get lastError(): Error | undefined { return this.error; }

  subscribe(listener: StatusListener): () => void {
    this.listeners.add(listener);
    this.visible += 1;
    if (this.visible === 1) {
      void this.refresh().catch(() => undefined);
      this.schedule(0);
    }
    listener(this.currentStatus);
    return () => {
      if (!this.listeners.delete(listener)) return;
      this.visible = Math.max(0, this.visible - 1);
      if (this.visible === 0) this.stop();
    };
  }

  async refresh(): Promise<Status> {
    if (this.refreshing) return this.refreshing;
    const version = this.operationVersion;
    this.refreshing = this.client.status()
      .then((status) => {
        if (version !== this.operationVersion) return this.currentStatus;
        this.currentStatus = status;
        this.error = undefined;
        this.emit(status);
        return status;
      })
      .catch((error: unknown) => {
        const normalized = error instanceof Error ? error : new Error(String(error));
        if (version === this.operationVersion) {
          this.error = normalized;
          if (this.currentStatus.running) {
            this.currentStatus = { running: false };
            this.emit(this.currentStatus);
          }
        }
        throw normalized;
      })
      .finally(() => {
        this.refreshing = undefined;
      });
    return this.refreshing;
  }

  async execute(args: string[]): Promise<Status> {
    this.operationVersion += 1;
    try {
      const status = await this.client.command(args);
      this.currentStatus = status;
      this.error = undefined;
      this.emit(status);
      this.schedule(2_000);
      return status;
    } finally {
      this.operationVersion += 1;
    }
  }

  redraw(): void {
    this.emit(this.currentStatus);
  }

  stop(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = undefined;
  }

  private schedule(delayMs: number): void {
    if (this.visible === 0) return;
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      this.timer = undefined;
      void this.refresh()
        .catch(() => undefined)
        .finally(() => this.schedule(2_000));
    }, delayMs);
    this.timer.unref();
  }

  private emit(status: Status): void {
    for (const listener of this.listeners) listener(status);
  }
}
