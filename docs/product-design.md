# teaway product design

## Positioning

`teaway` is the reversible power-control layer for operating a Mac like a small,
always-on server:

> Keep the Mac available when ordinary sleep would interrupt it, including
> closed-lid portable operation; restore the exact setting owned by the tool;
> and optionally schedule one explicit delayed shutdown.

The primary audiences are:

- a developer using a spare MacBook as a headless build or automation machine;
- a Mac mini or desktop Mac serving a homelab or self-hosted workload;
- an operator running a long backup, import, render, transfer, or media job; and
- a remote user who needs power behavior to remain independent of one terminal.

The product succeeds when the operator can answer four questions immediately:

1. Is the Mac on a supported power source?
2. Is `teaway` currently responsible for disabling sleep?
3. Can it restore the exact setting it owns?
4. Is a `teaway` shutdown scheduled, and can it cancel only that event?

## Product boundary

`teaway` owns power state, not the server workload. It does not configure SSH,
Screen Sharing, VPNs, firewalls, DNS, launchd services, containers, monitoring,
backups, or public ports. It does not decide that work is complete from process
exit, idle time, CPU usage, or network state.

This narrow boundary makes the destructive operations auditable and keeps the
CLI useful across many server and workstation setups.

## Naming contract

The publisher is `soundadam`; the repository, Homebrew Formula token, SwiftPM
product, and executable are `teaway`. Homebrew installs only `teaway` because
the `tea` token already belongs to the Gitea CLI. A user-managed local alias may
point `tea` to `teaway`, but no release creates it.

The retired `tea-away` name is accepted only where an exact historical shutdown
owner must be cancelled safely. It is not a public executable, package, or
release identity.

## Primary journey

1. Install `teaway` and inspect the baseline with `status`.
2. Optionally register the narrow per-user helper after visible authorization.
3. Run `on`; the CLI snapshots the current value, applies the new state, verifies
   it, and records ownership.
4. Verify remote reachability and allow the workload to continue independently.
5. Run `off`; the CLI restores only the owned baseline.
6. When needed, schedule one explicit delayed shutdown and cancel only its exact
   tuple.

## Public command model

```text
teaway
teaway on
teaway off
teaway status

teaway shutdown after DURATION
teaway shutdown status
teaway shutdown cancel

teaway auth status
teaway auth register
teaway auth unregister

teaway version
teaway help
```

No argument is equivalent to `status`. Durations require units and are rendered
as an absolute local deadline with timezone before confirmation. `on` remains
enabled until `off` or system power-off; shutdown scheduling is independent.

## Guarantees

- Read-only commands do not request authorization or mutate power state.
- `on` requires AC power, persists intent before mutation, and verifies the live
  state before reporting success.
- `off` restores only a matching native-owned snapshot.
- A live external `disablesleep=1` value is never adopted implicitly.
- Shutdown scheduling requires a real TTY and the complete displayed phrase.
- At most one `teaway` shutdown exists, and cancellation uses its exact tuple.
- Private state is atomic and mode-restricted.
- Privileged execution uses fixed system paths and allowlisted operations.
- Registered mode delegates narrow operations to one macOS account, never an
  arbitrary shell or arbitrary `pmset` invocation.

## 0.3.0 scope

Version 0.3.0 establishes the server-oriented release line:

- registered per-user authorization with a root-owned narrow helper;
- ordinary sudo mode that preserves the system credential timestamp;
- reversible awake ownership and fail-closed recovery journals;
- exact delayed-shutdown transactions and macOS 26 schedule normalization;
- GitHub-hosted macOS CI with read-only workflow permissions;
- source-tag distribution through GitHub and Homebrew; and
- operator, authorization, security, migration, and release documentation.

## Deferred work

Possible additions must remain opt-in and independently reversible:

- display-off timing while the lid is open;
- Low Power Mode capture and exact restoration;
- reminders for unattended closed-lid operation;
- an AC server profile covering several additional `pmset` values; and
- a signed/notarized app bundle with an XPC helper and code-signature validation.

The multi-setting server profile is intentionally excluded from the default
path because it changes unrelated system-wide policy. A future implementation
must snapshot every allowlisted value and roll back partial failure.

## Non-goals

- Workload startup, supervision, interpretation, or completion detection.
- Remote-access, credential, tunnel, firewall, or network configuration.
- Cloud control, a browser dashboard, phone app, or multi-machine controller.
- Silent installation, silent privilege broadening, or hidden PAM changes.
- Unbounded shutdown scheduling or cancellation of unrelated system events.

The preferred implementation remains the smallest trustworthy mechanism that
makes a Mac's power behavior explicit and reversible.
