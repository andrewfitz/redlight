import assert from "node:assert/strict";
import test from "node:test";
import { StatusStore } from "../.test-build/redlight/status.js";

test("a stale poll cannot overwrite a mutation reply", async () => {
  let resolveStatus;
  let resolveCommand;
  const client = {
    status: () => new Promise((resolve) => { resolveStatus = resolve; }),
    command: () => new Promise((resolve) => { resolveCommand = resolve; }),
  };
  const store = new StatusStore(client);
  const updates = [];
  const unsubscribe = store.subscribe((status) => updates.push(status));

  const mutation = store.execute(["toggle"]);
  const freshStatus = { running: true, on: true };
  resolveCommand(freshStatus);
  await mutation;

  resolveStatus({ running: true, on: false });
  await store.refresh();

  assert.deepEqual(store.status, freshStatus);
  assert.deepEqual(updates.at(-1), freshStatus);
  unsubscribe();
});

test("poll failure clears stale readings and successful polling restores them", async () => {
  const offline = new Error("CLI unavailable");
  let result = { running: true, on: true };
  const store = new StatusStore({
    status: async () => {
      if (result === offline) throw offline;
      return result;
    },
  });
  const updates = [];
  const unsubscribe = store.subscribe((status) => updates.push(status));
  try {
    await store.refresh();
    result = offline;
    await assert.rejects(store.refresh(), offline);
    assert.deepEqual(updates.at(-1), { running: false });
    assert.equal(store.lastError, offline);
    result = { running: true, on: false };
    await store.refresh();
    assert.deepEqual(updates.at(-1), result);
    assert.equal(store.lastError, undefined);
  } finally {
    unsubscribe();
  }
});
