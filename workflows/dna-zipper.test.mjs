// Tests for dna-zipper.js, run against stubbed Workflow primitives (no model calls).
//   node --test workflows/dna-zipper.test.mjs
import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const SRC = fs.readFileSync(new URL('./dna-zipper.js', import.meta.url), 'utf8')
  .replace(/^export const meta/m, 'const meta')

// A scriptable stand-in for the agents. Options:
//   findings(label, categories) -> findings for a find agent (default: two per agent)
//   verdict(id)                 -> CONFIRMED / PARTIAL / REFUTED (default CONFIRMED)
//   ground(id, outcomes)        -> one of the domain's gate outcomes (default the first)
//   fail(label)                 -> true: that agent returns null, as a failed agent does
// Verifiers and ground agents answer for exactly the ids present in their prompt.
async function run(args, o = {}) {
  const calls = []
  const logs = []
  const agent = async (prompt, opts = {}) => {
    calls.push({ prompt, label: opts.label, phase: opts.phase, model: opts.model })
    if (o.fail?.(opts.label)) return null
    const props = opts.schema?.properties || {}
    if (props.findings) {
      const cats = props.findings.items.properties.category.enum
      const list = o.findings ? o.findings(opts.label, cats) : [
        { id: 'x', file: 'a', line: 12, severity: 'HIGH', category: cats[0], gate: true },
        { id: 'y', file: 'b', line: 3, severity: 'LOW', category: cats[1], gate: false },
      ]
      return { notes: 'stub', findings: list.map(f => ({ title: 't', detail: 'd', failure_scenario: 's',
        evidence: 'e', fix: 'x', ...f })) }
    }
    const ids = [...prompt.matchAll(/--- id: (\S+)/g)].map(m => m[1])
    if (props.checked) {
      return { checked: ids.map(id => ({ id, verdict: o.verdict ? o.verdict(id) : 'CONFIRMED', evidence: 'out' })) }
    }
    if (props.results) {
      const outcomes = props.results.items.properties.outcome.enum
      return { results: ids.map(id => ({ id, outcome: o.ground ? o.ground(id, outcomes) : outcomes[0], harness: 'h', observed: 'o' })) }
    }
    return `STUB(${opts.label})`
  }
  const parallel = async thunks => Promise.all(thunks.map(t => t().catch(() => null)))
  const pipeline = async (items, ...stages) => {
    const out = []
    for (const [i, item] of items.entries()) {
      let v = item
      for (const stage of stages) v = await stage(v, item, i)
      out.push(v)
    }
    return out
  }
  const phases = []
  // Evaluates this repo's own workflow file, the way the Workflow runtime does;
  // no outside input reaches the function body
  const fn = new Function('agent', 'parallel', 'pipeline', 'phase', 'log', 'args',
    `return (async () => { ${SRC} })()`)
  const result = await fn(agent, parallel, pipeline, t => phases.push(t), m => logs.push(m), args)
  return { result, calls, phases, logs }
}

const SLICES = [{ key: 'one', files: 'a', focus: 'f' }, { key: 'two', files: 'b', focus: 'f' }]
const base = domain => ({ domain, project: '/tmp/target', slices: SLICES })
const finders = calls => calls.filter(c => c.phase === 'Find')
// n distinct findings, all from the first slice agent (other agents return none),
// every one reusing the same agent id
const distinct = n => (label, cats) => label === 'find:slice:one'
  ? Array.from({ length: n }, (_, i) => ({ id: 'dup', file: `f${i}`, line: i + 1, severity: 'HIGH', category: cats[0], gate: true }))
  : []

const DOMAIN_MARKERS = {
  code:     { prepass: 'shellcheck',         ground: 'harness that would FAIL',                          verdict: 'safe to run and ship' },
  research: { prepass: 'placeholder tokens', ground: 'Settle each claim below against its SOURCE',        verdict: 'sound enough to publish or deposit' },
  fiction:  { prepass: 'SCAFFOLDING SCAN',   ground: 'Settle each finding below against THE MANUSCRIPT', verdict: 'ready to go out as a draft of this stage' },
}

