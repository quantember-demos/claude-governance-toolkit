#!/usr/bin/env bash
# verify-trust.sh — approve (or revoke) a project's verifier for the
# verify-effective-state.sh Stop hook.
#
#   verify-trust.sh <project-dir> [--also FILE ...] [--accept-unclassified]
#                                                     review the verifier, then approve it
#   verify-trust.sh <project-dir> --revoke            remove the approval
#   verify-trust.sh <project-dir> --fingerprint       print what approval would pin (read-only):
#                                                     line 1 fingerprint, line 2 verifier, then each pinned file
#
# Approval pins the verifier AND every file it sources. Pinning fails closed:
#   - `source` lines are resolved only when they are exact: an absolute path,
#     or a path relative to "$(dirname "$0")" / "$(dirname "${BASH_SOURCE[0]}")";
#   - anything else (a variable like "$ROOT/lib/x.sh", a relative path, a
#     project script run by bash/python/...) blocks approval until you pin the
#     file it loads with --also. A --also file whose path ends with the
#     reference's tail (e.g. lib/x.sh) covers that reference;
#   - code the scanner cannot classify (eval, exec, source after ; or &&, a
#     command run by path such as ./x or "$ROOT/bin/x") also blocks approval,
#     unless --accept-unclassified is given after reading it.
# Static scanning of shell is best-effort: keep verifiers simple.
# The hook re-hashes the pinned set every turn; any change stops the verifier
# until it is approved again.
#
# Approval is for a person: it reads the answer from the terminal (/dev/tty)
# and refuses inside Claude Code. This guards against Claude being talked into
# approving; it is not a boundary against other code running as you, which
# could edit the trust file directly. Revoking and --fingerprint need neither.

set -euo pipefail

project="${1:-}"
[[ -n $project ]] || { sed -n '2,24p' "$0" >&2; exit 2; }
shift
project="$(cd "$project" && pwd -P)"
mode=""
also=()
accept_unclassified=0
while (( $# )); do
  case "$1" in
    --revoke|--fingerprint) mode="$1"; shift ;;
    --accept-unclassified) accept_unclassified=1; shift ;;
    --also) [[ $# -ge 2 ]] || { echo "--also needs a file" >&2; exit 2; }
            [[ -f $2 ]] || { echo "--also: no such file: $2" >&2; exit 2; }
            also+=("$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"); shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# Same lookup as the hook: GOV_VERIFIER paths, ":"-separated, first one present
verifier=""
IFS=':' read -r -a candidates <<< "${GOV_VERIFIER:-scripts/verify.sh}"
for c in "${candidates[@]}"; do
  [[ -n $c && -f $project/$c ]] && { verifier="$project/$c"; break; }
done
[[ -n $verifier ]] || verifier="$project/${candidates[0]:-scripts/verify.sh}"
trust_file="${GOV_VERIFY_TRUST:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-governance/verify-trusted}"
list_file="$trust_file.d/$(printf '%s' "$verifier" | sha256sum | cut -c1-32).files"

seen=()
unresolved=()
unclassified=()
in_project() { case "$1" in "$project"/*) return 0 ;; esac; return 1; }
canon() { printf '%s/%s' "$(cd "$(dirname "$1")" && pwd -P)" "$(basename "$1")"; }
covered_by_also() {  # does a --also file end with this reference's tail?
  local tail a
  tail="$(sed -E 's#^(\$\{?[A-Za-z_][A-Za-z_0-9]*\}?|\$\([^)]*\)|~)/*##; s#^(\.\.?/)+##' <<<"$1")"
  [[ -n $tail ]] || return 1
  for a in "${also[@]+"${also[@]}"}"; do [[ $a == */"$tail" ]] && return 0; done
  return 1
}

