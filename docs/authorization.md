# Authorization model

## Goals

`teaway` needs administrator privileges only for the `pmset` mutations that
change lid-close sleep behavior or create/cancel one exact scheduled shutdown.
Read-only status and version commands remain unprivileged.

The authorization design has two modes:

1. ordinary `sudo`, with the system credential cache preserved; and
2. an optional, explicitly registered, passwordless narrow helper.

Neither mode reads, stores, transmits, or logs an administrator password.

## Default mode: ordinary sudo

An unregistered installation performs this sequence for a privileged mutation:

1. run `sudo -v` interactively;
2. recheck any safety precondition that could have changed while the user was
   authenticating, such as AC power for `teaway on`;
3. invoke one fixed `/usr/bin/pmset` operation through `sudo`; and
4. verify the resulting macOS state before reporting success.

The implementation never invokes `sudo -k`. A valid sudo timestamp can therefore
be reused according to the local sudo policy. Touch ID is available only when
the Mac administrator has enabled `pam_tid.so` for `sudo`; `teaway` does not
modify PAM configuration automatically. `teaway auth status` reports whether an
active `auth sufficient pam_tid.so` rule is visible in `sudo_local` or `sudo`.

## Registered mode

`teaway auth register` requests interactive administrator authorization and
installs two per-user files:

```text
/Library/PrivilegedHelperTools/com.soundadam.teaway.helper.<uid>
/etc/sudoers.d/soundadam-teaway-<uid>
```

The helper is a root-owned copy of the exact executable that performed
registration. The sudoers rule is validated before and after installation. The
CLI checks the helper version before treating the registration as healthy.

Registered mutations use `sudo -n` and the hidden helper entry point. They do
not prompt for a password or Touch ID while the registration remains healthy.

## Allowed operations

The helper protocol accepts only these operation classes:

```text
probe
version
set-disablesleep 0
set-disablesleep 1
schedule-shutdown MM/DD/YY HH:MM:SS teaway:<identifier>
cancel-shutdown MM/DD/YY HH:MM:SS teaway:<identifier>
cancel-shutdown MM/DD/YY HH:MM:SS tea-away:<legacy-identifier>
```

The root-owned process validates:

- the exact argument count;
- the allowlisted operation name;
- a strict `MM/dd/yy HH:mm:ss` date round trip;
- a canonical owner for new schedules;
- a canonical or recorded legacy owner for cancellation; and
- an ASCII alphanumeric/hyphen identifier of bounded length.

It then invokes the fixed path `/usr/bin/pmset` without a shell. Unsupported,
malformed, or extra arguments fail closed.

## Account-level risk

The sudoers rule identifies a macOS user, not the parent terminal or a specific
calling binary. After registration, any process running as that user can invoke
the allowlisted helper operations. The rule cannot run a shell and cannot pass
arbitrary `pmset` arguments, but it can still disable lid-close sleep or create
and cancel a conforming `teaway` shutdown.

Registration should therefore be used only on a trusted, single-user account.
It should not be enabled on shared accounts or machines where untrusted code is
routinely executed under the same user.

## Removal and repair

```sh
teaway auth status
teaway auth unregister
```

`status` reports one of:

- `unregistered`: both machine-level files are absent;
- `registered`: the helper is authorized and its version matches the CLI; or
- `needs-repair`: installation is partial, authorization failed, or versions
  differ.

`unregister` requires ordinary administrator authorization and removes the
helper and sudoers rule. Re-running `register` replaces a stale helper with the
current executable.

## Future app-bundle boundary

A signed, notarized app-bundle distribution can use a launchd/XPC privileged
helper registered through the current macOS Service Management APIs and enforce
code-signature requirements at the connection boundary. The source-built
Homebrew CLI does not have a stable Developer ID identity and therefore uses the
more explicit per-user sudoers boundary described above. The two designs should
not be represented as equivalent.
