#!/usr/bin/env bash
# Writes the checked-out commit's version to the step's `version` output. See action.yml for the
# format.
set -euo pipefail

# A shallow clone has no tags to count from, so git describe would silently fall back to the bare
# commit hash: fail instead, and say how to fix it. Fetching the history here would need git
# credentials, which checkouts in the org don't keep (`persist-credentials: false`).
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  echo "::error::The version needs the full history; check out with 'fetch-depth: 0'."
  exit 1
fi

version=$(git describe --tags --always --dirty)
if [[ "$version" == *-dirty && "$FAIL_ON_DIRTY" == true ]]; then
  echo "::error::Tracked files changed since the checkout, so this isn't the commit's version ($version):"
  git status --short --untracked-files=no
  exit 1
fi
echo "Version: $version"
echo "version=$version" >> "$GITHUB_OUTPUT"
