#!/usr/bin/env bash
# verify-effective-state.sh — Stop hook.
#
# Runs the current project's effective-state verifier when a turn ends and tells
# Claude when the running system no longer matches its declared intent. Silent
# when the verifier passes; never silent when it fails or is itself broken.
#
# Why this exists (docs/silent-success.md): "the command succeeded" is not evidence
# that "the system changed". This hook re-checks the system through independent
# channels, so a false green cannot survive the end of a turn.
#
# Verifier: an executable scripts/verify.sh in the project (or GOV_VERIFIER:
# paths relative to the project, ":"-separated, first one present wins) that
# supports --json and uses the exit
# contract 0 = all pass, 1 = failures, 2 = incomplete. Output format:
# docs/silent-success.md.
#
# Trust: a verifier is code from the project, so it runs only after you approve
# that exact file, in a terminal (never through Claude):
# scripts/verify-trust.sh <project> records its SHA-256 in
# ${GOV_VERIFY_TRUST:-~/.config/claude-governance/verify-trusted}. A changed
# file needs approving again. An untrusted verifier is mentioned once per session
# and never run.
#
# Reporting: on a Stop hook, additionalContext continues the turn so Claude can
# act on it. When stop_hook_active is set, Claude is already continuing because
# of a Stop hook; reporting again would loop, so the hook stays quiet.
#
# GOV_VERIFY_SUDO=1 runs a trusted verifier with non-interactive sudo when that is
# available; GOV_VERIFY_TIMEOUT (default 60) bounds its run time in seconds.

set -u

input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
active="$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)"
[ -n "$cwd" ] || exit 0
[ "$active" = "true" ] && exit 0   # already continuing for a Stop hook: report once

# Only for projects under GOV_PROJECTS_ROOT (default ~/Projects; "/" = everywhere).
# The root is resolved, because Claude Code reports a resolved working directory.
root="${GOV_PROJECTS_ROOT:-$HOME/Projects}"
root="$(cd "$root" 2>/dev/null && pwd -P || printf '%s' "$root")"
case "$cwd/" in
  "${root%/}/"*) : ;;
  *) exit 0 ;;
esac

verifier=""
IFS=':' read -r -a candidates <<< "${GOV_VERIFIER:-scripts/verify.sh}"
for c in "${candidates[@]}"; do
  [ -n "$c" ] && [ -f "$cwd/$c" ] && { verifier="$cwd/$c"; break; }
done
[ -n "$verifier" ] || exit 0

report() {
  jq -n --arg ctx "Effective-state verification (Stop hook, $verifier)

$1" '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $ctx}}'
  exit 0
}

# Say something at most once per session (for conditions a retry cannot fix)
report_once() {
  local key state
  state="${XDG_STATE_HOME:-$HOME/.local/state}/claude-governance/verify-notified"
  key="$(printf '%s|%s|%s' "$sid" "$verifier" "$1" | sha256sum | cut -c1-32)"
  [ -e "$state/$key" ] && exit 0
  mkdir -p "$state" 2>/dev/null && : > "$state/$key"
  report "$2"
}

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." 2>/dev/null && pwd)"
trust_file="${GOV_VERIFY_TRUST:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-governance/verify-trusted}"
# Approval pins the verifier and the files it sources (listed at approval);
# the fingerprint is sha256 over "sha256  path" lines for that set
list_file="$trust_file.d/$(printf '%s' "$verifier" | sha256sum | cut -c1-32).files"
hash="$(
  if [ -f "$list_file" ]; then cat "$list_file"; else printf '%s\n' "$verifier"; fi \
    | while IFS= read -r f; do
        printf '%s  %s\n' "$( (sha256sum < "$f" || echo missing) 2>/dev/null | cut -d' ' -f1)" "$f"
      done | sha256sum | cut -d' ' -f1
)"
if ! grep -qxF -- "$hash  $verifier" "$trust_file" 2>/dev/null; then
  report_once untrusted "A verifier exists at $verifier but was not run: it is not approved
(new, or changed since it was approved). Only the user can approve it, in their own
terminal, after reading it. Tell the user; do not run the approval yourself, and do not
run the verifier by other means. For the user:
  $here/scripts/verify-trust.sh $(printf '%q' "$cwd")"
fi
[ -x "$verifier" ] || report "The verifier $verifier is trusted but not executable (chmod +x it)."

if ! command -v timeout >/dev/null 2>&1; then
  report_once no-timeout "The verifier was not run: the 'timeout' command (GNU coreutils) is not
installed, and a verifier must not be able to hang the session."
fi

runner=()
if [ "${GOV_VERIFY_SUDO:-0}" = "1" ] && [ "$(id -u)" -ne 0 ]; then
  sudo -n true 2>/dev/null && runner=(sudo -n)
fi
limit="${GOV_VERIFY_TIMEOUT:-60}"
case "$limit" in ''|*[!0-9]*) limit=60 ;; esac

out="$(${runner[@]+"${runner[@]}"} timeout "$limit" "$verifier" --json 2>/dev/null)"
rc=$?

[ "$rc" -eq 0 ] && exit 0   # contract: 0 = every check passed

problem() {
  report "The verifier itself is not working, so the system state is UNVERIFIED:
$1
Output (first 300 characters): $(printf '%.300s' "${out:-<none>}")
Fix the verifier before trusting any 'done' in this project."
}

[ "$rc" -eq 124 ] && problem "it did not finish within ${limit} s (GOV_VERIFY_TIMEOUT)."
case "$rc" in
  1|2) ;;
  *) problem "it exited with status $rc; the contract allows 0, 1 or 2." ;;
esac
printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1 \
  || problem "it exited with status $rc but its output is not a JSON report."

summary="$(printf '%s' "$out" | jq -r '
  def checks(s): [(.checks // [])[] | select(.status == s)];
  if (.fail // 0) > 0 then
    "\(.fail) effective-state check(s) FAILED — the running system does not match its declared intent:\n" +
    ([ checks("FAIL")[]
       | "  - [\(.area // "?")] \(.check // "?"): expected \(.expected // "?"), observed \(.observed // "?")  (via \(.channel // "?"))" ]
     | .[0:12] | join("\n"))
  elif (.unverified // 0) > 0 then
    "\(.unverified) effective-state check(s) could not be verified (incomplete coverage):\n" +
    ([ checks("UNVERIFIED")[] | "  - [\(.area // "?")] \(.check // "?"): \(.observed // "?")" ]
     | .[0:8] | join("\n"))
  else empty end
' 2>/dev/null)"

[ -n "$summary" ] || problem "it exited with status $rc but reported no failed or unverified check."

report "$summary

This is observed system state, not a code-review opinion. Do not report this work as
complete until these are resolved or explicitly accepted. Re-check with:
  $verifier --json"
