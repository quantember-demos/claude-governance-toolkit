#!/usr/bin/env bash
# init_consensus.sh — create a stochastic-consensus run file for a problem.
# Usage: init_consensus.sh "<problem>" [N] [mode]
#   N: integer >= 3 (default 7)
#   mode: rank | decide | enumerate | analyze (default analyze)
# Prints the absolute path to the created run file on stdout.

set -uo pipefail

problem="${1:-}"
n="${2:-7}"
mode="${3:-analyze}"

if [[ -z "$problem" ]]; then
  echo "init_consensus.sh: missing problem statement" >&2
  exit 2
fi

# Base 10 explicitly: "08" would otherwise be read as invalid octal
if ! [[ "$n" =~ ^[0-9]+$ ]] || (( 10#$n < 3 || 10#$n > 50 )); then
  echo "init_consensus.sh: N must be an integer from 3 to 50 (got: $n)" >&2
  exit 2
fi
n=$((10#$n))
problem="$(printf '%s' "$problem" | tr '\r\n' '  ')"   # one line: no injected headings

case "$mode" in
  rank|decide|enumerate|analyze) ;;
  *) echo "init_consensus.sh: mode must be rank|decide|enumerate|analyze (got: $mode)" >&2; exit 2 ;;
esac

slug=$(printf '%s' "$problem" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c 'a-z0-9' '-' \
  | sed -E 's/-+/-/g; s/^-//; s/-$//' \
  | cut -c1-60)

[[ -z "$slug" ]] && slug="problem-$(printf '%s' "$problem" | sha256sum | cut -c1-8)"

ts=$(date -u +"%Y%m%dT%H%M%SZ")
# Per-user and kept across reboots: the run file is the artifact
dir="${GOV_RUNS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-governance}/stochastic-consensus"
mkdir -p "$dir"
run="${dir}/${ts}-${slug}.md"
k=2
while [[ -e $run ]]; do run="${dir}/${ts}-${slug}-${k}.md"; k=$((k + 1)); done

# Framing variations — subtle decorrelating perturbations, NOT personas.
# Each agent gets one. They do not see each other's framings or outputs.
framings=(
  "Approach this fresh, with no priors. Reason step by step."
  "Reason from first principles; ignore conventional wisdom unless you can re-derive it."
  "Be conservative — only assert claims you are highly confident in."
  "Be exploratory — surface unintuitive angles, lottery-ticket ideas, edge cases."
  "Default to the standard textbook analysis for this class of problem."
  "Steelman the most contrarian credible position before answering."
  "Walk through the failure modes first, then conclude."
  "Answer as if you had to defend it under cross-examination."
  "Optimize for the long horizon; ignore near-term considerations."
  "Optimize for near-term, concrete, shippable outcomes."
  "Identify the load-bearing assumption first, then reason from there."
  "Start by stating what evidence would change your answer."
)

{
  echo "# Stochastic Multi-Agent Consensus — Run"
  echo
  echo "**Problem:** ${problem}"
  echo "**Started (UTC):** $(date -u +"%Y-%m-%d %H:%M:%S")"
  echo "**N (agents):** ${n}"
  echo "**Mode:** ${mode}"
  echo
  echo "**Framings assigned to agents (1..N):**"
  for i in $(seq 1 "$n"); do
    idx=$(( (i - 1) % ${#framings[@]} ))
    echo "${i}. ${framings[$idx]}"
  done
  echo
  echo "**Procedure:** N agents run in parallel. Each receives the same problem and one framing line. They do not see each other. Their outputs are appended below verbatim, then aggregated into a Consensus section."
  echo
  echo "---"
  echo
} > "$run"

echo "$run"
