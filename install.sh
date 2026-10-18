#!/usr/bin/env bash
# Install the toolkit into ~/.claude (or $CLAUDE_HOME).
#
#   ./install.sh              copy hooks, scripts, skills and the workflow
#   ./install.sh --force      also replace files that differ from this version
#   ./install.sh --uninstall  remove what install.sh copied, unless you changed it
#
# Never edits settings.json: it prints the hook wiring to add instead
# (examples/settings.json). Files that already exist and differ are left
# alone unless --force is given, so local edits are not lost silently. The
# manifest records each copied file's SHA-256; uninstall removes a file only
# if it is still byte-identical to what was installed.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CLAUDE_HOME="${CLAUDE_HOME:-${HOME:?HOME is not set; set HOME or CLAUDE_HOME}/.claude}"
KIT="$CLAUDE_HOME/governance-toolkit"
MANIFEST="$KIT/.installed"
SKILLS=(model-chat stochastic-multi-agent-consensus retro scaffold-project)

# source (relative to the repo) -> destination
plan() {
  local f
  for f in "$REPO"/hooks/*.sh "$REPO"/scripts/*.sh; do
    printf '%s\t%s\n' "${f#"$REPO"/}" "$KIT/${f#"$REPO"/}"
  done
  for s in "${SKILLS[@]}"; do
    while IFS= read -r f; do
      printf '%s\t%s\n' "${f#"$REPO"/}" "$CLAUDE_HOME/skills/${f#"$REPO"/skills/}"
    done < <(find "$REPO/skills/$s" -type f | sort)
  done
  printf '%s\t%s\n' workflows/dna-zipper.js "$CLAUDE_HOME/workflows/dna-zipper.js"
  printf '%s\t%s\n' schema/session-memory.schema.json "$KIT/schema/session-memory.schema.json"
}

sha() { sha256sum < "$1" | cut -d' ' -f1; }

# Record "hash  path" for a file we copied (replacing any older line for it)
record() {
  local tmp
  tmp="$(mktemp "$MANIFEST.XXXXXX")"
  awk -v p="$1" 'substr($0, 67) != p' "$MANIFEST" > "$tmp"
  printf '%s  %s\n' "$(sha "$1")" "$1" >> "$tmp"
  mv "$tmp" "$MANIFEST"
}

# JSON string for a hook command: quoted for the shell if the path needs it
command_json() {
  local path=$1 cmd
  if [[ $path =~ [^A-Za-z0-9_./~-] ]]; then
    cmd="'${path//\'/\'\\\'\'}'"
  else
    cmd=$path
  fi
  jq -n --arg c "$cmd" '$c'
}

install() {
  local force=$1 src dest copied=0 skipped=0 same=0
  mkdir -p "$KIT"
  touch "$MANIFEST"
  while IFS=$'\t' read -r src dest; do
    if [[ -e $dest ]] && cmp -s "$REPO/$src" "$dest"; then
      # Already identical: claim it only if an earlier install put it there
      same=$((same + 1))
      continue
    fi
    if [[ -e $dest ]] && [[ $force != 1 ]]; then
      echo "skipped $dest: it differs from this version (use --force to replace)" >&2
      skipped=$((skipped + 1))
      continue
    fi
    mkdir -p "$(dirname "$dest")"
    cp -p -- "$REPO/$src" "$dest"
    record "$dest"
    copied=$((copied + 1))
  done < <(plan)
  echo "Installed $copied files into $CLAUDE_HOME ($same already up to date, $skipped skipped)."
  echo
  echo "Hooks are not active until you add them to $CLAUDE_HOME/settings.json."
  echo "Merge this into its \"hooks\" (and set GOV_PROJECTS_ROOT in \"env\"):"
  echo
  local h="$KIT/hooks"
  jq -n --argjson surface "$(command_json "$h/session-memory-surface.sh")" \
        --argjson scaffold "$(command_json "$h/session-memory-scaffold.sh")" \
        --argjson verify "$(command_json "$h/verify-effective-state.sh")" '{
    env: { GOV_PROJECTS_ROOT: "\(env.HOME)/Projects" },
    hooks: {
      SessionStart: [ { hooks: [ { type: "command", command: $surface } ] } ],
      Stop: [ { hooks: [ { type: "command", command: $scaffold },
                         { type: "command", command: $verify } ] } ]
    } }'
}

uninstall() {
  [[ -f $MANIFEST ]] || { echo "nothing installed (no $MANIFEST)"; return 0; }
  local line hash dest home
  home="$(cd "$CLAUDE_HOME" && pwd -P)"
  while IFS= read -r line; do
    hash="${line:0:64}"; dest="${line:66}"
    [[ -n $dest && -f $dest ]] || continue
    case "$(cd "$(dirname "$dest")" && pwd -P)/" in
      "$home"/*) ;;
      *) echo "kept $dest: outside $CLAUDE_HOME" >&2; continue ;;
    esac
    if [[ "$(sha "$dest")" != "$hash" ]]; then
      echo "kept $dest: changed since it was installed" >&2
      continue
    fi
    rm -f -- "$dest" && echo "removed $dest"
  done < "$MANIFEST"
  rm -f -- "$MANIFEST"
  # Remove directories this install left empty, and only those
  local s
  for s in "${SKILLS[@]}"; do
    [[ -d $CLAUDE_HOME/skills/$s ]] && find "$CLAUDE_HOME/skills/$s" -depth -type d -empty -delete
  done
  [[ -d $KIT ]] && find "$KIT" -depth -type d -empty -delete
  echo "Remove the toolkit's hook entries from $CLAUDE_HOME/settings.json yourself."
}

case "${1:-}" in
  "") install 0 ;;
  --force) install 1 ;;
  --uninstall) uninstall ;;
  -h|--help) sed -n '2,11p' "$0" ;;
  *) echo "usage: $0 [--force | --uninstall]" >&2; exit 2 ;;
esac
