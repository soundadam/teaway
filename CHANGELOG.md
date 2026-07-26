# Changelog

All notable changes to `teaway` are documented here.

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
