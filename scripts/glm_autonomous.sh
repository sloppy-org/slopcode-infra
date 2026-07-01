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
REVIEW_FINALIZE_TIMEOUT="${GLM_REVIEW_FINALIZE_TIMEOUT:-10m}"
MAX_JOBS="${GLM_MAX_JOBS_PER_RUN:-50}"
EXO_API="${EXO_API:-http://127.0.0.1:52415}"

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

# True when the exo cluster can serve GLM: >=2 nodes and a placed model
# instance. exo itself is kept alive by its own LaunchAgent; the worker never
# restarts it, it only places the model on demand (idempotent).
glm_ready() {
  local st
  st="$(curl -s -m6 "${EXO_API}/state" 2>/dev/null)" || return 1
  [[ -n "$st" ]] || return 1
  printf '%s' "$st" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if len(d.get("topology",{}).get("nodes",[]))>=2 and len(d.get("instances",{}))>=1 else 1)'
}

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

# Extract the review markdown between the reviewer's markers (opencode streams
# tool noise around it) and the trailing STATUS line.
extract_review_body() {
  awk '/^<<<SLOPPY_REVIEW>>>/{f=1;next} /^<<<END_REVIEW>>>/{f=0} f' "$1"
}
extract_review_status() {
  grep -ioE 'STATUS:[[:space:]]*(approve|request_changes|request-changes|comment)' "$1" \
    | tail -1 | sed -E 's/.*:[[:space:]]*//' | tr '[:upper:]' '[:lower:]' | tr '-' '_'
}

review_artifact_path() {
  local repo="$1" pr="$2" reason="$3" safe ts
  safe="${repo//[^A-Za-z0-9._-]/_}"
  reason="${reason//[^A-Za-z0-9._-]/_}"
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  printf '%s/glm-review-%s-%s-%s-%s.out\n' "$LOG_DIR" "$safe" "$pr" "$reason" "$ts"
}

save_review_artifact() {
  local src="$1" repo="$2" pr="$3" reason="$4" dst
  [[ -s "$src" ]] || return 0
  mkdir -p "$LOG_DIR"
  dst="$(review_artifact_path "$repo" "$pr" "$reason")"
  cp "$src" "$dst"
  warn "review ${repo}#${pr}: saved ${reason} output to ${dst}"
}

finalize_review_output() {
  local repo="$1" pr="$2" dir="$3" raw="$4" out="$5" prompt transcript rc
  transcript="$(head -c "${GLM_FINALIZE_CONTEXT_MAX:-60000}" "$raw")"
  prompt=$(cat <<EOF
You are ${AGENT_NAME}. Convert the transcript below into the final GitHub PR
review for ${repo}#${pr}.

Do not do more investigation. Do not use tools. Preserve only claims supported
by the transcript. If the transcript contains no defensible review, output a
short comment explaining that no review could be completed.

Output ONLY this format:
<<<SLOPPY_REVIEW>>>
# markdown review body
<<<END_REVIEW>>>
STATUS: approve|request_changes|comment

===== TRANSCRIPT =====
${transcript}
===== END TRANSCRIPT =====
EOF
)
  GH_REPO="$repo" run_glm "$REVIEW_FINALIZE_TIMEOUT" "$prompt" "$out" "$dir"; rc=$?
  return "$rc"
}

# Post the review, preferring a formal verdict. On the bot's own PR GitHub
# rejects approve/request_changes, so fall back to a COMMENTED review, then a
# plain comment. All carry the same rich-markdown body.
post_review() {
  local pr="$1" md="$2" status="$3" event
  case "$status" in
    approve) event=--approve ;;
    request_changes) event=--request-changes ;;
    *) event=--comment ;;
  esac
  gh pr review "$pr" "$event" --body-file "$md" 2>/dev/null \
    || gh pr review "$pr" --comment --body-file "$md" 2>/dev/null \
    || gh pr comment "$pr" --body-file "$md"
}

