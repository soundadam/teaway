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

Only after the live value is restored should `teaway on` establish a new native
snapshot. Native `teaway` does not import, rewrite, or delete legacy state files.

## Cleanup

After the handoff is verified, remove the retired script, executable, state
directory, archive, and compatibility entrypoints. A personal `tea -> teaway`
alias may then be created outside Homebrew.

The historical `tea-away:` shutdown owner remains recognized only for exact
cancellation during recovery. It is not a supported public product name.
