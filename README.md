# Shared GitHub Actions workflows

Reusable workflows and actions for `cornucopia-machines` repos. Each one is maintained here once,
and its pinned actions are kept up to date by Dependabot in this repo. The repo is public, so
public repos (including ones outside the org) can use them too.

GitHub can only enforce a workflow across an organization (required-workflow rulesets) on paid
plans, so every repo opts in with a small caller workflow of its own.

This repo must stay accessible to the rest of the org: **Settings → Actions → General → Access →
"Accessible from repositories in the 'cornucopia-machines' organization"**. Without it, callers
fail with "workflow was not found".

## Secret scan (`secret-scan.yml`)

Runs [TruffleHog](https://github.com/trufflesecurity/trufflehog) over the commits each push or pull
request adds, and fails on secrets that are verified live or can't be verified. Add this to a repo
as `.github/workflows/secret-scan.yml`:

```yaml
name: Secret scan

on:
  push:
    branches: [main]
  pull_request:

jobs:
  secret-scan:
    uses: cornucopia-machines/.github/.github/workflows/secret-scan.yml@main
```

When it finds something, rotate the secret first: deleting it in a new commit leaves it in the
history, where anyone with read access can still find it. Then remove it from the code, and move it
into an env file or a GitHub secret.

To scan a repo's whole history locally, e.g. when adding the workflow to an existing repo:

```bash
trufflehog git file://. --results=verified,unknown
```

## Image vulnerability scanning (Trivy)

Two parts, because a build only sees an image as it was built, and new vulnerabilities get
disclosed while it's deployed:

- **The `trivy-image` action** goes in the build, right after the image is built. It fails on
  vulnerabilities that have a fix (unfixable ones are listed in the job summary; base images always
  carry some), and optionally on Dockerfile misconfigurations.
- **The `trivy-scheduled.yml` workflow** rescans published images weekly and keeps one issue per
  fixable vulnerability in sync, labelled `security`: it opens them, updates them, and closes them
  once the vulnerability is gone.

Both run Trivy from a release pinned by checksum in [`actions/trivy-image/install.sh`](actions/trivy-image/install.sh),
not through Aqua's own actions, whose tags were hijacked in 2026.

In the build, after the image is loaded into the local Docker:

```yaml
      - name: Scan image for vulnerabilities
        uses: cornucopia-machines/.github/actions/trivy-image@main
        with:
          images: my-image:ci
          dockerfile: Dockerfile
          # Leave `library` out where Dependabot already alerts on the image's language packages.
          pkg-types: os,library
```

And as `.github/workflows/image-scan.yml`:

```yaml
name: Image scan

on:
  schedule:
    - cron: '0 6 * * 1'
  workflow_dispatch:

jobs:
  scan:
    permissions:
      contents: read
      packages: read
      issues: write
    uses: cornucopia-machines/.github/.github/workflows/trivy-scheduled.yml@main
    with:
      images: |
        ghcr.io/cornucopia-machines/my-image:latest
```

To skip a finding that doesn't apply, list it in the repo's `.trivyignore` (one ID per line), or
use a `.trivyignore.yaml` to record the reason and an expiry date and point `ignorefile` at it.

The issue sync is a separate action, [`sync-cve-issues`](actions/sync-cve-issues/action.yml), so
other scanners can reuse it by writing their findings in the same JSON format.
