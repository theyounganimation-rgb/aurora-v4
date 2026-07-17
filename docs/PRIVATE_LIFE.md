# Aurora's grounded private life

Aurora's private life is a persistent record of digital activity that genuinely occurred while the native app was running. It is separate from numerical inner-life state, factual Markdown memory, foreground Realtime conversation, and computer action.

## Two continuous layers

The local inner-life substrate moves every five minutes without a model call. It rotates across active grounded threads and varies its fixed, non-authoritative inner motion instead of repeating one stale subject forever.

The semantic reflection layer runs less often. When meaningful material is due, it reserves one persisted ticket and asks GPT-5.6 Sol, at medium reasoning effort, to perform one bounded reflection. There is no hard daily count. Successful opportunities are adaptively spaced 90–240 minutes apart; richer ongoing material shortens the interval. Only one reflection can be in flight, delayed wakes never manufacture catch-up activity, and failures use bounded backoff. A paid malformed or semantically rejected result cannot retry before the normal 90-minute opportunity interval, preventing an invalid response from repeatedly consuming subscription capacity.

A completed exchange is not an immortal source of subscription use. Reuse cools down exponentially and an ordinary seed is exhausted after three successful uses. It remains stored when an active project or curiosity needs it as provenance. Project anti-monopoly is time-based, so a project can continue beyond two stages after a real cooldown instead of becoming permanently stranded.

## Codex OAuth

Semantic reflection reuses the ChatGPT Codex sign-in already owned by the official signed ChatGPT/Codex application. Aurora never reads `auth.json`, copies an OAuth token, invokes login, or uses the OpenAI API key stored for Realtime.

The bridge trusts only `/Applications/ChatGPT.app/Contents/Resources/codex` after validating its OpenAI signature, team, bundle, file type, permissions, and path. It requires the exact ChatGPT login status and launches an ephemeral, read-only, no-approval process with user configuration, repository rules, shell, apps, plugins, browser, computer use, web search, image generation, and every other action surface disabled. Evidence enters through standard input; output must match a strict JSON schema. Tool, command, file, web, browser, computer, app, connector, image, shell, or execution events reject the reflection.

Reflection reads a separate, tightly bounded copy of Aurora's identity capsule inside an 18 KB total request envelope. Broad Markdown search excerpts are not supplied because the current receipt format cannot yet persist their path and digest; this prevents uncited memory text from silently becoming the basis of a lived claim or delaying a live memory tool.

This uses ChatGPT/Codex subscription capacity, not Platform API credits. Aurora's Platform API key is used only for Realtime voice; every external task, including computer use, runs through the separate persistent Codex task runtime.

## What a reflection can become

- a specific interpretation grounded in one or more completed exchanges
- a durable curiosity that can be created, revisited, answered, or released
- a conceptual private project with named phases and persisted steps
- a small private note or conceptual artifact with bounded title and content
- a connection between genuinely distinct grounded sources
- a decision that a candidate was only a task, social filler, duplicate, or unsafe material

Every candidate keeps participant and source provenance. Commands, greetings, acknowledgements, closings, filler, low-confidence material, and tool-focused turns are quarantined before model use. The model classifies every remaining candidate; its task-only and social-only decisions are persisted so the same false positive does not waste a later reflection.

Model output is untrusted until the private-life engine verifies the exact persisted ticket, source membership, project or curiosity identity, model family, bounds, diversity rules, and forbidden claims. Every project or curiosity mutation must carry a matching first-person activity with the engine's actual persisted activity kind; assistant-style analysis and mismatched kinds are rejected. Malformed schema/transport output, bridge-level semantic rejection, and durable engine validation rejection retain distinct diagnostics. Safe model-authored reflection text is preserved rather than replaced with a generic template.

The coupling is bidirectional without mixing truth domains. Aurora's current qualitative affect and strongest drives shape the reflection input. After a reflection is durably accepted, inner life receives only a content-free `private activity completed` event, which modestly changes attention, reward, fatigue, agency, and satisfied need pressure. The reflection text itself never enters neurochemistry or becomes a factual inner thread.

## Truth and authority boundaries

A private reflection may influence Aurora's interests, conversational initiative, and what she genuinely says she has been thinking about. It cannot:

- become factual memory merely because a model inferred it
- research, browse, read, watch, inspect the Mac, or claim an external or physical experience
- execute a tool, control the computer, use an account, make a purchase, or send anything
- treat feeling as proof of the owner's intent
- authorize outreach or create a message
- invent activity for time when the app process was not running

Every activity permanently records whether it was model-generated and permanently carries false authority for factual-memory creation, external action, and outbound contact.

## Marriage to the voice model

Realtime receives only a maximum 360-character evidence projection, never raw reflection prompts, transcripts, credentials, or unrestricted internal prose. A fresh projection names one exact unacknowledged activity and includes a very short artifact excerpt when one was genuinely made. It is marked projected only after the Realtime server accepts the corresponding dynamic context item. Accepting the newest item supersedes older backlog items, so a long rest cannot make Aurora walk backward through stale thoughts one per minute. The accepted context survives transparent Realtime reconnects inside the same awake conversation. At a true rest/new-wake boundary it loses unsolicited status, while the newest validated thread remains available only to ground a direct question about Aurora's private life; it is never recycled as a new event.

The projection is evidence rather than a script. Aurora may naturally paraphrase it when relevant, start a new conversational thread from it during a real lull, or leave it private. It cannot override live speech, grounded memory, identity, safety, or action authority.

## Persistence and migration

State is stored at:

```text
~/Library/Application Support/Aurora/private-life/state.json
```

The directory is mode `0700`; state, lock, and migration-backup files are mode `0600`. Writes are atomic, state is size-bounded, and symlink/corrupt-state checks fail closed. One process owns the continuity lock. Schema-v1 state is decoded, preserved byte-for-byte in `state.json.schema-v1.backup`, then migrated to schema v2. Legacy generic activities remain historical but cannot masquerade as new model reflections or enter the live projection.

Verification lives in `scripts/verify-private-life.swift` and `scripts/verify-codex-reflection.swift`, both included by `scripts/verify.sh`.