for (const [domain, m] of Object.entries(DOMAIN_MARKERS)) {
  test(`${domain}: every stage runs with the domain's own prompts`, async () => {
    const { result, calls, phases } = await run(base(domain))
    assert.deepEqual([...new Set(phases)], ['Prepass', 'Find', 'Verify', 'Ground', 'Adversary', 'Synthesis'])
    const byLabel = l => calls.find(c => String(c.label).startsWith(l))
    assert.ok(byLabel('prepass:').prompt.includes(m.prepass), 'prepass prompt')
    assert.ok(byLabel('ground:').prompt.includes(m.ground), 'ground-truth prompt')
    assert.ok(byLabel('synthesis').prompt.includes(m.verdict), 'synthesis verdict question')
    assert.equal(result.coverage.agents_expected, finders(calls).length)
    assert.equal(result.coverage.agents_returned, finders(calls).length)
  })
}

test('every agent is told it is read-only', async () => {
  const { calls } = await run(base('code'))
  for (const c of calls) assert.ok(c.prompt.includes('READ-ONLY'), `${c.label} prompt lacks the read-only constraint`)
})

test('both find axes run: one agent per slice and one per lens', async () => {
  const labels = finders((await run(base('code'))).calls).map(c => c.label)
  assert.deepEqual(labels.filter(l => l.startsWith('find:slice:')), ['find:slice:one', 'find:slice:two'])
  assert.ok(labels.filter(l => l.startsWith('find:lens:')).length >= 5)
})

test('findings from both axes on one locator merge, recording both axes', async () => {
  const { result } = await run(base('code'))
  const keys = result.findings.map(f => `${f.file}:${f.line}:${f.category}`)
  assert.equal(new Set(keys).size, keys.length)
  assert.ok(result.findings.some(f => f.axes.includes('slice') && f.axes.includes('lens')))
  assert.ok(result.metrics.found_by_both_axes >= 1)
})

test('ids are assigned by the workflow: colliding agent ids stay separate', async () => {
  const { result } = await run(base('code'), { findings: distinct(7), verdict: id => (id === 'f1' ? 'REFUTED' : 'CONFIRMED') })
  assert.equal(result.refuted.length, 1, 'one refutation removes exactly one finding')
  assert.equal(result.findings.length, 6)
  assert.equal(new Set(result.findings.map(f => f.id)).size, 6)
})

test('refuted findings leave the survivors and count in the metrics', async () => {
  const { result } = await run(base('code'), { findings: distinct(4), verdict: id => (id === 'f2' ? 'REFUTED' : 'CONFIRMED') })
  assert.ok(!result.findings.some(f => f.id === 'f2'))
  assert.equal(result.metrics.refuted, 1)
  assert.equal(result.metrics.refute_rate, 0.25)
})

test('ground outcomes are split into settled and cleared per domain', async () => {
  const { result } = await run(base('code'), {
    findings: distinct(4),
    // Asymmetric on purpose: swapping which outcome is damning must change the counts
    ground: (id, outcomes) => ({ f1: 'REPRODUCED', f2: 'REPRODUCED', f3: 'NOT_REPRODUCED', f4: 'NOT_APPLICABLE' })[id] || outcomes[0],
  })
  assert.equal(result.metrics.ground_settled, 2)
  assert.equal(result.metrics.ground_cleared, 1)
})

test('mechanical claims verify on haiku; semantic claims on the session model', async () => {
  const v = (await run(base('code'))).calls.filter(c => c.phase === 'Verify')
  assert.ok(v.some(c => c.label.startsWith('verify:mechanical') && c.model === 'haiku'))
  assert.ok(v.some(c => c.label.startsWith('verify:semantic') && c.model === undefined))
})

test('ground truth runs in batches of 6', async () => {
  const { calls } = await run(base('code'), { findings: distinct(13) })
  assert.equal(calls.filter(c => c.phase === 'Ground').length, 3)
})

test('verify runs in bounded batches', async () => {
  const { calls } = await run(base('code'), { findings: distinct(30) })
  assert.ok(calls.filter(c => c.label.startsWith('verify:semantic')).length >= 3)
})

test('the deterministic pre-pass is passed on, truncated at 12000 characters', async () => {
  const prepass = 'A'.repeat(11990) + 'KEEP' + 'B'.repeat(500) + 'DROP'
  const { calls } = await run({ ...base('code'), prepass })
  const p = finders(calls)[0].prompt
  assert.ok(p.includes('KEEP') && !p.includes('DROP'))
  assert.ok(!calls.some(c => c.label === 'prepass:deterministic'), 'a supplied pre-pass is not re-run')
})

