#!/usr/bin/env bash
# session-memory-scaffold.sh — Stop hook.
# Scaffolds a per-project session-memory.json skeleton so Claude can enrich it.
# Reads the Stop-hook JSON on stdin; never blocks (always exits 0, no stdout).
#
# Schema: schema/session-memory.schema.json; the loop is described in
# docs/session-memory.md. Prints nothing: a Stop hook's output would make
# Claude continue the turn.
#
# Idempotent: one session object per session_id. First Stop of a session
# creates the object; every later Stop only refreshes its "ended" timestamp.

set -u

# --- read hook payload -------------------------------------------------------
input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0   # jq absent: no-op, do not block

cwd="$(printf '%s' "$input"  | jq -r '.cwd // empty')"
sid="$(printf '%s' "$input"  | jq -r '.session_id // empty')"
[ -n "$cwd" ] && [ -n "$sid" ] || exit 0

# --- only act for projects under the configured root -------------------------
# Only for projects under GOV_PROJECTS_ROOT (default ~/Projects; "/" = everywhere)
root="${GOV_PROJECTS_ROOT:-$HOME/Projects}"
root="$(cd "$root" 2>/dev/null && pwd -P || printf '%s' "$root")"   # cwd arrives resolved
case "$cwd/" in
  "${root%/}/"*) : ;;
  *) exit 0 ;;
esac
[ "${cwd%/}" = "${root%/}" ] && exit 0   # the root itself is not a project

# --- but NOT inside subagent git worktrees ----------------------------------
# A subagent with worktree isolation runs in <project>/.claude-worktrees/agent-<hash>,
# which passes the gate above; basename() would then make the agent hash a "project"
# and leave an empty memory file per subagent run. Insight belongs to the PARENT
# project, which gets its own file from the parent session.
case "$cwd" in
  */.claude-worktrees/*) exit 0 ;;
esac

project="$(basename "$cwd")"
# Claude Code's per-project directory name: "/" and "_" become "-"
encoded="${cwd//\//-}"; encoded="${encoded//_/-}"
memdir="${CLAUDE_HOME:-$HOME/.claude}/projects/$encoded/memory"
jsonfile="$memdir/session-memory.json"

mkdir -p "$memdir" 2>/dev/null || exit 0

# One writer at a time: concurrent Stop hooks (parallel sessions) would
# otherwise read the same file and drop each other's sessions
exec 9>"$memdir/.session-memory.lock" || exit 0
command -v flock >/dev/null 2>&1 && { flock -w 5 9 || exit 0; }

now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
today="$(date -u +"%Y-%m-%d")"

# --- optional tier, from a project registry (TSV: project<TAB>tier) ---------
tier=""
registry="${GOV_TIERS_FILE:-${root%/}/.tiers.tsv}"
if [ -f "$registry" ]; then
  t="$(awk -F'\t' -v p="$project" '$1==p {print $2; exit}' "$registry")"
  [ -n "$t" ] && tier="$t"
fi

# --- create the file skeleton if absent -------------------------------------
if [ ! -f "$jsonfile" ]; then
  jq -n --arg p "$project" --arg tier "$tier" --arg now "$now" \
    '{schema_version: 1, project: $p, tier: $tier, created: $now, sessions: []}' \
    > "$jsonfile" 2>/dev/null || exit 0
fi

# --- bail if the file is not valid JSON (never clobber) ---------------------
jq -e . "$jsonfile" >/dev/null 2>&1 || exit 0

tmp="$(mktemp "${jsonfile}.XXXXXX")" || exit 0
trap 'rm -f "$tmp"' EXIT
chmod --reference="$jsonfile" "$tmp" 2>/dev/null || true   # keep the file's permissions

present="$(jq --arg sid "$sid" \
  '[.sessions[] | select(.session_id == $sid)] | length' "$jsonfile" 2>/dev/null)"

if [ "${present:-0}" = "0" ]; then
  # First Stop of this session: append an un-enriched skeleton object.
  jq --arg sid "$sid" --arg now "$now" --arg today "$today" \
    '.sessions += [{
       session_id: $sid,
       date: $today,
       started: $now,
       ended: $now,
       enriched: false,
       summary: "",
       insights: [],
       troubleshooting: [],
       user_interactions: [],
       optimization_candidates: []
     }]' "$jsonfile" > "$tmp" 2>/dev/null && mv "$tmp" "$jsonfile"
else
  # Later Stop: only refresh the end timestamp.
  jq --arg sid "$sid" --arg now "$now" \
    '(.sessions[] | select(.session_id == $sid) | .ended) |= $now' \
    "$jsonfile" > "$tmp" 2>/dev/null && mv "$tmp" "$jsonfile"
fi

exit 0
