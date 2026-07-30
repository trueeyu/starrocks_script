# starrocks_script

Helper shell scripts for working with [StarRocks](https://github.com/StarRocks/starrocks):
backporting PRs across branches, figuring out which release branches a PR has
already landed on, deploying a locally built BE, and monitoring a running
cluster.

## Requirements

For `pr_branches.sh` and `backport.sh`:

- `git`
- [`gh`](https://cli.github.com/) CLI, authenticated (`gh auth login`)
- `jq`
- A local clone of `StarRocks/starrocks` with a remote pointing at the
  upstream repo (default name: `upstream`)

Both git scripts run inside the starrocks working tree by default, and accept
`REPO_DIR=/path/to/starrocks` so you can run them from anywhere.

`deploy_be.sh` only needs `ssh` and `scp`, plus passwordless ssh to the target
machines. `mem_alert.sh` and the remote half of `deploy_be.sh` are Linux-only
(they read `/proc`).

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

### `deploy_be.sh` — deploy a locally built `be/bin` + `be/lib` to remote nodes

Ships the local `bin/` and `lib/` of a BE build to one or more machines,
restarting BE safely on each. Runs on Linux; targets must be Linux.

```bash
# Single node
REMOTE_BE=/data/starrocks/be ./deploy_be.sh -s ~/starrocks/output/be be01

# Several nodes, rolling (serial), skip the confirmation prompt
./deploy_be.sh -s ./be -d /data/starrocks/be -y be01 be02 be03

# Read the host list from a file, keep going if a node fails
./deploy_be.sh -s ./be -d /data/starrocks/be -c -f hosts.txt

# Print the plan without touching anything
./deploy_be.sh -s ./be -d /data/starrocks/be -n be01
```

Per-node sequence (options must come **before** the host names):

1. `scp -r` the local `bin/` and `lib/` to `/tmp/be_deploy_<ts>/` on the target
   (compressed in transit; `SCP_COMPRESS=0` disables) — the upload and its
   sanity checks happen **before** BE is stopped.
2. `./bin/stop_be.sh`, then wait until no `starrocks_be` process belonging to
   this `BE_HOME` is left (matched by `/proc/<pid>/exe` and `cwd`, so other
   instances on the same host are untouched). Times out after
   `STOP_TIMEOUT`; `-k` escalates to `kill -9` instead of aborting.
3. Move the old `bin/` and `lib/` to `$REMOTE_BE/deploy_backup/<ts>/`.
4. Move the new `bin/` and `lib/` into place (whole-directory replacement —
   `conf/`, `storage/`, `log/` are never touched).
5. `./bin/start_be.sh --daemon`.
6. Verify: process appears within `START_TIMEOUT`, is still alive after
   `STABLE_WAIT`, and `http://127.0.0.1:<be_http_port>/api/health` returns 200.
7. On any failure from step 4 on, restore the backup and restart the old
   version (`ROLLBACK=0` to disable), print the tail of `log/be.out`, and exit
   non-zero. Failure on one node stops the rollout unless `-c` is given.

Options:

| Option | Purpose |
| ------ | ------- |
| `-s <dir>` | local be dir containing `bin/` and `lib/` (default `./be`) |
| `-d <dir>` | remote be dir, absolute path (required) |
| `-H <hosts>` | hosts, comma/space separated |
| `-f <file>` | host list file, one per line, `#` comments allowed |
| `-u <user>` / `-p <port>` | ssh user / port |
| `-y` | skip the confirmation prompt |
| `-k` | `kill -9` if BE does not exit before `STOP_TIMEOUT` |
| `-c` | continue with the remaining hosts after a failure |
| `-n` | dry run: print the plan only |

Env overrides:

| Var | Default | Purpose |
| --- | ------- | ------- |
| `LOCAL_BE` | `./be` | same as `-s` |
| `REMOTE_BE` | _(unset)_ | same as `-d` |
| `HOSTS` | _(unset)_ | same as `-H` |
| `SSH_USER` / `SSH_PORT` | _(unset)_ | same as `-u` / `-p` |
| `SSH_OPTS` | `-o ConnectTimeout=10` | extra ssh/scp options |
| `SCP_COMPRESS` | `1` | pass `-C` to scp; set `0` to disable compression |
| `STOP_TIMEOUT` | `120` | seconds to wait for `starrocks_be` to exit |
| `START_TIMEOUT` | `180` | seconds to wait for a healthy start |
| `STABLE_WAIT` | `10` | seconds to watch the new process before declaring success |
| `FORCE_KILL` | `0` | same as `-k` |
| `ROLLBACK` | `1` | restore the backup when the new version fails to start |
| `HEALTH_PORT` | `auto` | `auto` reads `be_http_port` from `conf/be.conf`; `0` skips the check |
| `BACKUP_KEEP` | `5` | backups kept under `$REMOTE_BE/deploy_backup/` |

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