test('adversary, absence critic and synthesis use the strongest model', async () => {
  const { calls } = await run(base('code'))
  for (const l of ['adversary', 'absence-critic', 'synthesis']) assert.equal(calls.find(c => c.label === l).model, 'opus', l)
})

test('the adversary is asked to check refutations too', async () => {
  const { calls } = await run(base('code'))
  assert.ok(calls.find(c => c.label === 'adversary').prompt.includes('a refutation can be wrong'))
})

test('a find agent that returns nothing is counted as lost', async () => {
  const { result, calls } = await run(base('code'), { fail: l => l === 'find:slice:one' })
  assert.equal(result.coverage.slice_loss, 1)
  assert.equal(result.coverage.agents_returned, finders(calls).length - 1)
  assert.ok(calls.find(c => c.label === 'synthesis').prompt.includes('FAILED TO RETURN'))
})

test('failed verify agents leave findings UNCHECKED and are reported, not called rubber-stamping', async () => {
  const { result, calls, logs } = await run(base('code'), { findings: distinct(10), fail: l => l.startsWith('verify:') })
  assert.ok(result.coverage.verify_agents_failed >= 1)
  assert.equal(result.coverage.findings_unchecked, 10)
  assert.ok(logs.some(l => l.includes('UNCHECKED')))
  assert.ok(!logs.some(l => l.includes('rubber-stamping')))
  assert.ok(calls.find(c => c.label === 'synthesis').prompt.includes('never checked'))
})

test('a failed ground agent is reported', async () => {
  const { result } = await run(base('code'), { fail: l => l.startsWith('ground:') })
  assert.ok(result.coverage.ground_agents_failed >= 1)
})

test('a failed adversary or absence critic is reported', async () => {
  const { result } = await run(base('code'), { fail: l => l === 'adversary' || l === 'absence-critic' })
  assert.equal(result.coverage.adversary_returned, false)
  assert.equal(result.coverage.absence_returned, false)
})

test('zero refutations over a large set warns of rubber-stamping', async () => {
  const { logs } = await run(base('code'), { findings: distinct(10) })
  assert.ok(logs.some(l => l.includes('rubber-stamping')))
})

test('a run with no findings still completes', async () => {
  const { result } = await run(base('code'), { findings: () => [] })
  assert.equal(result.metrics.findings_total, 0)
  assert.equal(result.metrics.refute_rate, 0)
})

test('economy runs the find stage on haiku and says so; findModel overrides', async () => {
  const cheap = await run({ ...base('code'), economy: true })
  assert.ok(finders(cheap.calls).every(c => c.model === 'haiku'))
  assert.ok(cheap.logs.some(l => l.includes('haiku')))
  assert.ok(finders((await run(base('code'))).calls).every(c => c.model === undefined))
  assert.ok(finders((await run({ ...base('code'), economy: true, findModel: 'sonnet' })).calls).every(c => c.model === 'sonnet'))
})

test('research: default and custom source policies', async () => {
  const def = (await run(base('research'))).calls.find(c => c.label === 'prepass:deterministic').prompt
  assert.ok(def.includes('prefer primary sources'))
  const policy = 'SOURCE POLICY: use only the attached corpus at /data/papers.'
  const custom = (await run({ ...base('research'), sourcePolicy: policy })).calls.find(c => c.label === 'prepass:deterministic').prompt
  assert.ok(custom.includes(policy) && !custom.includes('prefer primary sources'))
})

test('args may arrive as a JSON string; bad input is rejected clearly', async () => {
  assert.equal((await run(JSON.stringify(base('fiction')))).result.domain, 'fiction')
  await assert.rejects(run('{not json'), /not valid JSON/)
  await assert.rejects(run({ slices: SLICES }), /args.project is required/)
  await assert.rejects(run({ project: '/tmp/t' }), /args.slices is required/)
  await assert.rejects(run({ project: '/tmp/t', slices: 'src/*' }), /args.slices is required/)
  await assert.rejects(run({ ...base('poetry') }), /unknown domain 'poetry'/)
})
