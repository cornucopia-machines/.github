import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { afterEach, beforeEach, describe, it, mock } from "node:test";

import { DEBOUNCE_MS, Debouncer } from "../src/debouncer.js";
import { boardsFor, verifySignature } from "../src/github.js";
import worker from "../src/index.js";

const board4 = { project: 4, repo: "cornucopia-machines/.github", workflow: "claude-queue.yml", ref: "main" };
const board9 = { project: 9, repo: "cornucopia-machines/project-boards", workflow: "claude-queue.yml" };
const boards = [board4, board9];

const sign = (secret, body) => `sha256=${createHmac("sha256", secret).update(body).digest("hex")}`;
const labelled = (...names) => ({ labels: names.map((name) => ({ name })) });

describe("verifySignature", () => {
  const body = new TextEncoder().encode('{"zen":"Keep it logically awesome."}');

  it("accepts GitHub's signature", async () => {
    assert.equal(await verifySignature("s3cret", body, sign("s3cret", body)), true);
  });

  it("rejects another secret's signature", async () => {
    assert.equal(await verifySignature("s3cret", body, sign("other", body)), false);
  });

  it("rejects a missing or malformed header", async () => {
    assert.equal(await verifySignature("s3cret", body, null), false);
    assert.equal(await verifySignature("s3cret", body, "sha1=abc"), false);
    assert.equal(await verifySignature("s3cret", body, "sha256=zz"), false);
  });

  it("rejects everything without a secret", async () => {
    assert.equal(await verifySignature(undefined, body, sign("", body)), false);
  });
});

