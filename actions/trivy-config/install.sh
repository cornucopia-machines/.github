#!/usr/bin/env bash
# Installs a pinned Trivy release, verified against checksums pinned here rather than the
# release's own checksums file, which would come from the same (possibly compromised) place.
# aquasecurity/trivy-action and setup-trivy aren't used for the same reason: their tags were
# hijacked in 2026 to ship a credential stealer.
#
# To upgrade, bump the version and both checksums from the release's trivy_<version>_checksums.txt:
# https://github.com/aquasecurity/trivy/releases
set -euo pipefail

version=0.76.2
case "$RUNNER_ARCH" in
  X64) asset=Linux-64bit sha256=bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fdbf ;;
  ARM64) asset=Linux-ARM64 sha256=ab9d51f86e6a5fb936f605faff6b593ac51bc378fff4d3e8b9d58358b9c367c3 ;;
  *) echo "::error::No Trivy build pinned for runner architecture $RUNNER_ARCH"; exit 1 ;;
esac

dir="$RUNNER_TEMP/trivy-bin"
mkdir -p "$dir"
curl -fsSL --retry 3 -o "$dir/trivy.tar.gz" \
  "https://github.com/aquasecurity/trivy/releases/download/v$version/trivy_${version}_$asset.tar.gz"
echo "$sha256  $dir/trivy.tar.gz" | sha256sum --check --quiet
tar -xzf "$dir/trivy.tar.gz" -C "$dir" trivy
rm "$dir/trivy.tar.gz"

echo "$dir" >> "$GITHUB_PATH"
{
  echo "TRIVY_CACHE_DIR=$RUNNER_TEMP/trivy-cache"
  echo "TRIVY_NO_PROGRESS=true"
} >> "$GITHUB_ENV"
echo "date=$(date -u +%F)" >> "$GITHUB_OUTPUT"
