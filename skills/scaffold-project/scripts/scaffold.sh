#!/usr/bin/env bash
# scaffold.sh — write canonical governance files for a project.
#
# Usage: scaffold.sh --path <dir> [--classification Public|Internal|Confidential|Restricted]
#                    [--tier NAME] [--extras metrics,decisions,backlog]
#
# Always writes CLAUDE.md and feedback.md. Extra files come from --extras, or,
# when only --tier is given, from the tier's line in the tiers config
# (${GOV_TIERS_CONF:-~/.config/claude-governance/tiers.conf}; see
# examples/tiers.conf). With neither, the only extra is DECISIONS.md.
# THREAT_MODEL.md is added for Confidential and Restricted projects.
#
# Exit codes: 0 success, 2 bad args, 3 refusal (existing files), 4 path/permission problem.

set -uo pipefail

target=""
tier=""
extras=""
extras_given=0
classification="Internal"
tiers_conf="${GOV_TIERS_CONF:-$HOME/.config/claude-governance/tiers.conf}"

while (( $# )); do
  case "$1" in
    --path|--tier|--classification|--extras)
      [[ $# -ge 2 ]] || { echo "scaffold.sh: $1 needs a value" >&2; exit 2; }
      case "$1" in
        --path) target="$2" ;;
        --tier) tier="$2" ;;
        --classification) classification="$2" ;;
        --extras) extras="$2"; extras_given=1 ;;
      esac
      shift 2 ;;
    *) echo "scaffold.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$target" ]] && { echo "scaffold.sh: --path is required" >&2; exit 2; }
[[ ! -d "$target" ]] && { echo "scaffold.sh: not a directory: $target" >&2; exit 4; }
[[ ! -w "$target" ]] && { echo "scaffold.sh: not writable: $target" >&2; exit 4; }

case "$classification" in
  Public|Internal|Confidential|Restricted) ;;
  *) echo "scaffold.sh: --classification must be Public|Internal|Confidential|Restricted (got: $classification)" >&2; exit 2 ;;
esac

# Extras for a tier come from the config: one "TIER extras" line per tier
if (( ! extras_given )); then
  if [[ -n $tier ]]; then
    [[ -f $tiers_conf ]] || { echo "scaffold.sh: --tier given but no tiers config at $tiers_conf (see examples/tiers.conf)" >&2; exit 2; }
    line="$(tr -d '\r' < "$tiers_conf" | awk -v t="$tier" '$1 == t && $1 !~ /^#/ {print; exit}')"
    [[ -n $line ]] || { echo "scaffold.sh: tier '$tier' is not defined in $tiers_conf" >&2; exit 2; }
    extras="$(awk '{$1 = ""; print}' <<<"$line")"   # the rest of the line
    extras="${extras//[[:space:]]/}"                    # "metrics, backlog" -> "metrics,backlog"
    [[ $extras == "-" ]] && extras=""
  else
    extras="decisions"
  fi
fi
IFS=',' read -r -a extra_list <<<"$extras"
for e in "${extra_list[@]}"; do
  case "$e" in
    metrics|decisions|backlog|"") ;;
    *) echo "scaffold.sh: unknown extra '$e' (known: metrics, decisions, backlog)" >&2; exit 2 ;;
  esac
done
want() { [[ ",$extras," == *",$1,"* ]]; }

project="$(basename "$target")"
today="$(date -u +"%Y-%m-%d")"

# Every file this run will write, decided before anything is written
planned=(CLAUDE.md feedback.md)
want metrics && planned+=(METRICS.md)
want decisions && planned+=(DECISIONS.md)
want backlog && planned+=(BACKLOG.md)
[[ $classification == Confidential || $classification == Restricted ]] && planned+=(THREAT_MODEL.md)

# Refuse if any of them exists, including as a symlink (which would be
# followed): merging needs a parser, and overwriting loses hand edits
existing=()
for f in "${planned[@]}"; do
  [[ -e "$target/$f" || -L "$target/$f" ]] && existing+=("$f")
