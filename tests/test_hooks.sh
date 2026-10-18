#!/usr/bin/env bash
# Tests for the three hooks. Every run uses a throwaway HOME and projects root,
# so nothing touches the real ~/.claude. Needs jq.
# check() evaluates its condition later, so conditions are single-quoted and
# variables used only inside them look unused to shellcheck
# shellcheck disable=SC2016,SC2034

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

export HOME="$TMP/home"
export GOV_PROJECTS_ROOT="$TMP/projects"
mkdir -p "$HOME" "$GOV_PROJECTS_ROOT/demo_app" "$TMP/elsewhere"
PROJ="$GOV_PROJECTS_ROOT/demo_app"
MEM="$HOME/.claude/projects/$(printf '%s' "$PROJ" | tr '/_' '--')/memory/session-memory.json"

pass=0
fail=0
check() { if eval "$2"; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1"; fail=$((fail+1)); fi; }
payload() { jq -n --arg cwd "$1" --arg sid "$2" --arg src "${3:-}" --argjson active "${4:-false}" \
  '{cwd: $cwd, session_id: $sid, source: $src, stop_hook_active: $active}'; }
scaffold() { payload "$@" | "$REPO/hooks/session-memory-scaffold.sh"; }
surface() { payload "$@" | "$REPO/hooks/session-memory-surface.sh"; }
verify() { payload "$@" | "$REPO/hooks/verify-effective-state.sh"; }

echo "session-memory-scaffold.sh"
out="$(scaffold "$PROJ" s1)"
check "prints nothing (Stop output would continue the turn)" '[[ -z $out ]]'
check "creates the memory file" '[[ -f $MEM ]]'
check "one un-enriched session" '[[ "$(jq "[.sessions[] | select(.session_id==\"s1\" and .enriched==false)] | length" "$MEM")" == 1 ]]'
check "project name recorded" '[[ "$(jq -r .project "$MEM")" == demo_app ]]'
before="$(jq -r '.sessions[0].started' "$MEM")"
jq '.sessions[0].summary = "kept"' "$MEM" > "$MEM.t" && mv "$MEM.t" "$MEM"
sleep 1
scaffold "$PROJ" s1 >/dev/null
check "second Stop keeps one session" '[[ "$(jq ".sessions | length" "$MEM")" == 1 ]]'
check "second Stop keeps the content" '[[ "$(jq -r ".sessions[0].summary" "$MEM")" == kept ]]'
check "second Stop refreshes ended only" '[[ "$(jq -r ".sessions[0].started" "$MEM")" == "$before" && "$(jq -r ".sessions[0].ended" "$MEM")" != "$before" ]]'
scaffold "$PROJ" s2 >/dev/null
check "a new session appends" '[[ "$(jq ".sessions | length" "$MEM")" == 2 ]]'
scaffold "$TMP/elsewhere" s3 >/dev/null
check "outside the projects root: nothing written" '[[ -z "$(find "$HOME/.claude/projects" -path "*elsewhere*" 2>/dev/null)" ]]'
mkdir -p "$PROJ/.claude-worktrees/agent-abc"
scaffold "$PROJ/.claude-worktrees/agent-abc" s4 >/dev/null
check "subagent worktree: nothing written" '[[ -z "$(find "$HOME/.claude/projects" -path "*agent-abc*" 2>/dev/null)" ]]'
printf 'demo_app\tRESEARCH\n' > "$GOV_PROJECTS_ROOT/.tiers.tsv"
mkdir -p "$GOV_PROJECTS_ROOT/second"
scaffold "$GOV_PROJECTS_ROOT/second" s5 >/dev/null
M2="$HOME/.claude/projects/$(printf '%s' "$GOV_PROJECTS_ROOT/second" | tr '/_' '--')/memory/session-memory.json"
check "no registry entry: empty tier" '[[ "$(jq -r .tier "$M2")" == "" ]]'
rm "$MEM"; scaffold "$PROJ" s6 >/dev/null
check "tier read from the registry" '[[ "$(jq -r .tier "$MEM")" == RESEARCH ]]'
echo "{not json" > "$MEM"
scaffold "$PROJ" s7 >/dev/null
check "a corrupt file is never overwritten" '[[ "$(cat "$MEM")" == "{not json" ]]'

if python3 -c "import jsonschema" 2>/dev/null; then
  validate() { python3 -c 'import json, sys, jsonschema
jsonschema.validate(json.load(open(sys.argv[1])), json.load(open(sys.argv[2])))' "$1" "$REPO/schema/session-memory.schema.json"; }
  rm -f "$MEM"; scaffold "$PROJ" s8 >/dev/null
  check "hook output matches the published schema" 'validate "$MEM"'
  jq '.sessions[0] += {enriched: true, summary: "x",
       insights: [{text: "t", tags: ["a"], confidence: "high"}],
       troubleshooting: [{symptom: "s", taxonomy: "env", ref: "feedback.md#2026-01-01"}],
       user_interactions: [{type: "correction", scope: "project", note: "n"}],
       optimization_candidates: [{target: "CLAUDE.md", proposal: "p", rationale: "r", status: "proposed"}]}' \
     "$MEM" > "$TMP/enriched.json"
  check "an enriched record matches the schema" 'validate "$TMP/enriched.json"'
  jq '.sessions[0].troubleshooting = [{symptom: "s", taxonomy: "misc"}]' "$MEM" > "$TMP/bad.json"
  check "the schema rejects an unknown defect tag" '! validate "$TMP/bad.json" 2>/dev/null'
else
  echo "  SKIP  schema checks (python3 jsonschema not installed)"
fi

echo "session-memory-surface.sh"
jq -n '{schema_version: 1, project: "demo_app", tier: "", created: "x", sessions: [
  {session_id: "old", date: "2026-01-01", enriched: true, summary: "Built the importer.",
   insights: [], troubleshooting: [], user_interactions: [],
   optimization_candidates: [{target: "CLAUDE.md", proposal: "Always run the linter", rationale: "r", status: "proposed"},
                             {target: "CLAUDE.md", proposal: "Already adopted rule", rationale: "r", status: "applied"}]},
  {session_id: "now", date: "2026-01-02", enriched: true, summary: "Midway through tests.",
   insights: [{text: "fixtures live in tests/data", tags: [], confidence: "high"}],
   troubleshooting: [], user_interactions: [], optimization_candidates: []}]}' > "$MEM"
