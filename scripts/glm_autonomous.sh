#!/usr/bin/env bash
# Idle-gated autonomous GLM worker for the two-Mac cluster.
#
# When the cluster is idle (see glm_idle.sh), start GLM and let it grind a
# GitHub backlog with the local glm-coordinator agent (which may fan out to a
# single qwen-worker subtask). Two job kinds only:
#   implement  an open issue with no PR yet -> a new PR that Closes it
#   review     an open PR with commits newer than its last review -> a posted,
#              adversarial review verdict on GitHub
#
# It identifies as "Sloppy" in every PR and review it writes. It never merges
# and never edits an existing PR's code: PR fixes stay manual. One GLM job at a
# time (shared opencode GLM slot lock). Reviewing outranks new work: a new PR is
# filed only once every open PR has been reviewed at its current version. Within
# each phase, groups are tried in priority order.
#
# run     (default) start GLM if idle, then work until busy or the backlog is
#         empty; exit when the cluster turns busy so humans get it back
# next    print the next action without doing it (dry run)
# once    do a single action and exit
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"
# shellcheck disable=SC1091
source "${PROMPTS_LIB:-${HOME}/code/prompts/scripts/lib}/orchestrate_tools.sh"
# shellcheck disable=SC1091
source "${PROMPTS_LIB:-${HOME}/code/prompts/scripts/lib}/orchestrate_review.sh"

ACTION="${1:-run}"
AGENT_NAME="${GLM_AGENT_NAME:-Sloppy}"

# itpplasma is exhausted before any other group is touched. Word-splitting the
# space-separated group list is intentional.
# shellcheck disable=SC2206
TARGET_GROUPS=(${GLM_GROUPS:-itpplasma lazy-fortran sloppy-org computor-org krystophny})

WORK_ROOT="${GLM_WORK_ROOT:-${HOME}/.local/share/glm-autonomous/work}"
LOCK="${RUN_DIR}/glm-autonomous.lock"
IMPLEMENT_TIMEOUT="${GLM_IMPLEMENT_TIMEOUT:-3h}"
REVIEW_TIMEOUT="${GLM_REVIEW_TIMEOUT:-45m}"
MAX_JOBS="${GLM_MAX_JOBS_PER_RUN:-50}"
STOP_ON_YIELD="${GLM_STOP_ON_YIELD:-false}"

# GitHub API budget: skip a scan when core rate-limit remaining drops below this,
# pause GH_SLEEP between repos, and reuse a cached repo list for REPO_CACHE_TTL.
GH_MIN_REMAINING="${GLM_GH_MIN_REMAINING:-300}"
GH_SLEEP="${GLM_GH_SLEEP:-0.2}"
REPO_CACHE_TTL="${GLM_REPO_CACHE_TTL:-900}"
GH_COOLDOWN_MAX="${GLM_GH_COOLDOWN_MAX:-900}"

# Prefer GNU timeout; coreutils installs it as gtimeout on macOS.
if have timeout; then TIMEOUT_BIN="timeout"
elif have gtimeout; then TIMEOUT_BIN="gtimeout"
else TIMEOUT_BIN=""; fi
if [[ -n "$TIMEOUT_BIN" ]] && "$TIMEOUT_BIN" --help 2>&1 | grep -q -- '--foreground'; then
  TIMEOUT=("$TIMEOUT_BIN" --foreground)
else
  TIMEOUT=("${TIMEOUT_BIN:-timeout}")
fi
export TIMEOUT

need() { have "$1" || die "missing: $1"; }
need gh; need jq; need git; need opencode; need curl; need python3
have ssh || die "missing: ssh"
[[ -n "$TIMEOUT_BIN" ]] || die "missing: timeout (brew install coreutils for gtimeout)"

# Run-scoped set of "kind repo id" keys already attempted, so a job that makes
# no progress (escalation, timeout, invalid verdict) is not retried in a loop.
ATTEMPTED=""
is_attempted() { [[ -n "$ATTEMPTED" ]] && grep -qxF "$1" <<<"$ATTEMPTED"; }

