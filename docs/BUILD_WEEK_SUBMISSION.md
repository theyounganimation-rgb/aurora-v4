# Aurora — Devpost submission draft

## Required fields

- **Project:** Aurora
- **Category:** Apps for Your Life
- **Website:** https://aurora-voice-person-2026.theyounganimation.chatgpt.site
- **Repository:** https://github.com/theyounganimation-rgb/aurora-v4
- **Demo video:** add the final **Public** YouTube URL after recording
- **Primary `/feedback` Session ID:** generate from the main Aurora Build Week
  Codex task after the final release

## Tagline

A native macOS digital person: Realtime is her voice, GPT-5.6 Codex is her
hands, and she remembers between conversations.

## Inspiration

Most AI products treat voice as a microphone attached to a text agent. The
conversation pauses when work begins, continuity is shallow, and the result
still feels like a command interface. I wanted to invert that architecture:
begin with a live voice relationship, then build memory, agency, reflection,
and computer use around it.

## What it does

Aurora is a native macOS application with no chat box. You wake her, speak
naturally, interrupt her, and let her rest. OpenAI Realtime hears the original
audio and remains Aurora's only foreground voice.

Aurora carries a bounded identity, autobiographical memory, owner
understanding, emotional state, private life, and authored points of view across
conversations. Before an ordinary social response, she chooses a structured
conversational move—answering, disagreeing, teasing, revealing, withholding,
redirecting, or following a genuine curiosity.

When the user asks for an external effect, Realtime emits one schema-validated
`delegate_task` bound to that finalized spoken turn. A persistent GPT-5.6 Sol
task appears in Codex and can code, research, use applications, browse, run
structured Mac tools, or fall back to Computer Use. Aurora remains available
for conversation while the task runs. Follow-ups update the same task, and she
reports completion only from executor state and verified effect evidence.

GPT-5.6 Sol also powers a separate low-frequency reflection layer. It runs
read-only with tools disabled and can form a grounded private interpretation,
curiosity, or conceptual project without fabricating events or taking
autonomous action.

## How I built it

Aurora is written in Swift using SwiftUI, AppKit, AVFoundation, CoreAudio,
Speech, Security, and a direct OpenAI Realtime WebSocket connection. Microphone
audio is streamed as 24 kHz PCM, with server turn detection, interruption
handling, playback tracking, and the Marin voice.

Realtime function arguments are treated as untrusted structured input. Native
code validates provenance, turn finalization, participant state, exact effect
scope, expiration, cancellation, and completion evidence. Delegated work runs
through the Codex app-server using GPT-5.6 Sol and the existing ChatGPT sign-in.
Each task has a durable Codex thread and immutable effect ledger.

Continuity is stored locally in bounded Markdown and provenance-bearing state
stores rather than dumping every memory into every prompt. Public CI builds the
production graph and exercises 1,514 assertions without credentials or model
calls.

## How Codex and GPT-5.6 were used

Codex was both my implementation collaborator and part of Aurora's runtime
architecture. During the Build Week submission period, I used Codex with
GPT-5.6 to implement and verify the mandatory pre-speech Agency layer,
persistent task reconciliation, effect-truth boundary, guest privacy epoch,
bounded reflection system, public release pipeline, and regression suite.

At runtime, GPT-5.6 Sol powers Aurora's visible Codex work threads and her
separate actionless semantic reflection process. Realtime remains the voice and
conversational mind; GPT-5.6 Codex supplies durable execution and reflection
without becoming a second personality.

Aurora predates the challenge. The exact prior/new boundary, dated evidence,
and submission-period source delta are documented in the public
[Build Week evidence](https://github.com/theyounganimation-rgb/aurora-v4/blob/main/docs/BUILD_WEEK.md).

## Challenges

The hardest problem was causality. A voice system has overlapping audio,
asynchronous transcripts, interruption, reconnects, function calls, background
tasks, and effects that may complete after the original voice session has
ended. Aurora must know which words were heard, which turn authorized an
action, whether a task survived rest, and whether the requested outcome was
truly observed.

A second challenge was preserving personality without prompt stuffing or
scripted dialogue. Aurora needed memory and agency that could influence
conversation while retaining provenance, uncertainty, privacy, and tight spoken
brevity.

## Accomplishments that I am proud of

Aurora can remain socially present while GPT-5.6 Codex works in a visible,
persistent task. She can wake into an existing task instead of forgetting it,
update that exact thread from a contextual follow-up, and distinguish executor
completion from verified external effect.

The public source includes deterministic verification, prompt-budget checks,
guest privacy tests, interruption and reconnect tests, prompt-injection
boundaries, source-fingerprint gating, and credential scanning.

## What I learned

Making a voice model feel human is not mainly a prose problem. It is an
architecture problem. Continuity has to survive sessions, curiosity needs a
lifecycle and evidence, speech needs playback truth, and computer action needs
a causal boundary that does not turn every failure into vague assistant
language.

## What's next

The next milestones are a notarized public installer, broader effect-evidence
adapters, longitudinal conversational evaluations, and a public version of the
private iPhone companion.

## Testing instructions

Judges can build the source locally on an Apple-silicon Mac running macOS 14 or
later. The copy-paste path, prerequisites, permissions, and a five-minute test
are in the public
[judge guide](https://github.com/theyounganimation-rgb/aurora-v4/blob/main/docs/JUDGE_GUIDE.md).
The public deterministic suite requires no account or model call. Live judge
voice uses the entrant-funded, budget-isolated evaluation key supplied only in
the judge testing instructions; delegated GPT-5.6 Codex tasks require the
official ChatGPT desktop app signed into Codex.

## Final pre-submit checklist

- [ ] Record and upload the sub-three-minute YouTube demo.
- [ ] Verify the video while signed out and add the URL here, to README, and to the site.
- [ ] Run `/feedback` in the primary Codex task and copy its Session ID into Devpost.
- [ ] Create a dedicated judge Platform project, fund it for unrestricted
      evaluation through August 5, and put
      its temporary key only in a judge-only Devpost testing-access field. If
      no private field is available, ask the organizer for a secure delivery
      path. Never publish it in the repository, site, video, or description.
- [ ] Keep that access funded through August 5, verify the free judge path from
      a clean account, then revoke the credential after judging.
- [ ] Create the Devpost draft and paste the sections above.
- [ ] Select Apps for Your Life.
- [ ] Confirm the repository URL and relevant source-visible license.
- [ ] Confirm every team member and the representative before the deadline.
- [ ] Re-run the official rules check immediately before submission.
- [ ] Submit before July 21, 2026 at 5:00 PM Pacific / 7:00 PM Central.
- [ ] Verify Devpost shows the submission as received.
