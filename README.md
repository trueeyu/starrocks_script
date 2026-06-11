# starrocks_script

Helper shell scripts for working with [StarRocks](https://github.com/StarRocks/starrocks):
backporting PRs across branches, figuring out which release branches a PR has
already landed on, and monitoring a running cluster.

## Requirements

- `git`
- [`gh`](https://cli.github.com/) CLI, authenticated (`gh auth login`)
- `jq`
- A local clone of `StarRocks/starrocks` with a remote pointing at the
  upstream repo (default name: `upstream`)

All scripts run inside the starrocks working tree by default. Both scripts
also accept `REPO_DIR=/path/to/starrocks` so you can run them from anywhere.

## Scripts

### `pr_branches.sh` — which branches has this PR landed on?

Given a PR number or commit SHA, report the release branches that already
contain the change.

```bash
# Auto-discover branch-X.Y / branch-X.Y.Z on `upstream`
./pr_branches.sh 68571

# Restrict to specific branches
./pr_branches.sh 68571 branch-3.5 branch-3.4

# Pass a commit SHA instead of a PR number
./pr_branches.sh b38e14ebcfbd95d000a12ad663080740ea4a066e

# Run from outside the starrocks checkout
REPO_DIR=~/code/starrocks ./pr_branches.sh 68571
```

Detection methods (any one match counts as YES):

1. The PR's merge SHA is reachable from the branch tip.
2. A commit on the branch was cherry-picked from the SHA (`-x` trailer).
3. A commit subject on the branch references `(#N)` or `(backport #N)`.
4. A merged backport PR with title `... (backport #N)` targets the branch.

Output behavior in auto-discover mode:

- Only `YES` results are printed; `NO` and `MISSING` are suppressed.
- For `branch-X.Y.Z` patch branches, only the **first patch** in each
  `X.Y` series that contains the PR is shown (subsequent patches inherit it).
- If the minor branch `branch-X.Y` does not contain the PR, all of its
  `branch-X.Y.Z` patches are skipped without checking.
- Branches passed explicitly on the command line are always evaluated and
  always shown if YES.

Env overrides:

| Var              | Default                                  | Purpose |
| ---------------- | ---------------------------------------- | ------- |
| `REPO`           | `StarRocks/starrocks`                    | GitHub repo for `gh` queries |
| `REMOTE`         | `upstream`                               | git remote name |
| `BRANCH_PATTERN` | `branch-*`                               | ref glob for auto-discovery |
| `BRANCH_REGEX`   | `^branch-[0-9]+\.[0-9]+(\.[0-9]+)?$`     | regex filter (e.g. excludes `branch-3.5-cc`) |
| `REPO_DIR`       | _(unset)_                                | run git in this working tree |
| `NO_FETCH`       | _(unset)_                                | set to `1` to skip `git fetch` |

### `backport.sh` — backport PRs from one branch to another

Compares two branches (e.g. `branch-3.5` → `branch-3.5-cc`) and helps
backport the PRs that exist only on the source branch.

```bash
# Show commit-level / file-level diff between SRC and DST
./backport.sh diff

# List PRs merged into SRC since a date (default 2024-01-01)
./backport.sh list-prs 2025-01-01

# List PRs merged into SRC but not yet present in DST
./backport.sh pending 2025-01-01

# Cherry-pick a single PR into a new local backport branch and open a PR
./backport.sh backport 68571

# After resolving cherry-pick conflicts, push and open the PR
./backport.sh resume 68571

# Trigger Mergify-driven backports by commenting on the original PR(s)
./backport.sh mergify 68571 68572
```

Env overrides:

| Var          | Default          | Purpose |
| ------------ | ---------------- | ------- |
| `REMOTE`     | `upstream`       | git remote name |
| `SRC_BRANCH` | `branch-3.5`     | source branch |
| `DST_BRANCH` | `branch-3.5-cc`  | destination branch |

`pending` skips a PR if any of these is true on `DST_BRANCH`:

1. The merge SHA is reachable.
2. A commit message contains `cherry picked from commit <sha>`.
3. A commit subject references `(#N)` or `(backport #N)`.
4. The PR title references an original PR via `(backport #N)` and that
   original PR is already on `DST_BRANCH` (covers chained backports through
   sibling branches).

### `mem_alert.sh` — alert when available memory runs low

Polls `/proc/meminfo` on a fixed interval and, once available memory drops
below a percentage threshold, hits a local BE endpoint to dump a memory
report, then exits.

```bash
./mem_alert.sh
```

By default it checks every second, triggers at 7% available memory, runs
`curl -XGET http://127.0.0.1:8040/memz`, and appends the output to
`/data1/log/mem_alert_curl.html`. Edit the config block at the top of the
script (`THRESHOLD`, `CHECK_INTERVAL`, `CURL_LOG`, `CURL_CMD`) to adjust.

Intended to run on a StarRocks BE/CN node (reads Linux `/proc/meminfo`).