# Claude Governance Toolkit

Hooks, skills and a multi-agent audit workflow for [Claude Code](https://code.claude.com) that make AI-assisted work checkable: claims settled against evidence rather than agreement, success verified against the running system rather than exit codes, and lessons that carry from one session to the next.

The organising idea is in [docs/architecture.md](docs/architecture.md): six independent quality gates, L0 to L5, where each catches what the previous one missed. The main failure it guards against is in [docs/silent-success.md](docs/silent-success.md): work that reports success and has no effect.

## What is in it

| Piece | Kind | What it does |
|---|---|---|
| [`dna-zipper`](docs/dna-zipper.md) | Workflow | Multi-agent audit of a codebase, a research manuscript or a fiction manuscript. Deterministic pre-pass, two search axes, routed verification, a **ground-truth stage** that settles claims by running or reading something, an adversary, and an absence critic. |
| `verify-effective-state.sh` | Stop hook | Runs a project's `scripts/verify.sh`, once you have approved it, at the end of each turn. Tells Claude when the running system no longer matches its declared intent, or when the verifier itself is broken. Silent only when every check passes. |
| `session-memory-scaffold.sh` | Stop hook | Keeps a per-project [session record](docs/session-memory.md) of what each session learned. |
| `session-memory-surface.sh` | SessionStart hook | Shows that record at session start, and restores in-flight notes after a context compaction. |
| `model-chat` | Skill | A debate room: five personas argue in rounds and converge on a recommendation. |
| `stochastic-multi-agent-consensus` | Skill | N independent agents with varied framing; aggregate by consensus and flag single-source claims as unverified. |
| `retro` | Skill | Cluster a project's `feedback.md` by defect tag and propose guards against recurring problems. |
| `scaffold-project` | Skill | Create a project's `CLAUDE.md`, `feedback.md` and optional extras (metrics, decisions, backlog, threat model). |
| `feedback-append.sh` | Script | Add a tagged Symptom / Cause / Fix / Lesson entry to `feedback.md`. |
| `session-memory-digest.sh` | Script | List every project's session record: un-enriched sessions and proposed `CLAUDE.md` changes. |
| `verify-trust.sh` | Script | Approve (or revoke) a project's verifier for the verify hook. |

## Requirements

- Claude Code. The hooks follow the [hooks documentation](https://code.claude.com/docs/en/hooks) as of October 2026, and their tests feed them payloads of that shape.
- Linux with GNU coreutils (`sha256sum`, `timeout`, `flock`, `stat -c`), `bash` 4.3+, `jq`
- `node` 18+ to run the workflow's tests; `python3` with `jsonschema` (optional) for the schema tests
- The `dna-zipper` workflow needs Claude Code's Workflow tool; without it, the workflow cannot run (everything else works)

## Install

```bash
git clone https://github.com/quantember-demos/claude-governance-toolkit.git
cd claude-governance-toolkit
./install.sh
```

The installer copies:
- hooks and scripts into `~/.claude/governance-toolkit/`;
- skills into `~/.claude/skills/`;
- the workflow into `~/.claude/workflows/`.

It **does not edit `settings.json`**. It prints the hook wiring to add, as in [`examples/settings.json`](examples/settings.json):

```json
{
  "env": { "GOV_PROJECTS_ROOT": "/home/you/Projects" },
  "hooks": {
    "SessionStart": [ { "hooks": [ { "type": "command", "command": "~/.claude/governance-toolkit/hooks/session-memory-surface.sh" } ] } ],
    "Stop": [ { "hooks": [
      { "type": "command", "command": "~/.claude/governance-toolkit/hooks/session-memory-scaffold.sh" },
      { "type": "command", "command": "~/.claude/governance-toolkit/hooks/verify-effective-state.sh" }
    ] } ]
  }
}
```

**Updates and uninstall.**
- Re-run `./install.sh` to update. A file you have edited locally is kept, and reported, unless you pass `--force`.
- `./install.sh --uninstall` removes what the installer copied, except files you have changed since. Those are kept and listed.

### The verify hook runs code from your projects

A verifier is a script inside a project, and a project can be anything you cloned. So the hook runs a verifier only after you approve that exact file:

```bash
~/.claude/governance-toolkit/scripts/verify-trust.sh ~/Projects/my-app    # shows the whole file, asks, records its SHA-256
```

Approval reads your answer from the terminal (`/dev/tty`) and refuses to run inside Claude Code. That is deliberate: a repository can contain text written to steer Claude, and a gate Claude could open would not be a human gate. When a verifier is unapproved, Claude is told once per session to ask you.

**What approval covers.**
- **Scope:** the verifier and every file it `source`s, followed recursively, shown in full for review (control characters displayed, never interpreted). A change to any pinned file stops the verifier until you approve it again.
- **Fails closed.** Only exact sources are followed: absolute paths, or paths relative to `$(dirname "$0")` or `$(dirname "${BASH_SOURCE[0]}")`. A source through another variable (`"$ROOT/lib/x.sh"`), or a project script run by `bash`, `python` and the like, blocks approval until you pin the file with `--also FILE`. A `--also` file whose path ends with the reference's tail covers it, and its own sources are followed too.
- **What the scanner cannot follow also blocks approval:** `eval`, `exec`, a `source` after `;` or `&&`, or a command run by path (`./x`, `"$ROOT/bin/x"`). Simplify the verifier, or read those lines and pass `--accept-unclassified`. Static scanning of shell is best-effort, so keep verifiers simple.
- **Revoking:** `--revoke` removes an approval; `--fingerprint` shows what would be pinned without approving anything.

**What it is not.** Approval stops Claude from being talked into running unreviewed code. It is not a boundary against other software already running as you, which could edit the trust file directly.

**Root, and its limit.** With `GOV_VERIFY_SUDO=1` an approved verifier runs as root, and only when `sudo -n` works without a password. There is a short window between the hook's check and the run in which the files could change. Exploiting it requires code already running as you, which could equally call `sudo -n` itself, so the window adds no privilege.

### Session memory

For session memory to fill up, add the short rule in [docs/session-memory.md](docs/session-memory.md#claudes-part-add-this-to-your-claudemd) to your `~/.claude/CLAUDE.md`. The hooks keep the structure; Claude writes the content.

## Configuration

All optional.

| Variable | Default | Used by |
|---|---|---|
| `GOV_PROJECTS_ROOT` | `~/Projects` | hooks: act only under this directory (`/` = everywhere) |
| `GOV_TIERS_FILE` | `$GOV_PROJECTS_ROOT/.tiers.tsv` | session memory: optional `project<TAB>tier` registry |
| `GOV_TIERS_CONF` | `~/.config/claude-governance/tiers.conf` | scaffold-project: which extra files each tier gets ([example](examples/tiers.conf)) |
| `GOV_VERIFIER` | `scripts/verify.sh` | verify hook: verifier path(s) inside a project, `:`-separated; the first present is used |
| `GOV_VERIFY_TRUST` | `~/.config/claude-governance/verify-trusted` | verify hook: approved verifiers (`sha256  path`) |
| `GOV_VERIFY_TIMEOUT` | `60` | verify hook: seconds before a verifier is stopped and reported |
| `GOV_VERIFY_SUDO` | `0` | verify hook: `1` runs an approved verifier with non-interactive sudo |
| `GOV_RUNS_DIR` | `$XDG_STATE_HOME/claude-governance`, else `~/.local/state/claude-governance` | model-chat and consensus: where run files are kept |
| `CLAUDE_HOME` | `~/.claude` | everything: where Claude Code's configuration lives |

Tiers are an optional way to sort projects by why they exist and to give each kind different paperwork; the example config shows four. Everything works without them.

## Using the audit workflow

```js
Workflow({ name: "dna-zipper", args: {
  domain: "code",                  // code | research | fiction
  project: "/abs/path/to/target",
  slices: [ { key: "core", files: "src/core/*", focus: "state handling" } ],
  context: "Facts the agents must not assume: OS, versions, config locations.",
} })
```

It runs a dozen or more agents, so estimate the cost before launching; `economy: true` runs the widest stage on a cheaper model. [docs/dna-zipper.md](docs/dna-zipper.md) explains the stages and the run-health metrics, starting with: a verify stage that refutes nothing is rubber-stamping.

## Tests

```bash
tests/run.sh
```

It runs:
- the workflow under stubbed agents, with no model calls;
- the hooks against throwaway home directories;
- the scripts, including a round trip from `feedback-append.sh` to `retro`;
- the installer, into a temporary `CLAUDE_HOME`.

Nothing touches your real `~/.claude`.

## Support

Provided as-is, built against Claude Code's documented behaviour as of October 2026. Hook payloads and Claude Code's per-project directory naming can change between releases. Issues and pull requests are welcome; no response time is promised.

## License

MIT, see [LICENSE](LICENSE).
