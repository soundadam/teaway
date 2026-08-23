# teaway

[![CI](https://github.com/soundadam/teaway/actions/workflows/ci.yml/badge.svg)](https://github.com/soundadam/teaway/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/soundadam/teaway)](https://github.com/soundadam/teaway/releases/latest)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black)](https://github.com/soundadam/teaway#requirements)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> **Run a Mac like an always-on server.**

Product page: [soundadam.com/projects/teaway](https://soundadam.com/projects/teaway/)

`teaway` is a focused macOS command-line tool for headless and long-running Mac
setups. It keeps a Mac working when normal sleep would interrupt it—including a
MacBook with the lid closed—then restores the exact power setting it owned. It
can also schedule and precisely cancel one delayed shutdown.

Use it for a spare MacBook build box, a Mac mini home server, a homelab node,
long backups or media jobs, and self-hosted services that must survive the end
of an interactive session. `teaway` manages the power lifecycle only; SSH,
Screen Sharing, networking, service supervision, and the workload itself remain
under your control.

## Why teaway

- **Closed-lid and headless operation.** Manages the macOS `disablesleep` state
  instead of merely keeping one foreground process active.
- **Reversible ownership.** Records the value observed before `on` and restores
  only the state that `teaway` owns.
- **Safe repeated use.** An optional per-user helper removes repeated password
  prompts without granting a shell or arbitrary `pmset` access.
- **Explicit shutdowns.** Resolves a duration to an absolute local deadline,
  verifies the system event, and cancels only the matching `teaway` event.
- **No background control plane.** No daemon, listener, account, telemetry,
  remote API, workload inspection, or cloud dependency.

## Quick start

```sh
brew install soundadam/tap/teaway

# One visible administrator authorization, then narrow passwordless operations.
teaway auth register

# Open the client, or keep the Mac available from a script.
teaway
teaway on
teaway status

# Optional: shut down after a bounded delay.
teaway shutdown after 2h
teaway shutdown status
teaway shutdown cancel

# Restore the exact pre-teaway sleep setting.
teaway off
```

Before closing a laptop lid, verify that the Mac is stationary, well
ventilated, and reachable through the remote-access method you configured.
Remaining on AC power is still a good idea for unattended use because the
battery will drain, but `teaway on` works the same on battery or AC.
`teaway` deliberately does not configure Remote Login, Screen Sharing, VPNs,
firewalls, DNS, or service startup.

## Commands

| Command | Effect |
| --- | --- |
| `teaway` | Open the client |
| `teaway status` | Read power source, observed sleep state, ownership, and shutdown state |
| `teaway on` | Snapshot the current state, disable sleep, verify, and record ownership |
| `teaway off` | Restore only the exact state owned by `teaway` |
| `teaway shutdown after 30m` | Schedule one shutdown after an explicit duration |
| `teaway shutdown status` | Reconcile the private record with macOS scheduled power events |
| `teaway shutdown cancel` | Cancel only the exact `teaway`-owned shutdown |
| `teaway auth status` | Inspect ordinary/registered authorization and sudo Touch ID configuration |
| `teaway auth register` | Set up narrow passwordless controls after one visible administrator check |
| `teaway auth unregister` | Remove the helper and its sudoers rule |
| `teaway version` | Print the installed version |

Durations accept `m`, `h`, and `d` units. Delayed shutdowns are bounded between
10 minutes and 7 days.

Human-facing output explains results in plain language while retaining relevant
native settings for diagnosis. The client stays open across actions and does
not add a daemon or background process. When passwordless controls are not
ready, the next privileged action can set them up before macOS prompts.

## Operating model

### Awake state

`teaway on` performs a small transaction:

1. Inspect the current macOS sleep setting.
2. Persist the exact pre-change value in private state.
3. Apply `disablesleep=1` through a fixed privileged operation.
4. Re-read macOS state and report success only after verification.

`teaway off` reverses that transaction. With no owned record it is a no-op,
even when the live value is already `1`; another tool or administrator may own
that setting. This prevents `teaway` from silently undoing external policy.

### Authorization

Without registration, mutations use ordinary `sudo` and preserve the system
credential timestamp. With `teaway auth register`, the current executable is
copied to a root-owned per-user helper and a validated sudoers rule permits only:

- `disablesleep` values `0` and `1`;
- one canonical `teaway` shutdown schedule; and
- exact cancellation of a matching canonical or recorded legacy event.

The rule does not permit arbitrary CLI commands, arbitrary `pmset` arguments,
or a shell. Registration is an account-level trust decision and is intended for
a trusted single-user macOS account. Re-run `teaway auth register` after an
upgrade when `auth status` reports a helper version mismatch. Registration tells
you before invoking `sudo` that the one-time macOS password entry is hidden;
teaway never reads or stores it.

### Shutdown ownership

Shutdown scheduling is independent of `on` and `off`. `teaway off` never
silently cancels a shutdown. The system schedule is authoritative, while the
private journal supplies the exact owner and tuple needed for safe recovery.
macOS 26 two-digit/four-digit schedule rendering is normalized before exact
comparison. If macOS no longer reports the recorded event, `status` clears the
stale journal entry and a later `shutdown after` can proceed normally.

## Requirements

- macOS 13 Ventura or later
- Apple silicon or Intel Mac supported by the installed macOS release
- Administrator authorization for power mutations or helper registration

## Safety and availability limits

A MacBook has less cooling headroom with its lid closed. Keep the machine on a
hard, open surface; never run it closed inside a bag, drawer, or other confined
space. `teaway` does not override thermal protection and cannot prevent power
loss, kernel failure, forced updates, hardware faults, or a network outage.

Treat a laptop or desktop Mac as a small server only after configuring the rest
of the availability stack: remote access, service startup, backups, monitoring,
stable networking, and—where needed—a UPS. See
[Running a Mac as an always-on server](docs/operations.md).

## Install and upgrade

```sh
brew install soundadam/tap/teaway
brew update
brew upgrade teaway
```

The Homebrew Formula builds the `teaway` command from the immutable GitHub
source tag. Public releases do not ship an unnotarized prebuilt executable.
To work on the source tree, see [Contributing](CONTRIBUTING.md).

Homebrew installs only `teaway`. The shorter `tea` name belongs to another
Homebrew package and may be used only as a personal shell alias or shim.

## Documentation

Published docs: [teaway.mintlify.app](https://teaway.mintlify.app).
The source is [`docs/`](docs/README.md).

- [Start](docs/index.mdx)
- [Operating a Mac as an always-on server](docs/operations.md)
- [Authorization model](docs/authorization.md)
- [Security model](docs/security.md)
- [Migration from an older personal script](docs/migration.md)
- [Development](docs/development.mdx)
- [Product design and boundaries](docs/product-design.md)
- [Release readiness](docs/release-readiness.md)
- [Changelog](CHANGELOG.md)
- [Contributing](CONTRIBUTING.md)
- [Security reporting](SECURITY.md)

`teaway` is distributed under the [MIT License](LICENSE).
