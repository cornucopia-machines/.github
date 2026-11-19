// Starts the Claude queue dispatcher (.github/workflows/claude-queue.yml) when something happens that it should look
// at, instead of waiting for a schedule: GitHub sends the org's webhook events here, and an hourly Cron Trigger is the
// fallback for what no event announces (a run that died, a lost delivery). See README.md, "Claude queue trigger".
//
// It only filters events and calls workflow_dispatch: what to start is still worked out by
// scripts/claude-queue-dispatch.sh, from the board's state.

import { boardsFor, verifySignature } from "./github.js";

// The runtime finds the Durable Object class among the main module's exports. Nothing else may be exported from
// here: workerd takes every named export for a handler.
export { Debouncer } from "./debouncer.js";

export default {
  async fetch(request, env) {
    if (request.method !== "POST") {
      return new Response("Not found", { status: 404 });
    }
    const body = await request.arrayBuffer();
    if (!(await verifySignature(env.WEBHOOK_SECRET, body, request.headers.get("X-Hub-Signature-256")))) {
      return new Response("Bad signature", { status: 401 });
    }
    const event = request.headers.get("X-GitHub-Event");
    if (event === "ping") {
      return new Response("pong");
    }
    const payload = JSON.parse(new TextDecoder().decode(body));
    const matched = boardsFor(event, payload, boards(env));
    await Promise.all(matched.map((board) => poke(env, board)));
    const what = matched.length > 0 ? `Dispatching for project ${matched.map((b) => b.project).join(", ")}` : "Ignored";
    console.log(`${event}.${payload.action ?? ""}: ${what}`);
    return new Response(what, { status: 202 });
  },

  async scheduled(controller, env, ctx) {
    ctx.waitUntil(Promise.all(boards(env).map((board) => poke(env, board))));
  },
};

// The boards this Worker serves, from the BOARDS variable in wrangler.jsonc: their project number, and the repo, file
// and ref of their dispatcher workflow
function boards(env) {
  return typeof env.BOARDS === "string" ? JSON.parse(env.BOARDS) : env.BOARDS;
}

// Asks the board's Debouncer to dispatch
async function poke(env, board) {
  const stub = env.DEBOUNCER.get(env.DEBOUNCER.idFromName(String(board.project)));
  const response = await stub.fetch("https://debouncer/poke", { method: "POST", body: JSON.stringify(board) });
  if (!response.ok) {
    throw new Error(`Debouncer for project ${board.project}: ${response.status} ${await response.text()}`);
  }
}
