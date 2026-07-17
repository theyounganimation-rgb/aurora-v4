# Security and privacy

Aurora's public repository intentionally excludes credentials, signed builds,
personal continuity data, runtime logs, private network endpoints, device
identifiers, and the native iPhone companion project.

Before each public release, run:

```bash
./scripts/verify-public-release.sh
./scripts/verify-ci.sh
```

The first command scans the exact Git-tracked tree for prohibited artifacts,
personal machine identifiers, private network values, and credential-like
literals. The second runs deterministic architecture and regression checks.
Live account, audio, signed-app, and physical-device checks remain separate
local release gates.

Do not open a public issue containing an API key, OAuth token, pairing secret,
private memory, transcript, screenshot, network address, or local log. Report a
potential vulnerability privately to
[theyounganimation@gmail.com](mailto:theyounganimation@gmail.com) with the
minimum information needed to reproduce it.
