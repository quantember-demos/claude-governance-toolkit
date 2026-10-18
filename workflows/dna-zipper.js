export const meta = {
  name: 'dna-zipper',
  description: 'Multi-agent audit: deterministic pre-pass, dual-axis find, routed verify, ground-truth gate, adversary, absence critic. Domains: code, research, fiction.',
  whenToUse: 'Auditing a codebase, a research/nonfiction manuscript, or a fiction manuscript when correctness matters more than speed. args: {domain, project, slices, context, economy, sourcePolicy}.',
  phases: [
    { title: 'Prepass',   detail: 'deterministic tooling over the whole corpus, once' },
    { title: 'Find',      detail: 'axis A by slice, axis B by failure mode' },
    { title: 'Verify',    detail: 'routed: mechanical claims cheap, semantic claims strong' },
    { title: 'Ground',    detail: 'settle claims against external ground truth, not reasoning' },
    { title: 'Adversary', detail: 'refute survivors, hunt cross-slice seams', model: 'opus' },
    { title: 'Absence',   detail: 'what should exist and does not' },
    { title: 'Synthesis', detail: 'rank, dedup, declare coverage gaps', model: 'opus' },
  ],
}

// ---------------------------------------------------------------------------
// args: {
//   domain:   'code' | 'research' | 'fiction'                 (default 'code')
//   project:  absolute path to the target                    (required)
//   slices:   [{key, files, focus}] — the by-slice axis      (required)
//   context:  string — environment/source facts agents must not assume
//   lenses:   [{key, prompt}] — overrides the domain's failure-mode axis
//   economy:  true — run the find stage on a cheaper model        (default false)
//   findModel: model for the find stage; overrides economy (null = session model)
//   sourcePolicy: string — research domain: where sources must come from
//   prepass:  string — pre-computed deterministic output, skips that stage
// }
//
// The reproduction gate generalises. Terminal authority is RETRIEVAL OF GROUND
// TRUTH; execution is merely its code-shaped case:
//   code     -> run a harness that fails on current code   -> REPRODUCED
//   research -> open the cited source, read the passage    -> SUPPORTED / CONTRADICTED
//   fiction  -> locate both passages in the manuscript      -> CONTRADICTION_CONFIRMED
// In both, the verdict is settled by fetching something outside the reviewer's
// own reasoning. That is what stops a confident, wrong finding.
// ---------------------------------------------------------------------------

// Accept args as an object (direct / scriptPath invocation) OR as a JSON string (a named
// workflow invoked through a skill receives its args serialised). Without this parse, a
// string arg leaves `A.project` undefined and every named invocation throws.
let A = args || {}
if (typeof A === 'string') {
  try { A = A.trim() ? JSON.parse(A) : {} }
  catch (e) { throw new Error(`dna-zipper: args is a string but not valid JSON (${e.message})`) }
}
const PROJECT = A.project
if (!PROJECT) throw new Error('dna-zipper: args.project is required (absolute path)')

const SLICES = A.slices || []
if (!Array.isArray(SLICES) || !SLICES.length || !SLICES.every(s => s && s.key && s.files))
  throw new Error('dna-zipper: args.slices is required: an array of {key, files, focus}')

const DOMAIN = A.domain || 'code'

// Model for the find stage — the widest fan-out, so the main cost lever.
//
// economy:true runs it on haiku. That is right for routine audits and wrong for a
// pre-publication artifact: silently auditing a manuscript with cheap finders is a false
// economy on the one run that matters. findModel overrides either way, and a downgrade is
// logged, never silent.
const FIND_MODEL = A.findModel !== undefined
  ? (A.findModel || undefined)
  : (A.economy ? 'haiku' : undefined)

// Research domain: where evidence must come from. Pass args.sourcePolicy to describe local
// primary-source collections, licensed databases, or domain-specific rules.
const SOURCE_POLICY = A.sourcePolicy || `SOURCE POLICY: prefer primary sources — the original
paper, standard, dataset, patent or official publication — over summaries of them. Never a
forum or blog as a primary source. If a primary source cannot be reached, DO NOT silently
settle for a secondary one and carry on: say the figure comes from a secondary source
pending primary verification, and flag it.`

// ===========================================================================
// Domain profiles
// ===========================================================================

