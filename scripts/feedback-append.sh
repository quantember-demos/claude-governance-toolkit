#!/usr/bin/env bash
# feedback-append.sh — prepend an entry to a project's feedback.md.
#
# Usage:
#   feedback-append.sh <title> <symptom> <cause> <fix> <lesson>
#   feedback-append.sh -i                          # interactive
#   feedback-append.sh -p <project_path> <args...> # explicit project root
#   feedback-append.sh -i -p <project_path>        # interactive + explicit
#   feedback-append.sh -t <tag> <args...>          # defect tag (see below)
#
# Tag: one of env, crypto, script, data, assumption, scope, cost. Given with -t,
# or as a leading "[tag]" in the title; written as a "**Tag:**" line, which is
# what /retro clusters on.
#
# Resolution order for which feedback.md to write to:
#   1. -p / --project explicit flag (preferred for scripts / cross-cwd calls)
#   2. Walk up from $PWD looking for an existing feedback.md or CLAUDE.md
#      (treat the dir containing either as the project root)
#   3. Fall back to $PWD/feedback.md with a stderr warning
#
# Idempotent (always prepends; doesn't deduplicate). set -e safe.

set -euo pipefail

# ----- arg parse -----
project=""
interactive=0
tag=""
positional=()
TAGS=" env crypto script data assumption scope cost "

while (( $# > 0 )); do
    case "$1" in
        -p|--project|-t|--tag)
            [[ $# -ge 2 ]] || { echo "ERROR: $1 needs a value" >&2; exit 2; }
            case "$1" in -p|--project) project="$2" ;; *) tag="$2" ;; esac
            shift 2 ;;
        -i|--interactive) interactive=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --) shift; positional+=("$@"); break ;;
        *) positional+=("$1"); shift ;;
    esac
done

# ----- resolve project root -----
resolve_project_root() {
    if [[ -n "$project" ]]; then
        if [[ ! -d "$project" ]]; then
            echo "ERROR: --project '$project' is not a directory" >&2
            exit 2
        fi
        printf '%s' "$(cd "$project" && pwd)"
        return 0
    fi
    # walk up from $PWD looking for feedback.md or CLAUDE.md
    local d="$PWD"
    while [[ "$d" != "/" ]]; do
        if [[ -f "$d/feedback.md" || -f "$d/CLAUDE.md" ]]; then
            printf '%s' "$d"
            return 0
        fi
        d=$(dirname "$d")
    done
    echo "WARNING: no feedback.md or CLAUDE.md found walking up from $PWD; defaulting to $PWD" >&2
    printf '%s' "$PWD"
}

target_dir=$(resolve_project_root)
target="$target_dir/feedback.md"
# A symlinked feedback.md is written through, but only to a file inside the
# project: a cloned repository could otherwise point it at ~/.bashrc
if [[ -L $target ]]; then
    resolved="$(readlink -f -- "$target")"
    root_real="$(cd "$target_dir" && pwd -P)"
    case "$resolved" in
        "$root_real"/*) target="$resolved" ;;
        *) echo "ERROR: $target is a symlink pointing outside the project ($resolved); refusing to write" >&2
           exit 2 ;;
    esac
fi
date_str=$(date -u +%F)   # UTC, like the .last-retro stamp /retro compares against

# ----- collect entry fields -----
if (( interactive == 1 )); then
    read -r -p "Title: " title
    read -r -p "Symptom: " symptom
    read -r -p "Cause: " cause
    read -r -p "Fix: " fix
    read -r -p "Lesson: " lesson
elif (( ${#positional[@]} >= 5 )); then
    title="${positional[0]}"
    symptom="${positional[1]}"
    cause="${positional[2]}"
    fix="${positional[3]}"
    lesson="${positional[4]}"
else
    echo "Usage: $0 [-p <project_path>] <title> <symptom> <cause> <fix> <lesson>" >&2
    echo "       $0 [-p <project_path>] -i" >&2
    echo "       (use single quotes around args to avoid shell expansion of \$ # etc.)" >&2
    exit 1
fi

# Each field is one line: a newline inside an argument could otherwise start
# a fake "## date — title" entry
flat() { printf '%s' "$1" | tr '\r\n' '  '; }
title="$(flat "$title")"; symptom="$(flat "$symptom")"; cause="$(flat "$cause")"
fix="$(flat "$fix")"; lesson="$(flat "$lesson")"
[[ -n ${title// /} ]] || { echo "ERROR: the title is empty" >&2; exit 2; }

# ----- tag: -t, else a leading "[tag]" in the title ------------------------
if [[ -z $tag && $title =~ ^\[([A-Za-z]+)\] ]]; then
    tag="${BASH_REMATCH[1]}"
fi
tag="${tag,,}"
if [[ -n $tag && $TAGS != *" $tag "* ]]; then
    echo "ERROR: unknown tag '$tag' (use one of:$TAGS)" >&2
    exit 2
fi

# ----- compose entry -----
entry=$(cat <<EOF
## ${date_str} — ${title}
**Symptom:** ${symptom}
**Cause:** ${cause}
**Fix:** ${fix}
**Lesson:** ${lesson}
${tag:+**Tag:** ${tag}}
EOF
)
entry="${entry}
"

# ----- create-or-prepend -----
if [[ ! -f "$target" ]]; then
    proj=$(basename "$target_dir")
    {
        echo "# Feedback Log — ${proj}"
        echo
        echo "Newest entries on top. Format: Symptom / Cause / Fix / Lesson."
        echo
        echo "$entry"
    } > "$target"
    echo "Created $target"
    exit 0
fi

tmp=$(mktemp "${target}.XXXXXX")
chmod --reference="$target" "$tmp" 2>/dev/null || true   # keep the file's permissions
# The entry goes through the environment: awk -v would interpret backslash
# escapes in it (a written "\n" or a Windows path would be rewritten)
ENTRY="$entry" awk '
    BEGIN { inserted=0; entry=ENVIRON["ENTRY"] }
    /^## / && !inserted { print entry; inserted=1 }
    { print }
    END { if (!inserted) { print ""; print entry } }
' "$target" > "$tmp"
mv "$tmp" "$target"
echo "Appended to $target"
