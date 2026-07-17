# Aurora iPhone companion

> **Release status: private companion prototype — excluded from this public release.**

The public repository contains the Mac-side wire protocol and loopback server
because they document Aurora's single-runtime audio boundary and remain part of
the macOS architecture. It does **not** contain the iOS Xcode project, iPhone
application source, private deployment configuration, signing material, device
pairing state, or network endpoints.

Accordingly, this public release does not claim to provide a buildable,
installable, or supported iPhone companion. A working private deployment
requires source and configuration that are intentionally outside the public
tree.

## Public code boundary

The included Mac code models a remote audio-and-presence surface while keeping
all cognition, memory, Realtime ownership, task execution, and private life in
the single macOS Aurora process. The protocol carries bounded audio, presence,
playback acknowledgements, and wake/rest requests; it does not move API keys,
continuity files, task prompts, or screen content to the phone.

Private routing values are configuration, not source constants:

- `AURORA_COMPANION_ALLOWED_PEERS` supplies an allow-list of peer IPv4/IPv6
  addresses.
- `AURORA_COMPANION_SERVICE_HOST` supplies the private companion service host.

Both may be injected by a private build through its process environment or
matching `Info.plist` string entries. The public defaults are empty. With no
configured peer allow-list, the production listener rejects every remote
companion connection.

## Security properties retained in public source

The Mac listener remains loopback-only. A configured private deployment must
arrive through the authenticated proxy boundary and then complete an
application-level mutual HMAC challenge using fresh nonces and a random
Keychain pairing secret. Frames are versioned, length-bounded, monotonic, and
generation-scoped. Direct loopback is available only to tests and explicitly
opted-in debug runs.

## Verification boundary

The public Mac protocol and loopback checks live in
`scripts/verify-companion.swift` and `scripts/verify-companion-server.swift`.
Device builds, iOS analysis, physical microphone/speaker tests, reconnect and
interruption tests, and off-LAN transport validation belong to the excluded
private prototype and are not public-release claims.