gh_nap() { [[ "$GH_SLEEP" == 0 || "$GH_SLEEP" == 0.0 ]] || sleep "$GH_SLEEP"; }

gh_rate_ok() {
  local rem
  rem=$(gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null || echo 0)
  [[ "$rem" =~ ^[0-9]+$ ]] || rem=0
  (( rem >= GH_MIN_REMAINING ))
}

# Sleep until the core rate limit resets (capped), so an overloaded API pauses
# the worker instead of hammering it.
gh_wait_cooldown() {
  local reset now wait
  reset=$(gh api rate_limit --jq '.resources.core.reset' 2>/dev/null || echo 0)
  [[ "$reset" =~ ^[0-9]+$ ]] || reset=0
  now=$(date +%s)
  wait=$(( reset - now + 5 ))
  (( wait < 0 )) && wait=0
  (( wait > GH_COOLDOWN_MAX )) && wait="$GH_COOLDOWN_MAX"
  echo "[glm] github core rate-limited; cooling down ${wait}s" >&2
  sleep "$wait"
}

# True once the API budget is usable, waiting one cooldown if needed.
ensure_gh_budget() {
  gh_rate_ok && return 0
  gh_wait_cooldown
  gh_rate_ok
}

idle_ready() { GLM_IDLE_REMOTE="${GLM_IDLE_REMOTE:-true}" bash "${SCRIPT_DIR}/glm_idle.sh" check; }

# --- backlog discovery -------------------------------------------------------

group_repos() {
  local g="$1" f="${RUN_DIR}/glm-repos-${1//[^A-Za-z0-9]/_}.cache" age
  if [[ -f "$f" ]]; then
    age=$(( $(date +%s) - $(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0) ))
    (( age < REPO_CACHE_TTL )) && { cat "$f"; return 0; }
  fi
  if gh repo list "$g" --no-archived --limit 200 --json nameWithOwner \
    --jq '.[].nameWithOwner' >"${f}.tmp" 2>/dev/null; then
    mv "${f}.tmp" "$f"; cat "$f"
  else
    rm -f "${f}.tmp"; [[ -f "$f" ]] && cat "$f"
  fi
}

# Issue numbers with no open PR pointing at them. A PR "points at" issue N when
# GitHub links it (closingIssuesReferences, the authoritative signal) or a
# "#N" / "issue-N" token appears in the PR branch name or body. Erring toward
# skipping avoids ever double-implementing an issue that already has a PR.
unresolved_issues() {
  local repo="$1" issues text_ref closing referenced
  issues=$(gh issue list -R "$repo" --state open --limit 200 --json number --jq '.[].number' 2>/dev/null || true)
  [[ -n "$issues" ]] || return 0
  # Text refs from branch/body always work; native links are a separate
  # best-effort call, so a gh that lacks the field cannot blank the whole dedup
  # and cause duplicate PRs.
  text_ref=$(gh pr list -R "$repo" --state open --limit 200 --json headRefName,body 2>/dev/null \
    | jq -r '.[] | (.headRefName), (.body // "")' 2>/dev/null \
    | grep -oE '(issue-|#)[0-9]+' | grep -oE '[0-9]+')
  closing=$(gh pr list -R "$repo" --state open --limit 200 --json closingIssuesReferences 2>/dev/null \
    | jq -r '.[].closingIssuesReferences[]?.number' 2>/dev/null)
  referenced=$(printf '%s\n%s\n' "$text_ref" "$closing" | grep -E '^[0-9]+$' | sort -u)
  comm -23 <(sort -u <<<"$issues") <(sort -u <<<"${referenced:-}")
}

