import { action, SingletonAction, type WillAppearEvent, type WillDisappearEvent } from "@elgato/streamdeck";
import type { RedlightRuntime } from "../redlight/runtime.js";
import { dialColorText, displayValue, renderKey, safeActionUpdate, statusLabel } from "./action-support.js";

type StatusSettings = Record<string, never>;

@action({ UUID: "com.redlight.app.streamdeck.status" })
export class StatusAction extends SingletonAction<StatusSettings> {
  private readonly subscriptions = new Map<string, () => void>();

  constructor(private readonly runtime: RedlightRuntime) {
    super();
  }

  override onWillAppear(ev: WillAppearEvent<StatusSettings>): void {
    const action = ev.action;
    this.subscriptions.get(action.id)?.();
    const unsubscribe = this.runtime.status.subscribe((status) => {
      if (action.isKey()) {
        renderKey(action, status, "#e29a62");
      } else if (action.isDial()) {
        safeActionUpdate(action.setFeedback({
          title: statusLabel(status),
          color: `Color temp   ${dialColorText(action.id, status)}`,
          whitepoint: `White point   ${displayValue(status.whitepoint)}`,
          indicator1: status.color?.target ?? 0,
          indicator2: status.whitepoint?.target ?? 0,
        }));
      }
    });
    this.subscriptions.set(action.id, unsubscribe);
  }

  override onWillDisappear(ev: WillDisappearEvent<StatusSettings>): void {
    this.subscriptions.get(ev.action.id)?.();
    this.subscriptions.delete(ev.action.id);
  }
}
