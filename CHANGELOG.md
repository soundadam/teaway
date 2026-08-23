# Changelog

All notable changes to `teaway` are documented here.

## [Unreleased]

### Fixed

- Drew the guided menu on an alternate screen so the action prompt is not
  painted twice and leftover status-box borders do not remain after a
  `state.json` ownership repair.

### Changed

- Published operator docs from `docs/` to [teaway.mintlify.app](https://teaway.mintlify.app).
- Made the TUI a session client: it stays open after an action, drops the
  Refresh command, and shows only the status lines that currently matter.
- Deprecated `teaway tui` and `teaway interactive`; no-argument `teaway` is
  the client.
- Stopped reading `TEA_STATE_DIR`, `TEA_AWAY_STATE_DIR`, and sibling
  `tea-away` state files. Historical `tea-away:` shutdown owners remain
  cancellable.
- Asked to set up or repair passwordless controls immediately before a
  privileged TUI action, instead of waiting for a later sudo prompt.
- Replaced the shutdown delay text field with a stepped 10-minute-to-7-day
  picker and a custom-duration fallback.
- Replaced the Swift CLI with a Go cobra command tree and a Charm TUI
  (`huh` + `lipgloss`) so `teaway` with no arguments is a guided menu instead
  of a numbered prompt.
- Refused to run the user-facing CLI as root, and explained how to reclaim a
  `state.json` that became unreadable after `sudo teaway`.

## [0.4.2] - 2026-08-19

### Changed

- Allowed `teaway on` on battery and AC power alike. Status still reports the
  current power source, but it is no longer a gate.
- Kept operator-facing documentation on the `teaway` command. Implementation
  language details stay in contributor and supply-chain docs.

## [0.4.1] - 2026-08-05

### Changed

- Made passwordless helper setup discoverable from the guided menu and explain
  before macOS authorization that password entry is hidden, used once, and
  never read or stored by teaway.

## [0.4.0] - 2026-08-05

### Changed

- Made status and action results more approachable while retaining native power
  values where they help diagnosis.
- Added `teaway interactive` (and `teaway tui`) as a guided menu over the same
  bounded power and shutdown operations; it exits after completing one action.
- Made the no-argument `teaway` entry point open that guided menu; explicit
  `teaway status` remains available for non-interactive status output.
- Removed the repeated remote-reachability warning from `teaway on`; reachability
  remains an operator preflight documented in the operating guide.
- Removed the long typed shutdown confirmation; the explicit bounded command now
  schedules directly and still verifies the exact macOS event.

### Fixed

- Reconciled stale shutdown journal entries when macOS no longer reports their
  owned event, so they no longer block a later shutdown.
- Made the rendered Homebrew Formula tests independent of physical
  `disablesleep` reporting and existing helper registration state.

## [0.3.0] - 2026-07-26

### Added

- Optional `teaway auth register`, `status`, and `unregister` commands.
- A root-owned per-user helper with a narrow passwordless sudoers policy.
- macOS 26 scheduled-power-event parsing and two/four-digit year normalization.
- GitHub-hosted macOS CI for tests, release builds, security invariants, and
  helper fail-closed behavior.
- Server-oriented operations, authorization, security, migration, and release
  documentation.

### Changed

- Positioned the project for headless, homelab, self-hosted, and long-running
  Mac operation.
- Ordinary privileged operations preserve the existing sudo credential cache
  rather than forcing a new prompt.
- Shutdown verification and cancellation compare a canonical exact tuple even
  when macOS changes the displayed year width.

### Security

- Registered mode delegates only fixed sleep and exact shutdown operations; it
  does not grant arbitrary `pmset`, public CLI, or shell execution.
- Stale or partial helper installations fail closed.

## [0.2.3] - 2026-07-26

- Avoided creating an absent retired state directory during default locking.
- Formalized `soundadam` as publisher and `teaway` as the canonical repository,
  Formula, and executable identity.

## [0.2.2] - 2026-07-18

- Established the MIT-licensed native Swift source release line.
