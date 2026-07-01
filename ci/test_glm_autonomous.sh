#!/usr/bin/env bash
# TARGET_GROUPS is reassigned per test and read as a global by next_action.
# shellcheck disable=SC2034
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/glm_autonomous.sh"

bash -n "${SCRIPT}" || { echo "FAIL: glm_autonomous.sh syntax"; exit 1; }
bash -n "${REPO_ROOT}/scripts/install_mac_glm_autonomous_launchagent.sh" \
  || { echo "FAIL: install_mac_glm_autonomous_launchagent.sh syntax"; exit 1; }

FAILED=0
ROOT="$(mktemp -d)"
FIX="${ROOT}/fix"; FAKEBIN="${ROOT}/bin"; LIBDIR="${ROOT}/lib"; WORK="${ROOT}/work"
mkdir -p "${FIX}" "${FAKEBIN}" "${LIBDIR}" "${WORK}"
POSTED_LOG="${FIX}/posted.log"; : >"${POSTED_LOG}"
pass() { echo PASS; }
fail() { echo "FAIL: $*"; return 1; }

# --- fakes -------------------------------------------------------------------
cat >"${FAKEBIN}/gh" <<'SH'
#!/usr/bin/env bash
FIX="$GH_FIXTURES"; all="$*"
slug() { echo "${1//[^A-Za-z0-9]/_}"; }
argval() { local flag="$1"; shift; local p=""; for a in "$@"; do [[ "$p" == "$flag" ]] && { echo "$a"; return; }; p="$a"; done; }
case "$1 $2" in
  "repo list")   cat "$FIX/repos_$(slug "$3").txt" 2>/dev/null ;;
  "repo clone")  mkdir -p "${4}/.git" 2>/dev/null || true ;;
  "repo view")   echo "main" ;;
  "issue list")  cat "$FIX/issues_$(slug "$(argval -R "$@")").txt" 2>/dev/null ;;
  "issue view")  echo "" ;;
  "pr list")
    r="$(argval -R "$@")"
    if   [[ "$all" == *closingIssuesReferences* ]]; then cat "$FIX/prjson_$(slug "$r").txt" 2>/dev/null || echo '[]'
    elif [[ "$all" == *number,isDraft*          ]]; then cat "$FIX/propen_$(slug "$r").txt" 2>/dev/null; fi ;;
  "pr view")
    r="$(argval -R "$@")"
    if   [[ "$all" == *commits,comments* ]]; then cat "$FIX/prview_$(slug "$r")_${3}.json" 2>/dev/null
    elif [[ "$all" == *headRefName*      ]]; then echo "fix/issue-${3}"; fi ;;
  "pr review")   echo "$all" >>"$FIX/posted.log" ;;
  "pr comment")  echo "$all" >>"$FIX/posted.log" ;;
  "api user")    echo "botuser" ;;
  "api rate_limit")
    if   [[ "$all" == *remaining* ]]; then echo "${GH_FAKE_REMAINING:-5000}"
    elif [[ "$all" == *reset*     ]]; then echo "${GH_FAKE_RESET:-0}"; fi ;;
  *) : ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' >"${FAKEBIN}/git"
