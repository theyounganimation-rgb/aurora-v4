# Pre-Build-Week public site evidence — 2026-07-12 Pacific

Aurora existed before the OpenAI Build Week submission window opened on
July 13, 2026 at 9:00 AM Pacific. This is a source-visible record of the first
saved Aurora site version; it is not claimed as eligible Build Week work.

## Git object

```text
commit 6213d2b468dbd62563419839fe83a1dd11c5d719
tree   faa50b7fb1bd22440659e614944a2303d776a6d2
author Osiris <osiris@localhost> 1783919883 -0500
commit Osiris <osiris@localhost> 1783919883 -0500

Publish Aurora macOS beta site
```

That Unix timestamp is July 13, 2026 at 12:18:03 AM Central / July 12 at
10:18:03 PM Pacific. A clean `git archive` of the exact commit has SHA-256:

```text
7c6aa920f5834aa04f9c044378ea4c81b62b95a4921d693600100279c46c185d
```

## What version 1 already claimed

The saved page called Aurora a “Voice-first. Mac-native. Early beta” and
described all of these pre-existing capabilities:

- direct Realtime voice conversation;
- memory with continuity across app launches;
- background interests, reflections, projects, moods, and memories;
- first-run OpenAI API-key onboarding with Keychain storage;
- early permissioned Mac control that could open apps, manage windows/tabs,
  navigate the web, and work through visible screen tasks.

Representative source from that exact page:

```tsx
const capabilities = [
  { title: "Conversation, not commands", copy: "Talk naturally... responds in real time..." },
  { title: "A memory with a point of view", copy: "...carry unfinished threads forward..." },
  { title: "Hands for the Mac", copy: "...open apps, manage windows and tabs..." },
  { title: "A life between conversations", copy: "...interests, reflections, projects..." },
];
```

The original nested site history remains in the local Sites project so its Git
object and saved version can be reproduced. The obsolete unnotarized beta
archive from that page is intentionally not republished. The current entry
claims only the separately documented Build Week extension.