const DOMAINS = {

  code: {
    unit: 'file',
    locator: 'repo-relative path',
    locatorLine: 'line number',
    categories: ['lockout', 'dataloss', 'falsegreen', 'idempotency', 'crossmodule', 'security', 'correctness', 'portability', 'style'],
    // Field that marks a finding as settleable by external ground truth.
    gateField: 'executable',
    gateFieldDesc: 'true if this claim could be settled by RUNNING something rather than by reading',
    gateOutcomes: ['REPRODUCED', 'NOT_REPRODUCED', 'NOT_APPLICABLE'],
    gateName: 'Reproduce',
    readonly: `HARD CONSTRAINT: you are READ-ONLY. Inspection commands are fine (cat, grep, find,
shellcheck, bash -n, --help, man, read-only status queries). You may NEVER mutate: no
installs, no service start/stop/enable/disable, no writes outside /tmp, no edits to any
project file.`,
    prepass: `Run deterministic analysis over the ENTIRE corpus. You are not judging design —
you are producing a complete, mechanical defect list for other agents to build on.

1. Enumerate every source file (do not sample — list them all).
2. Syntax-check each (bash -n, python -m py_compile, node --check, tsc --noEmit ...).
3. Lint each at its strictest useful setting (shellcheck -x -s bash, ruff, eslint ...).
4. Report EVERY error and warning with file:line and rule id. Do not filter for relevance.
   State explicitly which files produced no output.
5. Cross-reference config: every key the code reads vs every key the config defines.
   Report read-but-never-defined and defined-but-never-read.`,
    lenses: [
      { key: 'lockout',     prompt: 'Access loss. Firewall rules replaced rather than added, a listener moved without the firewall following, auth tightened with no verified credential in place, a service restarted before its new access path exists.' },
      { key: 'dataloss',    prompt: 'Destruction. Trace every rm, delete, --delete, dd, mkfs, truncate, mv over an existing path, and every truncating redirect. Under what plausible failure does any of them target something the user needs?' },
      { key: 'falsegreen',  prompt: 'Reported success that did not happen. Failures discarded, success logged unconditionally, checks that skip instead of failing when the thing under test is absent, exit codes that cannot express failure.' },
      { key: 'idempotency', prompt: 'Second-run behaviour. What breaks, duplicates, or silently reverts on a re-run? Does anything regenerate a file whose live value was deliberately corrected?' },
      { key: 'crossmodule', prompt: 'Interactions no single-file reviewer can see: ordering hazards, one component reverting another, shared state with two owners, helpers whose contract callers violate, templates shadowed by later-loading drop-ins.' },
    ],
    gatePrompt: `Demonstrate — or fail to demonstrate — each finding below.

You MAY write and run scripts under /tmp, and copy project files into /tmp and modify the
copies. You may NOT modify anything inside the project.

Build the smallest harness that would FAIL on the current code if the defect is real.
Run it. Report what actually happened.

REPRODUCED     — you ran something and observed the claimed bad behaviour.
NOT_REPRODUCED — you ran a fair harness and the defect did not appear. Say what you
                 expected and what you got instead.
NOT_APPLICABLE — genuinely cannot be exercised (needs hardware you lack). Do not use this
                 to avoid work.`,

    failureDesc: 'concrete inputs/state -> concrete bad outcome',
    harnessDesc: 'the exact script/command written to demonstrate the defect',
    observedDesc: 'what actually happened when it ran',
    sevCritical: 'access loss, unbootable, destroyed data',
    sevHigh: 'silently fails to apply a control the user believes is active, or breaks on re-run',
    damning: ['REPRODUCED'],
    exonerating: ['NOT_REPRODUCED'],
    groundAuthority: 'a harness that ran',
    verdictQuestion: 'safe to run and ship',
    beforeWhat: 'running this again',
    seams: 'Read across boundaries: ordering hazards between units, one component reverting another, helpers whose contract callers violate, whole-run failure modes, anything letting the test suite report green on a broken system.',
    absenceQuestions: `1. What capability does this project clearly imply but not deliver?
2. What is not covered by any check, test, or verification?
3. Which failure modes has nobody defended against at all?
4. What did THIS AUDIT not examine — files, paths, runtime states nobody opened?
5. Where does the code assume something about its environment that is never asserted?`,
    extraSection: null,
  },

  research: {
    unit: 'document',
    locator: 'document path',
    locatorLine: 'line number, or 0 if you cite a section/heading instead',
    categories: [
      'unsupported-claim',    // asserted without a source
      'quote-drift',          // the source does not say what is quoted/attributed
      'overstated-certainty', // hedging does not match the strength of the evidence
      'internal-inconsistency', // figures/claims disagree across sections
      'missing-counterargument', // a known objection is never addressed
      'stale-figure',         // superseded data, or a figure with no date
      'method-conclusion-gap',// the conclusion does not follow from the stated method
      'attribution',          // licensing, credit, or provenance problem
      'structure',            // organisation/clarity defect
    ],
    gateField: 'has_citation',
    gateFieldDesc: 'true if this finding concerns a claim that cites, or should cite, an external source — i.e. it can be settled by reading that source rather than by reasoning',
    gateOutcomes: ['SUPPORTED', 'PARTIALLY_SUPPORTED', 'CONTRADICTED', 'SOURCE_NOT_FOUND', 'NO_CITATION'],
    gateName: 'Source check',
    readonly: `HARD CONSTRAINT: you are READ-ONLY on the manuscript. You may read any file, fetch
public sources, and query local corpora. You may NEVER edit the manuscript or any project
file.

${SOURCE_POLICY}`,
    prepass: `Run deterministic analysis over the ENTIRE manuscript. You are not judging argument
quality — you are producing a mechanical defect list for other agents to build on.

1. Inventory every document, its headings, and per-section word counts. Flag outliers.
2. Scan for scaffolding left in the prose: placeholder tokens ([NAME], [TK], TK, XXX,
   TODO, FIXME, lorem), bracketed editorial notes, duplicated sentences. Report counts and
   locations — this class of defect is mechanically detectable and must never reach an agent.
3. Extract every citation. Validate format consistency. List citations that are
   incomplete (no author/year/locator).
4. Resolve every URL and DOI you can reach; report dead links, redirects and 404s.
5. Extract every numeric figure with its unit and the claim it attaches to. Report any
   figure that appears more than once with DIFFERENT values, and any figure with no
   stated source.
6. Report proper-noun spelling variants (the same entity spelled differently).

Return raw results grouped by document, plus an inventory of what was checked.`,
    lenses: [
      { key: 'unsupported',     prompt: 'Load-bearing claims with no source. Sweep the whole manuscript for assertions that a reader would reasonably demand evidence for — quantitative claims, causal claims, claims about what others have found, claims about consensus — and check whether a citation is actually attached. An unsourced claim in a conclusion is more serious than one in background.' },
      { key: 'quotedrift',      prompt: 'Attribution integrity. For every direct quote, paraphrase, and "X showed that..." construction, does the cited source plausibly say that? Flag anything you cannot locate in the source, quotes that appear reworded, and attributions to a source that is about a different subject. Fabricated or drifted quotes are the highest-severity defect class here.' },
      { key: 'certainty',       prompt: 'Calibration. Compare the strength of each claim to the strength of its evidence. Flag where a single study is described as established, where "suggests" has become "shows", where a correlation is written as a cause, and conversely where a well-supported claim is hedged into uselessness.' },
      { key: 'consistency',     prompt: 'Internal coherence. Do the numbers, dates, units and definitions agree across the whole manuscript? Does the abstract match the conclusion? Does any section contradict another? Are terms used with a stable meaning throughout?' },
      { key: 'counterargument', prompt: 'Adversarial completeness. What is the strongest objection to this thesis, and does the manuscript address it? Flag known competing explanations, contrary evidence, and methodological limitations that go unmentioned. Silence about an obvious objection reads as either ignorance or concealment.' },
      { key: 'methodgap',       prompt: 'Does the conclusion follow? Trace each headline conclusion back to the method and data actually described. Flag conclusions broader than the evidence supports, generalisations beyond the sample, and any step where the reasoning skips.' },
    ],
    gatePrompt: `Settle each claim below against its SOURCE. Do not reason about whether the claim is
plausible — go and read what the source actually says.

For each: locate the cited source (in the order the source policy sets, then the
official/publisher version, then an archive). Read the relevant passage. Quote it verbatim
in "observed".

SUPPORTED           — the source says what the manuscript claims.
PARTIALLY_SUPPORTED — the source supports part of it, or supports it with caveats the
                      manuscript drops. Say exactly what was dropped.
CONTRADICTED        — the source says something materially different. Quote both.
SOURCE_NOT_FOUND    — you could not reach the source. Say what you tried. This is NOT the
                      same as unsupported, and must not be reported as if it were.
NO_CITATION         — the claim has no source to check. That is itself the finding.

Put the retrieval you performed in "harness" (the URL fetched, the corpus queried, the
file read) and the actual passage in "observed". A verdict with no quoted passage is not
a verdict.`,

    failureDesc: 'what a reader concludes wrongly, or what breaks in the argument, as a result',
    harnessDesc: 'the retrieval performed: URL fetched, corpus queried, file read',
    observedDesc: 'the actual passage, quoted verbatim',
    sevCritical: 'a false claim a reader would act on, or fabricated attribution',
    sevHigh: 'a load-bearing claim that does not hold, or a conclusion the evidence does not support',
    damning: ['CONTRADICTED', 'PARTIALLY_SUPPORTED', 'NO_CITATION'],
    exonerating: ['SUPPORTED'],
    groundAuthority: 'the source passage itself',
    verdictQuestion: 'sound enough to publish or deposit',
    beforeWhat: 'publishing',
    seams: 'Read across the whole argument: does the thesis hold when the sections are taken together? Do two well-sourced sections imply something the manuscript never notices? Does the abstract promise what the body delivers? Is there a load-bearing assumption never stated anywhere? And ask the question no consistency check asks: is what is described physically possible, not merely internally consistent?',
    absenceQuestions: `1. What question does this manuscript raise and never answer?
2. Which load-bearing claim has no source, and would a reader notice?
3. What counter-argument would a hostile expert reviewer raise first, and is it addressed?
4. What did THIS AUDIT not examine — sections, sources, appendices nobody opened?
5. What does the argument assume without ever stating it?
6. What is promised in the abstract, introduction or outline but not delivered in the body?
7. Is the work constrained by anything outside its own content — licensing, export control, regulatory scope, ethics review — that nobody has checked?
8. What does this document assume about its own history that a first-time reader cannot verify?`,
    extraSection: { title: 'Verification debt', body: `Sources that could not be reached, and what it would take to close each. A claim
load-bearing on a published conclusion with an unreachable source is a BLOCKER on
publication, not a footnote.` },
  },
  fiction: {
    unit: 'chapter',
    locator: 'manuscript file path',
    locatorLine: 'line number, or 0 if you cite a chapter/scene instead',
    categories: [
      'continuity',        // the text contradicts the text
      'timeline',          // events cannot occur in the stated order or interval
      'voice-drift',       // a character or narrator stops sounding like themselves
      'pov-violation',     // knowledge or interiority the POV cannot have
      'unresolved-setup',  // a promise made to the reader and never paid
      'scaffolding',       // drafting apparatus left in the prose
      'motivation',        // a character acts against established want or nature
      'repetition',        // echoed phrasing, image, or beat
      'canon-conflict',    // contradicts the series bible or an earlier book
      'pacing',            // structural proportion problem
    ],
    gateField: 'in_text',
    gateFieldDesc: 'true if this finding can be settled by locating specific passages in the manuscript and quoting them, rather than by craft judgement',
    gateOutcomes: ['CONTRADICTION_CONFIRMED', 'NO_CONTRADICTION', 'PASSAGE_NOT_FOUND', 'CRAFT_JUDGEMENT'],
    gateName: 'Text check',
    readonly: `HARD CONSTRAINT: you are READ-ONLY on the manuscript. Read any file, grep freely,
consult the series bible and outline. You may NEVER edit the manuscript or any project file.

The manuscript is the authority on itself. Where a series bible and the text disagree, that
disagreement IS the finding — report both, do not silently prefer one.`,
    prepass: `Run deterministic analysis over the ENTIRE manuscript. You are not judging craft —
you are producing a mechanical defect list for other agents to build on. Much of what
matters most here is greppable, and no reasoning token should be spent on it.

1. Inventory every chapter/scene file with word counts. Flag outliers in both directions.
2. SCAFFOLDING SCAN — highest priority. Search the prose for drafting apparatus that must
   never reach a reader: bracketed placeholders ([NAME], [PLACE], [DATE], [TK]), TK, XXX,
   TODO, FIXME, LOREM, doubled punctuation, unclosed quotation marks, and editorial
   asides. Report EVERY occurrence with a count per token and the files involved. Drafts
   written by several hands in parallel routinely carry hundreds of these; one grep is all
   this takes.
3. Proper-noun inventory: every capitalised name and its variant spellings, with counts.
   Near-identical variants are either a continuity defect or a typo — list them all.
4. Extract explicit time markers (dates, "three days later", ages, seasons) per chapter in
   reading order, as a raw timeline for others to check.
5. Repeated-phrase detection: any distinctive phrase of 5+ words occurring more than once,
   and any sentence duplicated across files.
6. Per-chapter POV/tense markers: first vs third person, past vs present, and the named
   POV character if identifiable. Report any chapter that mixes them.
7. Dialogue-tag and adverb frequency per chapter, as a crude voice-consistency baseline.

Return raw results grouped by file, plus an inventory of what was checked.`,
    lenses: [
      { key: 'continuity',   prompt: 'The text contradicting the text. Physical details, names, ages, relationships, objects, injuries, clothing, weather, geography, who knows what and when. Sweep the whole manuscript and report any pair of passages that cannot both be true. Quote both.' },
      { key: 'timeline',     prompt: 'Chronology. Build the actual sequence of events from the text and check it holds: travel times, gestation, ages against stated dates, seasons against described weather, how long a wound takes to heal, whether a character can be in two places. Report any interval that cannot work.' },
      { key: 'voice',        prompt: 'Voice consistency and drift. Does each character sound like themselves throughout, and distinct from the others? Does the narrator hold a stable register? Flag chapters where diction, sentence rhythm, or vocabulary shifts without in-story cause — the signature of a fan-out written by different hands.' },
      { key: 'povtense',     prompt: 'POV and tense discipline. Does any passage give the POV character knowledge they cannot have — another character interiority, an event they did not witness, information they learn later? Any tense slippage? Any head-hopping within a scene?' },
      { key: 'setuppayoff',  prompt: 'Promises to the reader. Catalogue every setup — an object noticed, a skill established, a threat named, a question posed, a mystery opened — and check whether it pays off. Then the reverse: does any payoff arrive without its setup? Unpaid setups are the defect readers remember.' },
      { key: 'motivation',   prompt: 'Character logic. Does anyone act against their established want, fear, competence or knowledge because the plot needs them to? Trace each major decision back to what the text has established about that character. Flag anything only explicable as authorial convenience.' },
      { key: 'canon',        prompt: 'Conflict with the series bible, outline, or earlier books. Where the manuscript and the canon documents disagree, report both sides and say which the text actually supports. Do not assume the bible is right.' },
    ],
    gatePrompt: `Settle each finding below against THE MANUSCRIPT ITSELF. Do not reason about whether
the problem is plausible — go and find the passages.

For each: locate the specific passages involved. Quote them verbatim, with their locators,
in "observed". Put the search you performed (the grep, the files read) in "harness".

CONTRADICTION_CONFIRMED — you found both passages and they genuinely cannot both be true.
                          Quote both. This is the strongest verdict available here.
NO_CONTRADICTION        — you found the passages and they are compatible, or context
                          elsewhere resolves it. Say what resolves it.
PASSAGE_NOT_FOUND       — you could not locate the text the finding refers to. The finding
                          may be about something that is not actually in the manuscript.
CRAFT_JUDGEMENT         — this is a matter of taste or quality, not a factual claim about
                          the text, and cannot be settled by retrieval. Say so honestly
                          rather than manufacturing a verdict. Pacing, prose quality and
                          "this scene is weak" belong here.

The last outcome matters: unlike code and research, much of fiction critique is genuinely
not settleable by retrieval. Marking a craft opinion as CONTRADICTION_CONFIRMED to look
rigorous is the worst thing you can do in this stage.`,
    failureDesc: 'what the reader notices, or where the story breaks, as a result',
    harnessDesc: 'the search performed: the grep run, the files read',
    observedDesc: 'the passages themselves, quoted verbatim with locators',
    sevCritical: 'a contradiction or timeline break a reader will certainly catch, or drafting scaffolding left in the prose',
    sevHigh: 'an unpaid setup, a POV violation, or voice drift that breaks immersion',
    damning: ['CONTRADICTION_CONFIRMED'],
    exonerating: ['NO_CONTRADICTION', 'PASSAGE_NOT_FOUND'],
    groundAuthority: 'the quoted passages themselves',
    verdictQuestion: 'ready to go out as a draft of this stage',
    beforeWhat: 'sending this out',
    seams: 'Read across the whole book: does the arc actually complete? Do two chapters written separately imply a contradiction neither contains alone? Does the ending answer the question the opening asks? Is there a character who disappears without exit, a subplot that stops rather than resolves, or a stated theme the events never earn?',
    absenceQuestions: `1. What setup is made and never paid off, and what payoff arrives with no setup?
2. Which character disappears without an exit, or is introduced and never used?
3. What question does the opening pose that the ending does not answer?
4. What did THIS AUDIT not examine — chapters, appendices, outline documents nobody opened?
5. What does the story assume the reader knows but never establishes?
6. Which scene is promised by the structure — a confrontation, a reveal, a reckoning — and never written?
7. Is there scaffolding, outline text, or an author note still sitting in the prose?`,
    extraSection: { title: 'Craft judgement (not settleable by retrieval)', body: `Findings the text-check stage marked CRAFT_JUDGEMENT. These are opinions about quality,
not claims about the text, and are reported separately so they are weighed as opinion.` },
  },

}

