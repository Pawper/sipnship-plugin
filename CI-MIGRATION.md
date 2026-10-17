# Moving an existing ci.yml to the 0.9.8 layout

`ci.yml` is the project's own file, so `sync-templates.sh` reports a change to the template and never rewrites it. This page is the change, written so a person or an agent can apply it by hand. The template is `templates/.github/workflows/ci.yml` in the plugin; read it alongside.

## Why

On self-hosted runners every job pays a runner pickup, a checkout and a setup, which cost far more than a two-second check script. Before 0.9.8 the template ran each rule as its own job: about ten runner jobs a pull request. On two Windows runners one pull request took about 12 minutes from push to "CI passed" for under 2 minutes of real work, and with four pull requests open, jobs sat queued 4 to 9 minutes. Older runs also kept their runners after a new push.

After the move a pull request runs three jobs (`checks`, `app`, `CI passed`) and takes about 3 to 4 minutes on the same machines.

## The change, step by step

1. **Add a concurrency group** at the top level, after `permissions:`:
   ```yaml
   concurrency:
     group: ci-${{ github.event_name == 'pull_request' && github.event.pull_request.number || github.sha }}
     cancel-in-progress: true
   ```
   A new push to a pull request cancels its older run. Each push to main is its own group, so every commit on main still gets its full run.

2. **Make one `checks` job** from `classify` and the small rule jobs: `line-endings`, `status-page`, `numbering-check`, `spec-check`, `setup-check`, `shared-check`, and the `client-env-check` step from `build`. One checkout with `fetch-depth: 0`; each old job's `run:` line becomes a step. Keep the `classes` output (now `steps.classes.outputs.classes`). Give the job `env: BASE: ${{ github.event_name == 'pull_request' && github.event.pull_request.base.sha || github.event.before }}` and pass `"$BASE"` where the old jobs passed the base SHA. Conditions move from the job to the step: the pull-request-only rules get `if: github.event_name == 'pull_request'`; `line-endings` and `status-page` keep running on pushes too.

3. **Make one `app` job** from `app` and `build`: one checkout, the install **once** (`npm ci`), then the type-check, the tests and the build as steps. It `needs: checks` and runs when the classes contain `app`, `tests` or `other`; the build step alone has `if: contains(needs.checks.outputs.classes, 'app') || contains(needs.checks.outputs.classes, 'other')`. Keep the shard comment if the tests may outgrow one runner.

4. **Drop `data` and `docs`** as jobs. If either ran a real check that is not already a step above, it becomes a step in `checks` with `if: contains(steps.classes.outputs.classes, 'data')` (or `'docs'`). If it repeated a step above (a second `numbering-check.sh`, a second `status/check.sh`), delete it.

5. **`CI passed` needs `[checks, app]`** and its loop lists those two. Its name stays exactly `CI passed`, because branch protection and the merge queue require that check by name.

6. **Keep** `full`, `report-red` and `report-green` as they are. Keep `runs-on:` and the workflow-level `defaults.run.shell` exactly as the project had them.

## Check it

- `sh scripts/sync/sync-templates.sh` no longer says ci.yml runs its checks as separate jobs.
- On the first pull request after the move: three jobs, `CI passed` green, and a step that fails names the rule it broke.
- Push twice to one pull request quickly: the first run shows as cancelled.
- Branch protection still requires only `CI passed`. If a project had required a per-rule job by name, remove that requirement, because the job no longer exists.

## 0.10.1: read the live pull request body

Two small changes to the `checks` job, for a project already on the layout above:

1. Add `pull-requests: read` under `permissions:`. A check that reads a pull request's body (the spec check, or a project's own "Parity:" or "Twin:" guard) can then fetch the live body. A re-run (`gh run rerun`) keeps the event payload of the run it re-runs, so without this an edited body only counts after an empty commit.
2. In the spec-check step, set `SPEC_TEXT` from the live body, falling back to the event's copy:
   ```yaml
   env:
     GH_TOKEN: ${{ github.token }}
     PAYLOAD_TEXT: |
       ${{ github.event.pull_request.title }}
       ${{ github.event.pull_request.body }}
   run: |
     SPEC_TEXT=$(gh api "repos/${{ github.repository }}/pulls/${{ github.event.pull_request.number }}" --jq '.title + "\n" + (.body // "")' 2>/dev/null) || SPEC_TEXT=$PAYLOAD_TEXT
     export SPEC_TEXT
     sh scripts/ci/spec-check.sh "$BASE" "${{ github.sha }}"
   ```
   A project's own body-reading checks can do the same.

## 0.14.0: the design step

A project that adopts `design/tokens.json` adds one step to the `checks` job, after the client env check:

```yaml
      - name: Fail when a screen gains a literal colour, size or font, or the design files are stale
        if: github.event_name == 'pull_request' && hashFiles('design/tokens.json') != ''
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          SPEC_TEXT=$(gh api "repos/${{ github.repository }}/pulls/${{ github.event.pull_request.number }}" --jq '.title + "\n" + (.body // "")' 2>/dev/null) || SPEC_TEXT="${{ github.event.pull_request.title }}"
          export SPEC_TEXT
          sh scripts/ci/design-check.sh "$BASE" "${{ github.sha }}"
```

It needs Node on the runner (the generator) and `pull-requests: read` (the live body, for a `Design:` line). A project without `design/tokens.json` is untouched: the step skips itself.

## 0.16.0: the base is current main

In `ci.yml`, `BASE` for a pull request was `github.event.pull_request.base.sha`: main as it was at the pull request's last event. `github.sha` is the merge of the branch into main as it is now, so every check's diff also held whatever landed on main in between, and a pull request was flagged for a literal it never touched. Change the line to:

```yaml
      BASE: ${{ github.event_name == 'pull_request' && 'HEAD^1' || github.event.before }}
```

`HEAD^1` is the merge commit's first parent, current main, and every check already takes `BASE` as a git revision. `design-check.sh` also guards itself: given a merge commit as HEAD, it uses that commit's first parent whatever base it was passed.
