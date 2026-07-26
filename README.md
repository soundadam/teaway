# teaway

[![CI](https://github.com/soundadam/teaway/actions/workflows/ci.yml/badge.svg)](https://github.com/soundadam/teaway/actions/workflows/ci.yml)

`teaway` is the stable `soundadam` macOS power-control CLI. Its primary job is
to keep a Mac running after the lid is closed, then restore the setting it
changed when the user turns it off. A separate command family can schedule,
inspect, or cancel one explicit delayed shutdown.

`teaway` does not manage development tools, terminals, remote access, or work
processes. It changes only the power behavior the user requested.

## Naming contract

The publisher brand is always written `soundadam`. The stable product identity,
repository, Formula token, and executable name are all `teaway`. A personal
terminal may use `tea -> teaway`, but that shortcut is never installed publicly.

Homebrew Core already owns the `tea` token for the Gitea CLI. The public
repository name, Formula token, and installed executable are therefore
`teaway`, with no hyphen. The Formula installs only `teaway` and must never
install a conflicting `tea` executable or alias.

After migration, a user may keep `tea -> teaway` as a local shell alias or
personal shim. That alias is local configuration, not part of the public
package. During migration, do not repoint the existing personal `tea` command
until its legacy power state has been restored. After verification, remove the
legacy script, binary, state directory, and compatibility entrypoints.

The retired `tea-away` name is not a public name, Formula token, executable, or
upgrade path for `teaway`. No legacy binary is retained in the active checkout,
release archive, or Homebrew package.

## Current command surface

```sh
teaway                         # same as status
teaway on
teaway off
teaway status

teaway shutdown after 2h
teaway shutdown status
teaway shutdown cancel

teaway auth status
teaway auth register
teaway auth unregister

teaway version
```

`on` owns a reversible awake-state change. It records the setting it observed
before enabling lid-closed operation. `off` restores only a setting owned by
that native record; with no native-owned record it is a no-op and must not clear
an externally managed `SleepDisabled=1` value.

Shutdown is independent of `on` and `off`. `shutdown after` resolves a duration
such as `30m` or `2h` to an absolute local deadline and requires explicit human
confirmation before visible macOS authorization. `shutdown cancel` may cancel
only the single matching `teaway`-owned event. `off` never silently cancels a
scheduled shutdown.

By default, privileged changes use ordinary system `sudo`. `teaway` validates
authorization with `sudo -v` but does not invalidate an existing sudo timestamp,
store a password, or pipe a password through the process. A Mac whose local PAM
configuration enables Touch ID for `sudo` may satisfy that authorization with
Touch ID.

`teaway auth status` also reports whether the local sudo PAM configuration has
an active Touch ID rule. It is diagnostic only: `teaway` does not rewrite PAM
configuration or silently broaden system-wide authentication policy.

`teaway auth register` is an explicit opt-in for repeated local use. It requests
administrator authorization once, installs a per-user root-owned copy of the
current executable under `/Library/PrivilegedHelperTools`, and installs a
matching `/etc/sudoers.d` rule. The rule permits only the hidden helper protocol
for `disablesleep` and exact `teaway` shutdown operations; it does not grant
passwordless execution of arbitrary `pmset`, shells, or the public CLI. Use
`teaway auth status` to inspect the installation and `teaway auth unregister`
to remove it.

The registered authorization is a machine-level trust decision: any process
running as that macOS user can invoke the narrow helper operations. Do not
register it on a shared or untrusted account. See
[`docs/authorization.md`](docs/authorization.md) for the complete boundary.

Reminders, open-lid display-off timing, Low Power Mode integration, and the old
AC server profile are compatibility candidates for later releases. They are not
part of the current public command surface.

## Migration from the personal script

If migrating from a personal shell implementation, an observed
`SleepDisabled=1` remains legacy or externally owned; `teaway` must not adopt
it without an owned awake snapshot. Restore the legacy state explicitly with
that script's full path before using the native implementation:

```sh
/path/to/legacy/tea status
/path/to/legacy/tea off
```

Do not use the shorthand `tea` for this handoff: it may later become the local
alias for `teaway`. Native `off` must not adopt or reset legacy state
automatically, and `teaway` does not import or delete shell state. Verify the
restored baseline before repointing a local alias. Retain the original script
only until migration is verified, then remove it with every retired binary,
state directory, and compatibility entrypoint.

No retired `tea`, `tea-away`, or pre-`teaway` artifact belongs in the active
workspace, release archive, tap, or user command path.

## Build and validation

The current native release is version 0.2.3 under the canonical name:

```sh
swift test
swift build -c release --product teaway
./scripts/package-development.zsh 0.2.3
```

The development archive may be signed with the selected Apple Development
identity and hardened runtime for local validation only. Apple Development is
not Developer ID, does not make the archive suitable for public distribution,
and does not replace notarization.

The development archive is local validation evidence, not the Homebrew source
asset. Homebrew builds from the immutable GitHub source tag.

## Homebrew direction

The source Formula target is
[`packaging/Formula/teaway.rb.in`](packaging/Formula/teaway.rb.in). It builds
the native `teaway` executable from source and its test invokes only read-only
`version` and `status` commands. The earlier hyphenated Formula template belongs
to the historical 0.2.1 candidate and must not be published under either name.

Install the source release from the personal tap:

```sh
brew install soundadam/tap/teaway
```

To render the Formula for a tagged release:

```sh
./scripts/render-formula.zsh OWNER/REPO 0.2.3 SHA256 SPDX-LICENSE
```

The project is distributed under the [MIT License](LICENSE). Real-hardware
lid-close and shutdown acceptance remains an explicit operator test; package
installation never changes power state.

See [`docs/product-design.md`](docs/product-design.md),
[`docs/security.md`](docs/security.md), and
[`docs/release-readiness.md`](docs/release-readiness.md).
