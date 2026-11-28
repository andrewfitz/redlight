import { RedlightClient } from "./client.js";
import { CommandQueue } from "./queue.js";
import { StatusStore } from "./status.js";

export type RedlightRuntime = {
  client: RedlightClient;
  status: StatusStore;
  queue: CommandQueue;
  execute: (args: string[]) => Promise<import("./types").Status>;
};

export function createRuntime(): RedlightRuntime {
  const client = new RedlightClient();
  const status = new StatusStore(client);
  const queue = new CommandQueue();
  return {
    client,
    status,
    queue,
    execute: (args) => queue.enqueue(() => status.execute(args)),
  };
}