const D = DOMAINS[DOMAIN]
if (!D) throw new Error(`dna-zipper: unknown domain '${DOMAIN}' (known: ${Object.keys(DOMAINS).join(', ')})`)

if (FIND_MODEL === 'haiku') {
  log(`NOTE: find stage runs on haiku (economy). For a pre-publication or high-stakes artifact, pass args.findModel:null to inherit the session model.`)
}

const LENSES = A.lenses || D.lenses

const CONTEXT = `
TARGET: ${PROJECT}   (domain: ${DOMAIN})

${A.context || '(no context supplied — verify facts before asserting them)'}

${D.readonly}

EVIDENCE RULE: a claim you did not verify is not a finding. Every factual assertion must be
backed by something you actually ran or actually read — quote it. "Looks like", "appears
to", "presumably" are not evidence. If you cannot produce evidence, say so and lower the
severity.
`

// ===========================================================================

const FINDINGS_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['findings', 'notes'],
  properties: {
    notes: { type: 'string', description: 'One paragraph: what you examined and its overall health. State explicitly what you did NOT examine.' },
    findings: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['id', 'file', 'line', 'severity', 'category', 'title', 'detail', 'failure_scenario', 'evidence', 'gate', 'fix'],
        properties: {
          id: { type: 'string', description: 'short kebab-case slug' },
          file: { type: 'string', description: D.locator },
          line: { type: 'integer', description: D.locatorLine },
          severity: { type: 'string', enum: ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW'] },
          category: { type: 'string', enum: D.categories },
          title: { type: 'string' },
          detail: { type: 'string' },
          failure_scenario: { type: 'string', description: D.failureDesc },
          evidence: { type: 'string', description: 'the command you ran and its output, or the passage you read, quoted. Required.' },
          gate: { type: 'boolean', description: D.gateFieldDesc },
          fix: { type: 'string' },
        },
      },
    },
  },
}

