#!/usr/bin/env bash
# session-memory-digest.sh — read-only scan of every project's session-memory.json.
#
# Surfaces the learning / optimization loop payload:
#   * optimization candidates still in "proposed" status — CLAUDE.md edits to weigh
#   * sessions not yet enriched by Claude — incomplete capture to backfill
#
# Schema of session-memory.json: schema/session-memory.schema.json; see
# docs/session-memory.md for the loop it supports.
#
# Usage:
#   session-memory-digest.sh           human-readable report
#   session-memory-digest.sh --json    machine-readable aggregate
#
# Read-only: never writes. Idempotent.

set -u

projroot="${CLAUDE_HOME:-$HOME/.claude}/projects"
mode="${1:-text}"
case "$mode" in
  text|--json) ;;
  -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
  *) echo "unknown option: $mode (use --json, or nothing)" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "jq required but not installed" >&2; exit 1; }

files=()
while IFS= read -r f; do files+=("$f"); done \
  < <(find "$projroot" -type f -path '*/memory/session-memory.json' 2>/dev/null | sort)

if [ "${#files[@]}" -eq 0 ]; then
  echo "No session-memory.json files found under $projroot"
  exit 0
fi

# Skip any file that is not a session record, so one bad file cannot abort the
# scan or make the report read as an all-clear. Skips are counted and shown.
valid=()
skipped=0
for f in "${files[@]}"; do
  if jq -e 'type == "object" and (.sessions | type == "array")' "$f" >/dev/null 2>&1; then
    valid+=("$f")
  else
    echo "WARN: skipping $f: not a session-memory record (invalid JSON or wrong shape)" >&2
    skipped=$((skipped + 1))
  fi
done
files=("${valid[@]}")
[ "${#files[@]}" -eq 0 ] && { echo "No valid session-memory.json files."; exit 0; }

if [ "$mode" = "--json" ]; then
  jq -s '{
    generated: (now | todate),
    projects: [ .[] | {
      project, tier: (.tier // ""),
      sessions:   (.sessions | length),
      unenriched: ([.sessions[] | select(.enriched == false)] | length),
      proposed:   ([.sessions[].optimization_candidates[]? | select(.status == "proposed")] | length)
    } ],
    proposed_candidates: [ .[] | .project as $p | .sessions[]
      | .date as $d | .optimization_candidates[]?
      | select(.status == "proposed")
      | {project: $p, date: $d, target, proposal, rationale} ]
  }' "${files[@]}"
  exit 0
fi

echo "=== Session-Memory Digest — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
[ "$skipped" -gt 0 ] && echo "!! $skipped file(s) skipped as unreadable; the lists below omit them (see warnings)."
echo
printf '%-26s %-10s %8s %11s %9s\n' PROJECT TIER SESSIONS UNENRICHED PROPOSED
printf '%-26s %-10s %8s %11s %9s\n' "------" "----" "--------" "----------" "--------"
for f in "${files[@]}"; do
  jq -r '"\(.project // "?")\t\(if (.tier // "") == "" then "-" else .tier end)\t\(.sessions|length)\t\([.sessions[]|select(.enriched==false)]|length)\t\([.sessions[].optimization_candidates[]?|select(.status=="proposed")]|length)"' "$f"
done | while IFS=$'\t' read -r p t s u pr; do
  printf '%-26s %-10s %8s %11s %9s\n' "$p" "$t" "$s" "$u" "$pr"
done

echo
echo "--- Proposed CLAUDE.md optimization candidates ---"
found=0
for f in "${files[@]}"; do
  out="$(jq -r '.project as $p | .sessions[] | .date as $d
    | .optimization_candidates[]? | select(.status == "proposed")
    | "• [\($p) \($d)] target: \(.target)\n    proposal: \(.proposal)\n    why:      \(.rationale)"' "$f")"
  if [ -n "$out" ]; then printf '%s\n' "$out"; found=1; fi
done
[ "$found" -eq 0 ] && echo "(none — no pending CLAUDE.md changes proposed)"

echo
echo "--- Sessions awaiting enrichment ---"
found=0
for f in "${files[@]}"; do
  out="$(jq -r '.project as $p | .sessions[] | select(.enriched == false)
    | "• \($p) — \(.session_id) (\(.date))"' "$f")"
  if [ -n "$out" ]; then printf '%s\n' "$out"; found=1; fi
done
[ "$found" -eq 0 ] && echo "(none — all sessions enriched)"
