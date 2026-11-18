#!/usr/bin/env bash
# Adds what bots open across the org to the "Foreseeable work" project, if it isn't on it yet: Dependabot's pull
# requests to In review (they wait for a person's review), and the issues our workflows open (CVE issues, upgrade
# reminders) to Backlog. Run by .github/workflows/board-bot-items.yml; see README.md, "Foreseeable work board".
#
# Needs GH_TOKEN with read access to the org's issues and pull requests, and write access to its projects. With
# DRY_RUN set, it only lists what it would add.
#
# The GraphQL queries' $names are GraphQL variables, passed with -F, not shell ones:
# shellcheck disable=SC2016
set -euo pipefail

org=${ORG:-cornucopia-machines}
project=${PROJECT_NUMBER:-4}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

# The project, its Status field, and the options we set
read -r project_id field_id in_review backlog < <(
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
      (.field.options[] | select(.name == "In review") | .id),
      (.field.options[] | select(.name == "Backlog") | .id)
    ] | join(" ")'
)
if [ -z "${backlog:-}" ]; then
  echo "Project $org/$project has no Status field with In review and Backlog options" >&2
  exit 1
fi

# Every issue and pull request on the project already, archived ones too, so a card someone archived stays archived
on_board=$(gh api graphql --paginate -F org="$org" -F number="$project" -f query='
  query($org: String!, $number: Int!, $endCursor: String) {
    organization(login: $org) {
      projectV2(number: $number) {
        items(first: 100, after: $endCursor) {
          nodes { content { ... on Issue { id } ... on PullRequest { id } } }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }' --jq '.data.organization.projectV2.items.nodes[].content.id // empty' | sort -u)

added=0
# $1: search query, $2: Status option ID, $3: its name, for the summary
add_missing() {
  local query=$1 status=$2 status_name=$3 node url item
  while IFS=$'\t' read -r node url; do
    [ -n "$node" ] || continue
    if grep -qxF "$node" <<< "$on_board"; then
      continue
    fi
    if [ -n "${DRY_RUN:-}" ]; then
      echo "Would add $url ($status_name)"
      added=$((added + 1))
      continue
    fi
    item=$(gh api graphql -F project="$project_id" -F content="$node" -f query='
      mutation($project: ID!, $content: ID!) {
        addProjectV2ItemById(input: {projectId: $project, contentId: $content}) { item { id } }
      }' --jq .data.addProjectV2ItemById.item.id)
    gh api graphql -F project="$project_id" -F item="$item" -F field="$field_id" -F option="$status" -f query='
      mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
        updateProjectV2ItemFieldValue(input: {
          projectId: $project, itemId: $item, fieldId: $field, value: {singleSelectOptionId: $option}
        }) { projectV2Item { id } }
      }' > /dev/null
    echo "Added $url ($status_name)"
    echo "- $url → $status_name" >> "$summary"
    added=$((added + 1))
  done < <(gh api --method GET search/issues --paginate -f q="$query" -f per_page=100 \
    --jq '.items[] | [.node_id, .html_url] | @tsv')
}

echo "### Added to the board" >> "$summary"
add_missing "org:$org is:open is:pr author:app/dependabot" "$in_review" "In review"
add_missing "org:$org is:open is:issue author:app/github-actions" "$backlog" "Backlog"
if [ "$added" -eq 0 ]; then
  echo "Nothing new." | tee -a "$summary"
fi
