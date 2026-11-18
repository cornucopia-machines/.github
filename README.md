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

## Vulnerability scanning (Grype)

Two parts, because a build only sees an image as it was built, and new vulnerabilities get
disclosed while it's deployed:

- **The [`grype-scan`](actions/grype-scan/action.yml) action** goes in the build. It scans an SBOM
  (Syft's, or ESP-IDF's for firmware) or an image, lists the findings in the job summary, and fails
  on the ones that have a fix. Unfixable ones are only listed; base images always carry some. Where
  the fix isn't in your hands (a distroless base gets distro fixes only when it's rebuilt), set
  `fail-on: none` to warn instead.
- **The [`scheduled-image-scan.yml`](.github/workflows/scheduled-image-scan.yml) workflow**
  rescans published images on a schedule and keeps one issue per fixable vulnerability in sync,
  labelled `security`: it opens them, updates them, and closes them once the vulnerability is gone.

Limit `pkg-types` to what nothing else covers, so a vulnerability isn't reported twice. Dependabot
already alerts on npm, pip and the like from the lockfiles, so an image usually needs `deb` (or
`apk`) for the distro's packages, and `binary` for runtimes found by their executables, such as the
Node binary in a distroless image, which no package manager lists.

In the build, after generating the image's SBOM (or scanning `docker:my-image:ci` directly):

```yaml
      - name: Check the image for vulnerabilities
        uses: cornucopia-machines/.github/actions/grype-scan@main
        with:
          targets: sbom:my-image.syft.cdx.json
          pkg-types: deb,binary
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
    uses: cornucopia-machines/.github/.github/workflows/scheduled-image-scan.yml@main
    with:
      images: |
        ghcr.io/cornucopia-machines/my-image:latest
      pkg-types: deb,binary
```

To skip a finding that doesn't apply, add an `ignore` rule to the repo's `.grype.yaml`, with a
comment saying why.

For images you don't build, set `group-by: target`: one issue per image, listing its
vulnerabilities, since the fix is updating or replacing the image rather than anything per
vulnerability. `issues: false` only lists the findings in the job summary.

The issue sync is a separate action, [`sync-cve-issues`](actions/sync-cve-issues/action.yml), so
other scanners can reuse it by writing their findings in the same JSON format.

## Misconfiguration checks (Trivy)

The [`trivy-config`](actions/trivy-config/action.yml) action checks Dockerfiles, compose files and
the like for security misconfigurations, such as running as root or privileged containers, and fails
on any. Grype doesn't do this.

```yaml
      - name: Check the Dockerfile
        uses: cornucopia-machines/.github/actions/trivy-config@main
        with:
          paths: Dockerfile
```

Grype and Trivy are installed from releases pinned by checksum in each action's `install.sh`, not
through the vendors' own actions; Aqua's Trivy action tags were hijacked in 2026.

## Pinning actions

Every repo in the org pins the actions its workflows use by how far we trust who publishes them; zizmor
([`zizmor.yml`](zizmor.yml)) enforces it wherever the shared lint runs:

| Publisher | Pinned to | Example |
| --- | --- | --- |
| GitHub (`actions/*`, `github/*`) | the major version tag | `actions/checkout@v7` |
| Us (`cornucopia-machines/*`) | `@main` | `cornucopia-machines/.github/actions/grype-scan@main` |
| Everyone else | a commit SHA, with the version in a comment | `trufflesecurity/trufflehog@<sha> # v3.99.9` |

The hijacked tags that made SHA pinning common (tj-actions/changed-files in 2025, Aqua's trivy-action) were
third-party actions, so those stay pinned to a commit. Following GitHub's own major tags is a risk we accept, for
far fewer updates. Each repo's Dependabot checks `github-actions` monthly, grouped into one PR, with a 7-day
cooldown: in practice a PR only when a third-party action released, or GitHub one shipped a new major. Security
updates come right away regardless.

## Linting

Everything here is used by every repo in the org, so the Lint workflow checks each change:
actionlint for workflows, `check-jsonschema` for `action.yml` files (actionlint doesn't read them),
shellcheck for the scripts, and [zizmor](https://docs.zizmor.sh) for security issues, configured in
[`zizmor.yml`](zizmor.yml).
