# Release readiness

## Release target

Version 0.4.2 lets `teaway on` work the same on battery and AC power, and keeps
operator-facing documentation on the installed CLI. The public artifact is an
immutable source tag; the Homebrew Formula builds the executable from that
source. No unnotarized prebuilt binary is published.

## Required evidence

### Product and documentation

- README explains the server-oriented use case, quick start, safety limits, and
  the boundary between power control and workload/remote-access management.
- Operations, authorization, security, migration, product-design, contributing,
  and security-reporting documents are linked from the repository front page.
- Repository description and topics cover macOS, headless operation, homelab,
  self-hosting, sleep prevention, Swift, and Homebrew without claiming network
  or workload features.
- Version strings, changelog, release notes, tag, and Formula all equal 0.4.2.

### Native behavior

- No argument opens the guided menu; `status` is the explicit read-only status command.
- `on` captures, applies, and verifies the exact reversible awake state on
  battery or AC power.
- `off` restores only native-owned state and leaves external state unchanged.
- Default authorization preserves the sudo credential timestamp.
- Registered authorization grants only the allowlisted helper operations.
- Shutdown scheduling uses bounded durations, exact system verification, and
  compensating cancellation.
- macOS 26 four-digit schedule output is normalized to the canonical tuple.
- Failure and recovery paths retain enough state to fail closed.

### Validation

- All Swift tests pass on the release source tree.
- A release build reports `teaway 0.4.2`.
- The hidden helper rejects non-root direct execution.
- GitHub Actions passes for both push and pull-request events on a hosted macOS
  runner with read-only token permissions.
- Real hardware verifies repeated `on`/`off`, external-state preservation,
  shutdown commit/status/cancel, and final restoration to `disablesleep=0`.
- The final machine state has no `teaway` shutdown event.

### Distribution

- The annotated `v0.4.2` tag points to the merged and CI-tested main commit.
- The GitHub release describes the authorization trust decision and the need to
  refresh a stale helper after upgrades.
- The source archive SHA-256 is calculated after the tag is published.
- The personal tap Formula uses the immutable tag, exact checksum, MIT license,
  macOS 13 minimum, and read-only tests.
- A clean Homebrew source build and Formula test pass.

## Release procedure

1. Update the release branch to version 0.4.2 and complete the documentation.
2. Run local tests, release build, security invariants, and documentation checks.
3. Push the branch and require successful pull-request CI.
4. Merge the pull request into `main` and verify main CI.
5. Create and push one annotated `v0.4.2` tag.
6. Publish GitHub release notes for the tag.
7. Download the tag archive and calculate its SHA-256.
8. Update, audit, source-install, and test the `soundadam/homebrew-tap` Formula.
9. Refresh the locally registered helper and verify the final safe state.

Never publish an Apple Development-signed archive as a public binary. A future
prebuilt release requires Developer ID Application signing and notarization.
