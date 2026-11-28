import { action, SingletonAction, type KeyDownEvent, type KeyUpEvent, type WillAppearEvent, type WillDisappearEvent } from "@elgato/streamdeck";
import type { RedlightRuntime } from "../redlight/runtime.js";
import type { Status } from "../redlight/types.js";
import { bindStatus, renderKey, reportError, type ActionSurface } from "./action-support.js";

type PausePeekSettings = Record<string, never>;

const renewalMs = 1_500;
const maximumHoldMs = 60_000;

type PeekGesture = {
  renewalTimer?: NodeJS.Timeout;
  releaseTimer: NodeJS.Timeout;
};

@action({ UUID: "com.redlight.app.streamdeck.pause-peek" })
export class PausePeekAction extends SingletonAction<PausePeekSettings> {
  private readonly subscriptions = new Map<string, { deviceId: string; unsubscribe: () => void }>();
  private readonly held = new Set<string>();
  private gesture?: PeekGesture;

  constructor(
    private readonly runtime: RedlightRuntime,
  ) {
    super();
  }

  override onWillAppear(ev: WillAppearEvent<PausePeekSettings>): void {
    const { action } = ev;
    this.unbind(action.id);
    if (!action.isKey()) return;
    this.subscriptions.set(action.id, {
      deviceId: action.device.id,
      unsubscribe: bindStatus(this.runtime, action, renderPausePeek),
    });
  }

  override async onWillDisappear(ev: WillDisappearEvent<PausePeekSettings>): Promise<void> {
    this.unbind(ev.action.id);
    if (!this.held.delete(ev.action.id) || this.held.size !== 0) return;
    await this.endPeek();
  }

  async onDeviceDisconnect(deviceId: string): Promise<void> {
    let released = false;
    for (const [id, subscription] of this.subscriptions) {
      if (subscription.deviceId !== deviceId) continue;
      this.unbind(id);
      released = this.held.delete(id) || released;
    }
    if (released && this.held.size === 0) await this.endPeek();
  }

  override async onKeyDown(ev: KeyDownEvent<PausePeekSettings>): Promise<void> {
    if (!this.subscriptions.has(ev.action.id) || this.held.has(ev.action.id)) return;
    this.held.add(ev.action.id);
    if (this.gesture) return;

    // Stream Deck supplies transitions only. A missing key-up on a connected
    // device would otherwise renew the app-side lease indefinitely.
    const gesture: PeekGesture = {
      releaseTimer: setTimeout(() => {
        if (this.gesture !== gesture) return;
        this.held.clear();
        void this.endPeek();
      }, maximumHoldMs).unref(),
    };
    this.gesture = gesture;
    try {
      // The app decides whether Peek can start. Paused status reports on=false,
      // and a stopped app responds to Peek without launching.
      const status = await this.runtime.execute(["peek", "on"]);
      if (!status.running) throw new Error("Start Redlight before peeking.");
      if (this.gesture === gesture) this.startRenewal(gesture);
    } catch (error) {
      if (this.gesture === gesture) {
        this.held.clear();
        this.clearGesture();
      }
      await reportError(ev.action, error);
    }
  }

  override async onKeyUp(ev: KeyUpEvent<PausePeekSettings>): Promise<void> {
    if (!this.held.delete(ev.action.id)) return;
    if (this.held.size !== 0 || !this.gesture) return;
    this.clearGesture();
    try {
      // Enqueue at event receipt, after startup or renewal and before a new press.
      await this.runtime.execute(["peek", "off"]);
    } catch (error) {
      await reportError(ev.action, error);
    }
  }

  private startRenewal(gesture: PeekGesture): void {
    let renewing = false;
    gesture.renewalTimer = setInterval(() => {
      if (renewing) return;
      renewing = true;
      void this.runtime.execute(["peek", "renew"])
        .catch(() => undefined)
        .finally(() => { renewing = false; });
    }, renewalMs);
    // A closed Stream Deck connection must let the process exit and the app lease expire.
    gesture.renewalTimer.unref();
  }

  private clearGesture(): void {
    if (this.gesture) clearTimeout(this.gesture.releaseTimer);
    if (this.gesture?.renewalTimer) clearInterval(this.gesture.renewalTimer);
    this.gesture = undefined;
  }

  private async endPeek(): Promise<void> {
    this.clearGesture();
    try {
      await this.runtime.execute(["peek", "off"]);
    } catch {
      // Redlight may already have stopped. Its lease still expires.
    }
  }

  private unbind(id: string): void {
    this.subscriptions.get(id)?.unsubscribe();
    this.subscriptions.delete(id);
  }
}

function renderPausePeek(action: ActionSurface, status: Status): void {
  renderKey(action, status, status.peeking ? "#f7d6a1" : "#e88c61", status.peeking ? "Peeking" : "Hold: Peek");
}
