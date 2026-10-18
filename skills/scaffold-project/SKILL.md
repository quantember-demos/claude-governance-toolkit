---
name: scaffold-project
description: Scaffold a project directory with governance files — CLAUDE.md (classification, asset inventory, encryption, backups, goals, optional tier), feedback.md (Symptom/Cause/Fix/Lesson log), and optional extras (METRICS.md, DECISIONS.md, BACKLOG.md; THREAT_MODEL.md for confidential work). Use when the user says "scaffold project", "init governance", "set up project files", "/scaffold-project", or asks to bootstrap a new project's CLAUDE.md/feedback.md. Refuses to overwrite existing canonical files.
---

# scaffold-project — Governance Bootstrap

## When to invoke

Triggers: "scaffold project", "init governance", "set up project files", `/scaffold-project [path]`, or any request to bootstrap a project's CLAUDE.md / feedback.md / governance scaffolding.

## Procedure

### 1. Determine target

- Default target: the current working directory. If that looks wrong (a home directory, a system path), ask.
- Project name = `basename "$target"`.

### 2. Tier (optional)

Tiers are optional. If the user keeps a tiers config (`$GOV_TIERS_CONF`, default `~/.config/claude-governance/tiers.conf`; example in `examples/tiers.conf`), it maps each tier to the extra files it gets. If the user also keeps a project registry (`$GOV_TIERS_FILE`, default `$GOV_PROJECTS_ROOT/.tiers.tsv`: `project<TAB>tier`), look the project up there:

```bash
awk -F'\t' -v p="<project>" '$1 == p {print $2; exit}' "${GOV_TIERS_FILE:-${GOV_PROJECTS_ROOT:-$HOME/Projects}/.tiers.tsv}"
```

If the user uses tiers and the project has none, ask. Do not guess. Without tiers, skip this step.

### 3. Classification

Ask once: Public / Internal / Confidential / Restricted. Default `Internal` if the user defers. `THREAT_MODEL.md` is generated only for Confidential or Restricted.

### 4. Encrypted repositories

If `<target>/.gitattributes` contains `filter=git-crypt`, the repository is encrypted: confirm with the user before writing plaintext files. If the working copy is *locked* (files start with `\x00GITCRYPT`), refuse and ask the user to unlock it first.

### 5. Run the scaffolder

```bash
bash ~/.claude/skills/scaffold-project/scripts/scaffold.sh \
  --path "<target>" \
  --classification "<class>" \
  [--tier "<tier>"] [--extras metrics,decisions,backlog]
```

The script:
- Refuses if `CLAUDE.md` OR `feedback.md` already exists (exit 3, prints what was found).
- Writes `CLAUDE.md` and `feedback.md` (always).
- Writes the extras from `--extras`, or from the tier's line in the tiers config, or `DECISIONS.md` alone when neither is given.
- Writes `THREAT_MODEL.md` if classification is Confidential or Restricted.
- Prints the file list it created.

### 6. Report

Tell the user:
- The list of files created (paths).
- The classification, tier (if any) and extras used.
- One-line next step: "Fill in the Asset Inventory and Backups sections of CLAUDE.md before real work starts in this project."

Do not commit anything. The user owns the next steps.

## Refusal mode

If the script exits 3 (existing files), report exactly what was found and stop. Do not propose merge, backup-and-overwrite, or any partial behaviour: overwriting loses hand edits, and merging needs a parser this skill does not have.

## Complement

`/retro` is the active half of the feedback loop: it reads `feedback.md`, clusters entries by defect tag, and proposes guards. Run it after a few entries have accumulated.
