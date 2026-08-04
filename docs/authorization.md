# Authorization model

## Goals

Administrator privileges are required only for the `pmset` mutations that
change sleep behavior or create/cancel one exact delayed shutdown. Read-only
status and version commands remain unprivileged.

The design provides:

1. ordinary `sudo`, with the system credential cache preserved; and
2. an optional explicitly registered per-user helper.

Neither mode reads, stores, transmits, or logs an administrator password.

## Default mode: ordinary sudo

For a mutation, an unregistered installation:

1. runs `sudo -v` interactively;
2. rechecks safety preconditions that may have changed during authentication;
3. invokes one fixed `/usr/bin/pmset` operation through `sudo`; and
4. verifies the resulting macOS state.

The implementation never invokes `sudo -k`. Touch ID is available only when the
administrator has enabled `pam_tid.so` for sudo. `teaway auth status` reports an
active rule when it can read one, but never changes PAM configuration.

## Registered mode

`teaway auth register` requests visible administrator authorization and installs:

```text
/Library/PrivilegedHelperTools/com.soundadam.teaway.helper.<uid>
/etc/sudoers.d/soundadam-teaway-<uid>
```

The helper is a root-owned copy of the exact executable that performed
registration. The sudoers rule is validated before and after installation. The
CLI checks that the root helper reports the same `teaway` version before using
registered mode.

Before macOS asks for authorization, the CLI explains that account-password
input is hidden and handled by `sudo`; teaway never reads or stores it. This
single visible administrator check installs the narrow rule so later registered
mutations do not ask for a password. The guided menu exposes the same setup when
registration is absent or needs repair.

Registered mutations use `sudo -n` and do not prompt for a password or Touch ID
while the installation remains healthy.

## Delegated operations

The sudoers rule permits only:

```text
version
set-disablesleep 0
set-disablesleep 1
schedule-shutdown MM/DD/YY HH:MM:SS teaway:<identifier>
cancel-shutdown MM/DD/YY HH:MM:SS teaway:<identifier>
cancel-shutdown MM/DD/YY HH:MM:SS tea-away:<legacy-identifier>
```

A hidden root-only `probe` parser case exists for internal diagnostics but is
not included in the passwordless sudoers rule.

The helper validates exact arity, allowlisted operation, canonical two-digit
year date round trips, owner prefix, and a bounded ASCII alphanumeric/hyphen
identifier. It then invokes `/usr/bin/pmset` without a shell. Unsupported,
malformed, or extra arguments fail closed.

macOS may display scheduled events with a four-digit year. The unprivileged CLI
normalizes that display to the canonical two-digit tuple before requesting an
exact helper cancellation; the root helper does not accept ambiguous display
formats directly.

## Account-level risk

The sudoers rule identifies a macOS user, not a terminal or calling binary.
After registration, any process running as that user can disable sleep or create
and cancel a conforming `teaway` shutdown. It still cannot run a shell or pass
arbitrary `pmset` arguments.

Use registered mode only on a trusted single-user account. Shared or untrusted
accounts should use ordinary sudo.

## Upgrade, repair, and removal

```sh
teaway auth status
teaway auth register
teaway auth unregister
```

Status is:

- `unregistered` when both machine-level files are absent;
- `registered` when the helper is authorized and version-matched; or
- `needs-repair` when installation is partial, unauthorized, ignored, or stale.

An upgrade may intentionally produce a version mismatch. Re-running `register`
replaces the helper after visible authorization. `unregister` removes the helper
and sudoers rule using ordinary administrator authorization.

## Future app-bundle boundary

A signed and notarized app bundle could use a launchd/XPC privileged helper and
validate code signatures at the connection boundary. A source-built Homebrew
CLI has no stable Developer ID identity and therefore uses the explicit per-user
sudoers boundary described here. The two models are not equivalent.
