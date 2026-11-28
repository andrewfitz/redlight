import { action, SingletonAction, type KeyDownEvent, type WillAppearEvent, type WillDisappearEvent } from "@elgato/streamdeck";
import type { RedlightRuntime } from "../redlight/runtime.js";
import { bindStatus, reportError, renderKey, type ActionSurface } from "./action-support.js";

type ToggleSettings = Record<string, never>;

@action({ UUID: "com.redlight.app.streamdeck.toggle" })
export class ToggleAction extends SingletonAction<ToggleSettings> {
  private readonly subscriptions = new Map<string, () => void>();

  constructor(private readonly runtime: RedlightRuntime, private readonly command = "toggle") {
    super();
  }

  override onWillAppear(ev: WillAppearEvent<ToggleSettings>): void {
    this.bind(ev.action as unknown as ActionSurface);
  }

  override onWillDisappear(ev: WillDisappearEvent<ToggleSettings>): void {
    this.unbind(ev.action.id);
  }

  override async onKeyDown(ev: KeyDownEvent<ToggleSettings>): Promise<void> {
    try {
      await this.runtime.execute([this.command]);
    } catch (error) {
      await reportError(ev.action, error);
    }
  }

  private bind(action: ActionSurface): void {
    this.unbind(action.id);
    this.subscriptions.set(action.id, bindStatus(this.runtime, action, (surface, status) => {
      const label = this.command === "pause" ? "Pause" : this.command === "resume" ? "Resume" : undefined;
      renderKey(surface, status, undefined, label);
    }));
  }

  private unbind(id: string): void {
    this.subscriptions.get(id)?.();
    this.subscriptions.delete(id);
  }
}

@action({ UUID: "com.redlight.app.streamdeck.pause" })
export class PauseAction extends ToggleAction {
  constructor(runtime: RedlightRuntime) { super(runtime, "pause"); }
}

@action({ UUID: "com.redlight.app.streamdeck.resume" })
export class ResumeAction extends ToggleAction {
  constructor(runtime: RedlightRuntime) { super(runtime, "resume"); }
}
