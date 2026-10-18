#!/usr/bin/env bash
# session-memory-surface.sh — SessionStart hook.
# Surfaces the project's accumulated session memory at session entry. It is
# "source"-aware (the SessionStart payload's "source" field):
#
#   * startup | resume | clear | fork : inject the last enriched session's
#     summary plus any open ("proposed") CLAUDE.md optimization candidates.
#   * compact                  : inject a COMPACTION-RECOVERY block — the
#     current session's in-flight insights / troubleshooting / summary, plus a
#     re-read instruction — so work captured before the compaction is not lost.
#
# Pairs with session-memory-scaffold.sh (Stop hook, write side). Schema:
# schema/session-memory.schema.json; the loop: docs/session-memory.md.
# SessionStart "source" values and additionalContext are documented at
# https://code.claude.com/docs/en/hooks
#
# Read-only. Emits SessionStart additionalContext JSON, or nothing at all.

set -u

input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
src="$(printf '%s' "$input" | jq -r '.source // empty')"
sid="$(printf '%s' "$input" | jq -r '.session_id // empty')"
[ -n "$cwd" ] || exit 0

# Only for projects under GOV_PROJECTS_ROOT (default ~/Projects; "/" = everywhere)
root="${GOV_PROJECTS_ROOT:-$HOME/Projects}"
root="$(cd "$root" 2>/dev/null && pwd -P || printf '%s' "$root")"   # cwd arrives resolved
case "$cwd/" in
  "${root%/}/"*) : ;;
  *) exit 0 ;;
esac

# Claude Code's per-project directory name: "/" and "_" become "-"
encoded="${cwd//\//-}"; encoded="${encoded//_/-}"
digest="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../scripts" 2>/dev/null && pwd)/session-memory-digest.sh"
jsonfile="${CLAUDE_HOME:-$HOME/.claude}/projects/$encoded/memory/session-memory.json"
[ -f "$jsonfile" ] || exit 0
jq -e . "$jsonfile" >/dev/null 2>&1 || exit 0

ctx="$(jq -r --arg src "$src" --arg sid "$sid" --arg jf "$jsonfile" --arg digest "$digest" '
  (.project // "this project") as $proj
  | (.sessions // []) as $S
  | ($S | map(select(.enriched == true)) | last) as $lastenr
  | ([$S[] | select(.session_id == $sid)] | last) as $cur
  | ([$S[].optimization_candidates[]? | select(.status == "proposed")]) as $props
  | ( if ($props | length) > 0
      then "\n\nOpen CLAUDE.md optimization candidates (\($props|length)) — review, apply or reject:\n"
           + ([$props[:10][] | "  - [\(.target // "?")] \(.proposal // "")"] | join("\n"))
           + (if ($props | length) > 10 then "\n  … and \(($props | length) - 10) more (see the digest)" else "" end)
      else "" end ) as $propblock
  | ( if $lastenr != null
      then "Session memory — \($proj) (last enriched session \($lastenr.date // "undated")):\n\($lastenr.summary // "(no summary)")"
      else null end ) as $base
  | if $src == "compact"
    then
      "[!] Context was just compacted — session-memory recovery for \($proj).\n"
      + "Re-read \($jf) for the full in-flight record before continuing.\n"
      + ( if ($cur != null)
            and ( ((($cur.insights // []) | length) + (($cur.troubleshooting // []) | length)) > 0
                  or (($cur.summary // "") != "") )
          then ( if (($cur.summary // "") != "")
                 then "\nThis session so far: \($cur.summary)\n" else "\n" end )
               + ( if ((($cur.insights // []) | length) > 0)
                   then "Insights captured this session:\n"
                        + ([$cur.insights[] | "  - \(.text // "")"] | join("\n")) + "\n"
                   else "" end )
               + ( if ((($cur.troubleshooting // []) | length) > 0)
                   then "Troubleshooting this session:\n"
                        + ([$cur.troubleshooting[] | "  - \(.symptom // "") [\(.taxonomy // "untagged")]" + (if .ref then " -> \(.ref)" else "" end)] | join("\n")) + "\n"
                   else "" end )
          else "\n(Nothing logged to the current session record yet. If work happened before the compaction, reconstruct it from feedback.md and recent commits, and record it in session-memory.json now.)\n"
          end )
      + $propblock
    else
      if ($base == null) and (($props | length) == 0)
      then empty
      else ($base // "Session memory — \($proj):")
           + $propblock
           + "\n\nFull record: \($jf). Cross-project review: \($digest)"
      end
    end
' "$jsonfile")"

[ -n "$ctx" ] || exit 0

jq -n --arg ctx "$ctx" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
exit 0
