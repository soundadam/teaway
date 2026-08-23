---
title: "Migration"
description: "Handoff from a retired personal tea or tea-away shell script."
---

# Migration from a personal tea or tea-away script

This document applies only to machines that previously used the retired
personal shell implementation. New installations can ignore it.

An observed `disablesleep=1` value without a native `teaway` ownership record is
external state. Native `teaway off` deliberately refuses to clear it.

## Handoff

Before repointing any personal `tea` alias, invoke the original implementation
by its full path and restore its state:

```sh
/path/to/legacy/tea status
/path/to/legacy/tea off
```

Then inspect the native baseline:

```sh
teaway status
```

Native `teaway` does not import, rewrite, or delete legacy state files, and it
no longer reads `tea-away` directories or `TEA_STATE_DIR` environment
variables. A leftover `tea-away:` shutdown event on the Mac can still be
cancelled by exact tuple.

## Cleanup

After the handoff is verified, remove the retired script, executable, state
directory, archive, and compatibility entrypoints. A personal `tea -> teaway`
alias may then be created outside Homebrew.

The historical `tea-away:` shutdown owner remains recognized only for exact
cancellation during recovery. It is not a supported public product name.