const VERDICT_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['checked'],
  properties: {
    checked: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['id', 'verdict', 'evidence'],
        properties: {
          id: { type: 'string' },
          verdict: { type: 'string', enum: ['CONFIRMED', 'PARTIAL', 'REFUTED'] },
          evidence: { type: 'string' },
          correction: { type: 'string' },
        },
      },
    },
  },
}

const GATE_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['results'],
  properties: {
    results: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['id', 'outcome', 'harness', 'observed'],
        properties: {
          id: { type: 'string' },
          outcome: { type: 'string', enum: D.gateOutcomes },
          harness: { type: 'string', description: D.harnessDesc },
          observed: { type: 'string', description: D.observedDesc },
        },
      },
    },
  },
}

// ===========================================================================

phase('Prepass')

const prepass = A.prepass || await agent(
  `${D.prepass}

${CONTEXT}

Flag loudly if anything could not be checked, and why.`,
  { label: 'prepass:deterministic', phase: 'Prepass' }
)

log(`prepass complete (${String(prepass).length} chars)`)

// ---------------------------------------------------------------------------

phase('Find')

const findPrompt = (scope, focus) => `You are auditing ${PROJECT}. ${scope}

${CONTEXT}

DETERMINISTIC PRE-PASS (already run — build on it, do not repeat it):
${String(prepass).slice(0, 12000)}

The pre-pass covers what tooling can settle mechanically. Your job is what it CANNOT see.

FOCUS:
${focus}

Severity: CRITICAL = ${D.sevCritical}.
HIGH = ${D.sevHigh}.
MEDIUM = wrong but recoverable. LOW = cosmetic.

Set "gate": true when ${D.gateFieldDesc}. Those findings go to a stage that will try to
settle them against external ground truth. Be honest about this flag — a finding marked
gate:true that cannot actually be settled is worse than an honest false.

A short list of real defects beats a long list of maybes. Do not pad.`

