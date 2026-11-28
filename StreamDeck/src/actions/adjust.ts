import {
  action,
  SingletonAction,
  type DidReceiveSettingsEvent,
  type DialDownEvent,
  type DialRotateEvent,
  type KeyDownEvent,
  type WillAppearEvent,
  type WillDisappearEvent,
} from "@elgato/streamdeck";
import type { RedlightRuntime } from "../redlight/runtime.js";
import type { Status } from "../redlight/types.js";
import { dialColorText, displayValue, renderKey, reportError, safeActionUpdate, statusLabel, type ActionSurface } from "./action-support.js";

type Channel = "color" | "whitepoint";
type Direction = "up" | "down";
type AdjustSettings = { channel?: Channel; step?: number; direction?: Direction };

type AdjustSurface = WillAppearEvent<AdjustSettings>["action"];
type VisibleAdjustment = {
  channel: Channel;
  unsubscribe: () => void;
};

type PendingAdjustment = {
  action: ActionSurface;
  channel: Channel;
  delta: number;
  timer?: NodeJS.Timeout;
  flushing?: boolean;
};

const dialDebounceMs = 50;

@action({ UUID: "com.redlight.app.streamdeck.adjust" })
export class AdjustAction extends SingletonAction<AdjustSettings> {
  private readonly visible = new Map<string, VisibleAdjustment>();
  private readonly pending = new Map<string, PendingAdjustment>();

  constructor(private readonly runtime: RedlightRuntime) {
    super();
  }

  override onWillAppear(ev: WillAppearEvent<AdjustSettings>): void {
    const { action, payload } = ev;
    this.visible.get(action.id)?.unsubscribe();
    const view: VisibleAdjustment = {
      channel: normalizeSettings(payload.settings).channel,
      unsubscribe: () => {},
    };
    view.unsubscribe = this.runtime.status.subscribe((status) => renderAdjust(action, status, view.channel));
    this.visible.set(action.id, view);
  }

  override onWillDisappear(ev: WillDisappearEvent<AdjustSettings>): void {
    this.visible.get(ev.action.id)?.unsubscribe();
    this.visible.delete(ev.action.id);
    this.clearPending(ev.action.id);
  }

  override onDidReceiveSettings(ev: DidReceiveSettingsEvent<AdjustSettings>): void {
    const view = this.visible.get(ev.action.id);
    if (!view) return;
    view.channel = normalizeSettings(ev.payload.settings).channel;
    renderAdjust(ev.action, this.runtime.status.status, view.channel);
  }

  override async onKeyDown(ev: KeyDownEvent<AdjustSettings>): Promise<void> {
    const settings = normalizeSettings(ev.payload.settings);
    await this.step(ev.action, settings.channel, settings.direction, settings.step);
  }

  override async onDialDown(ev: DialDownEvent<AdjustSettings>): Promise<void> {
    const settings = normalizeSettings(ev.payload.settings);
    this.commitPending(ev.action.id);
    try {
      await this.runtime.execute(["reset", settings.channel]);
    } catch (error) {
      await reportError(ev.action, error);
    }
  }

  override onDialRotate(ev: DialRotateEvent<AdjustSettings>): void {
    const settings = normalizeSettings(ev.payload.settings);
    const ticks = ev.payload.ticks;
    if (!Number.isSafeInteger(ticks) || ticks === 0) return;
    const direction: Direction = ticks > 0 ? settings.direction : settings.direction === "up" ? "down" : "up";
    const key = `${ev.action.id}:${settings.channel}`;
    const pending = this.pending.get(key) ?? {
      action: ev.action,
      channel: settings.channel,
      delta: 0,
    };
    const amount = Math.abs(ticks) * settings.step;
    pending.delta += direction === "up" ? amount : -amount;
    this.pending.set(key, pending);
    this.scheduleFlush(key, pending);
  }

  private async step(action: ActionSurface, channel: Channel, direction: Direction, amount: number): Promise<void> {
    try {
      await this.runtime.execute([channel, direction, String(amount)]);
    } catch (error) {
      await reportError(action, error);
    }
  }

  private scheduleFlush(key: string, pending: PendingAdjustment): void {
    if (pending.timer || pending.flushing) return;
    pending.timer = setTimeout(() => {
      pending.timer = undefined;
      void this.flush(key, pending);
    }, dialDebounceMs);
  }

  private async flush(key: string, pending: PendingAdjustment): Promise<void> {
    if (this.pending.get(key) !== pending) return;
    const delta = pending.delta;
    pending.delta = 0;
    if (delta === 0) {
      this.pending.delete(key);
      return;
    }
    pending.flushing = true;
    try {
      await this.stepDelta(pending, delta);
    } finally {
      pending.flushing = false;
    }
    if (this.pending.get(key) !== pending) return;
    if (pending.delta !== 0) {
      this.scheduleFlush(key, pending);
    } else {
      this.pending.delete(key);
    }
  }

  private stepDelta(pending: PendingAdjustment, delta: number): Promise<void> {
    // Both channels saturate within a 100% step. Enqueuing more steps would only repeat the mutation.
    return this.step(pending.action, pending.channel, delta > 0 ? "up" : "down", Math.min(100, Math.abs(delta)));
  }

  private commitPending(id: string): void {
    for (const [key, pending] of this.pending) {
      if (pending.action.id !== id) continue;
      if (pending.timer) clearTimeout(pending.timer);
      this.pending.delete(key);
      // Execute enqueues synchronously, so these ticks precede the reset and later ticks follow it.
      if (pending.delta !== 0) void this.stepDelta(pending, pending.delta);
    }
  }

  private clearPending(id: string): void {
    for (const [key, pending] of this.pending) {
      if (pending.action.id !== id) continue;
      if (pending.timer) clearTimeout(pending.timer);
      this.pending.delete(key);
    }
  }
}

function normalizeSettings(settings: AdjustSettings): Required<AdjustSettings> {
  return {
    channel: settings.channel === "whitepoint" ? "whitepoint" : "color",
    direction: settings.direction === "down" ? "down" : "up",
    step: Number.isFinite(settings.step) && (settings.step ?? 0) > 0 ? Math.min(100, settings.step ?? 5) : 5,
  };
}

function renderAdjust(action: AdjustSurface, status: Status, channel: Channel): void {
  const label = channel === "color" ? "Color Temp" : "White Point";
  if (action.isDial()) {
    const level = status[channel];
    safeActionUpdate(action.setFeedback({
      title: status.running ? label : statusLabel(status),
      value: channel === "color" ? dialColorText(action.id, status) : displayValue(level),
      indicator: Math.max(0, Math.min(100, level?.target ?? 0)),
    }));
  } else if (action.isKey()) {
    renderKey(action, status, "#e28e56", status.running ? label : undefined);
  }
}