printf '#!/usr/bin/env bash\nexit 0\n' >"${FAKEBIN}/opencode"
chmod +x "${FAKEBIN}"/*

cat >"${LIBDIR}/orchestrate_tools.sh" <<'SH'
run_tool_with_timeout() { cat "${FAKE_MODEL_OUT:-/dev/null}"; return "${FAKE_MODEL_RC:-0}"; }
wait_local_opencode_slot() { :; }
release_local_opencode_slot() { :; }
SH
cat >"${LIBDIR}/orchestrate_review.sh" <<'SH'
review_status_from_json() { jq -r '.review_status // "comment"' "$1" | tr '_' '-'; }
validate_review_json() {
  jq -e 'type=="object" and has("review_status") and has("findings")' "$1" >/dev/null 2>&1 \
    && [[ "$(review_status_from_json "$1")" =~ ^(approve|request-changes|comment)$ ]]
}
post_review_json() { echo "POST pr=$1 status=$(review_status_from_json "$2")" >>"${POSTED_LOG:-/dev/null}"; }
SH

export PATH="${FAKEBIN}:${PATH}"
export GH_FIXTURES="${FIX}" PROMPTS_LIB="${LIBDIR}" GLM_WORK_ROOT="${WORK}"
export GLM_GH_SLEEP=0 POSTED_LOG
export RUN_DIR="${ROOT}/run"; mkdir -p "${RUN_DIR}"
export GLM_GROUPS="itpplasma"

# shellcheck disable=SC1090
source "${SCRIPT}"
set +eu

reset_fixtures() { rm -f "${FIX}"/*.txt "${FIX}"/*.json; rm -f "${RUN_DIR}"/glm-repos-*.cache; ATTEMPTED=""; : >"${POSTED_LOG}"; }

# PR view fixtures (commits + comments + reviews).
prview_needs()        { printf '{"commits":[{"committedDate":"2026-06-01T00:00:00Z"}],"comments":[],"reviews":[]}' >"${FIX}/prview_${1}_${2}.json"; }
prview_done_comment() { printf '{"commits":[{"committedDate":"2026-06-01T00:00:00Z"}],"comments":[{"createdAt":"2026-06-02T00:00:00Z","body":"ORCHESTRATE_REVIEW_STATUS: approve"}],"reviews":[]}' >"${FIX}/prview_${1}_${2}.json"; }
prview_done_review()  { printf '{"commits":[{"committedDate":"2026-06-01T00:00:00Z"}],"comments":[],"reviews":[{"submittedAt":"2026-06-02T00:00:00Z","body":"ORCHESTRATE_REVIEW_STATUS: approve"}]}' >"${FIX}/prview_${1}_${2}.json"; }

# --- tests -------------------------------------------------------------------

test_priority_review_first() {
  echo "TEST: within a group, a PR needing review is the first action"
  reset_fixtures; TARGET_GROUPS=(itpplasma)
  printf 'itpplasma/a\nitpplasma/b\n' >"${FIX}/repos_itpplasma.txt"
  printf '1\n' >"${FIX}/propen_itpplasma_a.txt"; prview_needs itpplasma_a 1
  : >"${FIX}/propen_itpplasma_b.txt"
  local out; out="$(next_action)"
  if [[ "$out" == "review itpplasma/a 1" ]]; then pass; else fail "got [$out]"; fi
}

test_group_fallthrough() {
  echo "TEST: a lower-priority group is only reached when the top one is clear"
  reset_fixtures; TARGET_GROUPS=(itpplasma foo)
  printf 'itpplasma/a\n' >"${FIX}/repos_itpplasma.txt"
  : >"${FIX}/propen_itpplasma_a.txt"; : >"${FIX}/issues_itpplasma_a.txt"
  printf 'foo/x\n' >"${FIX}/repos_foo.txt"
  : >"${FIX}/propen_foo_x.txt"; printf '5\n' >"${FIX}/issues_foo_x.txt"
  local out; out="$(next_action)"
  if [[ "$out" == "implement foo/x 5" ]]; then pass; else fail "got [$out]"; fi
}

test_review_beats_new_work_across_groups() {
  echo "TEST: a PR needing review anywhere outranks filing a new PR"
  reset_fixtures; TARGET_GROUPS=(itpplasma foo)
  printf 'itpplasma/a\n' >"${FIX}/repos_itpplasma.txt"
  : >"${FIX}/propen_itpplasma_a.txt"; printf '5\n' >"${FIX}/issues_itpplasma_a.txt"
  printf 'foo/x\n' >"${FIX}/repos_foo.txt"
  printf '9\n' >"${FIX}/propen_foo_x.txt"; prview_needs foo_x 9
  local out; out="$(next_action)"
  if [[ "$out" == "review foo/x 9" ]]; then pass; else fail "got [$out]"; fi
}

test_skip_issue_with_existing_pr() {
  echo "TEST: an issue whose number appears in a PR branch is not implemented"
  reset_fixtures
  printf '5\n7\n' >"${FIX}/issues_itpplasma_a.txt"
  printf '[{"headRefName":"fix/issue-5","body":"some body","closingIssuesReferences":[]}]' >"${FIX}/prjson_itpplasma_a.txt"
  local out; out="$(unresolved_issues itpplasma/a | tr '\n' ' ')"
  if [[ "$out" == *7* && "$out" != *5* ]]; then pass; else fail "got [$out]"; fi
}

test_skip_issue_referenced_by_closes() {
  echo "TEST: 'Closes #N' in a PR body excludes issue N"
  reset_fixtures
  printf '8\n9\n' >"${FIX}/issues_itpplasma_a.txt"
  printf '[{"headRefName":"feature-branch","body":"Closes #8","closingIssuesReferences":[]}]' >"${FIX}/prjson_itpplasma_a.txt"
  local out; out="$(unresolved_issues itpplasma/a | tr '\n' ' ')"
  if [[ "$out" == *9* && "$out" != *8* ]]; then pass; else fail "got [$out]"; fi
}

test_skip_issue_native_link() {
  echo "TEST: GitHub closingIssuesReferences excludes an issue with no text ref"
  reset_fixtures
  printf '8\n9\n' >"${FIX}/issues_itpplasma_a.txt"
  printf '[{"headRefName":"random-branch","body":"no textual ref","closingIssuesReferences":[{"number":8}]}]' >"${FIX}/prjson_itpplasma_a.txt"
  local out; out="$(unresolved_issues itpplasma/a | tr '\n' ' ')"
  if [[ "$out" == *9* && "$out" != *8* ]]; then pass; else fail "got [$out]"; fi
}

test_needs_review_new() {
  echo "TEST: a PR with no prior review needs review"
  reset_fixtures; prview_needs itpplasma_a 1
  if pr_needs_review itpplasma/a 1; then pass; else fail "should need review"; fi
}

test_needs_review_done_via_comment() {
  echo "TEST: a PR reviewed via an issue comment (own PR) is not re-reviewed"
  reset_fixtures; prview_done_comment itpplasma_a 1
  if pr_needs_review itpplasma/a 1; then fail "should not need review"; else pass; fi
}

test_needs_review_done_via_gh_review() {
  echo "TEST: a PR reviewed via gh pr review (reviews field) is not re-reviewed"
  reset_fixtures; prview_done_review itpplasma_a 1
  if pr_needs_review itpplasma/a 1; then fail "should not need review"; else pass; fi
}

test_rate_ok() {
  echo "TEST: gh_rate_ok honors the remaining-core threshold"
  if ! GH_FAKE_REMAINING=5000 gh_rate_ok; then fail "5000 should pass"; return; fi
  if GH_FAKE_REMAINING=50 GH_MIN_REMAINING=300 gh_rate_ok; then fail "50 should fail"; return; fi
  pass
}

test_cooldown_waits() {
  echo "TEST: gh_wait_cooldown sleeps toward the reset, capped by the max"
  local slept="${ROOT}/slept" now n; : >"${slept}"
  # shellcheck disable=SC2329  # invoked indirectly by gh_wait_cooldown
  sleep() { echo "$1" >>"${slept}"; }
  now=$(date +%s)
  GH_FAKE_RESET=$(( now + 40 )) GLM_GH_COOLDOWN_MAX=900 gh_wait_cooldown >/dev/null 2>&1
  n="$(tail -n1 "${slept}")"
  unset -f sleep
  if [[ "$n" -ge 40 && "$n" -le 900 ]]; then pass; else fail "slept=[$n]"; fi
}

test_ensure_budget_high_no_sleep() {
  echo "TEST: ensure_gh_budget returns immediately when budget is healthy"
  local slept="${ROOT}/slept2" rc; : >"${slept}"
  # shellcheck disable=SC2329  # would be invoked if a cooldown were needed
  sleep() { echo x >>"${slept}"; }
  GH_FAKE_REMAINING=5000 ensure_gh_budget; rc=$?
  unset -f sleep
  if [[ "$rc" == 0 && ! -s "${slept}" ]]; then pass; else fail "rc=$rc slept=$(cat "${slept}")"; fi
}

test_attempted_skipped() {
  echo "TEST: an item already attempted this run is skipped by next_action"
  reset_fixtures; TARGET_GROUPS=(itpplasma)
  printf 'itpplasma/a\n' >"${FIX}/repos_itpplasma.txt"
  printf '1\n' >"${FIX}/propen_itpplasma_a.txt"; prview_needs itpplasma_a 1
  : >"${FIX}/issues_itpplasma_a.txt"
  ATTEMPTED="review itpplasma/a 1"
  local out; out="$(next_action)"; ATTEMPTED=""
  if [[ -z "$out" ]]; then pass; else fail "expected no action, got [$out]"; fi
}

test_do_review_posts_status() {
  echo "TEST: do_review extracts the JSON verdict and posts the mapped status"
  reset_fixtures
  printf 'reasoning line\n{"review_status":"request_changes","summary":"Sloppy: x","findings":[]}\ntrailer\n' >"${ROOT}/mout"
  FAKE_MODEL_OUT="${ROOT}/mout" do_review itpplasma/a 1 >/dev/null 2>&1
  if grep -q "POST pr=1 status=request-changes" "${POSTED_LOG}"; then pass; else fail "log=[$(cat "${POSTED_LOG}")]"; fi
}

test_do_review_approve() {
  echo "TEST: do_review maps an approve verdict"
  reset_fixtures
  printf '{"review_status":"approve","summary":"Sloppy: ok","findings":[]}\n' >"${ROOT}/mout"
  FAKE_MODEL_OUT="${ROOT}/mout" do_review itpplasma/a 2 >/dev/null 2>&1
  if grep -q "POST pr=2 status=approve" "${POSTED_LOG}"; then pass; else fail "log=[$(cat "${POSTED_LOG}")]"; fi
}

test_do_review_rejects_garbage() {
  echo "TEST: do_review posts nothing when the model emits no valid verdict"
  reset_fixtures
  printf 'no json here at all\n' >"${ROOT}/mout"
  FAKE_MODEL_OUT="${ROOT}/mout" do_review itpplasma/a 3 >/dev/null 2>&1
  if [[ ! -s "${POSTED_LOG}" ]]; then pass; else fail "log=[$(cat "${POSTED_LOG}")]"; fi
}

test_installer_dry() {
  echo "TEST: launchd installer dry-run writes a periodic, reboot-clean plist"
  if [[ "$(uname -s)" != Darwin ]]; then echo "SKIP (macOS-only)"; return 0; fi
  local tmp p; tmp="$(mktemp -d)"
  AGENTS_DIR="${tmp}/agents" INSTALL_DRY_RUN=true GLM_TICK_INTERVAL=300 \
    bash "${REPO_ROOT}/scripts/install_mac_glm_autonomous_launchagent.sh" >/dev/null 2>&1 || true
  p="${tmp}/agents/com.slopcode.glm-autonomous.plist"
  if grep -q 'com.slopcode.glm-autonomous' "$p" 2>/dev/null \
     && grep -q 'RunAtLoad' "$p" 2>/dev/null \
     && grep -q '<key>StartInterval</key><integer>300</integer>' "$p" 2>/dev/null \
     && grep -q '<key>KeepAlive</key><false/>' "$p" 2>/dev/null \
     && grep -q '<string>run</string>' "$p" 2>/dev/null; then
    rm -rf "$tmp"; pass
  else rm -rf "$tmp"; fail "plist missing expected keys"; fi
}

test_priority_review_first        || FAILED=$((FAILED + 1))
test_group_fallthrough            || FAILED=$((FAILED + 1))
test_review_beats_new_work_across_groups || FAILED=$((FAILED + 1))
test_skip_issue_with_existing_pr  || FAILED=$((FAILED + 1))
test_skip_issue_referenced_by_closes || FAILED=$((FAILED + 1))
test_skip_issue_native_link       || FAILED=$((FAILED + 1))
test_needs_review_new             || FAILED=$((FAILED + 1))
test_needs_review_done_via_comment || FAILED=$((FAILED + 1))
test_needs_review_done_via_gh_review || FAILED=$((FAILED + 1))
test_rate_ok                      || FAILED=$((FAILED + 1))
test_cooldown_waits               || FAILED=$((FAILED + 1))
test_ensure_budget_high_no_sleep  || FAILED=$((FAILED + 1))
test_attempted_skipped            || FAILED=$((FAILED + 1))
test_do_review_posts_status       || FAILED=$((FAILED + 1))
test_do_review_approve            || FAILED=$((FAILED + 1))
test_do_review_rejects_garbage    || FAILED=$((FAILED + 1))
test_installer_dry                || FAILED=$((FAILED + 1))

rm -rf "${ROOT}"
if [[ "${FAILED}" -gt 0 ]]; then echo "${FAILED} glm_autonomous test(s) failed"; exit 1; fi
echo "all glm_autonomous tests passed"
