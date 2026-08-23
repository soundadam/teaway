# teaway

[![CI](https://github.com/soundadam/teaway/actions/workflows/ci.yml/badge.svg)](https://github.com/soundadam/teaway/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/soundadam/teaway)](https://github.com/soundadam/teaway/releases/latest)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black)](https://github.com/soundadam/teaway#requirements)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> **Run a Mac like an always-on server.**

Product page: [soundadam.com/projects/teaway](https://soundadam.com/projects/teaway/)

`teaway` keeps a Mac working when ordinary sleep would interrupt it—including a
MacBook with the lid closed—then restores the exact power setting it owned. It
can also schedule and cancel one delayed shutdown.

It manages the power lifecycle only. SSH, Screen Sharing, networking, service
supervision, and the workload remain under your control.

## Quick start

```sh
brew install soundadam/tap/teaway
teaway
```

No argument opens the client. It stays open across actions: keep the Mac awake,
allow sleep again, schedule or cancel a shutdown, and set up passwordless
controls when a change needs them.

The same actions exist as scriptable commands (`teaway on`, `teaway off`,
`teaway status`, `teaway shutdown …`, `teaway auth …`). See
[Using teaway](https://teaway.mintlify.app/using).

Before closing a laptop lid, verify that the Mac is stationary, well
ventilated, and reachable through the remote-access method you configured.
Remaining on AC power is still a good idea for unattended use. `teaway` does
not configure Remote Login, Screen Sharing, VPNs, firewalls, DNS, or service
startup.

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

## Requirements

- macOS 13 Ventura or later
- Apple silicon or Intel Mac supported by the installed macOS release
- Administrator authorization for power mutations or helper registration

## Safety

A MacBook has less cooling headroom with its lid closed. Keep the machine on a
hard, open surface; never run it closed inside a bag, drawer, or other confined
space. `teaway` does not override thermal protection and cannot prevent power
loss, kernel failure, forced updates, hardware faults, or a network outage.

Treat a laptop or desktop Mac as a small server only after configuring the rest
of the availability stack. See [Safety](https://teaway.mintlify.app/safety).

## Install and upgrade

```sh
brew install soundadam/tap/teaway
brew update
brew upgrade teaway
```

The Homebrew Formula builds the `teaway` command from the immutable GitHub
source tag. Public releases do not ship an unnotarized prebuilt executable.
After an upgrade, the client offers to repair passwordless controls if the
helper is stale.

Homebrew installs only `teaway`. The shorter `tea` name belongs to another
Homebrew package and may be used only as a personal shell alias.

To work on the source tree, see [Contributing](CONTRIBUTING.md).

## Documentation

Published docs: [teaway.mintlify.app](https://teaway.mintlify.app).
The source is [`docs/`](docs/README.md).

- [Using teaway](https://teaway.mintlify.app/using)
- [Safety](https://teaway.mintlify.app/safety)
- [Security](https://teaway.mintlify.app/security)
- [Changelog](CHANGELOG.md)
- [Contributing](CONTRIBUTING.md)
- [Security reporting](SECURITY.md)

`teaway` is distributed under the [MIT License](LICENSE).