const sliceAgents = SLICES.map(s => () =>
  agent(findPrompt(`Your slice is: ${s.files}`, s.focus),
        { label: `find:slice:${s.key}`, phase: 'Find', schema: FINDINGS_SCHEMA, model: FIND_MODEL })
    .then(r => r == null ? null : ({ slice: s.key, axis: 'slice', result: r })))

const lensAgents = LENSES.map(l => () =>
  agent(findPrompt(`You sweep the WHOLE target — every ${D.unit}, no slice boundary. You are looking for ONE class of defect only.`, l.prompt),
        { label: `find:lens:${l.key}`, phase: 'Find', schema: FINDINGS_SCHEMA, model: FIND_MODEL })
    .then(r => r == null ? null : ({ slice: l.key, axis: 'lens', result: r })))

// Barrier: the two axes must be merged and deduped before the expensive stages.
const found = (await parallel([...sliceAgents, ...lensAgents])).filter(Boolean)

const seen = new Map()
for (const row of found) {
  for (const f of (row.result?.findings || [])) {
    const key = `${f.file}:${f.line}:${f.category}`
    if (seen.has(key)) { seen.get(key).axes.push(row.axis); continue }
    seen.set(key, { ...f, axes: [row.axis], slice: row.slice })
  }
}
// Agents pick their own ids, which collide across agents; every later stage keys
// verdicts by id, so give each merged finding a unique one here
const all = [...seen.values()].map((f, i) => ({ ...f, agent_id: f.id, id: `f${i + 1}` }))
const bothAxes = all.filter(f => f.axes.length > 1).length
const sliceLoss = (SLICES.length + LENSES.length) - found.length
log(`${all.length} unique findings from ${found.length}/${SLICES.length + LENSES.length} agents (${bothAxes} found by both axes)`)

