# OpenAI Build Week 2026 evidence

Aurora is entered in **Apps for Your Life**. It is a pre-existing project that
was meaningfully extended during the official submission period, which began
July 13, 2026 at 9:00 AM Pacific. This record deliberately separates the older
prototype from the work being submitted for judging.

## Before the submission period

Aurora already existed as a native Apple-silicon macOS voice prototype with a
Realtime conversation loop, early continuity and inner-life work, first-run API
key onboarding, and an earlier computer-control route.

The clearest pre-period artifact is the first saved public-site version:

- local source commit `6213d2b468dbd62563419839fe83a1dd11c5d719`
- authored July 13, 2026 at 12:18 AM Central / July 12 at 10:18 PM Pacific
- saved as Aurora Sites version 1 before the submission window
- described an early v0.1 beta, Realtime conversation, memory, background life,
  API-key onboarding, and direct permissioned Mac control

The commit object, tree, timestamp, archive checksum, and representative
pre-period source are published in
[the public site-v1 evidence](baselines/2026-07-12-public-site-v1.md).

Those existing ideas are context, not claimed as new Build Week work.

## Meaningful extension completed during Build Week

A restorable working-computer-control baseline was frozen on July 15 before the
new personhood pass. Comparing that archive with the current production source
shows **15,135 insertions and 507 deletions across 56 production files**, while
keeping the previously working task route as the regression floor.
The full sanitized per-file comparison is published in
[the production diffstat](baselines/2026-07-15-production-diffstat.md).

### 1. Authored agency before ordinary speech

Four new persistent Agency files add 2,649 lines of production code. Before an
ordinary social reply, Realtime must produce a schema-validated
`conversation_move` tied to the current finalized turn. The move can answer,
challenge, disagree, tease, withhold, reveal, redirect, initiate, pursue a
curiosity, reciprocate, or repair. Native code validates the move and its
provenance; it does not prescribe Aurora's final sentence.

Evidence:

- `Sources/Aurora/Agency/AgencyModels.swift`
- `Sources/Aurora/Agency/AgencyEngine.swift`
- `Sources/Aurora/Agency/AgencyStore.swift`
- `Sources/Aurora/Agency/AuroraAgencyRuntime.swift`
- `Sources/Aurora/Tools/ConversationMoveAdapter.swift`
- `scripts/verify-agency-state.swift`
- `scripts/verify-conversation-agency.swift`

### 2. Owner understanding and genuine curiosity

A new provenance-bearing owner-understanding subsystem separates exact things
the owner said from tentative inferences and genuine unknowns. Curiosities have
a lifecycle: they can be prepared, asked exactly, answered, deferred, or kept
without monopolizing future conversations. Generic assistant questions cannot
silently satisfy a different curiosity.

Evidence:

- `Sources/Aurora/Understanding/`
- `scripts/verify-owner-understanding.swift`
- the curiosity and playback cases in `scripts/verify-conversation-agency.swift`

### 3. GPT-5.6 Sol private reflection

Meaningful fully heard exchanges can reserve a bounded reflection ticket.
`gpt-5.6-sol` runs through the existing ChatGPT Codex sign-in in an ephemeral,
read-only process with tools, shell, apps, plugins, browser, Computer Use, and
web search disabled. Strict output may become a private interpretation,
curiosity, conceptual project step, or small artifact. It cannot invent outside
events, create factual memory, contact anyone, or authorize action.

Evidence:

- `Sources/Aurora/PrivateLife/CodexReflectionBridge.swift`
- `Sources/Aurora/PrivateLife/PrivateLifeEngine.swift`
- `scripts/verify-codex-reflection.swift`
- `scripts/verify-private-life.swift`

### 4. Causal speech and effect truth

