# teaway product design

## Positioning

`teaway` is a focused macOS power-control CLI:

> Keep the Mac running after the lid closes, restore the previous behavior on
> request, and optionally schedule one explicit shutdown for later.

The product succeeds when the user can answer three questions immediately:

1. Is `teaway` currently keeping lid-close sleep disabled?
2. Can `teaway` restore the exact setting it owns?
3. Is a `teaway`-owned shutdown scheduled, and when will it happen?

It is not a development-tool launcher or a remote-access product. The process
that benefits from the Mac staying awake remains entirely outside `teaway`.

## Naming contract

The publisher brand is `soundadam`; the stable product identity is `teaway`.
Public package metadata must preserve both spellings exactly.

The canonical public repository, Homebrew Formula token, and executable name
are `teaway`. Homebrew installs only that executable because Core already owns
`tea` for the Gitea CLI. `tea` is permitted only as a user-managed local alias
or personal shim pointing to `teaway`; it is never created by the Formula.

The retired `tea-away` token is not a second public name, compatibility
executable, or release alias. No legacy binary is retained in the active
workspace or package. The current release using the final naming contract is
0.2.3.

## Primary journey

1. `teaway status` reports the current power source, observed `SleepDisabled`
   value, native ownership state, and any `teaway`-owned shutdown.
2. `teaway on` snapshots the current lid-close sleep setting, requests visible
   authorization, applies the awake setting, verifies it, and records ownership.
3. The user closes the lid while their existing workload continues independently.
4. `teaway off` restores the exact saved setting only when native `teaway` owns
   that snapshot. Without native ownership it reports a no-op.
5. When desired, `teaway shutdown after 2h` schedules a separate shutdown.
   `shutdown status` inspects it and `shutdown cancel` removes only that exact
   `teaway`-owned event.

## Public command model

```text
teaway
teaway on
teaway off
teaway status

teaway shutdown after DURATION
teaway shutdown status
teaway shutdown cancel

teaway version
teaway help
```

No argument is equivalent to `status`. Durations use explicit units such as
`30m`, `2h`, or `1d`. Relative shutdown durations are always rendered as an
absolute local time with timezone before authorization.

`on` has no duration. It remains enabled until `off` or system power-off.
Automatic shutdown is expressed only through the separate `shutdown after`
command. `off` does not cancel shutdown, and shutdown does not infer that other
work is complete.

## 0.2.3 scope

- Native `on`, `off`, and consolidated read-only `status` under `teaway`.
- Exact pre-change awake snapshot and fail-closed ownership checks.
- No-op `off` when no native-owned snapshot exists.
- One `teaway`-owned delayed shutdown with `after`, `status`, and exact `cancel`.
- Fixed system executable paths, private atomic state, visible authorization,
  a typed confirmation challenge, and deterministic tests.
- Real-hardware validation that lid-closed work continues on supported macOS and
  hardware, followed by exact restoration testing.
- A source Formula named `teaway` and a local Apple Development-signed archive
  for development validation.
- An optional user-managed local `tea -> teaway` alias that is excluded from the
  Formula and release archive.

## Deferred compatibility

The personal script also contains useful secondary behavior. It should be
evaluated after the corrected core is proven:

- periodic notification and Glass reminder, exposed as an `on` option rather
  than a command family;
- an open-lid display-off timer;
- optional Low Power Mode capture and restoration;
- the AC-only server profile that changes sleep, display sleep, disk sleep,
  network wake, TCP keepalive, and TTY wake settings;
- a reminder-sound diagnostic command.

These features must preserve exact prior settings and roll back partial failure.
The server profile in particular should not enter the default path because it
changes several unrelated system-wide settings.

## Migration contract

An existing `SleepDisabled=1` observation without a native ownership record is
legacy or external state, not native `teaway` state. Native `off` must therefore
be a no-op rather than resetting it.

Before cutover, the user runs the original personal command by its full path:

```sh
/path/to/legacy/tea status
/path/to/legacy/tea off
```

Only after the legacy state is restored and verified should `teaway on`
establish its own snapshot. Native `teaway` does not import, rewrite, or delete
shell snapshot files. Do not repoint the local `tea` alias during this handoff;
after cutover it may point to `teaway`. Once migration is verified, remove the
legacy script, binary, state directory, and compatibility entrypoints.

Retired `tea` and `tea-away` artifacts are not publishable and are not retained
in the active workspace. The canonical `teaway` product began its stable source
release line at 0.2.2 and continues as the product identity in 0.2.3.

## Explicit non-goals

- Starting, stopping, supervising, or interpreting user workloads.
- Configuring remote access, networking, credentials, tunnels, or public ports.
- Multiple machines, a cloud controller, browser dashboard, or phone app.
- A privileged helper, LaunchDaemon, sudoers rule, password cache, or unattended
  conditional automation.
- Deciding that work is complete from idle time, process exit, or network state.

The smallest trustworthy implementation is preferred: one reversible awake
state and one independently owned shutdown event.