// ---------------------------------------------------------------------------

phase('Verify')

const mechanical = all.filter(f => !f.gate && f.severity === 'LOW')
const semantic   = all.filter(f => !mechanical.includes(f))

const verifyBatch = (batch, model, tag) => {
  if (!batch.length) return Promise.resolve({ checked: [] })
  const digest = batch.map(f =>
    `--- id: ${f.id} (${f.severity}/${f.category}) ${f.file}:${f.line}\n  claim: ${f.title}\n  detail: ${f.detail}\n  author's evidence: ${(f.evidence || '').slice(0, 500)}`
  ).join('\n')
  return agent(
    `You are the adversarial checker for ${PROJECT}. Your job is NOT to agree. Try to BREAK
each claim below.

${CONTEXT}

For each finding: go to the cited location and confirm it says what is claimed. Content
absent = REFUTED. Right content, wrong locator = PARTIAL. Re-derive the claim
independently — does context elsewhere already address it? Settle every sub-claim with
something you actually run or read, and PUT IT in the evidence field.

Default to REFUTED when you cannot produce evidence. An unrefuted claim you did not
actually check is a failure on YOUR part, not a confirmation.

${digest}`,
    { label: `verify:${tag}`, phase: 'Verify', model, schema: VERDICT_SCHEMA }
  )
}

// Batches keep each verifier's prompt bounded
const verifyJobs = [
  ...chunk(mechanical, 20).map((b, i) => () => verifyBatch(b, 'haiku', `mechanical-${i + 1}`)),
  ...chunk(semantic, 12).map((b, i) => () => verifyBatch(b, undefined, `semantic-${i + 1}`)),
]
const verdictSets = verifyJobs.length ? await parallel(verifyJobs) : []
const verifyFailed = verdictSets.filter(v => v == null).length