Aurora now distinguishes generated audio, transmitted audio, and audio that
actually played. A conversational move or disclosure is learned from only when
the exact intended material was heard. Task delivery is also separate from task
effect: executor completion without trusted outcome evidence cannot become a
false spoken success. Barge-in, Rest, and reconnect tombstone stale moves so a
late response cannot update the newer conversation.

Evidence:

- `Sources/Aurora/Realtime/AuroraRealtimeClient.swift`
- `Sources/Aurora/Realtime/RealtimeInputCommitEvidence.swift`
- `Sources/Aurora/App/AuroraAppModel.swift`
- `scripts/verify-realtime.swift`
- `scripts/verify-app-model-tool-effect-truth.swift`
- `scripts/verify-reconnect-agency-boundary.sh`

### 5. Guest privacy and participant provenance

Owner-to-guest transitions now create a fresh Realtime conversation. Guest
sessions exclude owner continuity, relationship state, private Agency, current
tasks, and owner-specific projections. Guest or mixed-source material cannot be
silently attributed to Cade, while guest-grounded interaction may remain valid
as its own experience.

Evidence:

- `Sources/Aurora/App/SessionParticipantProvenance.swift`
- `Sources/Aurora/App/ToolAddressedInputProvenance.swift`
- `scripts/verify-session-participant-provenance.swift`
- guest-boundary cases in `scripts/verify-private-life.swift`

### 6. Persistent GPT-5.6 Codex handoff

Realtime remains present while an external request becomes one strict
`delegate_task`. The proposal is bound to the finalized owner turn and exact
effect. A persistent `gpt-5.6-sol` Codex app-server task performs the work in a
visible Codex thread, accepts contextual revisions, survives voice Rest, and
returns only bounded terminal truth. Screen, page, email, document, and tool
content may guide execution but cannot create or widen authorization.

Evidence:

- `Sources/Aurora/Codex/DelegateTaskCoordinator.swift`
- `Sources/Aurora/Codex/DelegateTaskAuthorization.swift`
- `Sources/Aurora/Codex/CodexTaskRuntime.swift`
- `scripts/verify-delegate-task.swift`
- `scripts/verify-codex-task-runtime.swift`
- `scripts/verify-exclusive-codex-routing.sh`

### 7. Public, reproducible verification

The source release, CI workflow, credential/private-path scan, source
fingerprint gate, architecture documentation, judge setup, and exact demo plan
were added during the window. Public CI builds the production graph and runs
the deterministic suite without accounts, keys, devices, or model calls.

Current measured evidence:

| Measurement | Result |
| --- | ---: |
| Swift production source | 66,300 lines across 90 files |
| Production build graph | 66 compiled files; 24 retired motors excluded |
| Verification and smoke entrypoints | 33 |
| Explicit `expect(...)` assertions | 1,514 |
| Representative Realtime instruction shell | 17,588 / 19,000 characters |
| Public GitHub CI at the initial source release | Passed |

## How Cade and Codex collaborated

Cade set the product goal and made the consequential decisions: voice must be
the foreground mind; personality must come from persistent authored agency, not
scripted lines; external effects must be authorized by the exact spoken turn;
Codex must be Aurora's durable hands without becoming her second voice; and
truth, privacy, interruption, and recovery must be explicit invariants.

Codex traced the live runtime, proposed bounded vertical slices, implemented
them, wrote adversarial regressions, compared the result with the frozen
baseline, audited credential and release boundaries, and ran the complete test
and packaging gates. Failures were treated as architecture evidence rather than
patched with phrase lists or canned dialogue.

At runtime, Codex is also part of Aurora: `gpt-5.6-sol` owns visible durable work
threads and the separate tool-disabled reflection process. OpenAI Realtime 2.1
remains the direct speech-to-speech conversational model.

## Primary Codex task evidence

The Devpost form requires the `/feedback` Session ID from the primary Codex
task. Generate it from the Aurora Build Week task after the final release and
insert it in the Devpost draft. The public repository intentionally does not
embed a user/account-linked feedback identifier.
