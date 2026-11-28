import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { runInNewContext } from "node:vm";
import { AdjustAction } from "../.test-build/actions/adjust.js";
import { CommandQueue } from "../.test-build/redlight/queue.js";

test("dial reset stays between earlier and later rotations", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const queue = new CommandQueue();
  const commands = [];
  const action = { id: "dial" };
  const settings = { channel: "whitepoint", step: 25 };
  const adjust = new AdjustAction({
    execute: (args) => queue.enqueue(() => { commands.push(args); }),
  });

  adjust.onDialRotate({ action, payload: { settings, ticks: 10 } });
  const reset = adjust.onDialDown({ action, payload: { settings } });
  adjust.onDialRotate({ action, payload: { settings, ticks: -1 } });
  await reset;
  t.mock.timers.tick(50);
  await queue.enqueue(() => {});

  assert.deepEqual(commands, [
    ["whitepoint", "up", "100"],
    ["reset", "whitepoint"],
    ["whitepoint", "down", "25"],
  ]);
});

test("a reset keeps pending ticks in order while a rotation command is in flight", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const queue = new CommandQueue();
  const commands = [];
  const firstCommand = Promise.withResolvers();
  const action = { id: "dial" };
  const settings = { channel: "color", step: 5 };
  const adjust = new AdjustAction({
    execute: (args) => queue.enqueue(() => {
      commands.push(args);
      if (commands.length === 1) return firstCommand.promise;
    }),
  });

  adjust.onDialRotate({ action, payload: { settings, ticks: 1 } });
  t.mock.timers.tick(50);
  adjust.onDialRotate({ action, payload: { settings, ticks: 30 } });
  const reset = adjust.onDialDown({ action, payload: { settings } });
  adjust.onDialRotate({ action, payload: { settings, ticks: 2 } });
  t.mock.timers.tick(50);
  firstCommand.resolve();
  await reset;
  await queue.enqueue(() => {});

  assert.deepEqual(commands, [
    ["color", "up", "5"],
    ["color", "up", "100"],
    ["reset", "color"],
    ["color", "up", "10"],
  ]);
});

test("dial feedback follows the selected channel as settings change", () => {
  const feedback = [];
  const action = {
    id: "dial",
    isDial: () => true,
    setFeedback: async (value) => { feedback.push(value); },
  };
  const status = {
    running: true,
    color: { target: 50 },
    colorKelvin: { target: 3200 },
    whitepoint: { target: 74 },
  };
  let listener;
  const adjust = new AdjustAction({
    status: {
      status,
      subscribe: (update) => {
        listener = update;
        update(status);
        return () => { listener = undefined; };
      },
    },
  });

  adjust.onWillAppear({ action, payload: { settings: { channel: "whitepoint" } } });
  assert.deepEqual(feedback.at(-1), { title: "White Point", value: "74%", indicator: 74 });
  adjust.onDidReceiveSettings({ action, payload: { settings: { channel: "color" } } });
  assert.deepEqual(feedback.at(-1), { title: "Color Temp", value: "50%", indicator: 50 });
  listener({ ...status, colorKelvin: { target: 3900 } });
  assert.equal(feedback.at(-1).value, "50%");
  adjust.onWillDisappear({ action });
  assert.equal(listener, undefined);
});

test("the Adjust inspector sends a numeric step and retains the last valid value", () => {
  const elements = new Map(["channel", "direction", "direction-label", "step", "colorUnit"].map((id) => [id, {
    addEventListener(_name, handler) { this.change = handler; },
    get valueAsNumber() { return this.value === "" ? NaN : Number(this.value); },
  }]));
  const messages = [];
  let socket;
  class WebSocket {
    static OPEN = 1;
    constructor() { socket = this; }
    send(message) { messages.push(JSON.parse(message)); }
  }
  const html = readFileSync(new URL("../com.redlight.app.streamdeck.sdPlugin/ui/adjust.html", import.meta.url), "utf8");
  const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
  const window = {};
  runInNewContext(script, { WebSocket, window, document: { querySelector: (selector) => elements.get(selector.slice(1)) } });

  window.connectElgatoStreamDeckSocket(1234, "pi-registration", "registerPropertyInspector", "{}", JSON.stringify({
    action: "com.redlight.app.streamdeck.adjust",
    context: "my-dial",
    payload: { controller: "Encoder", settings: { step: 5 } },
  }));

  const channel = elements.get("channel");
  const step = elements.get("step");
  assert.equal(channel.disabled, true);
  socket.readyState = WebSocket.OPEN;
  socket.onopen();
  assert.deepEqual(messages[0], { event: "registerPropertyInspector", uuid: "pi-registration" });
  assert.equal(elements.get("direction-label").textContent, "Clockwise direction");
  assert.equal(channel.disabled, false);

  channel.value = "whitepoint";
  elements.get("colorUnit").value = "kelvin";
  step.value = "7.25";
  step.change();
  const expectedUpdate = {
    event: "setSettings",
    action: "com.redlight.app.streamdeck.adjust",
    context: "my-dial",
    payload: { channel: "whitepoint", colorUnit: "kelvin", direction: "up", step: 7.25 },
  };
  assert.deepEqual(messages.at(-1), expectedUpdate);
  step.value = "101";
  step.change();
  assert.equal(step.value, "7.25");
  assert.deepEqual(messages.at(-1), expectedUpdate);
});