done
if (( ${#existing[@]} > 0 )); then
  echo "scaffold.sh: refusing — existing canonical files in $target:" >&2
  for f in "${existing[@]}"; do echo "  - $f" >&2; done
  echo "Resolve manually before re-running. This skill does not merge or overwrite." >&2
  exit 3
fi

created=()
# Write stdin to a file in the target, failing loudly (never report a file
# that was not written)
write() {
  # noclobber: never write through anything that appeared since the check
  ( set -C; cat > "$target/$1" ) || { echo "scaffold.sh: could not write $target/$1" >&2; exit 4; }
  created+=("$1")
}
tier_block=""
if [[ -n $tier ]]; then
  tier_block="## Tier

**${tier}**

"
fi

# --- CLAUDE.md (always) ---
write CLAUDE.md <<EOF
# ${project}

Project-specific instructions for Claude Code. Global rules in \`~/.claude/CLAUDE.md\` still apply; this file adds to them.

${tier_block}## Classification

**${classification}** — applies to everything in this directory unless a sub-path overrides.

| Level | Handling |
|-------|----------|
| Public | OK to publish; no personal data; no secrets. |
| Internal | Default. Do not publish externally without review. |
| Confidential | Customer data, financial data, or unreleased work. Encrypt at rest; restrict access. |
| Restricted | Regulated data (personal, health, financial account). Confirm the applicable rules before designing storage or transport. |

## Asset Inventory

_What this project stores or processes. Fill this in before real work starts; it is left blank on purpose._

- Code: yes / no
- Secrets (and where): _e.g. \`.env\`, \`~/.config/<service>/credentials\`, a vault path_
- Personal data: _none / describe_
- Financial data: _none / describe_
- Models or large artifacts: _none / describe_
- External services touched: _APIs, vendors, regions_

## Encryption

- At rest: _full-disk / repository-level (e.g. git-crypt, age) / none_
- Files outside the repo holding secrets: _list_
- Secret scanning before commit: _tool / none_

## Backups

- Where copies live: _e.g. two offline drives, a second machine, a hosted remote_
- Last verified restore: _YYYY-MM-DD_

## Goals

- What this project is for: _one sentence_
- How you will know it is working: _the one measure that matters_

## Project-Specific Rules

_Anything that overrides or extends the global rules for this project only. Keep it short._

EOF

# --- feedback.md (always) ---
write feedback.md <<EOF
# Feedback Log — ${project}

_Newest entries on top. Each entry: Symptom / Cause / Fix / Lesson, tagged with one of: env, crypto, script, data, assumption, scope, cost. Add entries with \`~/.claude/governance-toolkit/scripts/feedback-append.sh -t <tag> ...\`; review patterns with \`/retro\`. Read this file at the start of every session in this project._

## ${today} — scaffold initialized
**Symptom:** N/A — bootstrap entry.
**Cause:** N/A.
**Fix:** Project scaffolded via \`/scaffold-project\` (classification=${classification}${tier:+, tier=${tier}}).
**Lesson:** Fill in the CLAUDE.md asset inventory and backups before real work begins.
**Tag:** scope

EOF

# --- METRICS.md ---
if want metrics; then
write METRICS.md <<EOF
# Metrics — ${project}

Measured baseline: record it before changing a process, so improvement can be shown rather than asserted. Update at least monthly and after every incident.

## Cycle / Cost

| Metric | Baseline | Current | Last updated |
|--------|----------|---------|--------------|
| Average time per task / cycle | _TBD_ | _TBD_ | ${today} |
| Tokens or money per run | _TBD_ | _TBD_ | ${today} |
| Manual steps per run | _TBD_ | _TBD_ | ${today} |

## Defect Rates

| Defect type | Count last 30 days | Trend |
|-------------|--------------------|-------|
| env | _0_ | _flat_ |
| crypto | _0_ | _flat_ |
| script | _0_ | _flat_ |
| data | _0_ | _flat_ |
| assumption | _0_ | _flat_ |
| scope | _0_ | _flat_ |
| cost | _0_ | _flat_ |

## Main Measure

- Metric: _name_
- Target: _value by date_
- Current: _value (${today})_

EOF
fi

# --- DECISIONS.md ---
if want decisions; then
write DECISIONS.md <<EOF
# Decisions — ${project}

Lightweight decision log. One block per decision. Newest on top.

## Template

\`\`\`markdown
## YYYY-MM-DD — <decision in one line>
**Context:** what made this decision necessary.
**Alternatives considered:** A, B, C.
**Choice:** the option taken.
**Why:** the load-bearing reason — it must survive people forgetting.
**Consequences:** what we now have to live with (good and bad).
**Revisit when:** the condition that would invalidate this choice.
\`\`\`

EOF
fi

# --- BACKLOG.md ---
if want backlog; then
write BACKLOG.md <<EOF
# Backlog — ${project}

Items deferred from current work. Weigh each by what it costs against what it gains; promote, demote or drop them at every retro.

## Active

| Item | Build cost | Running cost | Expected gain | Notes |
|------|------------|--------------|---------------|-------|
| _example: retry failed uploads_ | _2 h_ | _none_ | _no more lost uploads_ | _link_ |

## Dropped (with date and reason)

| Item | Dropped | Why |
|------|---------|-----|

EOF
fi

# --- THREAT_MODEL.md (Confidential or Restricted) ---
if [[ "$classification" == "Confidential" || "$classification" == "Restricted" ]]; then
write THREAT_MODEL.md <<EOF
# Threat Model — ${project}

Classification: **${classification}**. Revisit on every architecture change and at least quarterly.

## Assets at Risk

_Refer to the Asset Inventory in CLAUDE.md. List the items whose loss, leak or corruption would matter most._

## Adversaries

| Adversary | Capability | Motivation |
|-----------|------------|------------|
| Outside attacker (network) | _low / med / high_ | _opportunistic / targeted_ |
| Insider (curious) | _read-only access_ | _curiosity_ |
| Insider (malicious) | _full access_ | _financial / grudge_ |
| Supply chain (dependency / model) | _can ship code we run_ | _opportunistic_ |
| Accidental (us) | _full access_ | _none_ |

## Top Risks (STRIDE)

| Threat | Vector | Impact | Mitigation | Residual |
|--------|--------|--------|------------|----------|
| Spoofing | | | | |
| Tampering | | | | |
| Repudiation | | | | |
| Information disclosure | | | | |
| Denial of service | | | | |
| Elevation of privilege | | | | |

## Controls in Place

- Encryption at rest: _disk / repository / none_
- Encryption in transit: _TLS / SSH / N/A_
- Access control: _who, how_
- Backup integrity: _verified how, last verified ${today}_
- Logging / monitoring: _what, where_

EOF
fi

# --- Output ---
echo "scaffold.sh: created in $target:"
for f in "${created[@]}"; do echo "  + $f"; done
echo "scaffold.sh: classification=${classification}${tier:+ tier=${tier}} extras=${extras:-none}"
exit 0
