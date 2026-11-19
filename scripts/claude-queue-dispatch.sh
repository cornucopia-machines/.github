#!/usr/bin/env bash
# Starts Claude's worker routine for the "Foreseeable work" project's Claude queue: one run per free slot under the
# WIP limit, each for the next item in the queue, and one run for each of Claude's items that has something new to
# follow up. Run by .github/workflows/claude-queue.yml; see README.md, "Claude queue dispatcher".
#
# It only reads GitHub and moves items' Status; the worker does everything else. When it starts a run for a new item,
# it moves the item to In progress first, so the next dispatch doesn't take it again.
#
# Needs GH_TOKEN with read access to the org's issues, pull requests and checks, and write access to its projects,
# and FIRE_TOKEN, the worker routine's API trigger token. With DRY_RUN set, it only says what it would do (and needs
# no FIRE_TOKEN).
#
# The GraphQL queries' $names are GraphQL variables, passed with -F, not shell ones:
# shellcheck disable=SC2016
set -euo pipefail

org=${ORG:-cornucopia-machines}
project=${PROJECT_NUMBER:-4}
wip_limit=${WIP_LIMIT:-3}
stale_hours=${STALE_HOURS:-3}
# The worker routine, and the repos it checks out: items from other repos stay in the queue
routine=${ROUTINE_ID:?}
read -r -a worker_repos <<< "${WORKER_REPOS:?}"
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
dry_run=${DRY_RUN:-}

say() {
  echo "$*"
  echo "- $*" >> "$summary"
}

# The project, its Status field, and the options we use
read -r project_id field_id opt_queue opt_progress opt_done < <(
  gh api graphql -F org="$org" -F number="$project" -f query='
    query($org: String!, $number: Int!) {
      organization(login: $org) {
        projectV2(number: $number) {
          id
          field(name: "Status") { ... on ProjectV2SingleSelectField { id options { id name } } }
        }
      }
    }' --jq '.data.organization.projectV2 | [
      .id,
      .field.id,
      (.field.options[] | select(.name == "Claude queue") | .id),
      (.field.options[] | select(.name == "In progress") | .id),
      (.field.options[] | select(.name == "Done") | .id)
    ] | join(" ")'
)
if [ -z "${opt_done:-}" ]; then
  echo "Project $org/$project has no Status field with Claude queue, In progress and Done options" >&2
  exit 1
fi

