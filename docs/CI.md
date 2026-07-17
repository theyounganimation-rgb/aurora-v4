# Deterministic CI

`scripts/verify-ci.sh` runs Aurora's production Swift build and the complete
deterministic source-verification suite on a GitHub macOS runner. The suite
covers continuity, companion protocol boundaries, private life, owner
understanding, agency, conversation routing, Codex task reconciliation,
delegation, Realtime continuations, provenance, and the personhood prompt
budget. Runtime integrations are exercised with local fakes and temporary
state; no model request is made.

Before that suite starts, `scripts/verify-public-release.sh` inspects the exact
Git-tracked tree and rejects private project directories, packaged apps,
archives, signing material, personal machine/network identifiers, and
credential-like literals.

CI deliberately excludes the signed ChatGPT/Codex account handshake, live
Realtime conversation probe, microphone and camera access, paired-iPhone
checks, installed-app screen control, code signing, and device installation.
Those depend on private accounts, hardware, or an interactive desktop and
remain local release checks.

Run the same public check locally with:

```bash
./scripts/verify-ci.sh
```

`scripts/verify.sh` keeps the signed account handshake enabled by default for
the private local release gate.
