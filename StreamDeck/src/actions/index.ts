import streamDeck from "@elgato/streamdeck";
import type { RedlightRuntime } from "../redlight/runtime.js";
import { setColorUnit } from "./action-support.js";
import { AdjustAction } from "./adjust.js";
import { PausePeekAction } from "./pause-peek.js";
import { PresetAction } from "./preset.js";
import { StatusAction } from "./status.js";
import { PauseAction, ResumeAction, ToggleAction } from "./toggle.js";

export function registerActions(runtime: RedlightRuntime): void {
  streamDeck.actions.onWillAppear(({ action, payload }) => setColorUnit(action.id, payload.settings.colorUnit));
  streamDeck.settings.onDidReceiveSettings(({ action, payload }) => {
    setColorUnit(action.id, payload.settings.colorUnit);
    runtime.status.redraw();
  });
  streamDeck.actions.onWillDisappear(({ action }) => setColorUnit(action.id));
  const pausePeek = new PausePeekAction(runtime);
  streamDeck.devices.onDeviceDidDisconnect(({ device }) => {
    void pausePeek.onDeviceDisconnect(device.id);
  });
  const actions = [
    new ToggleAction(runtime),
    pausePeek,
    new PauseAction(runtime),
    new ResumeAction(runtime),
    new PresetAction(runtime),
    new AdjustAction(runtime),
    new StatusAction(runtime),
  ];
  for (const action of actions) streamDeck.actions.registerAction(action);
}