# 0 if the PR has commits newer than its last posted review (or was never
# reviewed). Verdicts land as a PullRequestReview (gh pr review) or, on our own
# PRs, an issue comment; both carry the ORCHESTRATE_REVIEW_STATUS marker, so we
# scan reviews AND comments. Compared against last commit time, not updatedAt,
# which our own post would bump.
pr_needs_review() {
  local repo="$1" pr="$2" j last_commit last_review
  j=$(gh pr view "$pr" -R "$repo" --json commits,comments,reviews 2>/dev/null) || return 1
  last_commit=$(jq -r '.commits[-1].committedDate // .commits[-1].authoredDate // ""' <<<"$j")
  [[ -n "$last_commit" ]] || return 1
  last_review=$(jq -r '
    [ (.comments[]? | select((.body // "")|contains("ORCHESTRATE_REVIEW_STATUS:")) | .createdAt),
      (.reviews[]?  | select((.body // "")|contains("ORCHESTRATE_REVIEW_STATUS:")) | .submittedAt) ]
    | map(select(. != null and . != "")) | sort | last // ""' <<<"$j")
  [[ -z "$last_review" ]] && return 0
  [[ "$last_commit" > "$last_review" ]]
}

open_prs() {
  gh pr list -R "$1" --state open --limit 200 \
    --json number,isDraft --jq '.[]|select(.isDraft|not)|.number' 2>/dev/null || true
}

# Print the next action as "review REPO PR" / "implement REPO ISSUE".
#
# Reviewing outranks new work globally: every PR that needs review (across all
# groups, in group-priority order) is handled before any issue is implemented.
# Only when no PR anywhere needs review do we file a new PR, again in group
# order. Items already attempted this run and low API budget both short-circuit
# the scan so it never busy-loops or blows the rate limit.
next_action() {
  local group repo pr n repos
  for group in "${TARGET_GROUPS[@]}"; do
    gh_rate_ok || return 1
    repos=$(group_repos "$group")
    [[ -n "$repos" ]] || continue
    while IFS= read -r repo; do
      [[ -n "$repo" ]] || continue
      gh_rate_ok || return 1
      while IFS= read -r pr; do
        [[ -n "$pr" ]] || continue
        is_attempted "review $repo $pr" && continue
        if pr_needs_review "$repo" "$pr"; then
          echo "review $repo $pr"; return 0
        fi
      done <<<"$(open_prs "$repo")"
      gh_nap
    done <<<"$repos"
  done
  for group in "${TARGET_GROUPS[@]}"; do
    gh_rate_ok || return 1
    repos=$(group_repos "$group")
    [[ -n "$repos" ]] || continue
    while IFS= read -r repo; do
      [[ -n "$repo" ]] || continue
      while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        is_attempted "implement $repo $n" && continue
        echo "implement $repo $n"; return 0
      done <<<"$(unresolved_issues "$repo")"
      gh_nap
    done <<<"$repos"
  done
  return 1
}

# --- checkout + GLM invocation ----------------------------------------------

prepare_checkout() {
  local repo="$1"
  local dir="${WORK_ROOT}/${repo//\//-}"
  mkdir -p "$WORK_ROOT"
  if [[ -d "$dir/.git" ]]; then
    git -C "$dir" fetch --quiet --prune origin || true
    git -C "$dir" reset --hard --quiet 2>/dev/null || true
    git -C "$dir" clean -qfdx 2>/dev/null || true
  else
    gh repo clone "$repo" "$dir" -- --quiet || return 1
  fi
  # Re-enable pushing to origin: a prior review checkout may have disabled it.
  local ourl
  ourl="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
  [[ -n "$ourl" ]] && git -C "$dir" remote set-url --push origin "$ourl" 2>/dev/null || true
  echo "$dir"
}

# Make the checkout unable to push anywhere, so a review run can never overwrite
# a PR branch even if the model ignores the read-only instruction.
disable_push() {
  local dir="$1" r
  for r in $(git -C "$dir" remote 2>/dev/null); do
    git -C "$dir" remote set-url --push "$r" no-push://blocked-by-sloppy-review 2>/dev/null || true
  done
}

extract_json() {
  python3 - "$1" <<'PY'
import json, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
dec = json.JSONDecoder()
i = text.find("{")
while i != -1:
    try:
        obj, _ = dec.raw_decode(text[i:])
    except json.JSONDecodeError:
        i = text.find("{", i + 1); continue
    if isinstance(obj, dict) and "review_status" in obj:
        json.dump(obj, sys.stdout); sys.exit(0)
    i = text.find("{", i + 1)
sys.exit(1)
PY
}

run_glm() {
  local dur="$1" prompt="$2" out="$3"
  # repo_root is the checkout opencode runs in; read by run_tool_with_timeout.
  # shellcheck disable=SC2034
  repo_root="$4"
  run_tool_with_timeout "$dur" opencode glm "$prompt" worker high glm-coordinator \
    >"$out" 2>>"${LOG_DIR}/glm-autonomous.log"
}

do_implement() {
  local repo="$1" n="$2" dir title body base prompt out rc
  dir=$(prepare_checkout "$repo") || { warn "clone failed: $repo"; return 1; }
  title=$(gh issue view "$n" -R "$repo" --json title --jq '.title' 2>/dev/null || echo "")
  body=$(gh issue view "$n" -R "$repo" --json body --jq '.body' 2>/dev/null || echo "")
  base=$(gh repo view "$repo" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo main)
  git -C "$dir" checkout --quiet -B "fix/issue-${n}" "origin/${base}" || return 1
  prompt=$(cat <<EOF
You are ${AGENT_NAME}, an autonomous coding agent. GitHub repo ${repo}, issue
#${n}: ${title}

${body}

Implement this on the current branch fix/issue-${n}. Rules:
- Scoped change only; reuse local patterns; keep the diff narrow.
- Add or update tests for changed behavior and run the test suite; it must pass.
- Least code that does the job. No stubs, placeholders, dead code, or broad reformatting.

Then deliver a pull request (commit and push ARE explicitly requested here):
1. Stage only files you changed; commit with a clear message.
2. Push fix/issue-${n} and open a PR whose body contains "Closes #${n}" and ends
   with the line "-- ${AGENT_NAME} (autonomous agent)". Identify as ${AGENT_NAME}
   in any PR comments you write.
3. Do NOT merge. Do NOT touch any other PR or branch.

If the task is ambiguous or too broad, make no changes, open no PR, and print
ORCHESTRATE_NEEDS_ESCALATION: <reason>
EOF
)
  out=$(mktemp)
  echo "[glm] implement ${repo}#${n}" >&2
  GH_REPO="$repo" run_glm "$IMPLEMENT_TIMEOUT" "$prompt" "$out" "$dir"; rc=$?
  grep -q '^ORCHESTRATE_NEEDS_ESCALATION:' "$out" 2>/dev/null \
    && echo "[glm] escalated ${repo}#${n}: $(grep '^ORCHESTRATE_NEEDS_ESCALATION:' "$out" | head -1)" >&2
  rm -f "$out"
  return "$rc"
}

do_review() {
  local repo="$1" pr="$2" dir prompt raw json rc
  dir=$(prepare_checkout "$repo") || { warn "clone failed: $repo"; return 1; }
  # gh pr checkout resolves fork PRs correctly (raw fetch of the head ref name
  # would miss forks and review the wrong commit). Then block all pushes so the
  # read-only review can never modify the PR branch.
  if ! ( cd "$dir" && GH_REPO="$repo" gh pr checkout "$pr" --force >/dev/null 2>&1 ); then
    warn "review ${repo}#${pr}: gh pr checkout failed"; return 1
  fi
  disable_push "$dir"
  prompt=$(cat <<EOF
You are ${AGENT_NAME}, an autonomous reviewer. Adversarially and critically
review GitHub PR #${pr} in ${repo}. The branch is checked out. Read-only: do NOT
edit, stage, commit, push, or merge.

Assume bugs exist and hunt for them. Judge issue requirements, changed files,
tests and CI evidence, correctness, scope, and hard repo rules. Use
request_changes for any missing requirement, missing test for changed behavior,
wrong behavior, unrelated broad changes, or rule violation. Approve only when
requirements are met and evidence exists.

Output ONLY one JSON object, no prose and no code fences. Begin "summary" with
"${AGENT_NAME}: " so the posted review identifies you.
{"review_status":"approve|request_changes|comment","confidence":0.0,
 "summary":"${AGENT_NAME}: short","requirements":[{"id":"REQ-001","status":"satisfied|missing","evidence":"path or command"}],
 "findings":[{"id":"REQ-001-X","severity":"blocking|major|minor","category":"bug|test|scope|style","file":"path","line":1,"evidence":"fact","why_blocking":"reason","suggested_fix":"fix"}],
 "escalation_required":false,"escalation_reason":""}
EOF
)
  raw=$(mktemp)
  echo "[glm] review ${repo}#${pr}" >&2
  GH_REPO="$repo" run_glm "$REVIEW_TIMEOUT" "$prompt" "$raw" "$dir"; rc=$?
  if [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
    warn "review ${repo}#${pr}: reviewer left changes; discarding (not pushed)"
    git -C "$dir" reset --hard --quiet 2>/dev/null || true
    git -C "$dir" clean -qfdx 2>/dev/null || true
  fi
  json=$(mktemp)
  if extract_json "$raw" >"$json" && validate_review_json "$json"; then
    if ( cd "$dir" && GH_REPO="$repo" post_review_json "$pr" "$json" ); then
      rc=0
    else
      warn "review ${repo}#${pr}: posting the verdict failed"
      rc=1
    fi
  else
    warn "review ${repo}#${pr}: no valid JSON verdict (rc=$rc)"
    rc=1
  fi
  rm -f "$raw" "$json"
  return "$rc"
}

do_action() {
  local kind="$1" repo="$2" id="$3"
  case "$kind" in
    review) do_review "$repo" "$id" ;;
    implement) do_implement "$repo" "$id" ;;
    *) warn "unknown action: $kind"; return 2 ;;
  esac
}

# --- entry points ------------------------------------------------------------

# Guard so tests can source this file and exercise functions without dispatch.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
case "$ACTION" in
  next)
    next_action || { echo "no work"; exit 0; }
    ;;
  once)
    read -r kind repo id < <(next_action) || { echo "no work" >&2; exit 0; }
    do_action "$kind" "$repo" "$id"
    ;;
  run)
    lockd="${LOCK}.d"
    if ! mkdir "$lockd" 2>/dev/null; then
      pid=$(cat "$lockd/pid" 2>/dev/null || true)
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        echo "another glm_autonomous run (pid $pid) holds the lock; exit" >&2; exit 0
      fi
      rm -rf "$lockd"; mkdir "$lockd" 2>/dev/null || { echo "lock race; exit" >&2; exit 0; }
    fi
    echo "$$" >"$lockd/pid"
    trap 'rm -rf "$lockd"' EXIT
    if ! idle_ready; then
      echo "[glm] cluster busy; nothing to do" >&2
      exit 0
    fi
    echo "[glm] cluster idle; starting GLM" >&2
    GLM_SERVICE_REMOTE="${GLM_SERVICE_REMOTE:-true}" bash "${SCRIPT_DIR}/glm_service.sh" start >>"${LOG_DIR}/glm-autonomous.log" 2>&1 \
      || { warn "glm_service start failed (peer down?); retry next tick"; exit 0; }
    jobs=0
    while (( jobs < MAX_JOBS )); do
      if ! idle_ready; then
        echo "[glm] cluster turned busy after ${jobs} job(s); yielding" >&2
        if [[ "$STOP_ON_YIELD" == true ]]; then
          echo "[glm] stopping GLM to return RAM to the human" >&2
          GLM_SERVICE_REMOTE="${GLM_SERVICE_REMOTE:-true}" bash "${SCRIPT_DIR}/glm_service.sh" stop >>"${LOG_DIR}/glm-autonomous.log" 2>&1 || true
        fi
        break
      fi
      if ! ensure_gh_budget; then
        echo "[glm] github budget exhausted after cooldown; stopping" >&2
        break
      fi
      read -r kind repo id < <(next_action) || { echo "[glm] backlog empty after ${jobs} job(s)" >&2; break; }
      do_action "$kind" "$repo" "$id" || warn "job failed: $kind $repo $id"
      ATTEMPTED="${ATTEMPTED}${ATTEMPTED:+$'\n'}${kind} ${repo} ${id}"
      ((++jobs))
    done
    ;;
  *)
    echo "usage: $0 {run|next|once}" >&2
    exit 2
    ;;
esac
fi
