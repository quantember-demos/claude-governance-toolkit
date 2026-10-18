#!/usr/bin/env bash
# Tests for the scripts and skill helpers. Works only in a temp dir with a
# throwaway HOME. Needs jq for the digest test.
# check() evaluates its condition later, so conditions are single-quoted and
# variables used only inside them look unused to shellcheck
# shellcheck disable=SC2016,SC2034

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"

pass=0
fail=0
check() { if eval "$2"; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1"; fail=$((fail+1)); fi; }
FA="$REPO/scripts/feedback-append.sh"
CL="$REPO/skills/retro/scripts/cluster.sh"
SC="$REPO/skills/scaffold-project/scripts/scaffold.sh"

echo "feedback-append.sh + retro cluster.sh (round trip)"
P="$TMP/proj"; mkdir -p "$P/src/deep"
"$FA" -p "$P" -t env "venv missing" "s" "c" "f" "l" >/dev/null
check "creates feedback.md" '[[ -f $P/feedback.md ]]'
check "-t writes a Tag line" 'grep -qx "\*\*Tag:\*\* env" "$P/feedback.md"'
"$FA" -p "$P" "[script] bad quoting" "s" "c" "f" "l" >/dev/null
check "[tag] in the title writes a Tag line" 'grep -qx "\*\*Tag:\*\* script" "$P/feedback.md"'
check "newest entry on top" '[[ "$(grep -m1 "^## " "$P/feedback.md")" == *"bad quoting"* ]]'
(cd "$P/src/deep" && "$FA" -t env "found by walking up" s c f l >/dev/null)
check "walks up to the project root" '[[ "$(grep -c "^## " "$P/feedback.md")" == 3 && ! -e $P/src/deep/feedback.md ]]'
"$FA" -p "$P" -t data 'path C:\new\tab kept' 'literal \n here' c f l >/dev/null
check "backslashes are written as typed" 'grep -qF "path C:\\new\\tab kept" "$P/feedback.md" && grep -qF "literal \\n here" "$P/feedback.md"'
"$FA" -p "$P" -t bogus x s c f l >/dev/null 2>&1; rc=$?
check "unknown tag rejected (rc=$rc)" '[[ $rc -ne 0 && "$(grep -c "^## " "$P/feedback.md")" == 4 ]]'
"$FA" -p "$P" -t >/dev/null 2>&1; rc=$?
check "-t without a value rejected" '[[ $rc -ne 0 ]]'
# A hand-written legacy entry: tag only in the title, no Tag line
printf '## 2020-01-01 — [assumption] guessed an API\n**Symptom:** s\n**Cause:** c\n**Fix:** f\n**Lesson:** l\n\n' >> "$P/feedback.md"
out="$("$CL" "$P/feedback.md")"
check "retro sees the tags (env x2)" 'grep -qP "^2\tenv\t" <<<"$out"'
check "most common tag is listed first" '[[ "$(grep -P "^\d+\t" <<<"$out" | head -1 | cut -f2)" == env ]]'
check "retro sees a Tag line from [tag] titles" 'grep -qP "^1\tscript\t" <<<"$out"'
check "retro reads a legacy [tag]-only entry" 'grep -qP "^1\tassumption\t" <<<"$out"'
check "nothing counted as untagged" '! grep -q untagged <<<"$out"'
echo "2099-01-01" > "$P/.last-retro"
"$CL" "$P/feedback.md" >/dev/null 2>&1; rc=$?
check "cutoff after every entry: exit 5" '[[ $rc -eq 5 ]]'
"$CL" "$TMP/none.md" >/dev/null 2>&1; rc=$?
check "missing file: exit 4" '[[ $rc -eq 4 ]]'

echo "retro cluster.sh edge cases"
R="$TMP/retro"; mkdir -p "$R"
cat > "$R/feedback.md" <<'MDEOF'
## 2026-10-03 — [Script] bad quoting
**Tag:** Env, script

## 2026-3-2 — malformed header
**Tag:** cost

## 2026-10-01 — tag in a fence is ignored
```
**Tag:** data
```
**Tag:** assumption

## 2026-13-45 — impossible date
**Tag:** scope

## 2026-10-02 – en dash
MDEOF
out="$("$CL" "$R/feedback.md")"
check "Tag line wins, lowercased, first word" 'grep -qP "^1\tenv\t2026-10-03\tbad quoting$" <<<"$out"'
check "malformed header's tag does not leak" '! grep -q cost <<<"$out"'
check "a tag inside a code fence is ignored" 'grep -qP "^1\tassumption\t" <<<"$out" && ! grep -q data <<<"$out"'
check "impossible dates are skipped" '! grep -q scope <<<"$out" && grep -q "total: 3" <<<"$out"'
echo "2026-10-02" > "$R/.last-retro"
check "entries on the cutoff day are kept" 'grep -q "total: 2" <<<"$("$CL" "$R/feedback.md")"'

echo "feedback-append.sh hardening"
F="$TMP/fa"; mkdir -p "$F"
"$FA" -p "$F" "[ENV] upper-case tag" s c f l >/dev/null
check "tags are case-insensitive" 'grep -qx "\*\*Tag:\*\* env" "$F/feedback.md"'
"$FA" -p "$F" -t data "multi-line" $'line one\n## 2020-01-01 — fake' c f l >/dev/null
check "a newline in a field cannot inject an entry" '[[ "$(grep -c "^## " "$F/feedback.md")" == 2 ]]'
"$FA" -p "$F" "   " s c f l >/dev/null 2>&1; rc=$?
check "an empty title is rejected" '[[ $rc -ne 0 ]]'
chmod 640 "$F/feedback.md"; "$FA" -p "$F" -t env "keeps mode" s c f l >/dev/null
check "the file's permissions are kept" '[[ "$(stat -c %a "$F/feedback.md")" == 640 ]]'
mkdir -p "$F/real"; mv "$F/feedback.md" "$F/real/feedback.md"; ln -s "$F/real/feedback.md" "$F/feedback.md"
"$FA" -p "$F" -t env "through a symlink" s c f l >/dev/null
check "a symlinked feedback.md is written through" '[[ -L $F/feedback.md ]] && grep -q "through a symlink" "$F/real/feedback.md"'
echo secret > "$TMP/victim"; mkdir -p "$TMP/evil"; ln -s "$TMP/victim" "$TMP/evil/feedback.md"
"$FA" -p "$TMP/evil" -t env "x" s c f l >/dev/null 2>&1; rc=$?
check "a feedback.md symlink pointing outside the project is refused" '[[ $rc -ne 0 && "$(cat "$TMP/victim")" == secret ]]'
G="$TMP/nohead"; mkdir -p "$G"; printf '# Notes\nfree text\n' > "$G/feedback.md"
"$FA" -p "$G" -t env "first entry" s c f l >/dev/null
check "no heading yet: entry follows a blank line" 'grep -B1 "^## " "$G/feedback.md" | head -1 | grep -qx ""'

echo "scaffold.sh"
mkdir -p "$TMP/s1" "$TMP/s2" "$TMP/s3"
bash "$SC" --path "$TMP/s1" >/dev/null
check "default: CLAUDE.md, feedback.md, DECISIONS.md" '[[ "$(ls "$TMP/s1" | tr "\n" " ")" == "CLAUDE.md DECISIONS.md feedback.md " ]]'
check "no tier section without --tier" '! grep -q "^## Tier" "$TMP/s1/CLAUDE.md"'
GOV_TIERS_CONF="$REPO/examples/tiers.conf" bash "$SC" --path "$TMP/s2" --tier REVENUE --classification Confidential >/dev/null
check "tier extras from the example config + threat model" '[[ "$(ls "$TMP/s2" | tr "\n" " ")" == "BACKLOG.md CLAUDE.md DECISIONS.md feedback.md METRICS.md THREAT_MODEL.md " ]]'
check "tier recorded" 'grep -q "^\*\*REVENUE\*\*" "$TMP/s2/CLAUDE.md"'
bash "$SC" --path "$TMP/s1" >/dev/null 2>&1; rc=$?
check "refuses existing files (exit 3), untouched" '[[ $rc -eq 3 && "$(ls "$TMP/s1" | wc -l)" == 3 ]]'
bash "$SC" --path "$TMP/s3" --tier REVENUE >/dev/null 2>&1; rc=$?
check "--tier without a config: exit 2" '[[ $rc -eq 2 && -z "$(ls "$TMP/s3")" ]]'
bash "$SC" --path "$TMP/s3" --extras bogus >/dev/null 2>&1; rc=$?
check "unknown extra: exit 2" '[[ $rc -eq 2 ]]'
mkdir -p "$TMP/s4"; ln -s "$TMP/victim" "$TMP/s4/METRICS.md"
bash "$SC" --path "$TMP/s4" --extras metrics >/dev/null 2>&1; rc=$?
check "a planted symlink for any planned file stops the scaffold" '[[ $rc -eq 3 && "$(cat "$TMP/victim")" == secret && ! -e $TMP/s4/CLAUDE.md ]]'
check "feedback.md bootstrap entry is tagged" 'grep -qx "\*\*Tag:\*\* scope" "$TMP/s1/feedback.md"'

echo "session-memory-digest.sh"
M="$HOME/.claude/projects/-x-proj/memory"; mkdir -p "$M"
jq -n '{schema_version:1, project:"proj", tier:"", sessions:[{session_id:"a", enriched:false, optimization_candidates:[{target:"CLAUDE.md", proposal:"Run tests first", status:"proposed"}]}]}' > "$M/session-memory.json"
out="$("$REPO/scripts/session-memory-digest.sh" 2>&1)"
check "lists the project" 'grep -q "proj" <<<"$out"'
check "lists the proposed candidate" 'grep -q "Run tests first" <<<"$out"'

echo "skill init scripts"
export GOV_RUNS_DIR="$TMP/runs"
room="$(bash "$REPO/skills/model-chat/scripts/init_room.sh" "Should we cache results?" 5)"
check "model-chat room created under GOV_RUNS_DIR" '[[ -f $room && $room == "$TMP/runs/model-chat/"* ]]'
run="$(bash "$REPO/skills/stochastic-multi-agent-consensus/scripts/init_consensus.sh" "Pick a database" 6 analyze)"
check "consensus run created under GOV_RUNS_DIR" '[[ -f $run && $run == "$TMP/runs/stochastic-consensus/"* ]]'
check "consensus run lists 6 framings" '[[ "$(grep -cE "^[0-9]+\. " "$run")" -ge 6 ]]'
r1="$(bash "$REPO/skills/model-chat/scripts/init_room.sh" "Same" 5)"; r2="$(bash "$REPO/skills/model-chat/scripts/init_room.sh" "Same" 08)"
check "same topic in the same second: two files; 08 means eight" '[[ -f $r1 && -f $r2 && $r1 != "$r2" ]] && grep -q "Personas (8)" "$r2"'
bash "$REPO/skills/model-chat/scripts/init_room.sh" "x" 12 >/dev/null 2>&1; rc=$?
check "more personas than exist is refused" '[[ $rc -eq 2 ]]'
r3="$(bash "$REPO/skills/model-chat/scripts/init_room.sh" $'two\n# Injected' 5)"
check "a newline in the topic cannot add a heading" '! grep -q "^# Injected" "$r3"'

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
