# Aurora V4 judge guide

This path builds Aurora locally from the public source. It does not require a
Developer ID certificate, a downloaded binary, sample personal data, or a
pre-existing Aurora/OpenClaw installation.

## Platform and accounts

- Apple-silicon Mac running macOS 14 or later
- Xcode Command Line Tools with Swift 6 (`xcode-select --install` if absent)
- the dedicated evaluation Platform API key supplied in the judge-only testing
  instructions (a reviewer may use their own key instead if they prefer)
- microphone access
- required for the GPT-5.6 task/reflection demo: the official ChatGPT desktop
  app installed in `/Applications`, opened and left running, with Codex signed
  in using ChatGPT

Realtime conversation remains usable without ChatGPT/Codex; only GPT-5.6
reflection and delegated work require that second local runtime.

Aurora stores the Platform key only in macOS Keychain. The key is used for the
Realtime voice connection, not for delegated Codex tasks. A fresh install
creates private starter continuity files and does not invent prior history.
The entrant-funded evaluation key must remain available through August 5,
2026, use a dedicated budget-isolated project with enough credit for
unrestricted judging, and be revoked after judging.

## Build from a fresh clone

```bash
git clone https://github.com/theyounganimation-rgb/aurora-v4.git
cd aurora-v4
./scripts/verify-ci.sh
AURORA_SIGNING_IDENTITY=- ./scripts/build-app.sh release
```

The explicit `-` creates an ad-hoc local build for evaluation. Because the app
is compiled on the reviewer's own Mac, this avoids distributing an
unnotarized development-signed binary. The normal packager uses a stable local
certificate when one is available.

On first launch Aurora creates `~/Documents/Aurora Projects` as the safe default
workspace for project and research tasks. An exact absolute workspace supplied
in the authorized voice request still takes precedence.

Before opening Aurora for the full task demo, open the official ChatGPT app,
sign into Codex using ChatGPT, and leave ChatGPT running. Then launch Aurora:

```bash
open -a ChatGPT
open "$HOME/Applications/Aurora.app"
```

Aurora displays a small, non-blocking Codex readiness state during onboarding
and while resting. If ChatGPT was opened after Aurora, press **Check again**;
the shared daemon is safely re-probed without starting a model turn.

## First launch

1. Enter the name Aurora should use for the reviewer.
2. Paste the evaluation OpenAI Platform API key from the judge-only testing
   instructions into Aurora's native onboarding view. The website never
   receives it.
3. Allow Microphone and Speech Recognition when macOS asks.
4. Press Talk or say “Hey Aurora.”

Aurora itself does not request Accessibility, Screen Recording, Calendar,
Reminders, mail, or broad Automation access. When a requested task needs a Mac
capability, Codex and macOS own the relevant permission boundary.

## Five-minute functional test

### Realtime voice

Say:

> Hey Aurora. What should I know about the way you remember a conversation?

Interrupt once while she is speaking, then continue naturally. The orb should
return to listening and the replacement turn should win.

### Persistent GPT-5.6 Codex task

With ChatGPT/Codex signed in, say:

> Create a folder called Aurora Judge Test on my Desktop. Put a one-page HTML file in it that says “Aurora was here,” and open it when it is ready.

Aurora should acknowledge once and remain conversational. A visible Codex task
should appear. Rest Aurora, wake her, and ask:

> Are you still working on the page?

She should use the durable task state rather than guessing. Completion should
be reported only after the requested effect is observed.

### Contextual update

Say:

> Make that sentence violet instead.

The update should steer the same task context rather than starting an unrelated
goal.

## Deterministic evaluation without credentials

The complete public CI gate uses local fakes and temporary state. It exercises
the production build, Agency, continuity, owner understanding, private life,
guest privacy, task authorization and reconciliation, Realtime interruption,
prompt budgets, recovery, and prompt-injection boundaries without calling a
model:

```bash
./scripts/verify-ci.sh
```

## Expected limitations

- There is no notarized public installer in this release.
- Realtime judge usage is covered by the entrant-funded evaluation project
  when the supplied testing credential is used.
- GPT-5.6 reflection and task work require a ChatGPT/Codex sign-in.
- A fresh local session trusts the currently logged-in Mac user. Speaker
  provenance is a causal session boundary, not voice biometrics; do not leave
  consequential voice control unattended.
- Semantic private reflection is intentionally low-frequency and may not occur
  during a short fresh-install test.
- The private iPhone companion is not part of the public submission.
- This is a digital-person architecture and simulation, not a claim that
  consciousness has been demonstrated.
