---
name: retro
description: Run a retrospective on a project's feedback.md — cluster entries by defect taxonomy (env/crypto/script/data/assumption/scope/cost), surface recurring patterns, and propose 1-3 concrete guards (preflight check, hook, script) to install. The active half of the project feedback loop. Use when the user says "retro", "run a retro", "retrospective", "review feedback", "/retro", or asks to find patterns in feedback logs. Read-only by default; never modifies feedback.md without explicit permission.
---

# retro — Feedback Loop Retrospective

## When to invoke

Triggers: "retro", "run a retro", "retrospective", "review feedback", `/retro [project]`, or any request to find patterns in a project's feedback log.

This is the **active** half of the feedback loop — the passive half is the user (or you) writing entries to `feedback.md`. Without retros, those entries are a graveyard, not a loop.

## Procedure

### 1. Locate target

- Argument is a project path or name. If a name, resolve under `$GOV_PROJECTS_ROOT/<name>/` (default `~/Projects/<name>/`).
- Default: current working directory.
- Refuse if `<target>/feedback.md` does not exist — point the user at `/scaffold-project`.

### 2. Cluster

Run:

```bash
bash ~/.claude/skills/retro/scripts/cluster.sh <target>/feedback.md
```

The script emits, on stdout, a tab-separated table:

```
count<TAB>tag<TAB>most_recent_date<TAB>example_titles
```

It also prints a "since last retro" cutoff (read from `<target>/.last-retro` if present; otherwise "all time"). Entries dated on the cutoff day are included, since they may postdate that day's retro.

Tags come from each entry's `**Tag:**` line, or else a leading `[tag]` in its title (`~/.claude/governance-toolkit/scripts/feedback-append.sh -t <tag>` writes the line). If most entries come back `untagged`, say so first: clustering untagged entries shows nothing, and the fix is to tag them.

### 3. Read the entries

Read `<target>/feedback.md` directly. Pay attention to:

- The same root cause appearing under multiple titles (recurring incident).
- Tags clustered in time (a bad week — special-cause, not common-cause).
- Tags spread evenly over months (common-cause — needs a process change, not a one-off fix).
- Entries tagged `assumption` (these are the most actionable — they are guesses you got caught making).
- Entries tagged `cost` (these threaten ROI directly).

### 4. Synthesize the report

Produce a report (printed inline; do **not** write it to disk unless the user asks). Sections:

**Top patterns (≤5)** — each: `<tag>: <pattern>` in one sentence + `evidence: <date1>, <date2>, <date3>`.

**Distinguishing common-cause vs special-cause** — for each top pattern, state which it is and why.

**Proposed guards (1–3, ranked by value for effort)** — each: name a concrete artifact (a preflight check, a lint rule, a pre-commit hook, a memory entry, a shared script) and state the expected defect-rate reduction. Include build cost (rough hours) and run cost.

**One thing to stop doing** — based on `assumption` or `scope` entries.

**One thing to keep doing** — based on entries where the fix was clean and the lesson generalizes.

### 5. Offer follow-up

After printing the report, ask the user:

> Want me to (a) install one of the guards, (b) append this retro as a dated section to feedback.md, or (c) just leave the report on screen?

If the user picks (a), confirm exactly what file/script you'd create or modify before doing so. If (b), append a `## ${today} — Retro` block to feedback.md (newest-on-top order). If (c), do nothing else.

### 6. Stamp last-retro

If you wrote anything (option a or b), update `<target>/.last-retro` with today's UTC date so the next retro has a clear cutoff.

## Quality gates

- Do not propose guards for patterns with fewer than 2 incidents — that is special-cause, not a process problem.
- Do not propose guards that would require the user to remember to do something — guards must be enforced by code/hooks, not vigilance.
- If `feedback.md` has fewer than 3 entries, say so and decline to retro — there's nothing to cluster yet.

## Output style

Terse. Section headers + bullets. No trailing summary. The user reads diffs, not recaps.
