# Layered assurance: six independent gates (L0–L5)

A way to organise checks on AI-assisted work so that each layer catches what the one before missed. The model borrows from DNA replication: a cell copies its genome with roughly one error per 10⁹–10¹⁰ bases. No single mechanism achieves that. It comes from several independent checks whose escape rates multiply, so skipping any one of them multiplies the residual error.

Labelling each check with its layer makes incidents diagnosable: after a defect escapes, ask *which gate was skipped?*

| Layer | Biology | Software layer | When it fires | Concrete actions |
|---|---|---|---|---|
| **L0** | Origin licensing: replication starts only at licensed origins, once per cycle | **Change authorisation** | Before any destructive or shared-state action | State the exact command, its blast radius and its rollback, then wait for a human. A permissive tool mode does not waive this. |
| **L1** | Base selection: a wrong base is excluded by fit before it is incorporated | **Pre-write verification** | Before an edit, or before calling a non-trivial external API | Look things up rather than recall them: read local code and docs first, then official documentation, and cite it. No invented paths, flags, APIs or package names. |
| **L2** | Proofreading: the polymerase removes a wrong base in the same pass | **In-line self-check** | Immediately after each edit, in the same context | The check that matches what was touched: `bash -n` and `shellcheck`, `python -m py_compile`, `node --check`, `tsc --noEmit`, `cargo check`, a JSON parse. Fix on the spot. |
| **L3** | Mismatch repair: a second scan after the strand is complete | **Post-change validation** | After a coherent change is staged | Run the affected tests; review the diff against the original request; check callers of changed symbols; verify effective state ([silent-success.md](silent-success.md)). Fix the root cause, not the symptom. |
| **L4** | Excision repair: continuous surveillance for damage outside replication | **Drift surveillance** | On a schedule, and on demand | Re-verify cached reference data against its source; dependency audits; end-of-life checks; re-run effective-state verifiers to catch reversion. Report findings; do not auto-fix. |
| **L5** | Recombination repair: rebuild a broken strand from the sister copy | **Recovery and rollback** | Planned before any destructive action; used on failure | A tracked way back for every destructive step: a git branch or tag before the change, a backup of touched configuration, a log that makes state reconstructable, offline backups. |

## Operating rules

- **Layers compose; they never substitute.** Tests (L3) do not replace looking things up (L1); asking permission (L0) does not replace having a rollback (L5).
- **Match depth to blast radius.** A small local edit needs L1 and L2. Shared, system-level or governance changes need all six. Irreversible actions (force-push, formatting a disk, rotating a secret, anything public) need explicit confirmation at L0 and a written rollback at L5.
- **A hallucination is an L1 failure.** When a wrong path, API or flag survives to a test failure (L3) or an audit (L4), record why L1 missed it. A pattern of L1 failures means the lookup habit, or its tooling, needs strengthening; that is the most valuable improvement to make.
- **Records are the substrate of L4.** Without a running log (a project `feedback.md`, [session memory](session-memory.md)), surveillance has no baseline to compare against. Write records as work happens, not at the end.

## Where this toolkit fits

| Layer | Toolkit piece |
|---|---|
| L2 | Lint and syntax checks run by the [dna-zipper](dna-zipper.md) pre-pass |
| L3 | `hooks/verify-effective-state.sh`; the dna-zipper ground-truth stage |
| L4 | `skills/retro` (patterns in `feedback.md`); `scripts/session-memory-digest.sh` |
| L1 / L3 for important work | `skills/model-chat`, `skills/stochastic-multi-agent-consensus`, dna-zipper: independent reviewers framed for refutation |
| Records for L4 | `scripts/feedback-append.sh`; the session-memory hooks |

## Defect tags

Recording defects with a fixed set of tags lets `/retro` find patterns:

| Tag | Meaning |
|---|---|
| `env` | environment or setup: missing tool, wrong version, permissions, path |
| `crypto` | encryption, signing, secrets |
| `script` | a shell or code defect: quoting, idempotency, error handling |
| `data` | stale, wrong or unverified data |
| `assumption` | a guessed fact instead of a looked-up one (an L1 failure) |
| `scope` | work that crept beyond what was asked |
| `cost` | money or tokens spent without checking the return |