# Every item that isn't archived, in board order (which is queue order), one JSON object per line
items=$(gh api graphql --paginate -F org="$org" -F number="$project" -f query='
  query($org: String!, $number: Int!, $endCursor: String) {
    organization(login: $org) {
      projectV2(number: $number) {
        items(first: 100, after: $endCursor) {
          nodes {
            id
            isArchived
            type
            status: fieldValueByName(name: "Status") {
              ... on ProjectV2ItemFieldSingleSelectValue { name updatedAt }
            }
            content {
              ... on Issue { number state repository { nameWithOwner } labels(first: 50) { nodes { name } } }
              ... on PullRequest { number state repository { nameWithOwner } }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }' --jq '.data.organization.projectV2.items.nodes[] | select(.isArchived | not) | {
    id,
    type,
    status: .status.name,
    status_at: .status.updatedAt,
    repo: .content.repository.nameWithOwner,
    number: .content.number,
    state: .content.state,
    claude: ([.content.labels.nodes[]?.name] | index("claude") != null)
  }')

set_status() { # $1: item ID, $2: option ID
  gh api graphql -F project="$project_id" -F item="$1" -F field="$field_id" -F option="$2" -f query='
    mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $project, itemId: $item, fieldId: $field, value: {singleSelectOptionId: $option}
      }) { projectV2Item { id } }
    }' > /dev/null
}

failed=0
# Starts a worker run with $1 as its payload, and prints its session link
fire() {
  if [ -n "$dry_run" ]; then
    echo "(dry run)"
    return
  fi
  local body
  body=$(jq -n --arg text "$1" '{text: $text}')
  # No --retry: the endpoint has no idempotency key, so a retry could start a second run
  curl -sS --fail-with-body -X POST "https://api.anthropic.com/v1/claude_code/routines/$routine/fire" \
    -H @<(printf 'Authorization: Bearer %s\n' "${FIRE_TOKEN:?}") \
    -H 'anthropic-version: 2023-06-01' \
    -H 'anthropic-beta: experimental-cc-routine-2026-04-01' \
    -H 'content-type: application/json' \
    -d "$body" | jq -r .claude_code_session_url |
    # The link comes back with the session's cse_ ID, which claude.ai doesn't open; its session_ form does
    sed 's|/code/cse_|/code/session_|'
}

can_reach() {
  local repo
  for repo in "${worker_repos[@]}"; do
    [ "$repo" = "$1" ] && return 0
  done
  return 1
}

# What's new for one of Claude's issues since the worker last touched it, one reason per line (nothing if it's all
# been seen). $1: repo, $2: issue number, $3: Status, $4: when the Status last changed.
#
# The worker edits its tracking comment on the issue (first line `<!-- claude-queue -->`) at the start and at the end
# of every run, so anything newer than that edit, or than the Status change, is something it hasn't seen yet.
followup_reasons() {
  local repo=$1 number=$2 status=$3 status_at=$4 issue since prs pr
  issue=$(gh api graphql -F owner="${repo%/*}" -F name="${repo#*/}" -F number="$number" -f query='
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        issue(number: $number) {
          comments(last: 100) { nodes { body createdAt updatedAt } }
          closedByPullRequestsReferences(first: 20, includeClosedPrs: true) {
            nodes { number repository { nameWithOwner } }
          }
        }
      }
    }' --jq '.data.repository.issue')
  since=$(jq -r --arg status_at "$status_at" '
    [$status_at, (.comments.nodes[] | select(.body | startswith("<!-- claude-queue -->")) | .updatedAt)] | max
  ' <<< "$issue")
  jq -r --arg since "$since" '
    .comments.nodes[] | select((.body | startswith("<!-- claude-queue -->") | not) and .createdAt > $since)
    | "new comment on the issue (\(.createdAt))"
  ' <<< "$issue" | sort -u | head -n 1
  # The PRs the tracking comment lists, and the ones that close the issue
  prs=$(jq -r --arg self "$repo#$number" '
    [
      (.comments.nodes[] | select(.body | startswith("<!-- claude-queue -->")) | .body
        | scan("[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+")),
      (.closedByPullRequestsReferences.nodes[] | "\(.repository.nameWithOwner)#\(.number)")
    ] | unique[] | select(. != $self)
  ' <<< "$issue")
  local open_prs=0
  for pr in $prs; do
    local pr_repo=${pr%#*} pr_number=${pr##*#} data
    data=$(gh api graphql -F owner="${pr_repo%/*}" -F name="${pr_repo#*/}" -F number="$pr_number" -f query='
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          issueOrPullRequest(number: $number) {
            ... on PullRequest {
              state
              merged
              closedAt
              mergeable
              baseRef { target { ... on Commit { committedDate } } }
              reviews(last: 50) { nodes { submittedAt } }
              reviewThreads(last: 50) { nodes { comments(last: 50) { nodes { createdAt } } } }
              comments(last: 50) { nodes { createdAt } }
              commits(last: 1) {
                nodes {
                  commit {
                    statusCheckRollup {
                      contexts(first: 100) {
                        nodes {
                          __typename
                          ... on CheckRun { name conclusion completedAt }
                          ... on StatusContext { context state createdAt }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }' --jq '.data.repository.issueOrPullRequest') || {
      echo "Couldn't read $pr" >&2
      continue
    }
    # Not a pull request: an issue the tracking comment mentions
    [ -n "$(jq -r '.state // empty' <<< "$data")" ] || continue
    [ "$(jq -r .state <<< "$data")" = OPEN ] && open_prs=$((open_prs + 1))
    jq -r --arg since "$since" --arg pr "$pr" '
      if .state != "OPEN" then
        select(.closedAt > $since) | "\($pr) was \(if .merged then "merged" else "closed without merging" end)"
      else
        (select([.reviews.nodes[].submittedAt | select(. > $since)] | length > 0) | "new review on \($pr)"),
        (select([.reviewThreads.nodes[].comments.nodes[].createdAt | select(. > $since)] | length > 0)
          | "new review comment on \($pr)"),
        (select([.comments.nodes[].createdAt | select(. > $since)] | length > 0) | "new comment on \($pr)"),
        ([.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]?
          | select(
              (.__typename == "CheckRun"
                and (.conclusion | IN("FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"))
                and .completedAt > $since)
              or (.__typename == "StatusContext" and (.state | IN("FAILURE", "ERROR")) and .createdAt > $since))
          | .name // .context] | select(length > 0) | "CI failed on \($pr): \(join(", "))"),
        # A conflict comes from the base branch moving, so only once per change there
        (select(.mergeable == "CONFLICTING" and (.baseRef.target.committedDate // "") > $since)
          | "\($pr) has a merge conflict")
      end
    ' <<< "$data"
  done
  if [ "$status" = "In progress" ] && [ "$open_prs" -eq 0 ] &&
    jq -en --arg since "$since" --argjson hours "$stale_hours" 'now - ($since | fromdateiso8601) > $hours * 3600' \
      > /dev/null; then
    echo "in progress for over $stale_hours hours with no open PR (since $since)"
  fi
}

echo "### Claude queue" >> "$summary"

# Closed issues left in the queue are done
while IFS=$'\t' read -r id ref; do
  [ -n "$dry_run" ] || set_status "$id" "$opt_done"
  say "$ref is closed: moved to Done"
done < <(jq -r 'select(.status == "Claude queue" and .type == "ISSUE" and .state == "CLOSED")
  | [.id, "\(.repo)#\(.number)"] | @tsv' <<< "$items")

# Follow-ups on Claude's items
while IFS=$'\t' read -r repo number status status_at; do
  reasons=$(followup_reasons "$repo" "$number" "$status" "$status_at")
  [ -n "$reasons" ] || continue
  text=$(printf 'follow up %s#%s\n%s\n' "$repo" "$number" "- ${reasons//$'\n'/$'\n- '}")
  if session=$(fire "$text"); then
    say "Follow-up on $repo#$number ($(paste -sd ';' <<< "$reasons" | sed 's/;/; /g')): $session"
  else
    say "Couldn't start a follow-up on $repo#$number"
    failed=1
  fi
done < <(jq -r 'select(.type == "ISSUE" and .state == "OPEN" and .claude
  and (.status == "In progress" or .status == "In review"))
  | [.repo, .number, .status, .status_at] | @tsv' <<< "$items")

# New items, up to the WIP limit. Only Claude's own issues count (`claude` label), not the cards of its PRs, nor what
# a person is working on. An item this script claimed gets the label within a minute or two of its run starting, well
# before the next dispatch.
wip=$(jq -s '[.[] | select(.type == "ISSUE" and .state == "OPEN" and .claude
  and (.status == "In progress" or .status == "In review"))] | length' <<< "$items")
free=$((wip_limit - wip))
echo "In progress or In review: $wip of $wip_limit"
while [ "$free" -gt 0 ] && IFS=$'\t' read -r id type repo number; do
  ref="$repo#$number"
  if [ "$type" != ISSUE ]; then
    say "Skipped a $type item in the queue: only issues can be taken"
    continue
  fi
  if ! can_reach "$repo"; then
    say "Skipped $ref: the worker doesn't check out $repo"
    continue
  fi
  [ -n "$dry_run" ] || set_status "$id" "$opt_progress"
  if session=$(fire "take $ref"); then
    say "Took $ref: $session"
    free=$((free - 1))
  else
    # Give it back to the queue, so the next dispatch tries again
    set_status "$id" "$opt_queue"
    say "Couldn't start a run for $ref; it's back in the queue"
    failed=1
    break
  fi
done < <(jq -r 'select(.status == "Claude queue" and (.type != "ISSUE" or .state == "OPEN"))
  | [.id, .type, (.repo // "-"), (.number // "-")] | @tsv' <<< "$items")
if [ "$free" -le 0 ]; then
  echo "WIP limit reached" >> "$summary"
fi

exit "$failed"