# The argument of each `source` / `.` line: the rest of the line up to ; & |
# or a comment, with quotes removed ("$(dirname "$0")/x" -> $(dirname $0)/x)
source_refs() {
  grep -E '^[[:space:]]*(source|\.)[[:space:]]+' "$1" \
    | sed -E 's/^[[:space:]]*(source|\.)[[:space:]]+//; s/[[:space:]]+#.*$//; s/[;&|].*$//; s/["'\'']//g; s/[[:space:]]+$//'
}
# Project scripts run by an interpreter (not followed: pin them with --also)
run_refs() {
  grep -oE '(^|[;&|(`[:space:]])(bash|sh|zsh|python3?|perl|ruby|node)[[:space:]]+[^-;&|#[:space:]][^;&|#[:space:]]*' "$1" \
    | sed -E 's/^.*(bash|sh|zsh|python3?|perl|ruby|node)[[:space:]]+//; s/["'\'']//g' \
    | grep -E '/|\.(sh|py|pl|rb|js)$' || true
}

# Lines that load or run code in ways this scanner cannot follow. Comment lines
# are ignored; "-exec" (a find option) is not exec.
unclassified_refs() {
  # shellcheck disable=SC2016  # a literal regex, not expansions
  sed -E 's/^[[:space:]]*#.*$//' "$1" | grep -nE \
    '(^|[;&|(`]|\b(then|do|else))[[:space:]]*(eval|exec)([[:space:]]|$)|(^|[;&|(`]|\b(then|do|else))[[:space:]]*"?(\./|\.\./|\$\(dirname|\$\{BASH_SOURCE|\$\{?[A-Za-z_][A-Za-z_0-9]*\}?/)|[;&|][[:space:]]*(source|\.)[[:space:]]' \
    | sed -E 's/[[:space:]]+/ /g' | cut -c1-100 || true
}

# Follow the files a script loads, recursively. Exact references are pinned;
# everything else is UNRESOLVED unless a --also file covers it.
deps_of() {
  local file=$1 dir ref cand
  dir="$(dirname "$file")"
  while IFS= read -r ref; do
    [[ -n $ref ]] || continue
    cand=""
    # shellcheck disable=SC2016  # literal source text to match, not expansions
    case "$ref" in
      /*) cand="$ref" ;;
      '$(dirname $0)/'*|'$(dirname ${BASH_SOURCE[0]})/'*|'${BASH_SOURCE%/*}/'*|'${0%/*}/'*)
        cand="$dir/${ref#*/}" ;;
    esac
    if [[ -n $cand && -f $cand ]] && in_project "$(canon "$cand")"; then
      cand="$(canon "$cand")"
      if [[ " ${seen[*]} " != *" $cand "* ]]; then seen+=("$cand"); deps_of "$cand"; fi
    elif ! covered_by_also "$ref"; then
      unresolved+=("$(basename "$file"): source $ref")
    fi
  done < <(source_refs "$file")
  while IFS= read -r ref; do
    [[ -n $ref ]] || continue
    covered_by_also "$ref" || unresolved+=("$(basename "$file"): runs $ref")
  done < <(run_refs "$file")
  while IFS= read -r ref; do
    [[ -n $ref ]] || continue
    unclassified+=("$(basename "$file") line $ref")
  done < <(unclassified_refs "$file")
}

drop() {
  rm -f -- "$list_file"
  [[ -f $trust_file ]] || return 0
  local tmp
  tmp="$(mktemp "$trust_file.XXXXXX")"
  awk -v p="$verifier" 'substr($0, 67) != p' "$trust_file" > "$tmp"
  mv "$tmp" "$trust_file"
}

case "$mode" in
  --revoke) drop; echo "revoked: $verifier"; exit 0 ;;
esac

[[ -f $verifier ]] || { echo "no verifier at $verifier" >&2; exit 1; }
seen=("$verifier")
deps_of "$verifier"
# --also files are followed the same way: what they source is pinned too
for a in "${also[@]+"${also[@]}"}"; do
  if [[ " ${seen[*]} " != *" $a "* ]]; then seen+=("$a"); deps_of "$a"; fi
done
mapfile -t files < <(printf '%s\n' "${seen[@]}" "${also[@]+"${also[@]}"}" | sort -u)
fingerprint() { while IFS= read -r f; do printf '%s  %s\n' "$(sha256sum < "$f" | cut -d' ' -f1)" "$f"; done | sha256sum | cut -d' ' -f1; }
hash="$(printf '%s\n' "${files[@]}" | fingerprint)"

