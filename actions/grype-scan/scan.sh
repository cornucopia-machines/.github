#!/usr/bin/env bash
# Scans each target in $TARGETS, writes the combined findings to a JSON file (the `findings`
# output), a table of them to the job summary, and fails according to $FAIL_ON.
set -euo pipefail

out="${RUNNER_TEMP:-/tmp}/grype-scan"
mkdir -p "$out"
findings="$out/findings.json"
echo '[]' > "$findings"

config_args=()
[ -f "$CONFIG" ] && config_args=(--config "$CONFIG")

while IFS= read -r target; do
  target=$(echo "$target" | xargs)  # trims surrounding whitespace
  [ -z "$target" ] && continue
  echo "::group::Scanning $target"
  report="$out/report.json"
  # --by-cve: report CVE IDs where the advisory has one (rather than e.g. a GHSA ID), so other
  # scanners' findings and the issues opened from them line up.
  grype "$target" --by-cve --quiet --output json --file "$report" ${config_args[@]+"${config_args[@]}"}
  # The target as shown in summaries and issues, without Grype's scheme prefix.
  label=$(sed -E 's/^(sbom|registry|docker|oci-archive|docker-archive|dir|file):(\/\/)?//' <<< "$target")
  jq --arg target "$label" --arg types "$PKG_TYPES" --arg severity "$SEVERITY" '
    ($types | split(",") | map(select(. != ""))) as $types
    | ($severity | ascii_upcase | split(",")) as $severities
    | [.matches[]
        | select(($types | length) == 0 or (.artifact.type | IN($types[])))
        | select(.vulnerability.severity | ascii_upcase | IN($severities[]))
        | {
            id: .vulnerability.id,
            severity: (.vulnerability.severity | ascii_upcase),
            title: ((.vulnerability.description // ([.relatedVulnerabilities[]?.description | select(. != null)][0]) // "")
              | split("\n")[0] | .[0:200]),
            url: (.vulnerability.dataSource // ""),
            target: $target,
            package: .artifact.name,
            installed: .artifact.version,
            type: .artifact.type,
            fixed: (if .vulnerability.fix.state == "fixed" then (.vulnerability.fix.versions | join(", ")) else "" end)
          }]
    | unique' "$report" > "$out/target.json"
  jq -s 'add' "$findings" "$out/target.json" > "$out/combined.json"
  mv "$out/combined.json" "$findings"
  jq -r '.[] | [.id, .severity, .type, .package, .installed, (if .fixed == "" then "no fix" else .fixed end)] | @tsv' \
    "$out/target.json" | column -t -s $'\t' || true
  echo "::endgroup::"
done <<< "$TARGETS"

echo "findings=$findings" >> "$GITHUB_OUTPUT"

total=$(jq length "$findings")
fixable=$(jq '[.[] | select(.fixed != "")] | length' "$findings")
types=${PKG_TYPES:-all}
{
  echo "### Grype: $SEVERITY vulnerabilities ($types packages)"
  echo
  if [ "$total" -eq 0 ]; then
    echo "None found in:"
    echo
    # shellcheck disable=SC2016 # the backticks are literal Markdown, not command substitution
    grep -v '^[[:space:]]*$' <<< "$TARGETS" | sed 's/^[[:space:]]*/- `/; s/[[:space:]]*$/`/'
  else
    echo "$total found, $fixable with a fix."
    # shellcheck disable=SC2016 # a jq string; the backticks are literal Markdown
    row='"| `\(.target)` | [\(.id)](\(.url)) | \(.severity) | \(.type) | \(.package) | \(.installed) | \(if .fixed == "" then "no fix yet" else .fixed end) |"'
    header=$'| Found in | Vulnerability | Severity | Type | Package | Installed | Fixed in |\n| --- | --- | --- | --- | --- | --- | --- |'
    if [ "$fixable" -gt 0 ]; then
      echo
      echo "$header"
      jq -r ".[] | select(.fixed != \"\") | $row" "$findings"
    fi
    # Unfixable ones are mostly the distro's won't-fix entries; listed, but out of the way.
    if [ "$fixable" -lt "$total" ]; then
      echo
      echo "<details><summary>$((total - fixable)) without a fix</summary>"
      echo
      echo "$header"
      jq -r ".[] | select(.fixed == \"\") | $row" "$findings"
      echo
      echo "</details>"
    fi
  fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

case "$FAIL_ON" in
  none)
    # An annotation, so it shows on the run's (and a PR's) checks rather than only in the log.
    if [ "$fixable" -gt 0 ]; then
      echo "::warning::$fixable $SEVERITY vulnerabilities have a fix available; see the job summary."
    fi
    ;;
  any)
    if [ "$total" -gt 0 ]; then
      echo "::error::$total $SEVERITY vulnerabilities found; see the job summary."
      exit 1
    fi
    ;;
  fixable)
    if [ "$fixable" -gt 0 ]; then
      echo "::error::$fixable $SEVERITY vulnerabilities have a fix available; see the job summary. Update the affected packages (often by rebuilding on a newer base image), or, if one can't apply here, add an ignore rule with the reason to $CONFIG."
      exit 1
    fi
    ;;
  *) echo "::error::Unknown fail-on value: $FAIL_ON"; exit 1 ;;
esac