out="$(surface "$PROJ" new startup)"
ctx="$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out")"
check "startup: SessionStart JSON" '[[ "$(jq -r .hookSpecificOutput.hookEventName <<<"$out")" == SessionStart ]]'
check "startup: last enriched summary" '[[ $ctx == *"Midway through tests."* ]]'
check "startup: open candidates listed" '[[ $ctx == *"Always run the linter"* ]]'
check "startup: applied candidates are not" '[[ $ctx != *"Already adopted rule"* ]]'
check "startup: digest script path is real" '[[ -f "$(grep -o "/[^ ]*session-memory-digest.sh" <<<"$ctx")" ]]'
out="$(surface "$PROJ" now compact)"
ctx="$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out")"
check "compact: recovery block" '[[ $ctx == *"Context was just compacted"* ]]'
check "compact: this session's insights" '[[ $ctx == *"fixtures live in tests/data"* ]]'
check "fork is treated like startup" '[[ "$(surface "$PROJ" x fork | jq -r .hookSpecificOutput.additionalContext)" == *"Midway"* ]]'
check "outside the root: no output" '[[ -z "$(surface "$TMP/elsewhere" x startup)" ]]'
check "no memory file: no output" '[[ -z "$(surface "$GOV_PROJECTS_ROOT/nothing" x startup)" ]]'

echo "verify-effective-state.sh"
export GOV_VERIFY_TRUST="$TMP/trusted" XDG_STATE_HOME="$TMP/state"
TRUST="$REPO/scripts/verify-trust.sh"
# Approval needs a person at a terminal, so tests record approvals directly
approve() {  # record what approval would pin, via the read-only --fingerprint mode
  local fp h v list proj=$1; shift
  "$TRUST" "$proj" --revoke >/dev/null
  fp="$("$TRUST" "$proj" "$@" --fingerprint 2>/dev/null)"
  h="$(sed -n 1p <<<"$fp")"; v="$(sed -n 2p <<<"$fp")"
  list="$GOV_VERIFY_TRUST.d/$(printf '%s' "$v" | sha256sum | cut -c1-32).files"
  mkdir -p "$(dirname "$list")"; tail -n +3 <<<"$fp" > "$list"
  printf '%s  %s\n' "$h" "$v" >> "$GOV_VERIFY_TRUST"
}

