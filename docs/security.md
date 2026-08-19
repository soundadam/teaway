# Security model

## Trust boundary

`teaway` changes macOS power behavior only after an explicit command. It has no
network listener, cloud service, telemetry, workload inspection, password
cache, setuid executable, or always-running daemon. It never reads, stores,
logs, or pipes an administrator password. Privileged operations use fixed macOS
system paths.

Read-only `status` and `version` commands must not modify power settings or
scheduled events. Homebrew tests are restricted to read-only behavior.

## Authorization boundary

### Ordinary sudo

Without registration, a mutation validates authorization with `sudo -v`,
preserves any existing credential timestamp, and invokes one fixed `pmset`
operation. The implementation does not use `sudo -k`. Authentication method
selection—including Touch ID when PAM is configured for it—belongs to macOS.
`teaway auth status` is diagnostic and never edits PAM.

### Registered helper

`teaway auth register` installs, after visible authorization:

- `/Library/PrivilegedHelperTools/com.soundadam.teaway.helper.<uid>`; and
- `/etc/sudoers.d/soundadam-teaway-<uid>`.

Both are root-owned. The sudoers rule delegates only helper version inspection,
`disablesleep` values `0` and `1`, one canonical shutdown schedule, and exact
cancellation of a canonical or recorded legacy event. It does not delegate the
public CLI, a shell, arbitrary executables, or arbitrary `pmset` arguments.

The helper validates operation name, arity, date, owner prefix, identifier
character set, and identifier length before invoking `/usr/bin/pmset` without a
shell. The CLI normalizes macOS schedule display dates, but the privileged
protocol receives only canonical `MM/dd/yy HH:mm:ss` values.

The rule trusts the entire macOS account. Any process running as that user can
invoke the allowlisted operations, so registration is inappropriate for shared
or untrusted accounts. A version mismatch fails closed until registration is
refreshed.

## Awake ownership

`on` is an owned transaction:

1. Inspect the current sleep setting.
2. Persist the exact pre-change value in private native state.
3. Authorize and apply `disablesleep=1`.
4. Verify the live state before committing ownership.

State uses an atomic mode-0700 directory and mode-0600 files. Partial failure
retains a recovery phase rather than inventing success.

`off` restores only a matching native record. A live value of `1` without that
record is external and remains unchanged. Corrupt, conflicting, or unsupported
state fails closed.

## Shutdown boundary

Shutdown uses a separate transaction. `shutdown after` accepts only bounded
explicit durations and prints the absolute deadline, timezone, hostname, owner,
and action ID.

Before and after mutation, `teaway` inspects `/usr/bin/pmset -g sched`. It rejects
existing shutdowns or conflicting owners, persists the exact tuple before the
system call, verifies the scheduled event, and attempts exact compensation if a
later commit fails. macOS 26 four-digit year rendering is normalized before
comparison with the canonical two-digit tuple.

`shutdown cancel` removes only the exact owned event. It never runs broad
commands such as `pmset cancelall` and never cancels unrelated Apple wake events.
`off` and shutdown remain independent.

## Operational boundary

Keeping a closed laptop awake reduces thermal margin. Unattended closed-lid
operation is safest on a stationary Mac with an open, well-ventilated surface.
Remaining on AC power is recommended so the battery cannot silently drain, but
`teaway` does not refuse battery power. A bag, drawer, bedding, or other
confined location is outside the supported model.

`teaway` does not guarantee availability. Network loss, power failure, storage
failure, crashes, forced updates, hardware faults, and service failure remain
outside its control.

## Installation and supply chain

The canonical repository, Formula token, SwiftPM product, and executable are
`teaway`. Homebrew installs no `tea` or `tea-away` command.

GitHub Actions runs on GitHub-hosted macOS runners with read-only token
permissions. Checkout is pinned to an immutable action commit. CI checks common
credential patterns, production `sudo -k`, package validity, tests, release
builds, and helper fail-closed behavior.

Public releases use immutable source tags. The Homebrew Formula builds from
source and verifies the exact source archive SHA-256. Apple Development-signed
local archives are not public distribution assets. Any future prebuilt binary
requires Developer ID signing, timestamping, notarization, and verification of
the final immutable asset.

## Vulnerability reporting

Do not publish suspected security vulnerabilities in a public issue. Follow the
private process in [`SECURITY.md`](../SECURITY.md).