# Gather the full existing discussion as a markdown block: PR body, CI checks,
# every top-level comment and review, the inline review threads WITH resolved
# state, and the linked issues with their comments. Fed to the reviewer so it is
# conversation-aware rather than reviewing the diff in isolation.
pr_context() {
  local repo="$1" pr="$2" owner name core gql
  owner="${repo%%/*}"; name="${repo##*/}"
  core=$(gh pr view "$pr" -R "$repo" --json title,body,state,author,baseRefName,headRefName,additions,deletions,changedFiles,mergeable,reviewDecision,comments,reviews,statusCheckRollup 2>/dev/null || echo '{}')
  # shellcheck disable=SC2016
  gql=$(gh api graphql -f owner="$owner" -f name="$name" -F number="$pr" -f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100){nodes{isResolved isOutdated path line comments(first:30){nodes{author{login} body}}}} closingIssuesReferences(first:20){nodes{number title body comments(first:50){nodes{author{login} body}}}}}}}' 2>/dev/null || echo '{}')
  printf '## PR\n'
  jq -r '"- \(.title // "?")  [\(.state // "?")]  reviewDecision=\(.reviewDecision // "n/a")  mergeable=\(.mergeable // "n/a")\n- @\(.author.login // "?"), +\(.additions // 0)/-\(.deletions // 0) across \(.changedFiles // 0) files\n\n\(.body // "")"' <<<"$core" 2>/dev/null
  printf '\n\n## CI checks\n'
  jq -r '(.statusCheckRollup // []) | if length==0 then "- (none)" else [.[] | "- \(.name // .context // "check"): \(.conclusion // .state // .status // "?")"] | join("\n") end' <<<"$core" 2>/dev/null
  printf '\n\n## Top-level comments\n'
  jq -r '(.comments // []) | if length==0 then "- (none)" else [.[] | "\n**@\(.author.login // "?")** (\(.createdAt // "")):\n\(.body // "")"] | join("\n") end' <<<"$core" 2>/dev/null
  printf '\n\n## Reviews\n'
  jq -r '(.reviews // []) | if length==0 then "- (none)" else [.[] | "\n**@\(.author.login // "?")** [\(.state // "?")] (\(.submittedAt // "")):\n\(.body // "")"] | join("\n") end' <<<"$core" 2>/dev/null
  printf '\n\n## Inline review threads (resolved state)\n'
  jq -r '((.data.repository.pullRequest.reviewThreads.nodes) // []) | if length==0 then "- (none)" else [.[] | "\n### `\(.path):\(.line // 0)` — \(if .isResolved then "RESOLVED" else "OPEN" end)\(if .isOutdated then " (outdated)" else "" end)\n" + ([.comments.nodes[] | "  - @\(.author.login // "?"): \(.body)"] | join("\n"))] | join("\n") end' <<<"$gql" 2>/dev/null
  printf '\n\n## Linked issues\n'
  jq -r '((.data.repository.pullRequest.closingIssuesReferences.nodes) // []) | if length==0 then "- (none)" else [.[] | "\n### Issue #\(.number): \(.title)\n\(.body // "")\n\nComments:\n" + ([.comments.nodes[] | "  - @\(.author.login // "?"): \(.body)"] | join("\n"))] | join("\n") end' <<<"$gql" 2>/dev/null
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
  local repo="$1" pr="$2" dir prompt ctx raw body status md rc
  dir=$(prepare_checkout "$repo") || { warn "clone failed: $repo"; return 1; }
  # gh pr checkout resolves fork PRs correctly (raw fetch of the head ref name
  # would miss forks and review the wrong commit). Then block all pushes so the
  # read-only review can never modify the PR branch.
  if ! ( cd "$dir" && GH_REPO="$repo" gh pr checkout "$pr" --force >/dev/null 2>&1 ); then
    warn "review ${repo}#${pr}: gh pr checkout failed"; return 1
  fi
  disable_push "$dir"
  ctx="$(pr_context "$repo" "$pr" 2>/dev/null | head -c "${GLM_CONTEXT_MAX:-120000}")"
  prompt=$(cat <<EOF
You are ${AGENT_NAME}, an autonomous reviewer. Adversarially and critically
review GitHub PR #${pr} in ${repo}. The branch is checked out; read the code and
run \`gh pr diff ${pr}\`. Read-only: do NOT edit, stage, commit, push, or merge.
Do not take it easy: assume bugs exist and hunt for them.

Below the markers you are given the full existing context: the PR body, CI
checks, every top-level comment and review, the inline review threads WITH their
resolved/open state, and the linked issue(s) with their comments. Use ALL of it:
- triage what has already been raised and what is resolved vs still open;
- explicitly engage the prior discussion: what has been addressed, where you
  agree or disagree with earlier comments/reviewers, what remains open;
- judge requirements, correctness, tests and CI evidence, scope, and repo rules;
- propose concrete, meaningful next actions.

Write the review as GitHub-flavored Markdown:
- proper headings, lists and emphasis; include a short "Resolved vs open" section;
- reference exact locations as \`path/to/file:line\` and quote the relevant diff hunks;
- language-tagged fences for multi-line code, e.g. \`\`\`fortran ... \`\`\` (fortran, python, c, cpp, cmake, ...);
- LaTeX for math: \$ ... \$ inline, \$\$ ... \$\$ display;
- sign it as ${AGENT_NAME}.

Use request_changes for any missing requirement, missing test for changed
behavior, wrong behavior, a still-open prior concern, unrelated broad changes,
or rule violation. Approve only when requirements are met and evidence exists.

Output ONLY the review between these exact markers, each on its own line, then a
final status line and nothing after it:
<<<SLOPPY_REVIEW>>>
# your markdown review here
<<<END_REVIEW>>>
STATUS: approve|request_changes|comment
EOF
)
  prompt="${prompt}

===== EXISTING PR/ISSUE CONTEXT (comments, reviews, inline threads with resolved state, linked issues) =====
${ctx}
===== END CONTEXT ====="
  raw=$(mktemp)
  echo "[glm] review ${repo}#${pr}" >&2
  GH_REPO="$repo" run_glm "$REVIEW_TIMEOUT" "$prompt" "$raw" "$dir"; rc=$?
  if [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
    warn "review ${repo}#${pr}: reviewer left changes; discarding (not pushed)"
    git -C "$dir" reset --hard --quiet 2>/dev/null || true
    git -C "$dir" clean -qfdx 2>/dev/null || true
  fi
  body="$(extract_review_body "$raw")"
  status="$(extract_review_status "$raw")"
  if [[ -z "${body//[[:space:]]/}" && -s "$raw" ]]; then
    local final_raw final_body final_status final_rc
    final_raw=$(mktemp)
    warn "review ${repo}#${pr}: no marked review body; running finalizer"
    finalize_review_output "$repo" "$pr" "$dir" "$raw" "$final_raw"; final_rc=$?
    final_body="$(extract_review_body "$final_raw")"
    final_status="$(extract_review_status "$final_raw")"
    if [[ -n "${final_body//[[:space:]]/}" ]]; then
      body="$final_body"
      status="$final_status"
      rc="$final_rc"
    else
      save_review_artifact "$raw" "$repo" "$pr" "unmarked"
      save_review_artifact "$final_raw" "$repo" "$pr" "finalizer-empty"
    fi
    rm -f "$final_raw"
  fi
  [[ -n "$status" ]] || status=comment
  if [[ -n "${body//[[:space:]]/}" ]]; then
    md=$(mktemp)
    { printf '%s\n' "$body"; printf '\n<!-- ORCHESTRATE_REVIEW_STATUS: %s -->\n' "$status"; } >"$md"
    if ( cd "$dir" && GH_REPO="$repo" post_review "$pr" "$md" "$status" ); then
      rc=0
    else
      warn "review ${repo}#${pr}: posting the verdict failed"
      rc=1
    fi
    rm -f "$md"
  else
    warn "review ${repo}#${pr}: no review body produced (rc=$rc)"
    rc=1
  fi
  rm -f "$raw"
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
    echo "[glm] cluster idle; ensuring GLM model is placed" >&2
    bash "${SCRIPT_DIR}/exo_glm_autoload.sh" >>"${LOG_DIR}/glm-autonomous.log" 2>&1 || true
    if ! glm_ready; then
      warn "GLM cluster not ready (need 2 exo nodes + a placed model); retry next tick"
      exit 0
    fi
    jobs=0
    while (( jobs < MAX_JOBS )); do
      if ! idle_ready; then
        echo "[glm] cluster turned busy after ${jobs} job(s); yielding (exo stays up)" >&2
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
