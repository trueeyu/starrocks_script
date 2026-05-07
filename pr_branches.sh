#!/usr/bin/env bash
#
# pr_branches.sh
# Determine which branches a given PR (or commit SHA) has landed in.
#
# Requirements: git, gh (run `gh auth login`), jq
#
# Env overrides:
#   REPO=StarRocks/starrocks
#   REMOTE=upstream             # git remote name
#   BRANCH_PATTERN='branch-*'   # ref glob used when no branches are passed
#   BRANCH_REGEX                # extra regex filter on discovered branches
#                               # default: only versioned branches like
#                               #   branch-X.Y / branch-X.Y.Z
#   REPO_DIR=/path/to/starrocks # run git inside this working tree
#   NO_FETCH=1                  # skip `git fetch` step

set -euo pipefail

REPO="${REPO:-StarRocks/starrocks}"
REMOTE="${REMOTE:-upstream}"
BRANCH_PATTERN="${BRANCH_PATTERN:-branch-*}"
BRANCH_REGEX="${BRANCH_REGEX:-^branch-[0-9]+\.[0-9]+(\.[0-9]+)?$}"
REPO_DIR="${REPO_DIR:-}"

GIT() { command git ${REPO_DIR:+-C "$REPO_DIR"} "$@"; }

usage() {
  cat <<EOF
Usage:
  $0 <PR_NUMBER|COMMIT_SHA> [BRANCH ...]

Determines which branches contain the given PR or commit. If no branches are
listed, all remote refs matching '$BRANCH_PATTERN' on '$REMOTE' are checked.

Detection methods (any match counts):
  1. The merge SHA is reachable from the branch tip.
  2. A commit on the branch was cherry-picked from the SHA (\`-x\` trailer).
  3. A commit subject references this PR via '(#N)' or '(backport #N)'.
  4. A merged backport PR with title '... (backport #N)' targets the branch.

Env: REPO, REMOTE, BRANCH_PATTERN, NO_FETCH
EOF
}

is_pr_number() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_sha()       { [[ "$1" =~ ^[0-9a-f]{7,40}$ ]]; }

ensure_repo() {
  GIT rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "Not a git work tree${REPO_DIR:+ at $REPO_DIR}." >&2
    echo "Run inside the starrocks repo, or set REPO_DIR=/path/to/starrocks." >&2
    exit 1; }
  GIT remote get-url "$REMOTE" >/dev/null 2>&1 || {
    echo "Remote '$REMOTE' not found in $(GIT rev-parse --show-toplevel)." >&2
    echo "Set REMOTE=<name> or REPO_DIR=/path/to/starrocks." >&2
    exit 1; }
}

discover_branches() {
  GIT for-each-ref --format='%(refname:short)' \
      "refs/remotes/$REMOTE/$BRANCH_PATTERN" \
    | sed "s|^$REMOTE/||" \
    | grep -E "$BRANCH_REGEX" || true
}

# Populates: PR_NUM, SHA, TITLE
resolve_input() {
  local arg="$1"
  PR_NUM=""; SHA=""; TITLE=""

  if is_pr_number "$arg"; then
    PR_NUM="$arg"
    local pr_json state base
    pr_json="$(gh pr view "$PR_NUM" --repo "$REPO" \
                --json number,title,state,mergeCommit,baseRefName)"
    SHA="$(  jq -r '.mergeCommit.oid // ""' <<<"$pr_json")"
    TITLE="$(jq -r '.title // ""'           <<<"$pr_json")"
    state="$(jq -r '.state'                 <<<"$pr_json")"
    base="$( jq -r '.baseRefName'           <<<"$pr_json")"
    echo "Resolved PR #$PR_NUM: $TITLE" >&2
    echo "  base=$base state=$state merge=${SHA:-<none>}" >&2
    if [[ "$state" != "MERGED" ]]; then
      echo "  warning: PR is not MERGED; results may be incomplete." >&2
    fi
  elif is_sha "$arg"; then
    SHA="$(GIT rev-parse --verify "$arg^{commit}" 2>/dev/null || echo "$arg")"
    local subj
    subj="$(GIT log -1 --pretty=format:'%s' "$SHA" 2>/dev/null || true)"
    if [[ -n "$subj" ]]; then
      TITLE="$subj"
      PR_NUM="$(grep -Eo '\(#[0-9]+\)' <<<"$subj" | head -1 | grep -Eo '[0-9]+' || true)"
    fi
    echo "Resolved SHA: $SHA" >&2
    [[ -n "$TITLE"  ]] && echo "  subject: $TITLE" >&2
    [[ -n "$PR_NUM" ]] && echo "  (subject suggests PR #$PR_NUM)" >&2
  else
    usage; exit 1
  fi
}

# Lookup merged PRs whose title is "... (backport #PR_NUM)".
# Output: <branch>\t<merge_sha>\t<backport_pr_num>
chained_backport_refs() {
  local pr_num="$1"
  [[ -z "$pr_num" ]] && return 0
  gh pr list --repo "$REPO" --state merged \
     --search "in:title \"backport #$pr_num\"" \
     --limit 100 \
     --json number,title,baseRefName,mergeCommit 2>/dev/null \
   | jq -r --arg pr "$pr_num" '
       .[] | select(.title | test("\\(backport #" + $pr + "\\)"))
           | "\(.baseRefName)\t\(.mergeCommit.oid // "")\t\(.number)"' \
   || true
}

# Compute branch status. Output: <STATUS>\t<reason>
# STATUS is one of YES, NO, MISSING.
check_branch_status() {
  local branch="$1"
  local ref="$REMOTE/$branch"

  if ! GIT rev-parse --verify --quiet "$ref" >/dev/null; then
    printf 'MISSING\t%s not found\n' "$ref"
    return
  fi

  if [[ -n "$SHA" && "$SHA" != "null" ]] \
     && GIT merge-base --is-ancestor "$SHA" "$ref" 2>/dev/null; then
    printf 'YES\tsha reachable\n'
    return
  fi

  if [[ -n "$SHA" && "$SHA" != "null" ]]; then
    local short="${SHA:0:7}"
    if GIT log "$ref" --pretty=format:'%B' \
        | grep -Eq "cherry picked from commit ${short}[0-9a-f]*\)?"; then
      printf 'YES\tcherry-pick -x\n'
      return
    fi
  fi

  if [[ -n "$PR_NUM" ]]; then
    if GIT log "$ref" --pretty=format:'%s' \
        | grep -Eq "\(backport #${PR_NUM}\)|\(#${PR_NUM}\)"; then
      printf 'YES\tsubject references #%s\n' "$PR_NUM"
      return
    fi
  fi

  if [[ -n "${CHAIN_INFO:-}" ]]; then
    local b sha num
    while IFS=$'\t' read -r b sha num; do
      [[ -z "$b" ]] && continue
      if [[ "$b" == "$branch" ]]; then
        printf 'YES\tvia backport PR #%s, %s\n' "$num" "${sha:-no-sha}"
        return
      fi
    done <<<"$CHAIN_INFO"
  fi

  printf 'NO\t\n'
}

print_result() {
  local branch="$1" status="$2" reason="$3"
  case "$status" in
    YES)     printf '  %-30s  YES  (%s)\n'    "$branch" "$reason" ;;
    NO)      printf '  %-30s  NO\n'           "$branch" ;;
    MISSING) printf '  %-30s  MISSING (%s)\n' "$branch" "$reason" ;;
  esac
}

main() {
  if [[ $# -lt 1 ]]; then usage; exit 1; fi
  ensure_repo

  local input="$1"; shift
  resolve_input "$input"

  if [[ -z "${NO_FETCH:-}" ]]; then
    GIT fetch --quiet "$REMOTE" 2>/dev/null \
      || echo "warning: 'git fetch $REMOTE' failed; results may be stale." >&2
  fi

  local branches=() auto_discover=0
  if [[ $# -gt 0 ]]; then
    branches=("$@")
  else
    auto_discover=1
    while IFS= read -r line; do
      [[ -n "$line" ]] && branches+=("$line")
    done < <(discover_branches | sort -V)
  fi

  if [[ ${#branches[@]} -eq 0 ]]; then
    echo "No branches to check (pattern '$BRANCH_PATTERN' on '$REMOTE')." >&2
    exit 1
  fi

  CHAIN_INFO=""
  if [[ -n "$PR_NUM" ]]; then
    CHAIN_INFO="$(chained_backport_refs "$PR_NUM")"
  fi

  echo
  echo "Branches checked (${#branches[@]}):"
  # In auto-discover mode (sorted with `sort -V`), branch-X.Y is processed
  # before its branch-X.Y.Z patches. Two optimizations:
  #   - if the minor branch X.Y does not contain the PR, skip all its patches
  #     (patches are cut from the minor branch);
  #   - within an X.Y group, only show the first patch that contains the PR.
  local patch_done=" "  # X.Y keys whose first matching patch was shown
  local minor_no=" "    # X.Y keys whose minor branch is known to be NO
  local b result status reason key
  for b in "${branches[@]}"; do
    if (( auto_discover )) && [[ "$b" =~ ^branch-([0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
      key="${BASH_REMATCH[1]}"
      case "$minor_no"   in *" $key "*) continue ;; esac
      case "$patch_done" in *" $key "*) continue ;; esac
    fi

    result="$(check_branch_status "$b")"
    status="${result%%$'\t'*}"
    reason="${result#*$'\t'}"

    if (( auto_discover )) && [[ "$status" == NO ]] \
       && [[ "$b" =~ ^branch-([0-9]+\.[0-9]+)$ ]]; then
      minor_no="$minor_no${BASH_REMATCH[1]} "
    fi

    [[ "$status" != YES ]] && continue

    if (( auto_discover )) && [[ "$b" =~ ^branch-([0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
      patch_done="$patch_done${BASH_REMATCH[1]} "
    fi

    print_result "$b" "$status" "$reason"
  done
}

main "$@"