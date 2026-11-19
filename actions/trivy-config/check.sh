#!/usr/bin/env bash
# Checks each of the newline-separated $PATHS with Trivy, failing on misconfigurations of $SEVERITY,
# and keeps going after a failure so one run reports them all. See action.yml for the inputs.
set -euo pipefail

ignore_args=()
if [ -f "$IGNOREFILE" ]; then
  ignore_args=(--ignorefile "$IGNOREFILE")
fi

status=0
while IFS= read -r path; do
  # Trim the indentation and trailing spaces a YAML block scalar can leave.
  path=$(echo "$path" | xargs)
  [ -z "$path" ] && continue
  trivy config --quiet --severity "$SEVERITY" ${ignore_args[@]+"${ignore_args[@]}"} --exit-code 1 "$path" || status=1
done <<< "$PATHS"
exit "$status"
