# Running a Mac as an always-on server

`teaway` supplies the reversible power-control layer for a headless Mac,
MacBook server, Mac mini home server, homelab node, or long-running workstation.
It does not configure or supervise the services that run on the machine.

## Before enabling

Confirm each item independently:

1. The Mac runs macOS 13 or later.
2. Remote Login, Screen Sharing, a VPN, or another access method is already
   configured and tested from a second device.
3. Required workloads start independently of the current terminal session—for
   example through launchd, a service manager, a CI runner, or a documented
   manual procedure.
4. The Mac is stationary on a hard, open, well-ventilated surface. AC power is
   recommended for unattended use so the battery cannot silently drain, but
   `teaway on` works the same on battery or AC.
5. Backups, monitoring, network recovery, and power-loss behavior are understood.
6. No other tool is expected to own the same `disablesleep` setting.

A UPS can improve availability for a desktop Mac or a laptop with a degraded
battery, but it is outside `teaway` and must be tested separately.

## Initial setup

Install and inspect the baseline before changing anything:

```sh
brew install soundadam/tap/teaway
teaway version
teaway auth status
teaway status
```

For a trusted single-user account, register the narrow helper once:

```sh
teaway auth register
teaway auth status
```

Registration installs a root-owned helper and a per-user sudoers rule. It does
not create a daemon or network listener. Shared accounts should remain in
ordinary sudo mode.

## Start server-style operation

```sh
teaway on
teaway status
```

A healthy result reports `Awake mode: On — managed by teaway` and
`disablesleep=1`. `status` also reports the current power source; that value is
informational. Verify remote reachability again before closing a laptop lid.

For a guided client, run `teaway` with no arguments.

`teaway on` is idempotent. Running it again does not create a second ownership
record or overwrite the saved baseline.

## Stop and restore

```sh
teaway off
teaway status
```

`off` restores the exact value observed before the owned `on` transition. When
there is no owned record, it refuses to adopt or clear an external live value.

## Delayed shutdown

```sh
teaway shutdown after 2h
```

The command prints the absolute local deadline, hostname, owner, and action ID.
The schedule is committed only after macOS reports the exact event.

Inspect or cancel it with:

```sh
teaway shutdown status
teaway shutdown cancel
```

Only one `teaway` shutdown may exist. Apple wake events and schedules owned by
other software are left untouched.

## Daily checks

For an unattended or remote Mac, monitor at least:

- `teaway status` and `teaway auth status`;
- power source and battery health;
- thermal state and physical ventilation;
- free disk space and backup freshness;
- remote-access reachability;
- service health and restart behavior; and
- pending macOS maintenance or reboot requirements.

`teaway` intentionally has no polling daemon or telemetry. Integrate its
read-only status output into your own local monitoring only when that system can
handle command failure and distinguish `off`, `external`, and recovery states.

## Upgrade procedure

```sh
brew update
brew upgrade teaway
teaway version
teaway auth status
```

If the registered helper version differs from the CLI, refresh it with visible
administrator authorization:

```sh
teaway auth register
teaway auth status
```

Upgrading does not silently replace a root helper. This is deliberate: the
machine-level trust decision remains visible.

## Recovery

Start with read-only inspection:

```sh
teaway status
teaway shutdown status
teaway auth status
```

- `needs-recovery` means a transaction journal remains after an interrupted or
  unverifiable operation. Do not delete state files manually; use the matching
  `off` or `shutdown cancel` command and re-check macOS state.
- `external` means the live sleep setting is enabled without a native owned
  record. `teaway off` will leave it unchanged.
- `needs-repair` in authorization means the helper/rule pair is incomplete,
  unauthorized, or version-mismatched. Re-run registration or unregister it.

For emergency inspection, `/usr/bin/pmset -g` and `/usr/bin/pmset -g sched` are
read-only. Avoid broad cancellation commands because they may remove events
owned by macOS or other applications.

## What teaway does not make highly available

Disabling sleep is only one part of server operation. `teaway` cannot guarantee:

- network connectivity or remote-login configuration;
- process startup, restart, or health supervision;
- filesystem integrity, backups, or storage capacity;
- recovery from power loss, OS crashes, forced restarts, or hardware failure;
- safe thermals in a confined location; or
- uninterrupted operation during macOS updates.

Use the smallest set of additional tools required for those responsibilities,
and test failure recovery before relying on the Mac remotely.
