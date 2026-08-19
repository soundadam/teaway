# Contributing to teaway

Contributions should preserve the project's narrow boundary: reversible macOS
power control, exact shutdown ownership, and no hidden control plane.

## Development setup

Requirements are macOS 13 or later and Swift 5.9 / Xcode 15 or later.

```sh
git clone https://github.com/soundadam/teaway.git
cd teaway
swift package dump-package >/dev/null
swift test
swift build -c release --product teaway
```

## Safety rules

- Automated tests must intercept privileged operations. CI must never mutate
  runner power settings, install the helper, or execute an actual shutdown.
- Production commands must use fixed executable paths and typed arguments.
- Do not add password reading, piping, storage, logging, or silent PAM edits.
- State changes need an owned snapshot, verification, and fail-closed recovery.
- Shutdown changes need exact owner/tuple validation and targeted compensation.
- Features outside power control—networking, workload supervision, cloud
  control, and remote-access configuration—belong in another project.

## Pull requests

Include tests for normal behavior, idempotence, partial failure, conflict, and
recovery. Update README, operations, authorization, security, product design,
and changelog material when the public contract changes.

Before opening a pull request:

```sh
git diff --check
swift test
swift build -c release --product teaway
.build/release/teaway version
```

Hardware acceptance must be deliberate, reversible, and end with
`disablesleep=0` and no `teaway` shutdown event. Prefer AC power for long
hardware runs so the battery cannot drain mid-test.
