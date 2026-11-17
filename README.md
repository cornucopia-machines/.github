# Shared GitHub Actions workflows

Reusable workflows for `cornucopia-machines` repos. Each one is maintained here once, and its
pinned actions are kept up to date by Dependabot in this repo.

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
