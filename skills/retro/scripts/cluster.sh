#!/usr/bin/env bash
# cluster.sh — extract & cluster entries from a feedback.md file.
# Usage: cluster.sh <path/to/feedback.md>
# Output (tab-separated, stdout):
#   count<TAB>tag<TAB>most_recent_date<TAB>up_to_3_titles_pipe_separated
# Preceded by "since: <cutoff>" (from a .last-retro file beside feedback.md, or
# "all time") and "total: <n>".
# Exit codes: 0 ok, 2 bad args, 4 file missing, 5 nothing to cluster.

set -uo pipefail

file="${1:-}"
[[ -z "$file" ]] && { echo "cluster.sh: missing path" >&2; exit 2; }
[[ ! -f "$file" ]] && { echo "cluster.sh: not found: $file" >&2; exit 4; }

dir="$(dirname "$file")"
since="all time"
cutoff=""
if [[ -f "$dir/.last-retro" ]]; then
  last="$(tr -d '[:space:]' < "$dir/.last-retro")"
  if [[ "$last" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    since="$last"
    cutoff="$last"
  fi
fi

# Entries begin with "## YYYY-MM-DD — <title>". The tag comes from a
# "**Tag:** <tag>" line, else from a leading "[tag]" in the title. Lines inside
# fenced code blocks are ignored. A "## " heading that is not a valid dated
# entry closes the current entry, so its lines never land on the previous one.
# Prints: date<TAB>tag<TAB>title
mapfile -t entries < <(awk '
  function flush() { if (date != "") print date "\t" tag "\t" title; date = "" }
  /^(```|~~~)/ { fence = !fence; next }
  fence { next }
  /^## / {
    flush()
    d = substr($0, 4, 10)
    if (d !~ /^[0-9][0-9][0-9][0-9]-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$/ || substr($0, 14, 1) !~ /^( |)$/) next
    date = d
    title = substr($0, 15)
    sub(/^[^A-Za-z0-9[]+/, "", title)        # the dash after the date, any variant
    tag = "untagged"
    if (match(title, /^\[[A-Za-z]+\][[:space:]]*/)) {
      tag = tolower(substr(title, 2, index(title, "]") - 2))
      title = substr(title, RLENGTH + 1)
    }
    next
  }
  date != "" && /^\*\*Tag:\*\*/ {
    t = $0
    sub(/^\*\*Tag:\*\*[[:space:]]*/, "", t)
    split(t, w, /[ ,;]+/)                     # first word only: "env, script" -> env
    if (w[1] != "") tag = tolower(w[1])
  }
  END { flush() }
' "$file")

if (( ${#entries[@]} == 0 )); then
  echo "cluster.sh: no parseable entries in $file" >&2
  exit 5
fi

# Filter by cutoff. ISO dates compare correctly as strings; entries dated on
# the cutoff day are kept (they may postdate that day's retro).
filtered=()
for e in "${entries[@]}"; do
  d="${e%%	*}"
  [[ -z $cutoff || ! $d < $cutoff ]] && filtered+=("$e")
done

if (( ${#filtered[@]} == 0 )); then
  echo "since: $since"
  echo "cluster.sh: no entries since cutoff" >&2
  exit 5
fi

echo "since: $since"
echo "total: ${#filtered[@]}"
echo

# Aggregate by tag; most common first, then most recent.
printf '%s\n' "${filtered[@]}" | awk -F'\t' '
{
  tag = $2
  count[tag]++
  if ($1 > recent[tag]) recent[tag] = $1
  if (titles[tag] == "") titles[tag] = $3
  else if (split(titles[tag], a, "|") < 3) titles[tag] = titles[tag] "|" $3
}
END {
  for (t in count) printf "%d\t%s\t%s\t%s\n", count[t], t, recent[t], titles[t]
}
' | sort -t$'\t' -k1,1nr -k3,3r
