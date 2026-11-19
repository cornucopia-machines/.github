import { dispatchWorkflow } from "./github.js";

// At most one dispatch per board in this long. The workflow's concurrency group already serialises runs, but a run
// only reads the board once, and one action of the worker's (such as opening a PR) sends several events at once.
export const DEBOUNCE_MS = 30_000;

// One Durable Object per board, so its dispatches are debounced across every Worker instance: the first poke in a
// while dispatches right away, and the ones within DEBOUNCE_MS of a dispatch share one more, DEBOUNCE_MS after it.
// That last one matters: the run started by the first may already have read the board.
//
// A plain class rather than one extending cloudflare:workers' DurableObject, so the tests run in Node.
export class Debouncer {
  constructor(state, env) {
    this.storage = state.storage;
    this.env = env;
  }

  async fetch(request) {
    const board = await request.json();
    // For the alarm, which gets no request
    await this.storage.put("board", board);
    if ((await this.storage.getAlarm()) !== null) {
      return new Response("Already scheduled");
    }
    const now = Date.now();
    const last = (await this.storage.get("last")) ?? 0;
    if (now - last < DEBOUNCE_MS) {
      await this.storage.setAlarm(last + DEBOUNCE_MS);
      return new Response("Scheduled");
    }
    // Recorded before the request goes out: other pokes can come in while it's waiting for GitHub
    await this.storage.put("last", now);
    try {
      await dispatchWorkflow(this.env, board);
    } catch (error) {
      console.error(error);
      await this.storage.setAlarm(now + DEBOUNCE_MS);
      return new Response("Dispatch failed; retrying");
    }
    return new Response("Dispatched");
  }

  // When it throws, the runtime retries it, with a backoff
  async alarm() {
    await this.storage.put("last", Date.now());
    await dispatchWorkflow(this.env, await this.storage.get("board"));
  }
}
