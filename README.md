# starrocks_script

Helper shell scripts for working with [StarRocks](https://github.com/StarRocks/starrocks):
backporting PRs across branches, figuring out which release branches a PR has
already landed on, deploying a locally built BE / CN / FE, and monitoring a running
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

`deploy_be.sh` and `deploy_fe.sh` only need `ssh` and `scp`, plus passwordless ssh to the target
machines — `ssh_copy_id.sh` sets that up (needs `ssh-copy-id`, and `sshpass`
only for `-P`). `mem_alert.sh` and the remote half of the deploy scripts are Linux-only
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
4. The PR title references an original PR via `(backport #N)`, that original
   PR is already on `DST_BRANCH`, **and** both subjects match (covers chained
   backports through sibling branches).

Rule 4 compares subjects — not just the original PR number — so that a
`[Revert]` of an already-backported PR, whose title references the same
original PR, is still reported as pending. Subjects are compared with the
trailing `(#N)` / `(backport #N)` segments removed and everything but
lowercased alphanumerics stripped, so bracket and spacing churn does not
matter.

### `deploy_be.sh` — deploy a locally built `bin/` + `lib/` to BE / CN nodes

Ships the local `bin/` and `lib/` of a build to one or more machines,
restarting the service safely on each. Runs on Linux; targets must be Linux.

BE and CN share the same binary (`lib/starrocks_be`) and the same directory
layout — only the start/stop scripts, the config file and the `.out` log are
named differently — so `-r be|cn` (default `be`) switches roles.

```bash
# Typical use: roll the build out to every node listed in hosts.txt, as user sr
./deploy_be.sh -s ~/starrocks/output/be -d /home/disk1/sr/be -f hosts.txt -u sr

# Same, but skip the confirmation prompt and keep going if a node fails
./deploy_be.sh -s ~/starrocks/output/be -d /home/disk1/sr/be -f hosts.txt -u sr -y -c

# Print the plan without touching anything
./deploy_be.sh -s ~/starrocks/output/be -d /home/disk1/sr/be -f hosts.txt -u sr -n

# CN nodes — same build output, different role
./deploy_be.sh -r cn -s ~/starrocks/output/be -d /home/disk1/sr/cn -f cn_hosts.txt -u sr

# Hosts on the command line instead of a file
./deploy_be.sh -s ~/starrocks/output/be -d /home/disk1/sr/be -u sr be01 be02
```

Per-node sequence (options must come **before** the host names; `<role>` is
`be` or `cn`):

1. `scp -r` the local `bin/` and `lib/` to a staging dir
   `<stage>/.<role>_deploy_<ts>/` on the target, where `<stage>` defaults to
   the parent of `$REMOTE_BE` (override with `-t` / `STAGE_DIR`); compressed
   in transit (`SCP_COMPRESS=0` disables). The upload and its sanity checks
   happen **before** the service is stopped. Keeping the staging dir on the
   same filesystem as `$REMOTE_BE` makes step 4 an instant rename rather than
   a multi-GB copy while the service is down; it is removed when the node
   finishes, success or not.
2. `./bin/stop_<role>.sh`, then wait until no `starrocks_be` process belonging
   to this directory is left (matched by `/proc/<pid>/exe` and `cwd`, so a BE
   and a CN — or two instances — on the same host do not disturb each other).
   Times out after `STOP_TIMEOUT`; `-k` escalates to `kill -9` instead of
   aborting.
3. Move the old `bin/` and `lib/` to `$REMOTE_BE/deploy_backup/<ts>/`.
4. Move the new `bin/` and `lib/` into place (whole-directory replacement —
   `conf/`, `storage/`, `log/` are never touched).
5. `./bin/start_<role>.sh --daemon`.
6. Verify: process appears within `START_TIMEOUT`, is still alive after
   `STABLE_WAIT`, and `http://127.0.0.1:<be_http_port>/api/health` returns 200
   (`cn.conf` uses the same `be_http_port` key as `be.conf`).
7. On any failure from step 4 on, restore the backup and restart the old
   version (`ROLLBACK=0` to disable), print the tail of `log/<role>.out`, and
   exit non-zero. Failure on one node stops the rollout unless `-c` is given.

If the role does not match the target directory, the missing
`bin/start_<role>.sh` is caught by the pre-flight check — before anything is
stopped or moved.

#### Switching to an earlier version

Every deploy leaves the replaced `bin/` + `lib/` in
`$REMOTE_BE/deploy_backup/<ts>/` (newest `BACKUP_KEEP` kept), and those can be
switched back to — no `-s` or upload needed:

```bash
# List the backups on each host, newest first
./deploy_be.sh -d /home/disk1/sr/be -f hosts.txt -u sr -l

# Switch to a specific backup, or to the newest one
./deploy_be.sh -d /home/disk1/sr/be -f hosts.txt -u sr -R 20260927_082927
./deploy_be.sh -d /home/disk1/sr/be -f hosts.txt -u sr -R last
```

`<ts>` is when the backup was taken, i.e. when that version was *replaced*;
all hosts of one run share the same `<ts>`. `-l` prints the timestamp, the
time and the size, and flags incomplete backups.

`-R` copies the backup into the staging dir on the host (`cp -a`, so it needs
that much free disk; the backup itself is left intact) and then runs the
normal sequence from step 2 on: stop, back up the **current** version as a new
`<ts>`, swap, start, verify, roll back on failure. Because the current version
is saved too, `-R last` right after a switch switches straight back.

Options:

| Option | Purpose |
| ------ | ------- |
| `-r <role>` | `be` or `cn` (default `be`) |
| `-s <dir>` | local dir containing `bin/` and `lib/` (default `./be`) |
| `-d <dir>` | remote deploy dir, absolute path (required) |
| `-t <dir>` | parent of the remote staging dir (default: parent of `-d`); keep it on the same disk as `-d` |
| `-H <hosts>` | hosts, comma/space separated |
| `-f <file>` | host list file, one per line, `#` comments allowed |
| `-u <user>` / `-p <port>` | ssh user / port |
| `-y` | skip the confirmation prompt |
| `-k` | `kill -9` if the process does not exit before `STOP_TIMEOUT` |
| `-c` | continue with the remaining hosts after a failure |
| `-n` | dry run: print the plan only |
| `-l` | list the backups on each host |
| `-R <ts>` | switch to backup `<ts>` (from `-l`), or `last` for the newest |

Env overrides:

| Var | Default | Purpose |
| --- | ------- | ------- |
| `ROLE` | `be` | same as `-r` |
| `LOCAL_BE` | `./be` | same as `-s` |
| `REMOTE_BE` | _(unset)_ | same as `-d` |
| `STAGE_DIR` | parent of `REMOTE_BE` | same as `-t` |
| `HOSTS` | _(unset)_ | same as `-H` |
| `SSH_USER` / `SSH_PORT` | _(unset)_ | same as `-u` / `-p` |
| `SSH_OPTS` | `-o ConnectTimeout=10` | extra ssh/scp options |
| `SCP_COMPRESS` | `1` | pass `-C` to scp; set `0` to disable compression |
| `STOP_TIMEOUT` | `120` | seconds to wait for `starrocks_be` to exit |
| `START_TIMEOUT` | `180` | seconds to wait for a healthy start |
| `STABLE_WAIT` | `10` | seconds to watch the new process before declaring success |
| `FORCE_KILL` | `0` | same as `-k` |
| `ROLLBACK` | `1` | restore the backup when the new version fails to start |
| `HEALTH_PORT` | `auto` | `auto` reads `be_http_port` from `conf/<role>.conf`; `0` skips the check |
| `BACKUP_KEEP` | `5` | backups kept under `$REMOTE_BE/deploy_backup/` |

### `deploy_fe.sh` — deploy a locally built FE to FE nodes

Same shape as `deploy_be.sh` — same options minus `-r`, same staging,
backup and rollback — adapted to the FE.

```bash
# Typical use: roll the build out to every FE in fe_hosts.txt, as user sr
./deploy_fe.sh -s ~/starrocks/output/fe -d /home/disk1/sr/fe -f fe_hosts.txt -u sr

# Print the plan without touching anything
./deploy_fe.sh -s ~/starrocks/output/fe -d /home/disk1/sr/fe -f fe_hosts.txt -u sr -n

# Hosts on the command line, Leader (fe01) last
./deploy_fe.sh -s ~/starrocks/output/fe -d /home/disk1/sr/fe -u sr fe02 fe03 fe01

# List backups / switch to the newest one (see "Switching to an earlier version")
./deploy_fe.sh -d /home/disk1/sr/fe -f fe_hosts.txt -u sr -l
./deploy_fe.sh -d /home/disk1/sr/fe -f fe_hosts.txt -u sr -R last
```

**Order matters.** Hosts are deployed strictly in the order given, and the
next one is only touched once the previous FE is ready again, so the
cluster never loses more than one FE at a time. When upgrading versions,
put Observers first, then Followers, and the **Leader last**: a new-version
Leader can write journal entries an old-version Follower cannot replay. The
script does not detect the Leader itself (that needs SQL credentials); check
`SHOW FRONTENDS` and order the host list accordingly.

Differences from `deploy_be.sh`:

- Deploys `bin/` and `lib/` (required; `lib/starrocks-fe.jar` must exist),
  plus `webroot/`, `spark-dpp/` and `hive-udf/` when present locally. Each is
  replaced as a whole directory, so stale jars do not linger. `conf/`,
  `meta/` and `log/` are never touched.
- The FE process is found by `com.starrocks.StarRocksFE` on the command line
  plus `STARROCKS_HOME` in `/proc/<pid>/environ` matching the deploy dir (or,
  where the environ is unreadable, the pid in `bin/fe.pid`), so other FE
  instances on the host are left alone.
- `stop_fe.sh` waits forever by default; the script bounds that with
  `STOP_TIMEOUT` and still waits for `stop_fe.sh` itself to finish before
  moving on, so a late `stop_fe.sh` cannot kill the freshly started FE.
- Readiness is `GET http://127.0.0.1:<http_port>/api/bootstrap` returning
  `"status":"OK"` — it only does so once the FE has replayed its metadata and
  can serve, and it needs no auth even with `enable_http_auth`. `http_port`
  is read from `conf/fe.conf` (default `8030`). `START_TIMEOUT` defaults to
  600 s since replaying a large image takes a while.
- `start_fe.sh` needs Java, which a non-login ssh shell often lacks. The
  script uses `REMOTE_JAVA_HOME` if set, otherwise the `JAVA_HOME` of the FE
  that was running before the stop, otherwise `JAVA_HOME` from `fe.conf` or
  `java` on `PATH` — and aborts **before** stopping anything if none works.
- Only `bin/`/`lib/` etc. are backed up, not `meta/`. If a new version has
  already rewritten the image, rolling back to an older version may not be
  able to read it — back up `meta/` yourself before a version upgrade.
- `-l` / `-R <ts|last>` switch to an earlier version exactly as in
  `deploy_be.sh` — and the `meta/` caveat above applies to them in full.
  Switching across versions is a downgrade: check the StarRocks downgrade
  notes for the version pair and order the hosts as they say.
  An optional directory (`webroot/`, `spark-dpp/`, `hive-udf/`) missing from
  the backup is moved out with the current version, so the result matches the
  backup exactly.

Env overrides are the same as `deploy_be.sh` (`LOCAL_FE` / `REMOTE_FE` in
place of `LOCAL_BE` / `REMOTE_BE`, no `ROLE`), plus `REMOTE_JAVA_HOME`.

### `ssh_copy_id.sh` — set up passwordless ssh to many hosts

Runs `ssh-copy-id` against a list of hosts, taking the host list the same way
as `deploy_be.sh` (`-H`, `-f`, or positional), so the same `hosts.txt` works
for both.

```bash
# Typical use: install your key on every host in hosts.txt, as user sr
./ssh_copy_id.sh -f hosts.txt -u sr

# Same password everywhere: type it once (needs sshpass)
./ssh_copy_id.sh -f hosts.txt -u sr -P

# Only report which hosts are not passwordless yet
./ssh_copy_id.sh -f hosts.txt -u sr -n

# Use a specific key
./ssh_copy_id.sh -u sr -i ~/.ssh/id_sr be01 be02
```

Per host: probe with `BatchMode=yes` and skip hosts that already accept the
key (`-F` reinstalls anyway), run `ssh-copy-id`, then probe again to confirm.
A failing host does not stop the rest; the summary lists every host that
failed and the exit code is non-zero if any did.

- Key: `-i <key>` (public key is `<key>.pub`); by default the first of
  `~/.ssh/id_ed25519`, `~/.ssh/id_rsa`. If none exists, a passphrase-less
  ed25519 key is generated at `~/.ssh/id_ed25519`.
- `-P` reads the password once and feeds it to `sshpass` for every host; set
  `SSHPASS` to skip the prompt. Without `-P`, `ssh-copy-id` asks per host.
- Host keys: `SSH_OPTS` defaults to
  `-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new`, so first
  contact trusts the host key, but a changed key is still rejected.
- A host entry may be `user@host`, which overrides `-u` for that host.
- If the key installs but login still fails, the usual cause is remote `~` or
  `~/.ssh` permissions being too open for `sshd`.

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