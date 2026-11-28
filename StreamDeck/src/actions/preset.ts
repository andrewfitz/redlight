import { action, SingletonAction, type KeyDownEvent, type WillAppearEvent, type WillDisappearEvent } from "@elgato/streamdeck";
import type { RedlightRuntime } from "../redlight/runtime.js";
import type { Status } from "../redlight/types.js";
import { activePresetName, bindStatus, renderKey, reportError, type ActionSurface } from "./action-support.js";

type Preset = "day" | "warm" | "sunset" | "night" | "late";
type PresetSettings = { preset?: Preset };

@action({ UUID: "com.redlight.app.streamdeck.preset" })
export class PresetAction extends SingletonAction<PresetSettings> {
  private readonly subscriptions = new Map<string, () => void>();

  constructor(private readonly runtime: RedlightRuntime) {
    super();
  }

  override onWillAppear(ev: WillAppearEvent<PresetSettings>): void {
    this.bind(ev.action as unknown as ActionSurface);
  }

  override onWillDisappear(ev: WillDisappearEvent<PresetSettings>): void {
    this.unbind(ev.action.id);
  }

  override async onKeyDown(ev: KeyDownEvent<PresetSettings>): Promise<void> {
    const preset = normalizePreset(ev.payload.settings.preset);
    try {
      await this.runtime.execute(["preset", preset]);
    } catch (error) {
      await reportError(ev.action, error);
    }
  }

  private bind(action: ActionSurface): void {
    this.unbind(action.id);
    this.subscriptions.set(action.id, bindStatus(this.runtime, action, (surface, status) => {
      renderPreset(surface, status);
    }));
  }

  private unbind(id: string): void {
    this.subscriptions.get(id)?.();
    this.subscriptions.delete(id);
  }
}

function normalizePreset(value: unknown): Preset {
  if (value === "deep-red") return "late";
  return value === "day" || value === "warm" || value === "sunset" || value === "night" || value === "late"
    ? value
    : "night";
}

function renderPreset(action: ActionSurface, status: Status): void {
  renderKey(action, status, "#d8784e", activePresetName(status));
}
