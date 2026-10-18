#!/usr/bin/env bash
# install.sh tests, in a throwaway CLAUDE_HOME.
# check() evaluates its condition later, so conditions are single-quoted and
# variables used only inside them look unused to shellcheck
# shellcheck disable=SC2016,SC2034

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_HOME="$TMP/claude"
pass=0
fail=0
check() { if eval "$2"; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1"; fail=$((fail+1)); fi; }

echo "install.sh"
mkdir -p "$CLAUDE_HOME/skills/my-own-skill/empty-dir"
echo mine > "$CLAUDE_HOME/skills/my-own-skill/SKILL.md"
"$REPO/install.sh" > "$TMP/out" 2>&1
check "hooks installed" '[[ -x $CLAUDE_HOME/governance-toolkit/hooks/session-memory-surface.sh ]]'
check "scripts installed" '[[ -x $CLAUDE_HOME/governance-toolkit/scripts/feedback-append.sh ]]'
check "skills installed" '[[ -f $CLAUDE_HOME/skills/retro/scripts/cluster.sh && -f $CLAUDE_HOME/skills/scaffold-project/SKILL.md ]]'
check "workflow installed" '[[ -f $CLAUDE_HOME/workflows/dna-zipper.js ]]'
check "prints the settings snippet with real paths" 'grep -q "$CLAUDE_HOME/governance-toolkit/hooks/session-memory-surface.sh" "$TMP/out"'
check "does not create settings.json" '[[ ! -e $CLAUDE_HOME/settings.json ]]'
# The installed surface hook must find the installed digest script
digest="$(HOME="$TMP/h" GOV_PROJECTS_ROOT="$TMP/p" bash -c 'mkdir -p "$GOV_PROJECTS_ROOT/x" && d="$CLAUDE_HOME/projects/$(printf %s "$GOV_PROJECTS_ROOT/x" | tr "/_" "--")/memory" && mkdir -p "$d" && echo "{\"schema_version\":1,\"project\":\"x\",\"sessions\":[{\"session_id\":\"a\",\"enriched\":true,\"summary\":\"s\",\"insights\":[],\"troubleshooting\":[],\"user_interactions\":[],\"optimization_candidates\":[]}]}" > "$d/session-memory.json" && jq -n --arg c "$GOV_PROJECTS_ROOT/x" "{cwd:\$c,session_id:\"b\",source:\"startup\"}" | '"$CLAUDE_HOME"'/governance-toolkit/hooks/session-memory-surface.sh' | jq -r .hookSpecificOutput.additionalContext | grep -o '/[^ ]*session-memory-digest.sh')"
check "installed hook points at the installed digest" '[[ $digest == "$CLAUDE_HOME/governance-toolkit/scripts/session-memory-digest.sh" && -x $digest ]]'
"$REPO/install.sh" > "$TMP/out2" 2>&1
check "re-run is clean (nothing copied or skipped)" 'grep -q "Installed 0 files .* 0 skipped)" "$TMP/out2"'
echo "# my local edit" >> "$CLAUDE_HOME/skills/retro/SKILL.md"
"$REPO/install.sh" > "$TMP/out3" 2>&1
check "a locally edited file is kept" 'grep -q "my local edit" "$CLAUDE_HOME/skills/retro/SKILL.md" && grep -q "skipped .*retro/SKILL.md" "$TMP/out3"'
"$REPO/install.sh" --force > /dev/null 2>&1
check "--force replaces it" '! grep -q "my local edit" "$CLAUDE_HOME/skills/retro/SKILL.md"'
echo "# edited after install" >> "$CLAUDE_HOME/skills/model-chat/SKILL.md"
echo "$TMP/victim.txt" > "$TMP/victim.txt"
printf '%s  %s\n' "$(sha256sum < "$TMP/victim.txt" | cut -d' ' -f1)" "$TMP/victim.txt" >> "$CLAUDE_HOME/governance-toolkit/.installed"
"$REPO/install.sh" --uninstall > "$TMP/un" 2>&1
check "uninstall removes the toolkit" '[[ ! -e $CLAUDE_HOME/governance-toolkit/hooks && ! -e $CLAUDE_HOME/skills/retro && ! -e $CLAUDE_HOME/workflows/dna-zipper.js ]]'
check "uninstall keeps a file edited after install" 'grep -q "edited after install" "$CLAUDE_HOME/skills/model-chat/SKILL.md" && grep -q "kept .*model-chat/SKILL.md: changed" "$TMP/un"'
check "uninstall never deletes outside CLAUDE_HOME" '[[ -f $TMP/victim.txt ]] && grep -q "outside" "$TMP/un"'
check "uninstall keeps the user's own skill and its empty dir" '[[ -f $CLAUDE_HOME/skills/my-own-skill/SKILL.md && -d $CLAUDE_HOME/skills/my-own-skill/empty-dir ]]'
rm -rf "$CLAUDE_HOME"

# A file that already existed, identical to the toolkit's, is not claimed
mkdir -p "$CLAUDE_HOME/workflows"; cp "$REPO/workflows/dna-zipper.js" "$CLAUDE_HOME/workflows/"
"$REPO/install.sh" >/dev/null 2>&1; "$REPO/install.sh" --uninstall >/dev/null 2>&1
check "a pre-existing identical file is left in place" '[[ -f $CLAUDE_HOME/workflows/dna-zipper.js ]]'
rm -rf "$CLAUDE_HOME"

# Paths with a space and a quote: the printed hook commands must still run
export CLAUDE_HOME="$TMP/my claude's home"
"$REPO/install.sh" > "$TMP/out4" 2>&1
snippet="$(sed -n '/^{/,$p' "$TMP/out4")"
check "settings snippet is valid JSON" 'jq -e . >/dev/null <<<"$snippet"'
cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' <<<"$snippet")"
check "the printed command runs from a path with a space and a quote" 'jq -n "{cwd:\"/nowhere\",session_id:\"x\",source:\"startup\"}" | bash -c "$cmd"'
"$REPO/install.sh" --bogus >/dev/null 2>&1; rc=$?
check "unknown option rejected" '[[ $rc -eq 2 ]]'

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
