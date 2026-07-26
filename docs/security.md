# Security model

## Trust boundary

`teaway` changes macOS power behavior only after an explicit command. It does
not install a LaunchDaemon, setuid executable, password cache, listener, or
cloud control plane. It never reads, stores, logs, or pipes an administrator
password. Privileged operations use fixed macOS system paths.

Without registration, `teaway` uses ordinary system `sudo`: it validates the
current credential with `sudo -v`, preserves any valid sudo timestamp, and then
executes one fixed `pmset` operation. It does not use `sudo -k`, so it does not
force macOS to discard an existing authorization timestamp before every
operation. Authentication method selection remains the responsibility of the
local macOS PAM configuration; this includes Touch ID when enabled for `sudo`.
`teaway auth status` reports the observed Touch ID rule but never edits PAM.

The optional `teaway auth register` command makes a separate, explicit trust
decision. After visible administrator authorization, it installs:

- a per-user, root-owned executable under `/Library/PrivilegedHelperTools`; and
- a per-user, root-owned rule under `/etc/sudoers.d`.

The sudoers rule permits passwordless execution only of the hidden helper
protocol. It does not permit arbitrary public `teaway` commands, arbitrary
`pmset` arguments, a shell, or another executable. The helper accepts only:

1. `disablesleep` values `0` and `1`;
2. one canonical `teaway:` shutdown tuple with an exact date format; and
3. exact cancellation of canonical or recorded legacy `tea-away:` shutdown
   tuples.

Every dynamic field is parsed again by the root-owned helper before `pmset` is
invoked. A malformed operation fails closed. `teaway auth status` verifies that
the helper version matches the invoking CLI, and `teaway auth unregister`
removes both installed files.

Registration delegates these narrow operations to the entire macOS account,
not solely to one terminal process. Any process running as that user can invoke
the allowed helper commands. Registration is therefore inappropriate for a
shared or untrusted account. A future signed app-bundle distribution may move
this boundary to a launchd/XPC helper with code-signature validation; the
source-built Homebrew CLI does not claim that stronger identity boundary.

`status` and `version` are read-only. They must not modify power settings,
schedule an event, or cancel an event. A Homebrew test is restricted to those
two commands.

The Mac must remain stationary and well ventilated. Keeping a closed Mac awake
inside a bag is outside the supported model.

## Name and installation boundary

The public repository, Homebrew Formula token, and executable are all
`teaway`. The Formula installs no `tea` or `tea-away` command. Because Homebrew
Core owns `tea` for the Gitea CLI, `tea -> teaway` may exist only as a
user-managed local alias or personal shim outside the package.

During migration, the existing personal `tea` path must not be repointed until
its power state is restored. After verification, retired scripts, binaries,
state directories, and compatibility entrypoints are removed and must not be
presented as `teaway` or used as public release assets.

## Awake ownership

`on` is a reversible, owned state transition:

1. Inspect the current lid-close sleep setting.
2. Persist the exact pre-change value in private native state.
3. Request visible authorization and apply the awake setting.
4. Re-read macOS state and report success only after verification.

State is written atomically in a mode-0700 directory with mode-0600 files. A
snapshot accepts only its documented schema and values. Partial failure keeps
enough state for recovery and does not invent a successful ownership record.

`off` restores only a native `teaway`-owned snapshot. If no such snapshot
exists, `off` is a no-op. It must not turn `SleepDisabled` off merely because
the current value is `1`; that value may belong to the legacy script, another
tool, or the user. If macOS already reports the saved baseline, `teaway` clears
only its journal because the requested restoration is already complete. An
unreadable or unsupported state fails closed rather than guessing or
overwriting another owner.

An existing `SleepDisabled=1` value without a native record remains legacy or
external state. Native `off` must not clear it. Migration begins by running the
original personal command by its full path:

```sh
/path/to/legacy/tea status
/path/to/legacy/tea off
```

Native `teaway` never sources, imports, rewrites, or deletes legacy snapshot
files. The operator verifies the restored baseline before repointing any local
`tea` alias. The original script remains available only until migration is
verified, then it and all retired state and entrypoints are removed.

## Shutdown boundary

Shutdown is independent of awake ownership. It is requested only through:

```text
teaway shutdown after DURATION
teaway shutdown status
teaway shutdown cancel
```

`shutdown after` parses a bounded duration, displays the resolved absolute
deadline, timezone, hostname, action ID, and exact effect, then requires the
full displayed phrase from a real TTY followed by visible authorization.
Non-interactive use fails closed and discards the fresh uncommitted plan when
that can be verified safely.

Internally, scheduling retains the existing defensive transaction:

1. Create a short-lived `teaway`-owned plan.
2. Reject an existing shutdown or conflicting `teaway` event.
3. Persist the committing tuple before invoking macOS.
4. Schedule one `pmset` shutdown with a unique `teaway` owner.
5. Re-read `pmset -g sched` and commit state only when the exact tuple exists.
6. Attempt exact compensating cancellation if later persistence fails.

The action identifier may remain internal because only one `teaway` shutdown is
allowed. `shutdown status` reconciles private state with macOS, which remains
authoritative. `shutdown cancel` cancels only the exact observed
`teaway`-owned tuple. It never invokes `killall shutdown`, `pmset cancelall`, or
cancellation of an unrelated owner. A mismatch is a recovery error, not
permission to guess.

`off` never cancels shutdown. Shutdown is not triggered by workload exit, idle
CPU, network loss, or any inferred completion signal.

## Deferred compatibility boundaries

Reminder sound, open-lid display-off timing, Low Power Mode, and the AC server
profile are outside 0.2.3. If later restored, each must be opt-in, validate all
input, snapshot only allowlisted values, restore exactly what `teaway` changed,
and roll back partial failure. The server profile must verify AC power before
any state or system mutation.

## Legacy boundary

The personal zsh implementation, its marker-based reminder processes, and its
system-wide legacy shutdown cancellation are not part of this public native
repository or the 0.2.3 security model. Legacy scripts, binaries, state
directories, and archives are removed after verified migration and must not
become public assets.

## Signing boundary

The 0.2.3 `teaway` local development archive may be signed with Apple
Development and hardened runtime. This validates local provenance only. Apple
Development is not Developer ID and does not make an archive publishable.

A public prebuilt artifact would require Developer ID Application, secure
timestamping, notarization, stapling where applicable, and verification of the
final immutable asset. A source-built Formula does not inherit the developer's
local signing identity and does not require Apple Development signing.

No retired `tea` or `tea-away` archive may be used as a public release, renamed
to impersonate 0.2.3, retained in the active workspace, or referenced as a
Homebrew source asset.
