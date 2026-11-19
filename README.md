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

## Static analysis (`semgrep.yml`)

Runs [Semgrep](https://semgrep.dev) Community Edition and fails on any finding. It's free on private
repos, unlike CodeQL. Before adding it to a repo, run Semgrep there and fix or skip what it finds,
so the repo starts from zero. Then add this as `.github/workflows/semgrep.yml`:

```yaml
name: Semgrep

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  semgrep:
    uses: cornucopia-machines/.github/.github/workflows/semgrep.yml@main
    with:
      paths: src tests
```

`config` picks the rules: `p/default` (Semgrep's recommended set, for every language it supports)
unless you name others, e.g. `p/typescript p/nodejs`. To skip a finding that doesn't apply, add a
`// nosemgrep: <rule-id>` comment (`#` in Python or YAML) on its line, saying why; whole paths go in
`.semgrepignore`.

To run it locally, with the same version and rules:

```bash
pipx run semgrep==1.184.0 scan --metrics=off --config p/default src tests
```

## AI security review (`security-review.yml`)

Runs Anthropic's [claude-code-security-review](https://github.com/anthropics/claude-code-security-review),
the CI version of Claude Code's `/security-review`, on each pull request's first run. It comments on
the lines it thinks are vulnerable, and doesn't fail the PR. It needs an Anthropic API key as a repo
secret; without one (e.g. on Dependabot's PRs) it skips. Add this to a repo as
`.github/workflows/security-review.yml`:

```yaml
name: Security review

on:
  pull_request:

permissions:
  contents: read

jobs:
  review:
    permissions:
      contents: read
      pull-requests: write
    uses: cornucopia-machines/.github/.github/workflows/security-review.yml@main
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

## Version (`actions/version`)

Works out a commit's version, in the one format every product uses, so it's defined here once rather
than in each workflow: the tag for a release (`1.2.3`), and for anything else the last tag, the
commits since and the commit (`1.2.3-4-ga728583`, which is `git describe --tags --always --dirty`).
It needs the full history, and fails on a shallow clone instead of quietly falling back to a bare
hash. It also fails if tracked files have changed since the checkout, so a build of modified sources
can't pass for the commit's; set `fail-on-dirty: false` to get a version ending in `-dirty` instead:

```yaml
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
          persist-credentials: false

      - name: Get version
        id: version
        uses: cornucopia-machines/.github/actions/version@main

      - run: echo "Building $VERSION"
        env:
          VERSION: ${{ steps.version.outputs.version }}
```

The firmware doesn't use it: ESP-IDF works out the same `git describe --dirty` version itself,
inside the build.

## Release assets (`actions/upload-release-assets`)

Uploads build outputs to the GitHub release of a tag, with the runner's `gh` rather than a
third-party action. An asset of the same name fails the upload, so a file already on a release isn't
swapped for a different build; set `clobber: true` to replace it instead, e.g. so a re-run works. `files` takes one path or glob per
line. `if-no-release` says what to do when the tag has no release (a draft counts): `fail` (the
default), `create` it, or `warn` and skip, for a job that shouldn't fail over release notes. The job
needs `contents: write`:

```yaml
  release:
    needs: build
    if: startsWith(github.ref, 'refs/tags/')
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/download-artifact@v8
        with:
          path: artifacts

      - uses: cornucopia-machines/.github/actions/upload-release-assets@main
        with:
          files: artifacts/**/*
          if-no-release: create
```

`tag` defaults to the ref that triggered the run; for a `release` event, pass
`${{ github.event.release.tag_name }}`.

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

## Foreseeable work board (`board-bot-items.yml`)

Not shared with other repos: it runs here, every hour and by hand, to put what bots open across the org on the
[Foreseeable work](https://github.com/orgs/cornucopia-machines/projects/4) project, if it isn't there yet:

- Dependabot's pull requests, in **In review**: they wait for a person's review.
- The issues our workflows open (the image scans' CVE issues, upgrade reminders), in **Backlog**.

The board's own workflows move them to Done once they're merged or closed. A card that's archived stays archived;
a card that's deleted comes back within the hour, as long as its issue or pull request is open.

The `GITHUB_TOKEN` can't write to the org's projects, so it uses the "Claude GitHub Projects MCP" GitHub App
(Projects read and write, read access to issues and pull requests): its Client ID in the repo variable
`PROJECT_APP_CLIENT_ID`, and a private key in the secret `PROJECT_APP_PRIVATE_KEY`. It runs here rather than in
each repo because this repo is public, so its minutes are free, and because workflows that Dependabot triggers
only get Dependabot's secrets. To see what it would add without changing the board:
`DRY_RUN=1 scripts/board-add-bot-items.sh`, with a `gh` that can read the project.

## Claude queue dispatcher (`claude-queue.yml`)

Not shared with other repos either: every 15 minutes in working hours (Monday to Friday, 6:00 to 19:00 UTC) and by
hand, it starts the "Foreseeable work: Claude queue" routine, Claude's worker, for the
[Foreseeable work](https://github.com/orgs/cornucopia-machines/projects/4) project:

- **New items:** while fewer than `CLAUDE_QUEUE_WIP_LIMIT` (a repo variable, 3 if it isn't set) of Claude's open issues (`claude` label) are In progress or In review, it takes the next issue in Claude
  queue, moves it to In progress, and starts a run for it. Closed issues in the queue go to Done; issues from repos
  the routine doesn't check out stay in the queue.
- **Follow-ups:** for each of Claude's open issues (`claude` label) in In progress or In review, it starts a run when
  something happened since the worker last edited its tracking comment: a review or comment on one of its PRs, failed
  CI, a merge conflict after the base branch moved, one of its PRs merged or closed, a new comment on the issue, or
  3 hours In progress with no open PR.

Each run gets the issue in its payload (`take <repo>#<n>`, or `follow up <repo>#<n>` with the reasons), so the
routine has no schedule of its own. Checking the board this way costs no Claude usage, unlike a scheduled routine,
which also couldn't run more than hourly.

It uses the same GitHub App as the board workflow above, which also needs Checks, Commit statuses and Contents read
access for the PRs' CI results. The routine's API trigger token is in the secret `CLAUDE_QUEUE_FIRE_TOKEN`: it can
only start that routine. To see what it would do without changing anything, run it with **dry-run** checked, or
`DRY_RUN=1 ROUTINE_ID=… WORKER_REPOS='…' scripts/claude-queue-dispatch.sh` with a `gh` that can read the project.
Pull requests that change it do a dry run.

## Pinning actions

Every repo in the org pins the actions its workflows use by how far we trust who publishes them; zizmor
([`zizmor.yml`](zizmor.yml)) enforces it wherever the shared lint runs:

| Publisher | Pinned to | Example |
| --- | --- | --- |
| GitHub (`actions/*`, `github/*`) | the major version tag | `actions/checkout@v7` |
| Docker (`docker/*`) | the major version tag | `docker/login-action@v4` |
| Us (`cornucopia-machines/*`) | `@main` | `cornucopia-machines/.github/actions/grype-scan@main` |
| Everyone else | a commit SHA, with the version in a comment | `trufflesecurity/trufflehog@<sha> # v3.99.9` |

The hijacked tags that made SHA pinning common (tj-actions/changed-files in 2025, Aqua's trivy-action) were
third-party actions, so those stay pinned to a commit. Following GitHub's own major tags is a risk we accept, for
far fewer updates: if GitHub is compromised, so is the runner every workflow runs on. Docker's actions get the same
treatment for the same reason: our images are built from Docker's base images, and `setup-buildx-action` pulls
BuildKit at a floating tag, so pinning the action's commit wouldn't keep a compromised Docker out. Each repo's Dependabot checks `github-actions` monthly, grouped into one PR, with a 7-day
cooldown: in practice a PR only when a third-party action released, or GitHub one shipped a new major. Security
updates come right away regardless.

## Caches

The shared zizmor config turns off its `cache-poisoning` audit, which flags `actions/cache` in any workflow that
publishes releases. GitHub scopes caches by ref: a pull request's run can read the default branch's caches but
never write them, so poisoning one takes code that already runs on the default branch. Instead of an ignore comment
on every cache, follow one rule: **a build whose output ships (a release tag, a deploy) installs dependencies from
the lockfile and doesn't restore a cache.** Test, lint and PR builds can cache freely.

## Actions lint (`actions-lint.yml`)

Lints a repo's workflows and actions: [actionlint](https://github.com/rhysd/actionlint) for mistakes
(syntax, expression types, unknown inputs, shellcheck on `run:` scripts), `check-jsonschema` for
`action.yml` files (actionlint doesn't read them), and [zizmor](https://docs.zizmor.sh) for security
problems (template injection, over-broad permissions, credentials left in checkouts, risky triggers,
pinning). Add this to a repo as `.github/workflows/actions-lint.yml`:

```yaml
name: Actions lint

on:
  pull_request:
    paths:
      - .github/**

permissions:
  contents: read

jobs:
  lint:
    uses: cornucopia-machines/.github/.github/workflows/actions-lint.yml@main
```

zizmor uses this repo's [`zizmor.yml`](zizmor.yml), which enforces the pinning rule above. A calling
repo's own `zizmor.yml` or `.github/zizmor.yml` is merged on top of it rather than replacing it: maps
merge, with the repo's value winning where both set the same key, and lists such as `ignore` add up.
So a repo that ignores one file, or disables an audit, keeps the org's pinning policy, and loosening
that policy takes an explicit entry under `rules.unpinned-uses.config.policies`. The job log shows
the merged config. To skip a single finding, add a `# zizmor: ignore[<audit>]` comment on its line
instead, with a comment saying why. actionlint
reads the calling repo's `.github/actionlint.yaml`, if it has one.

To run the same checks locally:

```bash
# The ignores drop actionlint's errors on `uses: $/...`, which it doesn't support yet (see the workflow).
actionlint -ignore '"\$/[^"]*" at "uses" is not following the format' \
  -ignore 'action "\$/[^"]*" in invalid format because ref is missing'
curl -fsSL -o /tmp/zizmor.yml https://raw.githubusercontent.com/cornucopia-machines/.github/main/zizmor.yml
# Only if the repo has its own config: merge it on top, as the workflow does (mikefarah's yq 4).
yq eval-all --inplace '. as $item ireduce ({}; . *+ $item)' /tmp/zizmor.yml zizmor.yml
zizmor --config /tmp/zizmor.yml .
```

## Linting

Everything here is used by every repo in the org, so the Lint workflow checks each change: it runs
the Actions lint above from the same commit, configured by [`zizmor.yml`](zizmor.yml), and
shellcheck for the scripts.