mkdir -p "$PROJ/scripts"
V="$PROJ/scripts/verify.sh"
verifier() {  # verifier <exit code> <output>; it also leaves a marker when it runs
  printf '#!/usr/bin/env bash\ntouch "%s/ran"\nprintf "%%s" %q\nexit %s\n' "$TMP" "$2" "$1" > "$V"
  chmod +x "$V"
  rm -f "$TMP/ran"
}
ctx_of() { jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$1"; }
FAILJSON='{"fail":1,"unverified":0,"checks":[{"area":"net","check":"firewall","status":"FAIL","expected":"on","observed":"off","channel":"ufw status"}]}'

verifier 1 "$FAILJSON"
out="$(verify "$PROJ" t1)"
check "untrusted verifier is NOT run" '[[ ! -e $TMP/ran ]]'
check "untrusted verifier is reported, with how to approve it" '[[ "$(ctx_of "$out")" == *"not approved"*"verify-trust.sh"* ]]'
check "the notice comes once per session" '[[ -z "$(verify "$PROJ" t1)" && ! -e $TMP/ran ]]'
approve "$PROJ"
out="$(verify "$PROJ" t2)"
check "trusted: runs and reports the failed check" '[[ -e $TMP/ran && "$(ctx_of "$out")" == *"firewall: expected on, observed off"* ]]'
check "already continuing (stop_hook_active): silent" '[[ -z "$(verify "$PROJ" t2 "" true)" ]]'
printf '\n# changed\n' >> "$V"; rm -f "$TMP/ran"
out="$(verify "$PROJ" t3)"
check "a changed verifier is not run until approved again" '[[ ! -e $TMP/ran && "$(ctx_of "$out")" == *"not approved"* ]]'
"$TRUST" "$PROJ" --revoke >/dev/null
check "revoke removes the approval" '[[ ! -s $GOV_VERIFY_TRUST ]]'
setsid "$TRUST" "$PROJ" </dev/null >/dev/null 2>"$TMP/trust.err"; rc=$?
# Run from inside Claude Code (as these tests may be), whichever check fires first refuses
check "approval refuses without a person at a terminal" '[[ $rc -eq 3 && ! -s $GOV_VERIFY_TRUST ]] && grep -qE "interactive terminal|inside Claude Code" "$TMP/trust.err"'
"$TRUST" "$PROJ" --yes >/dev/null 2>&1; rc=$?
check "there is no --yes shortcut" '[[ $rc -eq 2 && ! -s $GOV_VERIFY_TRUST ]]'
check "the notice tells Claude not to approve it" '[[ "$(ctx_of "$out")" == *"do not run the approval yourself"* ]]'

broken() {  # broken <label> <exit> <output> <expected text>
  verifier "$2" "$3"; approve "$PROJ"
  local o want="$4"; o="$(verify "$PROJ" "b-$1")"
  check "broken verifier ($1) is reported" '[[ "$(ctx_of "$o")" == *"$want"* ]]'
}
broken garbage-exit-1 1 "not json at all" "not a JSON report"
broken exit-3 3 "{}" "exited with status 3"
broken no-output-exit-1 1 "" "not a JSON report"
broken fail0-but-exit-1 1 '{"fail":0}' "reported no failed or unverified check"
broken no-checks-array 1 '{"fail":1}' "1 effective-state check(s) FAILED"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$V"; chmod +x "$V"; approve "$PROJ"
out="$(GOV_VERIFY_TIMEOUT=1 verify "$PROJ" hang)"
check "a hanging verifier times out and is reported" '[[ "$(ctx_of "$out")" == *"did not finish within 1 s"* ]]'
verifier 2 '{"fail":0,"unverified":1,"checks":[{"area":"disk","check":"smart","status":"UNVERIFIED","observed":"no access"}]}'; approve "$PROJ"
check "incomplete coverage reported" '[[ "$(ctx_of "$(verify "$PROJ" u1)")" == *"could not be verified"* ]]'
verifier 0 '{"fail":0}'; approve "$PROJ"
check "all green: silent" '[[ -z "$(verify "$PROJ" g1)" && -e $TMP/ran ]]'
mkdir -p "$PROJ/ops"; mv "$V" "$PROJ/ops/check.sh"
check "GOV_VERIFIER path (untrusted until approved)" '[[ "$(ctx_of "$(GOV_VERIFIER=ops/check.sh verify "$PROJ" gv)")" == *"not approved"* ]]'
check "no verifier: silent" '[[ -z "$(verify "$GOV_PROJECTS_ROOT/second" s1)" ]]'
check "GOV_VERIFIER list: the first path present is used" '[[ "$(ctx_of "$(GOV_VERIFIER=scripts/verify.sh:ops/check.sh verify "$PROJ" gl)")" == *"ops/check.sh"* ]]'
ln -s "$GOV_PROJECTS_ROOT" "$TMP/rootlink"
verifier 1 "$FAILJSON"; approve "$PROJ"
# A verifier that sources a library: approval must cover the library too
L="$GOV_PROJECTS_ROOT/libproj"; mkdir -p "$L/scripts" "$L/lib"
echo 'ok() { true; }' > "$L/lib/common.sh"
printf '#!/usr/bin/env bash\nPROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"\nsource "$PROJECT_ROOT/lib/common.sh"\ntouch "%s/ran-lib"\necho "{\\"fail\\":1,\\"checks\\":[{\\"area\\":\\"a\\",\\"check\\":\\"c\\",\\"status\\":\\"FAIL\\"}]}"\nexit 1\n' "$TMP" > "$L/scripts/verify.sh"
chmod +x "$L/scripts/verify.sh"
check "a variable-prefixed source is not guessed: UNRESOLVED" '"$TRUST" "$L" --fingerprint 2>&1 >/dev/null | grep -q "UNRESOLVED: verify.sh: source \$PROJECT_ROOT/lib/common.sh"'
env -u CLAUDECODE "$TRUST" "$L" </dev/null >/dev/null 2>"$TMP/unres.err"; rc=$?
check "approval is refused while anything is unresolved (fail closed)" '[[ $rc -eq 4 ]] && grep -q "not pinned" "$TMP/unres.err"'
check "--also pins the library and resolves it" '"$TRUST" "$L" --also "$L/lib/common.sh" --fingerprint 2>"$TMP/fp.err" | grep -qx "$(cd "$L" && pwd -P)/lib/common.sh" && [[ ! -s $TMP/fp.err ]]'
CLAUDECODE=1 "$TRUST" "$L" --also "$L/lib/common.sh" </dev/null >/dev/null 2>"$TMP/cc.err"; rc=$?
check "approval refuses inside Claude Code" '[[ $rc -eq 3 ]] && grep -q "inside Claude Code" "$TMP/cc.err"'
echo 'source "$(dirname "${BASH_SOURCE[0]}")/extra.sh"' >> "$L/lib/common.sh"; echo 'e=1' > "$L/lib/extra.sh"
check "a --also file's own sources are pinned too" '"$TRUST" "$L" --also "$L/lib/common.sh" --fingerprint 2>/dev/null | grep -q "lib/extra.sh$"'
approve "$L" --also "$L/lib/common.sh"
rm -f "$TMP/ran-lib"; out="$(verify "$L" lib1)"
check "approved verifier with its library runs" '[[ -e $TMP/ran-lib && "$(ctx_of "$out")" == *"FAILED"* ]]'
echo 'touch /tmp/should-not-matter' >> "$L/lib/common.sh"; rm -f "$TMP/ran-lib"
out="$(verify "$L" lib2)"
check "a changed library stops the verifier until re-approved" '[[ ! -e $TMP/ran-lib && "$(ctx_of "$out")" == *"not approved"* ]]'
mkdir -p "$L/lib/sub"; echo 'z=1' > "$L/lib/sub/inner.sh"; echo 'source "$(dirname "${BASH_SOURCE[0]}")/sub/inner.sh"' > "$L/lib/near.sh"
printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/../lib/near.sh"  # trailing comment\npython3 tools/report.py\n' > "$L/scripts/verify.sh"
fp="$("$TRUST" "$L" --fingerprint 2>"$TMP/fp2.err")"
check "\$(dirname \$0) sources are followed recursively" 'grep -q "lib/near.sh$" <<<"$fp" && grep -q "lib/sub/inner.sh$" <<<"$fp"'
check "a project script run by an interpreter is UNRESOLVED" 'grep -q "UNRESOLVED: verify.sh: runs tools/report.py" "$TMP/fp2.err"'
cat > "$L/scripts/verify.sh" <<'VEOF'
#!/usr/bin/env bash
# usage: ./scripts/verify.sh --json      (a comment: ignored)
find /tmp -name x -exec true {} +
true && source "$L2/lib/y.sh"
eval "$CMD"
"$ROOT/bin/run" --json
./tools/check.sh
VEOF
"$TRUST" "$L" --fingerprint 2>"$TMP/fp3.err" >/dev/null
check "eval, exec-free find, mid-line source and path commands are classified" '[[ "$(grep -c "^UNCLASSIFIED" "$TMP/fp3.err")" == 4 ]] && ! grep -q "line 2:" "$TMP/fp3.err" && ! grep -q "line 3:" "$TMP/fp3.err"'
printf 'eval "$X" # \033[2K\033[1Ahidden\n' >> "$L/scripts/verify.sh"
"$TRUST" "$L" --fingerprint 2>"$TMP/esc.err" >/dev/null
check "escape codes from the project are shown, not sent to the terminal" '! grep -q $'"'"'\033'"'"' "$TMP/esc.err" && grep -qF "^[[2K" "$TMP/esc.err"'
env -u CLAUDECODE "$TRUST" "$L" </dev/null >/dev/null 2>"$TMP/uc.err"; rc=$?
check "unclassified code blocks approval" '[[ $rc -eq 4 ]] && grep -q "cannot follow" "$TMP/uc.err"'
CLAUDECODE=1 "$TRUST" "$L" --accept-unclassified </dev/null >/dev/null 2>"$TMP/uc2.err"; rc=$?
check "--accept-unclassified only lifts that block (the person check still applies)" '[[ $rc -eq 3 ]]'
check "a symlinked GOV_PROJECTS_ROOT still matches" '[[ -n "$(GOV_PROJECTS_ROOT="$TMP/rootlink" verify "$PROJ" sl)" ]]'

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
