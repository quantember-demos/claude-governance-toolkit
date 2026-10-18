# DNA-Zipper: a multi-agent audit that settles claims against ground truth

Code: [`workflows/dna-zipper.js`](../workflows/dna-zipper.js). Read with [silent-success.md](silent-success.md): the zipper is a detector, and that document is why detectors fail.

The mechanics live in the script. This file carries what code cannot: the reasoning behind the stage design, and the metrics that decide whether a run was any good.

## 1. The rule

> **Terminal authority is execution, or more generally retrieval of ground truth, not consensus.**
> Agreement between agents is a prior, not evidence. Route every claim that *can* be settled by running or reading something to the thing that settles it.

The common way multi-agent review fails: several agents correctly diagnose a defect and agree on a fix that does not work. The fix looks right to every reasoner because every reasoner shares the same blind spot. In bash, for example, `errexit` is ignored for the whole call tree under a command on the left of `||`, so a fix that adds error handling below that line has no effect. A short failing test shows that immediately; a fourth reviewer does not.

Corollary: never spend a reasoning token on what a linter, compiler or type checker does perfectly and deterministically.

## 2. Stages and why

| Stage | Purpose | Design note |
|---|---|---|
| **Prepass** | Deterministic tools over the **whole** corpus, once: syntax, lint, config cross-reference (code); placeholder scan, citations, links, figures (research); scaffolding, names, timeline markers (fiction) | Cheap and complete, and it feeds the agents instead of each agent re-running it on its own slice, which is how a file gets missed entirely. |
| **Find (two axes)** | Axis A slices by **unit** (file, document, chapter); axis B by **failure mode** across everything | Unit slices give coverage but cannot see cross-boundary defects. A finding seen by both axes is well supported; one seen by only one axis is often the interesting one. |
| **Verify (routed)** | Mechanical claims → cheap model; semantic or stateful claims → strong model | Cheap models misjudge stateful claims. Every verdict must carry evidence. |
| **Ground** | Every finding that *can* be settled by running or reading is: a harness that fails on current code, the cited source's passage, both contradicting passages | Promotes a verdict from "an agent believes it" to "the world agrees". This is the stage that catches a wrong fix. |
| **Adversary** | Refute survivors; hunt cross-slice seams; check the proposed fixes | The highest-value stage per token: no finder can see the seams between slices. |
| **Absence critic** | What should exist and does not; what did this audit not examine | The worst defects are often absences, such as a test suite that reports green on a system that was never configured. Every other agent looks at what is there. |
| **Synthesis** | Rank, dedupe, state what was *not* covered | Told about failed agents and zero-refutation runs, and must say so in the verdict. |

## 3. Anti-assent measures

A model asked *"is this correct?"* ratifies. Every verification stage therefore:

- **Requires evidence, not judgement.** The verdict carries the command and its output, or a quoted passage. Enforced in the output schema.
- **Frames for refutation:** *"try to prove this wrong; default to refuted if you cannot produce evidence"*.
- **Reviews the refutations too.** A checker that wrongly kills real findings is as harmful as one that confirms everything, so the adversary sees the refuted findings and may reinstate one with new evidence.
- **Diversifies the lens, not the sample.** N identical reviewers give correlated draws.

## 4. Run-health metrics: record these every run

A run is not good because it produced findings. The workflow returns `metrics` (findings_total, refuted, refute_rate, ground_settled, ground_cleared, ground_unreachable, found_by_both_axes) and `coverage` (agents expected and returned, slice_loss, verify and ground agents that failed, findings left unchecked, whether the adversary and absence critic returned). The last two rows below are for the operator to track across runs:

| Metric | Healthy | Meaning if not |
|---|---|---|
| Refutation rate | > 0 | The verify stage is rubber-stamping (the workflow warns at 0 on large runs) |
| Ground-truth settled vs cleared | both non-zero on a real codebase | Findings are speculative, or the gate is not being used |
| Agents returned vs expected, and stage failures | all returned, none failed | Silent coverage loss: the synthesis is told and must name what went unexamined or unchecked |
| Found by both axes | some | No overlap at all suggests the axes are not reading the same corpus |
| Cost per confirmed finding | tracked | No baseline to improve against |
| **Escape count** | falls over time | **The only metric that shows the audit improving** |

An *escape* is a real defect found later in a unit the zipper already audited. It is the zipper's own silent-success measure, and the number to drive down. Record the metrics somewhere durable, such as the project's [session memory](session-memory.md) `insights`.

## 5. Domains: the ground-truth gate generalises

| `args.domain` | Ground truth | Outcomes |
|---|---|---|
| `code` | run a harness that fails on current code | REPRODUCED / NOT_REPRODUCED / NOT_APPLICABLE |
| `research` | open the cited source and read the passage | SUPPORTED / PARTIALLY_SUPPORTED / CONTRADICTED / SOURCE_NOT_FOUND / NO_CITATION |
| `fiction` | locate both passages in the manuscript and quote them | CONTRADICTION_CONFIRMED / NO_CONTRADICTION / PASSAGE_NOT_FOUND / CRAFT_JUDGEMENT |

In each, the verdict is settled by fetching something outside the reviewer's own reasoning.

- **`research`** separates **SOURCE_NOT_FOUND from unsupported**: an unreachable source is verification debt, reported separately, not a defect. `args.sourcePolicy` describes where sources must come from, such as local primary-source collections or licensed databases. The default asks for primary sources over summaries and forbids silently settling for a secondary source.
- **`fiction`** is where the gate must be allowed to decline. Pacing, prose quality and "this scene is weak" are not settleable by retrieval, so the profile has `CRAFT_JUDGEMENT`, and the synthesis reports those separately as opinion. Its pre-pass matters most of the three: drafts written in parallel routinely carry hundreds of placeholder tokens (`[NAME]`, `TK`), and one grep finds them all before any agent reads a word.

## 6. Running it

The workflow runs under Claude Code's Workflow tool. With `dna-zipper.js` in `~/.claude/workflows/`:

```js
Workflow({ name: "dna-zipper", args: {
  domain: "code",                         // code | research | fiction
  project: "/abs/path/to/target",
  slices: [ { key: "core", files: "src/core/*", focus: "state handling" },
            { key: "cli",  files: "src/cli/*",  focus: "argument parsing" } ],
  context: "Runs on Ubuntu 24.04; config lives in /etc/app.",  // facts agents must not assume
  economy: false,                         // true: find stage on haiku
} })
```

Optional: `lenses` (replace the failure-mode axis), `findModel` (override the find-stage model; `null` = session model), `sourcePolicy` (research), `prepass` (pre-computed deterministic output).

## 7. Cost discipline

- **The find stage is the widest fan-out**: one agent per slice plus one per lens. `economy: true` runs it on haiku; keep the default for pre-publication or high-stakes work.
- **Estimate before launching.** Base the estimate on corpus size and agent count, and state it to whoever pays.
- **Every cost report is an estimate.** The workflow does not record per-agent tokens, so a cost report has to say that rather than quote false precision.

## 8. Testing

`node --test workflows/dna-zipper.test.mjs` runs the whole script against stubbed Workflow primitives, for all three domains, without model calls. The tests cover:
- stage order and per-domain prompt routing;
- the merge across both axes;
- model routing (`economy`, `findModel`);
- source-policy injection;
- argument validation.
