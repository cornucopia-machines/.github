#!/usr/bin/env bash
# Scans each image in $IMAGES, writes the combined findings to a JSON file (the `findings` output),
# a table of them to the job summary, and fails according to $FAIL_ON.
set -euo pipefail

out="${RUNNER_TEMP:-/tmp}/trivy-image"
mkdir -p "$out"
findings="$out/findings.json"
echo '[]' > "$findings"

# Trivy fails on an --ignorefile that doesn't exist, and most repos won't have one.
ignore_args=()
[ -f "$IGNOREFILE" ] && ignore_args=(--ignorefile "$IGNOREFILE")

while IFS= read -r image; do
  image=$(echo "$image" | xargs)  # trims surrounding whitespace
  [ -z "$image" ] && continue
  echo "::group::Scanning $image"
  report="$out/report-$(echo "$image" | tr -c 'A-Za-z0-9._-' '_').json"
  trivy image --quiet --scanners vuln --pkg-types "$PKG_TYPES" --severity "$SEVERITY" \
    ${ignore_args[@]+"${ignore_args[@]}"} --format json --output "$report" "$image"
  # One entry per vulnerable package; Trivy reports a CVE once per package (and file) it's found in.
  jq --arg image "$image" '[.Results[]? | .Vulnerabilities[]? | {
      id: .VulnerabilityID,
      severity: .Severity,
      title: (.Title // ""),
      url: (.PrimaryURL // ""),
      image: $image,
      package: .PkgName,
      installed: .InstalledVersion,
      fixed: (.FixedVersion // "")
    }] | unique' "$report" > "$out/image.json"
  jq -s 'add' "$findings" "$out/image.json" > "$out/combined.json"
  mv "$out/combined.json" "$findings"
  jq -r '.[] | [.id, .severity, .package, .installed, (if .fixed == "" then "no fix" else .fixed end)] | @tsv' \
    "$out/image.json" | column -t -s $'\t' || true
  echo "::endgroup::"
done <<< "$IMAGES"

echo "findings=$findings" >> "$GITHUB_OUTPUT"

total=$(jq length "$findings")
fixable=$(jq '[.[] | select(.fixed != "")] | length' "$findings")
{
  echo "### Trivy: $SEVERITY vulnerabilities ($PKG_TYPES packages)"
  echo
  if [ "$total" -eq 0 ]; then
    echo "None found in:"
    echo
    grep -v '^[[:space:]]*$' <<< "$IMAGES" | sed 's/^[[:space:]]*/- `/; s/[[:space:]]*$/`/'
  else
    echo "$total found, $fixable with a fix."
    echo
    echo "| Image | Vulnerability | Severity | Package | Installed | Fixed in |"
    echo "| --- | --- | --- | --- | --- | --- |"
    jq -r '.[] | "| `\(.image)` | [\(.id)](\(.url)) | \(.severity) | \(.package) | \(.installed) | \(if .fixed == "" then "no fix yet" else .fixed end) |"' "$findings"
  fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

case "$FAIL_ON" in
  none) ;;
  any)
    if [ "$total" -gt 0 ]; then
      echo "::error::$total $SEVERITY vulnerabilities found; see the job summary."
      exit 1
    fi
    ;;
  fixable)
    if [ "$fixable" -gt 0 ]; then
      echo "::error::$fixable $SEVERITY vulnerabilities have a fix available; see the job summary. Update the affected packages (often by rebuilding on a newer base image), or, if one can't apply here, add it to $IGNOREFILE with the reason."
      exit 1
    fi
    ;;
  *) echo "::error::Unknown fail-on value: $FAIL_ON"; exit 1 ;;
esac
