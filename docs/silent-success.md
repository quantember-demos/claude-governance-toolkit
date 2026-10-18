# Silent success: work that reports success and has no effect

Read this before declaring done any change to system state, configuration or behaviour, and before accepting a model's report that such a change is correct. `hooks/verify-effective-state.sh` is the code form of the rules below.

## 1. The failure mode

**An operation completes without error, reports success, and has no effect.**

Exit status and log output are properties of *the thing that ran*, not of *the system it was supposed to change*. `[OK]` means "the writer believes it wrote"; it does not mean the setting applied, the service loaded it, or the control is active.

This is distinct from a crash, and more dangerous, because every ordinary signal reads green. It survives lint, type checks, code review, the test suite and a model's audit.

## 2. Why it survives review: two biases that point the same way

**The artifact reports its own success.** `cmd 2>/dev/null || true` followed by an unconditional success log emits `[OK]` whatever happened. The success message is written by the same code whose effect is in question.

**The reviewer is disposed to agree.** A model asked *"is this correct?"* is more likely to affirm than to hunt. Assent is the low-effort answer; refutation requires constructing a counter-case.

The two compound: the code claims success, and the reviewer's prior is that claims are true. Neither checks the world. That is why a model cannot be the only detector of whether code does its job.

## 3. How it happens: mechanisms worth knowing

These are general behaviours, not edge cases.

- **`errexit` is suspended for a whole call tree.** In bash, `set -e` is ignored for any command on the left of `||` or `&&`, in an `if` condition, or after `!`, and that includes everything inside functions called from there. A single `main || handle_error` at the top disables `set -e` for the entire program. Fixes that add more error handling *below* that line change nothing. A ten-line test that runs a failing command inside such a function shows it at once; agreement between reviewers does not.
- **Skip is not pass.** A check written as `if [[ -f config ]]; then assert; else skip; fi`, where skip does not affect the exit code, passes on a machine where the feature was never installed. The absence of the control, the condition the check exists to detect, reports green.
- **Ignored failures in service managers.** In a systemd unit, a leading `-` on `ExecStartPost=-…` makes a failure of that command non-fatal and easy to miss.
- **Copying is not applying.** Writing a configuration file proves the file exists. Whether the running service loaded it is a separate question that only the service can answer.
- **The last statement decides a function's status.** `[[ cond ]] && cmd` as the final line returns 1 when `cond` is false, failing a function that did nothing wrong, or, under `||`, silently taking an error path.

## 4. The rules

1. **Observation channel ≠ mutation channel.** Never ask "did the write succeed"; ask "what does the system now report". Read state back through a different mechanism than the one that changed it (`sshd -T` rather than the file just written; `auditctl -l` rather than the rules file).
2. **Absence is FAIL, never SKIP.** A missing artifact for an enabled feature is the defect, not a reason to abstain.
3. **The exit code is the contract.** A verifier that cannot return non-zero for a broken system is decoration.
4. **Declare intent machine-readably**, separately from the implementation, or there is nothing to verify against.
5. **Execution is the terminal authority.** Agreement between reviewers, human or model, is not evidence. For anything with executable semantics, the failing test comes first.

## 5. Anti-patterns to search for

```
cmd 2>/dev/null || true          # ...followed by an unconditional success log
if [[ -f <artifact> ]]; then assert; else skip; fi
systemctl restart X              # ...used as proof that X's configuration is correct
ExecStartPost=-/usr/bin/thing    # leading '-' hides failures
cp config /etc/...               # copying a file ≠ the setting taking effect
if my_function; then             # disables errexit for the whole function body
[[ cond ]] && cmd                # as a function's last statement: returns 1 when cond is false
```

## 6. Counter-measures when a model is the detector

- **Never let the author be the verifier.** Same context, same misconception.
- **Require evidence, not judgement.** The verdict carries the command run and its actual output, or a quoted line from an authoritative source. *No evidence = not confirmed.* Enforce it in the output schema so it cannot be skipped.
- **Frame for refutation.** *"Try to prove this wrong; default to refuted if you cannot produce evidence"* outperforms *"is this correct?"*.
- **Ban the vocabulary of assent** in structured output. No "looks good": an enum verdict plus evidence.
- **Diversify the lens, not just the sample.** N identical reviewers give correlated draws. Near-identical answers across agents are mode collapse, not consensus.
- **Verify the fix, not just the finding.** Audits identify defects far more reliably than they specify corrections.
- **Check that the tests can fail.** Remove the fix and confirm the test goes red. A suite that cannot fail proves nothing; one that skips everything when a dependency is missing is the same failure in a different place.

## 7. The verifier contract used by `verify-effective-state.sh`

A project opts in with an executable `scripts/verify.sh` (or the path in `GOV_VERIFIER`). It asserts declared intent against observed state:

- `--json` prints a report;
- exit code `0` = all checks pass, `1` = at least one failed, `2` = incomplete (some checks could not be run).

```json
{
  "fail": 1,
  "unverified": 0,
  "checks": [
    {
      "area": "ssh",
      "check": "password authentication disabled",
      "status": "FAIL",
      "expected": "no",
      "observed": "yes",
      "channel": "sshd -T"
    }
  ]
}
```

`status` is `PASS`, `FAIL` or `UNVERIFIED`; `channel` names the observation channel, which per rule 1 should differ from the one that made the change.

**What the Stop hook does.**
- **Exit 0:** stays silent.
- **Failed or unverified checks:** reported to Claude at the end of a turn, once per turn.
- **A broken verifier is reported too.** That covers exiting outside 0–2, running past `GOV_VERIFY_TIMEOUT`, printing something that is not a JSON report, or exiting non-zero without naming a failed check. The broken verifier leaves the system state unverified; a hook that went quiet here would be silent success inside the anti-silent-success tool.
- **Trust:** a verifier is code from the project, so it runs only after its exact contents have been approved with `scripts/verify-trust.sh`. Approval pins the verifier and every file it sources, and must be given at a terminal by a person, never by Claude.

## 8. Where this sits

| Layer ([architecture](architecture.md)) | Role |
|---|---|
| **L2** in-line self-check | Lint and syntax only. Necessary, never sufficient: every mechanism in section 3 passes L2. |
| **L3** post-change validation | Where effective-state verification belongs: declared intent against observed state. |
| **L4** drift surveillance | Re-run the verifier on a schedule. This catches *reversion*: a fix silently undone later by whatever regenerates the file. |