if [[ $mode == --fingerprint ]]; then
  echo "$hash"
  echo "$verifier"
  printf '%s\n' "${files[@]}"
  for u in "${unresolved[@]+"${unresolved[@]}"}"; do echo "UNRESOLVED: $u" >&2; done
  for u in "${unclassified[@]+"${unclassified[@]}"}"; do echo "UNCLASSIFIED: $u" >&2; done
  exit 0
fi

if (( ${#unclassified[@]} )) && (( ! accept_unclassified )); then
  echo "verify-trust.sh: approval refused: code the scanner cannot follow, so approval could not pin what it loads:" >&2
  printf '  %s\n' "${unclassified[@]}" >&2
  echo "Simplify the verifier, or read these lines and pass --accept-unclassified." >&2
  exit 4
fi

if (( ${#unresolved[@]} )); then
  echo "verify-trust.sh: approval refused: the verifier loads code that is not pinned:" >&2
  printf '  %s\n' "${unresolved[@]}" >&2
  echo "Pin each file it loads with --also FILE, then run this again." >&2
  exit 4
fi

# Inside Claude Code? (its subprocesses carry CLAUDECODE, and descend from it)
inside_claude() {
  [[ -n ${CLAUDECODE:-} ]] && return 0
  local p=$$ exe
  while [[ $p -gt 1 && -r /proc/$p/status ]]; do
    exe="$(tr '\0' '\n' < "/proc/$p/cmdline" 2>/dev/null | head -1)"
    [[ $(basename -- "${exe:-x}") == claude ]] && return 0
    p="$(awk '/^PPid:/ {print $2}' "/proc/$p/status")"
  done
  return 1
}
if inside_claude; then
  echo "verify-trust.sh: refusing inside Claude Code; run it yourself, in your own terminal" >&2
  exit 3
fi
if ! { : < /dev/tty; } 2>/dev/null; then
  echo "verify-trust.sh: approval needs an interactive terminal; run it yourself, not from a script" >&2
  exit 3
fi

{
  echo "Verifier: $verifier"
  echo "Runs at the end of every Claude Code turn in this project${GOV_VERIFY_SUDO:+, AS ROOT (GOV_VERIFY_SUDO is set)}."
  echo
  if (( ${#unclassified[@]} )); then
    echo "ACCEPTED WITHOUT PINNING (--accept-unclassified): what these lines load is not covered:"
    printf '  %s\n' "${unclassified[@]}"
    echo
  fi
  echo "Approval pins these ${#files[@]} file(s); a change to any of them needs approval again:"
  for f in "${files[@]}"; do echo "  $f ($(wc -l < "$f") lines)"; done
  echo
} > /dev/tty
# Every pinned file in full. Control characters are shown, never interpreted:
# a file could otherwise use terminal escapes to hide what it really contains.
# less -U shows them as ^X; LESSOPEN/LESSCLOSE are cleared so no preprocessor runs.
if command -v less >/dev/null 2>&1; then
  LESSOPEN="" LESSCLOSE="" less -U -- "${files[@]}" < /dev/tty > /dev/tty
else
  for f in "${files[@]}"; do { echo "----- $f -----"; cat -v -n -- "$f"; } > /dev/tty; done
fi
printf 'Approve these %s file(s), all reviewed? Type "approve": ' "${#files[@]}" > /dev/tty
read -r answer < /dev/tty
[[ $answer == approve ]] || { echo "not approved"; exit 1; }
# A file may have changed while it was on screen
[[ "$(printf '%s\n' "${files[@]}" | fingerprint)" == "$hash" ]] || { echo "a file changed during review; not approved" >&2; exit 1; }

mkdir -p "$(dirname "$list_file")"
drop
printf '%s\n' "${files[@]}" > "$list_file"
printf '%s  %s\n' "$hash" "$verifier" >> "$trust_file"
echo "approved: $verifier and $(( ${#files[@]} - 1 )) other file(s) ($hash)"
