#!/usr/bin/env bash
# Uploads the files matching $PATTERNS to the release of $TAG in $GH_REPO. See action.yml for the inputs.
set -euo pipefail
shopt -s globstar nullglob

case "$CLOBBER" in
  true) clobber_args=(--clobber) ;;
  false) clobber_args=() ;;
  *)
    echo "::error::clobber must be true or false, not '$CLOBBER'"
    exit 1
    ;;
esac

case "$IF_NO_RELEASE" in
  fail | create | warn) ;;
  *)
    echo "::error::if-no-release must be fail, create or warn, not '$IF_NO_RELEASE'"
    exit 1
    ;;
esac

files=()
while IFS= read -r pattern; do
  pattern=$(echo "$pattern" | xargs)
  [ -z "$pattern" ] && continue
  # Unquoted on purpose, to expand the glob (so a path with spaces needs them escaped).
  # shellcheck disable=SC2206
  matches=($pattern)
  if [ "${#matches[@]}" -eq 0 ]; then
    echo "::error::No files match '$pattern'"
    exit 1
  fi
  for match in "${matches[@]}"; do
    [ -f "$match" ] && files+=("$match")
  done
done <<< "$PATTERNS"
if [ "${#files[@]}" -eq 0 ]; then
  echo "::error::No files to upload"
  exit 1
fi

# A draft release (e.g. Release Drafter's) counts: gh finds it by its tag too.
if ! gh release view "$TAG" > /dev/null 2>&1; then
  case "$IF_NO_RELEASE" in
    create)
      echo "Creating the release of $TAG with ${#files[@]} file(s)"
      gh release create "$TAG" "${files[@]}" --verify-tag --title "$TAG" --notes ""
      exit 0
      ;;
    warn)
      echo "::warning::$TAG has no release, so its files weren't uploaded; download them from this run's artifacts"
      exit 0
      ;;
    fail)
      echo "::error::$TAG has no release"
      exit 1
      ;;
  esac
fi

echo "Uploading ${#files[@]} file(s) to the release of $TAG"
gh release upload "$TAG" "${files[@]}" ${clobber_args[@]+"${clobber_args[@]}"}