const vmap = {}
for (const v of verdictSets.flatMap(r => r?.checked || [])) vmap[v.id] = v
for (const f of all) {
  const v = vmap[f.id] || { verdict: 'UNCHECKED', evidence: '' }
  f.verdict = v.verdict; f.verify_evidence = v.evidence; f.correction = v.correction || ''
}

const refuted   = all.filter(f => f.verdict === 'REFUTED')
const survivors = all.filter(f => f.verdict !== 'REFUTED')
const refuteRate = all.length ? refuted.length / all.length : 0
log(`verify: ${refuted.length}/${all.length} refuted (rate ${(refuteRate * 100).toFixed(0)}%)`)
if (verifyFailed) {
  log(`WARNING: ${verifyFailed} verify agent(s) failed to return; their findings are UNCHECKED, not confirmed`)
} else if (refuted.length === 0 && all.length > 8) {
  log('WARNING: zero refutations across a large finding set — the verify stage may be rubber-stamping')
}

// ---------------------------------------------------------------------------

phase('Ground')

const gated = survivors.filter(f => f.gate)
log(`${gated.length} of ${survivors.length} survivors are settleable against ground truth — running ${D.gateName}`)

const gateResults = gated.length ? await pipeline(
  chunk(gated, 6),
  batch => agent(
    `${D.gatePrompt}

${CONTEXT}

${batch.map(f => `--- id: ${f.id} (${f.severity}) ${f.file}:${f.line}\n  ${f.title}\n  claim: ${f.detail}\n  why it matters: ${f.failure_scenario}`).join('\n')}`,
    { label: `ground:${batch[0].id}`, phase: 'Ground', schema: GATE_SCHEMA }
  )
) : []

const groundFailed = gateResults.filter(r => r == null).length
const gmap = {}
for (const r of gateResults.filter(Boolean)) for (const x of (r.results || [])) gmap[x.id] = x
for (const f of survivors) {
  const r = gmap[f.id]
  if (r) { f.ground = r.outcome; f.ground_harness = r.harness; f.ground_observed = r.observed }
}

// Outcomes that mean "the ground truth agrees the manuscript/code is wrong".
const DAMNING = D.damning
const EXONERATING = D.exonerating

const settled   = survivors.filter(f => DAMNING.includes(f.ground))
const cleared   = survivors.filter(f => EXONERATING.includes(f.ground))
const unreachable = survivors.filter(f => f.ground === 'SOURCE_NOT_FOUND')
log(`ground: ${settled.length} settled against the target, ${cleared.length} cleared, ${unreachable.length} source unreachable`)

// ---------------------------------------------------------------------------

const digestOf = fs => fs.map(f =>
  `[${f.severity}/${f.category}] ${f.id} (${f.file}:${f.line}) verdict=${f.verdict}${f.ground ? ` ground=${f.ground}` : ''}\n` +
  `  ${f.title}\n  detail: ${f.detail}\n  consequence: ${f.failure_scenario}\n  fix: ${f.fix}\n` +
  `  evidence: ${(f.verify_evidence || f.evidence || '').slice(0, 600)}` +
  (f.correction ? `\n  CORRECTION: ${f.correction}` : '') +
  (f.ground_observed ? `\n  GROUND TRUTH: ${String(f.ground_observed).slice(0, 500)}` : '')
).join('\n\n')

phase('Adversary')

const [adversary, absence] = await parallel([
  () => agent(
    `You are the ADVERSARY for the audit of ${PROJECT}. Highest-value agent in this run —
the earlier stages cannot do either of these jobs for themselves.

${CONTEXT}

TASK A — REFUTE. Try to kill the surviving findings. Go to the real ${D.unit}s. Does
context elsewhere already prevent or address the problem? Is severity inflated? Is the
proposed fix correct, or would it break something else? Findings marked
${EXONERATING.join('/')} by the ground-truth stage are strong evidence AGAINST — weight
them accordingly. Default to skeptical.

TASK B — HUNT THE SEAMS. Each finder saw one slice or one lens, so defects spanning both
are invisible to all of them. ${D.seams}

TASK C — CHECK THE FIXES. For the top findings, would the proposed correction actually
work? An audit that diagnoses correctly and prescribes wrongly is worse than useless,
because the wrong fix is applied with confidence.

=== FINDINGS (${survivors.length}) ===
${digestOf(survivors) || '(none — for a target this size that is itself suspicious; audit that possibility)'}

=== REFUTED BY THE CHECKER (a refutation can be wrong too: resurrect one only with new evidence, and say so) ===
${refuted.map(f => `${f.id}: ${f.correction || f.verify_evidence}`).join('\n') || '(none)'}

Return prose: REFUTATIONS (id -> upheld/downgraded/killed + why + locator), NEW
CROSS-CUTTING FINDINGS, FIX CORRECTIONS. Cite a locator for everything.`,
    { label: 'adversary', phase: 'Adversary', model: 'opus' }
  ),
  () => agent(
    `You are the ABSENCE CRITIC for ${PROJECT}. Every other agent examined what IS there.
You examine what ISN'T.

${CONTEXT}

DETERMINISTIC INVENTORY:
${String(prepass).slice(0, 6000)}

Answer:
${D.absenceQuestions}

Absence defects are the highest-severity class in practice because nothing surfaces them:
what was never written raises no error. Be specific and cite locators.

=== findings so far, for context on what was already covered ===
${survivors.map(f => `${f.severity} ${f.file}:${f.line} ${f.title}`).join('\n').slice(0, 6000)}`,
    { label: 'absence-critic', phase: 'Absence', model: 'opus' }
  ),
])

