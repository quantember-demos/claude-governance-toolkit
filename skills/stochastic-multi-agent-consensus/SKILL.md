---
name: stochastic-multi-agent-consensus
description: Spawn N agents with the same prompt (slight framing variations) to independently analyze a problem, then aggregate by consensus. Use for decision-making, ranking options, strategic analysis, hallucination filtering, or surfacing high-variance ideas. Triggers on "consensus", "poll agents", "stochastic consensus", "spawn N agents to analyze", "multi-agent vote", "/stochastic-multi-agent-consensus", "what do 10 agents think", "get multiple opinions", or "poll on [topic]".
---

# stochastic-multi-agent-consensus — Independent-Sample Polling

## Purpose

Use N parallel, **independent** Claude agents as a stochastic ensemble over a problem. Each agent gets the same problem statement plus one decorrelating framing line; none of them see each other's output. Aggregate the returns to:

- **Filter hallucinations** — false claims rarely survive 7+ independent draws.
- **Quantify confidence** — claim X appearing 8/10 times is a different signal than 2/10.
- **Surface high-variance ideas** — the "lottery-ticket" idea only one agent had is worth flagging, not discarding.
- **Decide / rank under uncertainty** — when the right answer isn't reachable from first principles, sample many and tally.

This is **not** model-chat. Agents do not debate, do not see each other, and are not personas. The point is i.i.d.-ish sampling, not adversarial dynamics.

## Triggers

- Phrases: "consensus", "poll agents", "stochastic consensus", "spawn N agents to analyze", "multi-agent vote", "what do N agents think", "get multiple opinions", "poll on <topic>".
- Slash: `/stochastic-multi-agent-consensus <problem>`.
- Argument: free-text problem statement. If absent, ask the user once for it before proceeding.

## Inputs to gather

Before spawning, confirm or infer:

1. **Problem** — the question being polled. Required.
2. **N** — number of agents. Default **7**. Floor 3, soft ceiling 12 (cost grows linearly; >12 rarely changes the answer).
3. **Mode** — one of:
   - `rank` — agents return an ordered list of options.
   - `decide` — agents return a single choice from an enumerated set (or yes/no).
   - `enumerate` — agents return a list of distinct ideas/risks/options (open-ended).
   - `analyze` — agents return a free-form analysis with explicit claims (default).
4. **Context** — optional pointer(s) to local files the agents should read.

If N or mode is ambiguous, pick the default and proceed; do not block on micro-clarifications.

## Allowed Tools

Orchestrator (you): `Read, Grep, Glob, Bash, Write, Edit`, and the subagent tool (`Agent`; called `Task` in older Claude Code versions).

Spawned agents: `Read, Grep, Glob, Bash`. **Do not** grant the subagent tool (no recursive spawning), `Write`, or `Edit` — agents return their answer as their final message; the orchestrator does all writing.

## Procedure

### 1. Initialize the run file

```bash
bash ~/.claude/skills/stochastic-multi-agent-consensus/scripts/init_consensus.sh "<problem>" <N 3-50> <mode>
```

Capture stdout as `RUN`. The script writes the header, N, mode, and the per-agent framing assignments. The framing list is canonical and lives in the script — read `$RUN` after init to see which framing went to agent `i`.

### 2. Dispatch all N agents in parallel

Send a **single message** with N subagent (`Agent`) tool calls (`subagent_type: general-purpose`). Each agent prompt must contain, in order:

1. **Problem statement**, verbatim from the user.
2. **Framing line** for that agent index (read from `$RUN`).
3. **Context** — paths to any files the user pointed at, with a one-line note on each. Tell the agent to Read them before answering.
4. **Output contract**, chosen by mode:
   - `rank`: "Return a numbered ranked list of the options. One option per line: `N. <option> — <≤15-word reason>`. No preamble."
   - `decide`: "Return your single choice on the first line as `CHOICE: <option>` (or `CHOICE: yes` / `CHOICE: no`). Then ≤80 words of reasoning."
   - `enumerate`: "Return ≤8 distinct items, one per line: `- <item> — <≤15-word reason>`. No preamble."
   - `analyze`: "Return ≤200 words. Lead with a one-line `BOTTOM LINE:` claim. Then 2–4 bullet claims that load-bear it. Each bullet must be falsifiable (a fact, a number, or a testable prediction)."
5. **Hard rules**: "Do not spawn other agents. Do not write to disk. Return your answer as your final message. ≤500 tokens output."

Critically — **do not include any signal about what the other agents are doing or have said**. Each call is its own draw.

### 3. Append all returns to `$RUN`

