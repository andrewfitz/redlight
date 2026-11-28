import assert from "node:assert/strict";
import test from "node:test";
import { PausePeekAction } from "../.test-build/actions/pause-peek.js";
import { CommandQueue } from "../.test-build/redlight/queue.js";

const running = { running: true, on: true };

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((accept, fail) => {
    resolve = accept;
    reject = fail;
  });
  return { promise, resolve, reject };
}

function fixture(handle = () => running) {
  const queue = new CommandQueue();
  const commands = [];
  const alerts = [];
  const action = new PausePeekAction({
    status: { subscribe: () => () => {} },
    execute: ([command, verb]) => queue.enqueue(() => {
      assert.equal(command, "peek");
      commands.push(verb);
      return handle(verb);
    }),
  });

  function appear(id, deviceId = "one") {
    const event = {
      action: {
        id,
        device: { id: deviceId },
        isKey: () => true,
        showAlert: async () => { alerts.push(id); },
        setTitle: async () => {},
      },
    };
    action.onWillAppear(event);
    return event;
  }

  return {
    action,
    appear,
    commands,
    alerts,
    drain: () => queue.enqueue(() => {}),
  };
}

test("a fast tap only releases Peek after a slow Peek start", async () => {
  const initial = deferred();
  const { action, appear, commands } = fixture((verb) => {
    return verb === "on" ? initial.promise : running;
  });
  const key = appear("key");

  const down = action.onKeyDown(key);
  const up = action.onKeyUp(key);
  initial.resolve(running);

  await Promise.all([down, up]);
  assert.deepEqual(commands, ["on", "off"]);
});

test("a long press is measured before the Peek start replies", async () => {
  const initial = deferred();
  const { action, appear, commands } = fixture((verb) => {
    return verb === "on" ? initial.promise : running;
  });
  const key = appear("key");

  const down = action.onKeyDown(key);
  const up = action.onKeyUp(key);
  initial.resolve(running);

  await Promise.all([down, up]);
  assert.deepEqual(commands, ["on", "off"]);
});

test("release and repress retain independent gesture timing and command ordering", async () => {
  const initial = deferred();
  const { action, appear, commands } = fixture((verb) => {
    return verb === "on" ? initial.promise : running;
  });
  const key = appear("key");

  const firstDown = action.onKeyDown(key);
  const firstUp = action.onKeyUp(key);
  const secondDown = action.onKeyDown(key);
  const secondUp = action.onKeyUp(key);
  initial.resolve(running);

  await Promise.all([firstDown, firstUp, secondDown, secondUp]);
  assert.deepEqual(commands, ["on", "off", "on", "off"]);
});

test("failure of a released gesture cannot clear the next press", async () => {
  const initial = deferred();
  let starts = 0;
  const { action, appear, commands, alerts } = fixture((verb) => {
    return verb === "on" && starts++ === 0 ? initial.promise : running;
  });
  const key = appear("key");

  const firstDown = action.onKeyDown(key);
  const firstUp = action.onKeyUp(key);
  const secondDown = action.onKeyDown(key);
  initial.reject(new Error("Peek failed"));
  await Promise.all([firstDown, firstUp, secondDown]);
  await action.onKeyUp(key);

  assert.deepEqual(commands, ["on", "off", "on", "off"]);
  assert.deepEqual(alerts, ["key"]);
});

test("release during a pending renewal stops further heartbeats and queues off", async (context) => {
  context.mock.timers.enable({ apis: ["setInterval"] });
  const renewal = deferred();
  const { action, appear, commands, drain } = fixture((verb) => {
    return verb === "renew" ? renewal.promise : running;
  });
  const key = appear("key");
  await action.onKeyDown(key);

  context.mock.timers.tick(1_500);
  await Promise.resolve();
  assert.deepEqual(commands, ["on", "renew"]);
  context.mock.timers.tick(3_000);
  const up = action.onKeyUp(key);
  renewal.resolve(running);

  await up;
  context.mock.timers.tick(3_000);
  await drain();
  assert.deepEqual(commands, ["on", "renew", "off"]);
});

test("an idle disappearance leaves Redlight's command Peek untouched", async () => {
  const { action, appear, commands } = fixture();
  await action.onWillDisappear(appear("idle"));
  assert.deepEqual(commands, []);
});

test("a key disappearing during startup releases Peek without tapping", async () => {
  const initial = deferred();
  const { action, appear, commands } = fixture((verb) => {
    return verb === "on" ? initial.promise : running;
  });
  const key = appear("key");

  const down = action.onKeyDown(key);
  const disappear = action.onWillDisappear(key);
  initial.resolve(running);

  await Promise.all([down, disappear]);
  assert.deepEqual(commands, ["on", "off"]);
});

test("disconnect releases the last held key and stops renewal", async (context) => {
  context.mock.timers.enable({ apis: ["setInterval"] });
  const { action, appear, commands, drain } = fixture();
  const first = appear("first", "one");
  const second = appear("second", "two");
  await action.onKeyDown(first);
  await action.onKeyDown(second);
  await action.onDeviceDisconnect("one");
  assert.deepEqual(commands, ["on"]);
  await action.onDeviceDisconnect("two");
  context.mock.timers.tick(3_000);
  await drain();
  assert.deepEqual(commands, ["on", "off"]);
});

test("a lost key-up on a connected deck eventually releases Peek and accepts a new press", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval"] });
  const { action, appear, commands, drain } = fixture();
  const key = appear("key");
  await action.onKeyDown(key);
  t.mock.timers.tick(60_000);
  await drain();
  assert.equal(commands.at(-1), "off");
  const afterRelease = commands.length;
  t.mock.timers.tick(5_000);
  await action.onKeyUp(key);
  await drain();
  assert.equal(commands.length, afterRelease);
  await action.onKeyDown(key);
  await action.onKeyUp(key);
  assert.deepEqual(commands.slice(afterRelease), ["on", "off"]);
});