describe("boardsFor", () => {
  const statusChange = (from, to, extra = {}) => ({
    action: "edited",
    changes: {
      field_value: {
        field_name: "Status",
        project_number: 4,
        from: from && { name: from },
        to: to && { name: to },
        ...extra,
      },
    },
  });

  describe("projects_v2_item", () => {
    it("dispatches the item's board when an item moves to Claude queue", () => {
      assert.deepEqual(boardsFor("projects_v2_item", statusChange("Backlog", "Claude queue"), boards), [board4]);
    });

    it("dispatches when an item leaves In progress or In review", () => {
      assert.deepEqual(boardsFor("projects_v2_item", statusChange("In review", "Done"), boards), [board4]);
      assert.deepEqual(boardsFor("projects_v2_item", statusChange("In progress", "Backlog"), boards), [board4]);
      assert.deepEqual(boardsFor("projects_v2_item", statusChange("In progress", null), boards), [board4]);
    });

    it("ignores moves that don't free a slot or fill the queue", () => {
      // The dispatcher's own move when it takes an item
      assert.deepEqual(boardsFor("projects_v2_item", statusChange("Claude queue", "In progress"), boards), []);
      assert.deepEqual(boardsFor("projects_v2_item", statusChange("In progress", "In review"), boards), []);
      assert.deepEqual(boardsFor("projects_v2_item", statusChange(null, "Backlog"), boards), []);
    });

    it("ignores other fields", () => {
      const payload = statusChange("a", "Claude queue", { field_name: "Priority" });
      assert.deepEqual(boardsFor("projects_v2_item", payload, boards), []);
    });

    it("dispatches every board when the payload doesn't name the project", () => {
      const payload = statusChange("Backlog", "Claude queue", { project_number: undefined });
      assert.deepEqual(boardsFor("projects_v2_item", payload, boards), boards);
    });

    it("dispatches when the payload doesn't say what changed", () => {
      const payload = { action: "edited", changes: { field_value: { field_name: "Status", project_number: 9 } } };
      assert.deepEqual(boardsFor("projects_v2_item", payload, boards), [board9]);
    });

    it("dispatches when an item is archived, restored or deleted", () => {
      for (const action of ["archived", "restored", "deleted"]) {
        assert.deepEqual(boardsFor("projects_v2_item", { action }, boards), boards, action);
      }
    });

    it("ignores new and reordered items", () => {
      assert.deepEqual(boardsFor("projects_v2_item", { action: "created" }, boards), []);
      assert.deepEqual(boardsFor("projects_v2_item", { action: "reordered" }, boards), []);
    });
  });

  it("dispatches every board for Claude's issues", () => {
    assert.deepEqual(boardsFor("issues", { action: "closed", issue: labelled("bug", "claude") }, boards), boards);
    // The label removed when an item is handed back
    const unlabeled = { action: "unlabeled", issue: labelled(), label: { name: "claude" } };
    assert.deepEqual(boardsFor("issues", unlabeled, boards), boards);
    assert.deepEqual(boardsFor("issues", { action: "closed", issue: labelled("bug") }, boards), []);
  });

  it("dispatches for a person's comment on Claude's issue, not the worker's", () => {
    const issue = labelled("claude", "question");
    assert.deepEqual(boardsFor("issue_comment", { issue, comment: { performed_via_github_app: null } }, boards), boards);
    const own = { issue, comment: { performed_via_github_app: { slug: "claude" } } };
    assert.deepEqual(boardsFor("issue_comment", own, boards), []);
    assert.deepEqual(boardsFor("issue_comment", { issue: labelled(), comment: {} }, boards), []);
  });

  it("dispatches for Claude's PRs, except for pushes", () => {
    const closed = { action: "closed", pull_request: labelled("claude") };
    assert.deepEqual(boardsFor("pull_request", closed, boards), boards);
    const pushed = { action: "synchronize", pull_request: labelled("claude") };
    assert.deepEqual(boardsFor("pull_request", pushed, boards), []);
    assert.deepEqual(boardsFor("pull_request", { action: "closed", pull_request: labelled() }, boards), []);
  });

  it("dispatches for a person's review on Claude's PR, not the worker's", () => {
    const pr = labelled("claude");
    assert.deepEqual(boardsFor("pull_request_review", { pull_request: pr, review: {} }, boards), boards);
    assert.deepEqual(boardsFor("pull_request_review_comment", { pull_request: pr, comment: {} }, boards), boards);
    const own = { pull_request: pr, comment: { performed_via_github_app: { slug: "claude" } } };
    assert.deepEqual(boardsFor("pull_request_review_comment", own, boards), []);
    assert.deepEqual(boardsFor("pull_request_review", { pull_request: labelled(), review: {} }, boards), []);
  });

  it("dispatches for failed CI on the worker's branches", () => {
    const suite = (conclusion, branch = "claude/116-trigger") => ({
      action: "completed",
      check_suite: { conclusion, head_branch: branch },
    });
    assert.deepEqual(boardsFor("check_suite", suite("failure"), boards), boards);
    assert.deepEqual(boardsFor("check_suite", suite("timed_out"), boards), boards);
    assert.deepEqual(boardsFor("check_suite", suite("success"), boards), []);
    assert.deepEqual(boardsFor("check_suite", suite("failure", "main"), boards), []);
    assert.deepEqual(boardsFor("check_suite", { action: "requested", check_suite: {} }, boards), []);
  });

  it("ignores other events", () => {
    assert.deepEqual(boardsFor("push", { ref: "refs/heads/main" }, boards), []);
  });
});

// A Durable Object's storage, in memory
class FakeStorage {
  constructor() {
    this.values = new Map();
    this.alarm = null;
  }
  async get(key) {
    return this.values.get(key);
  }
  async put(key, value) {
    this.values.set(key, value);
  }
  async getAlarm() {
    return this.alarm;
  }
  async setAlarm(time) {
    this.alarm = time;
  }
}

