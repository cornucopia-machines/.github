// What the Worker knows about GitHub: its webhook signatures, which events concern a board, and starting a
// board's dispatcher workflow.

const CLAUDE_LABEL = "claude";
// The columns that count against the WIP limit: an item leaving them frees a slot
const SLOT_STATUSES = ["In progress", "In review"];
// The check suite conclusions the dispatcher follows up on (as "CI failed")
const FAILED_CONCLUSIONS = ["failure", "timed_out", "action_required", "startup_failure"];

// Checks GitHub's HMAC-SHA256 signature of the request body. crypto.subtle.verify compares in constant time.
export async function verifySignature(secret, body, header) {
  const match = /^sha256=([0-9a-f]{64})$/.exec(header ?? "");
  if (!secret || !match) {
    return false;
  }
  const signature = Uint8Array.from(match[1].match(/../g), (byte) => parseInt(byte, 16));
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  return crypto.subtle.verify("HMAC", key, signature, body);
}

const hasClaudeLabel = (issueOrPr) => (issueOrPr?.labels ?? []).some((label) => label.name === CLAUDE_LABEL);

// The worker's own comments and reviews. Starting a dispatch on them is at best wasted, and at worst starts a
// follow-up run for an item while the worker is still on it, since the dispatcher counts PR comments by anyone.
const byWorker = (payload) =>
  [payload.comment, payload.review].some((item) => item?.performed_via_github_app?.slug === "claude");

// The boards whose dispatcher should look at this event; none if it doesn't concern a board
export function boardsFor(event, payload, allBoards) {
  switch (event) {
    case "projects_v2_item": {
      // GitHub names the project in field changes; when it doesn't, every board looks
      const number = payload.changes?.field_value?.project_number;
      const ofProject = number === undefined ? allBoards : allBoards.filter((board) => board.project === number);
      return projectItemMatters(payload) ? ofProject : [];
    }
    // Issue and PR events don't say which board their item is on, so every board looks: a dispatch that finds
    // nothing new starts no run.
    case "issues":
      return hasClaudeLabel(payload.issue) || payload.label?.name === CLAUDE_LABEL ? allBoards : [];
    case "issue_comment":
      return !byWorker(payload) && hasClaudeLabel(payload.issue) ? allBoards : [];
    case "pull_request":
      // A push to the PR: the worker's own, whose CI result arrives as a check_suite event
      if (payload.action === "synchronize") {
        return [];
      }
      return hasClaudeLabel(payload.pull_request) || payload.label?.name === CLAUDE_LABEL ? allBoards : [];
    case "pull_request_review":
    case "pull_request_review_comment":
      return !byWorker(payload) && hasClaudeLabel(payload.pull_request) ? allBoards : [];
    case "check_suite":
      // The payload has no labels, but the worker's PR branches all start with claude/
      return payload.action === "completed" &&
        FAILED_CONCLUSIONS.includes(payload.check_suite?.conclusion) &&
        (payload.check_suite?.head_branch ?? "").startsWith("claude/")
        ? allBoards
        : [];
    default:
      return [];
  }
}

// Whether a board item's event can give the dispatcher something to start: an item moved to Claude queue, or one
// leaving In progress or In review, which frees a slot
function projectItemMatters(payload) {
  switch (payload.action) {
    // Its Status isn't in the payload, so it might have been in any column
    case "archived":
    case "restored":
    case "deleted":
      return true;
    case "edited": {
      const change = payload.changes?.field_value;
      if (!change || (change.field_name !== undefined && change.field_name !== "Status")) {
        return false;
      }
      // Older payloads don't say what changed
      if (!("from" in change) && !("to" in change)) {
        return true;
      }
      const from = change.from?.name;
      const to = change.to?.name;
      return to === "Claude queue" || (SLOT_STATUSES.includes(from) && !SLOT_STATUSES.includes(to));
    }
    default:
      return false;
  }
}

// Calls workflow_dispatch on the board's dispatcher workflow
export async function dispatchWorkflow(env, board) {
  const response = await fetch(
    `https://api.github.com/repos/${board.repo}/actions/workflows/${board.workflow}/dispatches`,
    {
      method: "POST",
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${env.DISPATCH_TOKEN}`,
        "User-Agent": "claude-queue-trigger",
        "X-GitHub-Api-Version": "2022-11-28",
      },
      body: JSON.stringify({ ref: board.ref ?? "main" }),
    },
  );
  if (!response.ok) {
    throw new Error(`Dispatching ${board.repo} ${board.workflow}: ${response.status} ${await response.text()}`);
  }
}
