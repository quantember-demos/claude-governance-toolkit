# Session memory: a learning loop across Claude Code sessions

Each project gets a machine-readable record, `session-memory.json`, that accumulates what each session learned: insights, troubleshooting, the user's corrections and preferences, and proposed improvements to the project's `CLAUDE.md`. Two hooks maintain and surface it; Claude fills it in.

It complements, and points into, the human-readable logs. A troubleshooting entry here is a *pointer* into `feedback.md`, never a copy of it.

## Where it lives

`~/.claude/projects/<encoded-project-path>/memory/session-memory.json` (or under `$CLAUDE_HOME`), the per-project directory Claude Code itself uses. The encoding replaces `/` and `_` with `-`: `/home/ana/Projects/web_app` → `-home-ana-Projects-web-app`. That matches Claude Code for paths made of letters, digits, `.`, `-`, `_` and `/`. For other characters, such as spaces, the hooks still agree with each other, but the file may not sit beside Claude Code's own memory for that project.

## Schema

Formal definition: [`schema/session-memory.schema.json`](../schema/session-memory.schema.json).

```jsonc
{
  "schema_version": 1,
  "project": "web_app",
  "tier": "",                       // optional, from a tiers registry
  "created": "2026-10-17T12:00:00Z",
  "sessions": [
    {
      "session_id": "…",            // Claude Code's session id
      "date": "2026-10-17",
      "started": "…", "ended": "…", // ended is refreshed by the hook each turn
      "enriched": false,            // Claude sets true once it has written something
      "summary": "",                // one line: what the session did
      "insights":          [ { "text": "", "tags": [], "confidence": "high|med|low" } ],
      "troubleshooting":   [ { "symptom": "", "taxonomy": "env|crypto|script|data|assumption|scope|cost", "ref": "feedback.md#2026-10-17" } ],
      "user_interactions": [ { "type": "preference|correction|approval|rejection", "scope": "global|project", "note": "" } ],
      "optimization_candidates": [ { "target": "CLAUDE.md", "proposal": "", "rationale": "", "status": "proposed|applied|rejected" } ]
    }
  ]
}
```

`enriched: true` means "captured at least once", not "final".

## What the hooks do

| Hook | Event | Does |
|---|---|---|
| `session-memory-scaffold.sh` | Stop | Creates the file and a skeleton entry for the session on its first turn; afterwards only refreshes `ended`. Prints nothing (Stop-hook output would make Claude continue the turn). Takes a lock, so parallel sessions cannot drop each other's entries. Never overwrites a file that is not valid JSON. Skips the projects root itself and subagent worktrees (`.claude-worktrees/`). |
| `session-memory-surface.sh` | SessionStart | On `startup`, `resume`, `clear` and `fork`: injects the last enriched session's summary and up to 10 `proposed` optimization candidates (the digest lists all). On `compact`: injects a recovery block with the current session's insights and troubleshooting, so work recorded before the compaction is not lost. |

`scripts/session-memory-digest.sh` scans every project's file and lists projects, un-enriched sessions and open proposals: the place to review proposed `CLAUDE.md` changes across projects.

## Claude's part: add this to your `CLAUDE.md`

The hooks provide structure and surfacing; the content comes from Claude. A rule in the global `~/.claude/CLAUDE.md` makes that happen:

```markdown
## Session memory

Each project has a session record at
`~/.claude/projects/<encoded-cwd>/memory/session-memory.json` (schema in the
claude-governance-toolkit docs). Treat it as a write-ahead log:

- The moment a durable insight, a troubleshooting event (a bug that took more
  than one try, an environment quirk), a user preference or correction, or a
  non-trivial decision occurs, append it to the current session's entry (match
  `session_id`, else the most recent un-enriched one) and set `enriched: true`.
  Do not wait for the end of the session: a compaction discards anything not
  yet written.
- Troubleshooting entries point into feedback.md (`ref`); never copy the body.
- Propose concrete, evidence-backed CLAUDE.md edits as `optimization_candidates`
  with status `proposed`; flip them to `applied` or `rejected` after review.
- After a context compaction, re-read session-memory.json before continuing.
```

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `GOV_PROJECTS_ROOT` | `~/Projects` | the hooks act only for working directories under this root (`/` = everywhere) |
| `GOV_TIERS_FILE` | `$GOV_PROJECTS_ROOT/.tiers.tsv` | optional `project<TAB>tier` registry; fills the `tier` field |

Set them in the `env` block of `~/.claude/settings.json` so the hooks see them.