describe("Debouncer", () => {
  let storage;
  let debouncer;
  let dispatches;
  let status;

  beforeEach(() => {
    storage = new FakeStorage();
    debouncer = new Debouncer({ storage }, { DISPATCH_TOKEN: "token" });
    dispatches = [];
    status = 204;
    mock.method(globalThis, "fetch", async (url, init) => {
      dispatches.push({ url, init });
      return new Response(status === 204 ? null : "Bad credentials", { status });
    });
    mock.timers.enable({ apis: ["Date"], now: 1_000_000 });
  });

  afterEach(() => {
    mock.restoreAll();
    mock.timers.reset();
  });

  const poke = () =>
    debouncer.fetch(new Request("https://debouncer/poke", { method: "POST", body: JSON.stringify(board4) }));

  it("dispatches the board's workflow right away", async () => {
    assert.equal(await (await poke()).text(), "Dispatched");
    assert.equal(dispatches.length, 1);
    assert.equal(
      dispatches[0].url,
      "https://api.github.com/repos/cornucopia-machines/.github/actions/workflows/claude-queue.yml/dispatches",
    );
    assert.equal(dispatches[0].init.headers.Authorization, "Bearer token");
    assert.deepEqual(JSON.parse(dispatches[0].init.body), { ref: "main" });
    assert.equal(storage.alarm, null);
  });

  it("collects the pokes after a dispatch into one more, DEBOUNCE_MS after it", async () => {
    await poke();
    mock.timers.tick(5_000);
    assert.equal(await (await poke()).text(), "Scheduled");
    assert.equal(storage.alarm, 1_000_000 + DEBOUNCE_MS);
    mock.timers.tick(5_000);
    assert.equal(await (await poke()).text(), "Already scheduled");
    assert.equal(dispatches.length, 1);

    mock.timers.tick(DEBOUNCE_MS);
    storage.alarm = null; // The runtime clears it before calling alarm()
    await debouncer.alarm();
    assert.equal(dispatches.length, 2);
  });

  it("dispatches right away again once DEBOUNCE_MS has passed", async () => {
    await poke();
    mock.timers.tick(DEBOUNCE_MS);
    assert.equal(await (await poke()).text(), "Dispatched");
    assert.equal(dispatches.length, 2);
  });

  it("retries a failed dispatch with an alarm", async () => {
    status = 401;
    mock.method(console, "error", () => {});
    assert.equal(await (await poke()).text(), "Dispatch failed; retrying");
    assert.equal(storage.alarm, 1_000_000 + DEBOUNCE_MS);
  });

  it("throws from the alarm when the dispatch fails, so the runtime retries it", async () => {
    await poke();
    status = 500;
    await assert.rejects(debouncer.alarm(), /500/);
  });
});

describe("fetch", () => {
  const secret = "s3cret";
  let pokes;
  const env = {
    WEBHOOK_SECRET: secret,
    BOARDS: JSON.stringify(boards),
    DEBOUNCER: {
      idFromName: (name) => name,
      get: (id) => ({
        fetch: async (url, init) => {
          pokes.push({ id, board: JSON.parse(init.body) });
          return new Response("Dispatched");
        },
      }),
    },
  };

  beforeEach(() => {
    pokes = [];
    mock.method(console, "log", () => {});
  });

  afterEach(() => mock.restoreAll());

  const deliver = (event, payload, signature) => {
    const body = JSON.stringify(payload);
    return worker.fetch(
      new Request("https://claude-queue-trigger.example.workers.dev/", {
        method: "POST",
        headers: { "X-GitHub-Event": event, "X-Hub-Signature-256": signature ?? sign(secret, body) },
        body,
      }),
      env,
    );
  };

  it("pokes the boards an event concerns", async () => {
    const response = await deliver("issue_comment", { action: "created", issue: labelled("claude"), comment: {} });
    assert.equal(response.status, 202);
    assert.deepEqual(pokes, [
      { id: "4", board: board4 },
      { id: "9", board: board9 },
    ]);
  });

  it("ignores events that don't concern a board", async () => {
    const response = await deliver("issues", { action: "opened", issue: labelled() });
    assert.equal(await response.text(), "Ignored");
    assert.deepEqual(pokes, []);
  });

  it("answers GitHub's ping", async () => {
    assert.equal(await (await deliver("ping", { zen: "Design for failure." })).text(), "pong");
  });

  it("rejects unsigned requests", async () => {
    const response = await deliver("issues", { issue: labelled("claude") }, "sha256=" + "0".repeat(64));
    assert.equal(response.status, 401);
    assert.deepEqual(pokes, []);
  });

  it("only takes POSTs", async () => {
    const response = await worker.fetch(new Request("https://claude-queue-trigger.example.workers.dev/"), env);
    assert.equal(response.status, 404);
  });
});
