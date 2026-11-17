#!/usr/bin/env bash
# Installs a pinned Grype release, verified against checksums pinned here rather than the release's
# own checksums file, which would come from the same (possibly compromised) place.
#
# To upgrade, bump the version and both checksums from the release's grype_<version>_checksums.txt:
# https://github.com/anchore/grype/releases
set -euo pipefail

version=0.122.0
case "$RUNNER_ARCH" in
  X64) asset=linux_amd64 sha256=e697e6f7224637df87e267e4318cc027feae99a8e1b80280241d32b9ee5d4920 ;;
  ARM64) asset=linux_arm64 sha256=7ebb44a7e69f8ca2491040e140a802117b2bf3ca8360d3856b3e0b9fe79962c4 ;;
  *) echo "::error::No Grype build pinned for runner architecture $RUNNER_ARCH"; exit 1 ;;
esac

dir="$RUNNER_TEMP/grype-bin"
mkdir -p "$dir"
curl -fsSL --retry 3 -o "$dir/grype.tar.gz" \
  "https://github.com/anchore/grype/releases/download/v$version/grype_${version}_$asset.tar.gz"
echo "$sha256  $dir/grype.tar.gz" | sha256sum --check --quiet
tar -xzf "$dir/grype.tar.gz" -C "$dir" grype
rm "$dir/grype.tar.gz"

echo "$dir" >> "$GITHUB_PATH"
{
  echo "GRYPE_DB_CACHE_DIR=$RUNNER_TEMP/grype-db"
  # The version is pinned above; don't nag about newer ones.
  echo "GRYPE_CHECK_FOR_APP_UPDATE=false"
} >> "$GITHUB_ENV"
echo "date=$(date -u +%F)" >> "$GITHUB_OUTPUT"