// ---------------------------------------------------------------------------

phase('Synthesis')

const coverage = {
  verify_agents_failed: verifyFailed,
  findings_unchecked: all.filter(f => f.verdict === 'UNCHECKED').length,
  ground_agents_failed: groundFailed,
  adversary_returned: adversary != null,
  absence_returned: absence != null,
  domain: DOMAIN,
  agents_expected: SLICES.length + LENSES.length,
  agents_returned: found.length,
  slice_loss: sliceLoss,
  refute_rate: `${(refuteRate * 100).toFixed(0)}%`,
  ground_settled: settled.length,
  ground_cleared: cleared.length,
  ground_unreachable: unreachable.length,
}

const report = await agent(
  `Produce the final audit report for ${PROJECT}.

${CONTEXT}
You may READ anything in the target to resolve a disagreement.

Authority order:
  1. GROUND-TRUTH results — ${D.groundAuthority} beats any amount of reasoning.
  2. The ADVERSARY — where it contradicts a finder or the checker, it wins unless the
     finder's evidence is stronger. Say which you took and why.
  3. Verified findings with real evidence.
  4. Unverified findings — include only if independently compelling, and mark them so.

RUN COVERAGE (state honestly, do not bury):
${JSON.stringify(coverage, null, 2)}
${sliceLoss > 0 ? `\n*** ${sliceLoss} AGENT(S) FAILED TO RETURN. Coverage is incomplete — say so prominently and name what went unexamined. ***` : ''}
${verifyFailed || groundFailed ? `\n*** ${verifyFailed} verify and ${groundFailed} ground-truth agent(s) failed to return: ${coverage.findings_unchecked} finding(s) were never checked. Say so; do not present them as verified. ***` : ''}
${refuteRate === 0 && all.length > 8 && !verifyFailed ? `\n*** The verify stage refuted NOTHING across ${all.length} findings. Treat CONFIRMED verdicts with suspicion; lean on ground-truth results. ***` : ''}
${unreachable.length > 0 ? `\n*** ${unreachable.length} source(s) could not be reached. "Source not found" is NOT the same as "unsupported" — report it as verification debt, not as a defect. ***` : ''}

Write GitHub-flavoured markdown:

# DNA-Zipper Audit — <target>
_One-paragraph verdict: is this ${D.verdictQuestion} as it stands, yes or no, and the single most important reason._

## Coverage and confidence
What was examined, what was not, how many findings were settled against ground truth vs
merely reasoned. Be honest about this run's limits.

## Severity summary
Table: severity | count | one-line theme.

## Confirmed defects
Most-severe first. Each: **[SEVERITY] title** — locator, the concrete consequence, the
evidence it is real (prefer ground-truth output, quoted), and the minimal fix. Mark each
as GROUND-TRUTH SETTLED or REASONED so the reader knows which is which.

## Cross-cutting problems
The adversary's findings that no single-slice reviewer could see.

## Absent by omission
The absence critic's findings.

${D.extraSection ? `## ${D.extraSection.title}
${D.extraSection ? D.extraSection.body : ''}

` : ''}## Ranked next actions
At most 8, in do-this-first order, each naming its locator. Separate "fix before
${D.beforeWhat}" from "improve when convenient".

## Considered and dismissed
Terse: claim -> why it is not a defect. Include refutations, adversary kills, and
${EXONERATING.join('/')} results. This stops a future run re-finding the same non-defect.

Be direct. Every claim cites a locator or a retrieval. No hedging, no filler, no praise.

=== FINDINGS ===
${digestOf(survivors)}

=== ADVERSARY ===
${adversary || '(adversary failed to return)'}

=== ABSENCE CRITIC ===
${absence || '(absence critic failed to return)'}`,
  { label: 'synthesis', phase: 'Synthesis', model: 'opus' }
)

return {
  target: PROJECT,
  domain: DOMAIN,
  coverage,
  metrics: {
    findings_total: all.length,
    refuted: refuted.length,
    refute_rate: refuteRate,
    ground_settled: settled.length,
    ground_cleared: cleared.length,
    ground_unreachable: unreachable.length,
    found_by_both_axes: bothAxes,
  },
  findings: survivors,
  refuted,
  adversary,
  absence,
  report,
}

// --- helpers ---
function chunk(arr, n) {
  const out = []
  for (let i = 0; i < arr.length; i += n) out.push(arr.slice(i, i + n))
  return out
}
