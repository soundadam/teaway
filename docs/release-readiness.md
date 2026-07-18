# Release readiness

## Current state

- The product contract is lid-closed awake control plus an independent delayed
  shutdown.
- The canonical public repository, Formula token, and executable name are
  `teaway`. The Formula installs only `teaway`; `tea -> teaway` is an optional
  user-managed local alias.
- Version 0.2.2 is the first MIT-licensed source release. Its public commands are `on`,
  `off`, `status`, `shutdown after`, `shutdown status`, and `shutdown cancel`.
- The signed 0.2.0 archive is rejected session-prototype evidence. The signed
  0.2.1 `tea-away` archive is a corrected but historical naming candidate.
  Neither is a release candidate, may be renamed as 0.2.2, published, or
  referenced by the `teaway` Formula.
- The legacy zsh executable and its existing archives are not public assets.
- The development packaging workflow performs no release, tag, tap mutation,
  credential export, or actual power operation.

## Required 0.2.2 evidence

### Native behavior

- No argument and `status` are read-only and show the observed
  `SleepDisabled` value, power source, native ownership state, and
  `teaway`-owned shutdown state.
- `on` captures the exact pre-change value, applies and verifies the awake
  setting, and rolls back or preserves recovery state after partial failure.
- `off` restores only a matching native-owned snapshot. With no owned snapshot
  it is a tested no-op, including when the machine reports
  `SleepDisabled=1` from a legacy or external owner.
- `shutdown after` supports bounded explicit durations, typed confirmation,
  exact scheduling verification, and failed-save compensation.
- `shutdown status` reconciles private state with macOS without mutation.
- `shutdown cancel` cancels only the exact `teaway`-owned event and fails closed
  on conflicts or unverifiable state.
- `off` and shutdown remain independent operations.
- Reminder, display-off, Low Power Mode, and server-profile commands are absent
  from the 0.2.2 public interface.

### Naming and local alias

- SwiftPM product, binary, archive, manifest, Formula token, installed command,
  help output, and examples consistently use `teaway`.
- No release or Formula installs `tea` or `tea-away`.
- If the owner wants the short command after cutover, `tea -> teaway` is created
  only in personal local configuration and is tested separately from Homebrew.
- The 0.2.1 `tea-away` artifact remains visibly historical and cannot satisfy
  any 0.2.2 release check.

### Migration and real hardware

- Any pre-existing `SleepDisabled=1` state remains legacy or external, not
  adopted by native `teaway`.
- Before native cutover, the owner runs the legacy script's `off` command by
  its full path and verifies the baseline with `teaway status`.
- The local `tea` alias is not repointed until that restoration is complete.
  The legacy script remains the explicit rollback path until migration passes.
- Native code never imports or deletes legacy snapshot files; the 0.2.2
  migration test follows the documented manual handoff.
- A disposable supported Mac verifies lid-closed workload continuity, exact
  `off` restoration, AC and battery reporting, reboot behavior, delayed
  shutdown, status reconciliation, and exact cancellation.
- Automated tests continue to intercept every privileged operation. Real power
  tests are deliberate manual acceptance, never packaging side effects.

### Build and packaging

- `TeaAwayVersion.current`, documentation examples, archive name, manifest,
  Formula tag, and Homebrew-reported version all equal 0.2.2.
- SwiftPM and the source Formula retain the same macOS and Swift/Xcode minimums.
- The local development archive contains only the corrected `teaway` executable
  and manifest, is signed with the selected Apple Development identity and
  hardened runtime, round-trips successfully, reports 0.2.2, and has a verified
  checksum.
- The archive manifest states `local-development-only`, `notarized=false`, and
  `homebrew_public_asset=false`.
- The Formula is named `teaway`, has no workload-tool dependency, and invokes
  only read-only `version` and `status` commands in its test.
- The public source tree excludes the legacy zsh executable and retired Formula.

## Remaining validation

1. Complete the migration and real-hardware acceptance above.
2. Add macOS CI for future releases.
3. For any future public prebuilt binary, obtain Developer ID Application and
   complete timestamping and notarization. Apple Development is insufficient.

## Release order

1. Test the source tree and create one annotated immutable 0.2.2 tag.
2. Download the exact tag archive and calculate its SHA-256.
3. Render, audit, and install-test the fully qualified `teaway` Formula.
4. Run the legacy restoration and real-hardware migration acceptance separately.
5. Only after migration succeeds, optionally create a local `tea -> teaway`
   alias outside Homebrew.

Never use the Apple Development archive as a public source asset. Never publish
or relabel the rejected 0.2.0 archive, the historical 0.2.1 `tea-away` archive,
or an existing legacy `tea-0.1.0` archive as a `teaway` release.
