#!/usr/bin/env bash
# init_room.sh — create a model-chat room file for a debate topic.
# Usage: init_room.sh "<topic>" [num_personas]
# Prints the absolute path to the created room file on stdout.

set -uo pipefail

topic="${1:-}"
num="${2:-5}"

if [[ -z "$topic" ]]; then
  echo "init_room.sh: missing topic" >&2
  exit 2
fi

# Base 10 explicitly: "08" would otherwise be read as invalid octal
if ! [[ "$num" =~ ^[0-9]+$ ]] || (( 10#$num < 5 || 10#$num > 10 )); then
  echo "init_room.sh: num_personas must be an integer from 5 to 10 (got: $num)" >&2
  exit 2
fi
num=$((10#$num))
topic="$(printf '%s' "$topic" | tr '\r\n' '  ')"   # one line: no injected headings

slug=$(printf '%s' "$topic" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c 'a-z0-9' '-' \
  | sed -E 's/-+/-/g; s/^-//; s/-$//' \
  | cut -c1-60)

[[ -z "$slug" ]] && slug="topic-$(printf '%s' "$topic" | sha256sum | cut -c1-8)"

ts=$(date -u +"%Y%m%dT%H%M%SZ")
# Per-user and kept across reboots: the room file is the artifact
dir="${GOV_RUNS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-governance}/model-chat"
mkdir -p "$dir"
room="${dir}/${ts}-${slug}.md"
n=2
while [[ -e $room ]]; do room="${dir}/${ts}-${slug}-${n}.md"; n=$((n + 1)); done

# Roster: first 5 fixed, then bench in order.
roster_lines=(
  "1. Pragmatist — what works in practice, near-term ROI, evidence-based."
  "2. Skeptic — pokes holes, demands rigor, surfaces failure modes."
  "3. Theorist — first-principles, frameworks, cross-domain synthesis."
  "4. Synthesist — maps agreement/disagreement, drives convergence."
  "5. Adversary — defends the contrarian / unpopular position."
  "6. Historian — precedent, prior art, what previous attempts taught."
  "7. Engineer — concrete implementation paths, constraints, costs."
  "8. Economist — incentives, market dynamics, marginal cost/benefit."
  "9. Ethicist — second-order effects, fairness, duties to non-participants."
  "10. Futurist — long-horizon trajectories, regime shifts, optionality."
)

{
  echo "# Model Chat — Debate Room"
  echo
  echo "**Topic:** ${topic}"
  echo "**Started (UTC):** $(date -u +"%Y-%m-%d %H:%M:%S")"
  echo "**Personas (${num}):**"
  for i in $(seq 1 "$num"); do
    idx=$((i - 1))
    if (( idx < ${#roster_lines[@]} )); then
      echo "- ${roster_lines[$idx]}"
    fi
  done
  echo
  echo "**Format:** Round-robin. Personas reply in parallel each round; messages are appended to this file in roster order. Stop on convergence or after 5 rounds."
  echo
  echo "---"
  echo
} > "$room"

echo "$room"