Once all N have come back, append in agent-index order:

```markdown
## Agent N — <framing line>
<verbatim agent message>

```

Do this with `Bash` `cat >> "$RUN" <<'EOF' ... EOF` blocks (or sequential `Edit`s). The orchestrator never paraphrases the agent.

### 4. Aggregate

Read `$RUN`, then write a **Consensus** section. Aggregation depends on mode:

**`rank` mode — Borda + first-place:**
- For each option, compute Borda points (`N - rank + 1` per ballot) and first-place vote count.
- Print a single ranked table: `option | borda | first_place_votes | appeared_in_top3 (count)`.
- Highlight the option with both the highest Borda and the most first-place votes; if those diverge, flag it explicitly as a contested choice.

**`decide` mode — majority + dissent:**
- Count `CHOICE:` lines. Print `<choice>: <count>/N` for each.
- If majority ≥ ⌈2N/3⌉: report **strong consensus**.
- If majority is bare (>N/2 but <⌈2N/3⌉): report **weak majority**, and quote the most substantive dissenting reason verbatim.
- If no majority: report **no consensus**, list each cluster's reasoning, and recommend the user reframe.

**`enumerate` mode — frequency clustering:**
- Group items by lexical/semantic similarity (you do this — be charitable: "build a CI hook" and "add a pre-commit check" are the same cluster).
- Bucket clusters into:
  - **High-consensus** (appeared in ≥⌈2N/3⌉ agents).
  - **Medium-consensus** (≥N/3 and <⌈2N/3⌉).
  - **Singleton / lottery tickets** (1–2 agents only) — list these separately and **do not discard**; they are the highest-information part of the run.

**`analyze` mode — claim aggregation:**
- Extract each agent's `BOTTOM LINE:` and load-bearing claims.
- Cluster claims; for each cluster report `claim | support_count | dissent_count | unrebutted_objections`.
- Separate **convergent claims** (≥⌈2N/3⌉ support, no unrebutted objection) from **contested claims** (mixed) from **outlier insights** (1 agent, novel, falsifiable).

Append all of this to `$RUN` under `## Consensus`.

### 5. Write the recommendation

Append `## Recommendation` to `$RUN` with:

- **One-line answer to the problem**, qualified by the consensus level (`strong consensus`, `weak majority`, `no consensus`, `convergent`, `contested`).
- **Confidence**: `<x>/N` (or "no convergence").
- **Lottery tickets to not discard**: 0–3 bullets, the singleton ideas worth keeping despite low vote count.
- **What would change the answer**: one bullet — name the evidence or test that, if obtained, would shift consensus.

### 6. Report to the user

Print, in this order, ≤200 words:

1. Path to `$RUN`.
2. The Recommendation section verbatim.
3. One sentence on whether to spend more agents (e.g., "if the bare majority bothers you, re-run with N=12") or stop.

Do **not** dump the full transcript to the user — `$RUN` is the artifact.

## Quality gates

- **Independence**: each agent prompt must be self-contained. Never include another agent's output, the framing list as a whole, or the run file path.
- **Anti-mode-collapse**: if all N returns are >70% lexically identical (which means the framings did nothing), flag it: either the question was trivial or the framings are too weak. Do not pretend agreement is meaningful when the variance is ~0.
- **Hallucination filter**: any specific factual claim (a number, a citation, a function name, a person's quote) that appears in only 1 or 2 agents should be marked **unverified** in the Consensus section. Confident-sounding singletons are a known hallucination pattern.
- **Cost gate**: at N≥10 with `analyze` mode, tell the user the rough token cost before spawning (each agent is a full independent analysis), and get a go-ahead.
- **No recursion**: spawned agents must not be allowed to spawn further agents. Enforce by not granting the subagent tool.
- **Sensitivity**: `$RUN` lives under `~/.local/state/claude-governance/stochastic-consensus/` (or `$GOV_RUNS_DIR/stochastic-consensus/`). If the problem involves confidential data, ask before starting and keep the output somewhere appropriately private, such as an encrypted project directory.

## When NOT to use

- The answer is reachable by reading code, docs, or running a script. Use those tools instead — sampling LLMs to count their guesses is the worst possible oracle.
- The user wants debate / cross-examination dynamics. Use `/model-chat` instead.
- The problem has a verifiable ground truth and the user just wants the answer. Look it up.
- N=1 questions ("what's the syntax for X"). One agent, one answer.

## Output style

Terse. The artifact is `$RUN`; the chat reply is a pointer plus the Recommendation section. No trailing commentary on what the run "felt like".
