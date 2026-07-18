# Aurora working computer-control baseline — 2026-07-15

This restore point captures an installed build that the owner confirmed was usable and successfully completed every requested computer task in the most recent live test. Preserve it before changing personhood, Markdown continuity, voice behavior, or settings UI.

## Verified identity

- Source fingerprint: `697e436dde6f8225beaa5ff5a12d516f5a7a1f3f01a6c58ffdd5f0fb826b3cea`
- Source archive SHA-256: `7da4467a059a7254df735896c2296c5eff15166b0519524d26bac0042eb0bbd0`
- Signed executable SHA-256: `8018a9344cf78c7afbbd317889ed646f0a96011bba33273990297699afb6dd8d`
- App archive SHA-256: `a650a4b393fdf67cf0065a49198496639e4baefe8b074ad0fa6e15535b5c4cda`
- Bundle identifier: `ai.aurora.voice`
- Signing identity: intentionally omitted from public source
- Team identifier: intentionally omitted from public source

## Protected artifacts

The matching baseline directory is stored at:

`~/Library/Application Support/Aurora/baselines/2026-07-15-working-computer-control/`

It contains:

- `aurora-source.tar.gz` — source excluding derived builds, distribution output, and unrelated generated site output.
- `Aurora.app.zip` — the signed, runnable native app.
- `Aurora.build-receipt.plist` — source/build identity binding.
- `delegate-task-state.json` — task continuity at capture time.
- `inner-life-state.json` — inner-life state at capture time.
- `private-life-state.json` — private-life state at capture time.
- this manifest.

## Restore rule

Do not restore individual source files piecemeal. Stop Aurora, preserve the current state separately, expand the complete source archive, install the saved signed app archive, restore the matching build receipt, and run the installed-app verification suite before launching it. The state snapshots are optional and should only be restored when deliberately returning Aurora's continuity to this exact moment.

This baseline is the regression floor: later personhood and UI work must keep the existing computer-control suites passing.
