package app

import (
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/soundadam/teaway/internal/duration"
	"github.com/soundadam/teaway/internal/execx"
	"github.com/soundadam/teaway/internal/power"
	"github.com/soundadam/teaway/internal/privilege"
	"github.com/soundadam/teaway/internal/shutdown"
	"github.com/soundadam/teaway/internal/state"
	"github.com/soundadam/teaway/internal/teaerr"
	"github.com/soundadam/teaway/internal/version"
)

type App struct {
	Power    power.Service
	Shutdown shutdown.Service
	Auth     privilege.Registration
	Stdout   io.Writer
	Stderr   io.Writer
	Host     string
	Now      func() time.Time
	TimeZone *time.Location
}

func New(env map[string]string, stdout, stderr io.Writer) (App, error) {
	if env == nil {
		env = envMap()
	}
	store := state.Store{Paths: state.Resolve(env)}
	runner := execx.System{}
	_, uid, err := privilege.CurrentUser()
	if err != nil {
		uid = os.Getuid()
	}
	userName, _, _ := privilege.CurrentUser()
	execPath, err := os.Executable()
	if err != nil {
		execPath = os.Args[0]
	}
	priv := privilege.Executor{Runner: runner, UID: uid}
	host, _ := os.Hostname()
	return App{
		Power:    power.Service{Store: store, Runner: runner, Priv: priv},
		Shutdown: shutdown.Service{Store: store, Runner: runner, Priv: priv},
		Auth: privilege.Registration{
			Runner:     runner,
			Executable: execPath,
			UserName:   userName,
			UID:        uid,
		},
		Stdout: stdout,
		Stderr: stderr,
		Host:   host,
		Now:    time.Now,
	}, nil
}

func envMap() map[string]string {
	out := map[string]string{}
	for _, entry := range os.Environ() {
		key, value, ok := strings.Cut(entry, "=")
		if ok {
			out[key] = value
		}
	}
	return out
}

func (a App) printf(format string, args ...any) {
	fmt.Fprintf(a.Stdout, format+"\n", args...)
}

func (a App) formatTime(t time.Time) string {
	loc := a.TimeZone
	if loc == nil {
		loc = time.Local
	}
	return t.In(loc).Format("2006-01-02 15:04:05 Z07:00")
}

func (a App) On() error {
	rec, err := a.Power.On()
	if err != nil {
		return err
	}
	if rec.OriginalDisableSleep == rec.ExpectedDisableSleep {
		a.printf("✓ Awake mode was already enabled. Teaway is now tracking it.")
	} else {
		a.printf("✓ Awake mode is on. This Mac will stay awake until you run `teaway off`.")
	}
	a.printf("  Previous setting saved: disablesleep=%d", rec.OriginalDisableSleep)
	a.printf("  Keep this Mac powered and well ventilated.")
	return nil
}

func (a App) Off() error {
	result, err := a.Power.Off()
	if err != nil {
		return err
	}
	switch {
	case result.HadRecord:
		a.printf("✓ Awake mode is off. The previous sleep setting was restored.")
	case result.RestoredDisableSleep == 0:
		a.printf("✓ Awake mode is already off. Nothing changed.")
	default:
		a.printf("Awake mode is controlled elsewhere. Nothing changed.")
	}
	a.printf("  Current setting: disablesleep=%d", result.RestoredDisableSleep)
	return nil
}

func (a App) Status() error {
	powerStatus, err := a.Power.Status()
	if err != nil {
		return err
	}
	shutdownStatus, err := a.Shutdown.Status()
	if err != nil {
		return err
	}
	a.printPower(powerStatus)
	a.printShutdown(shutdownStatus)
	return nil
}

func (a App) printPower(status power.Status) {
	a.printf("Teaway status")
	a.printf("  Awake mode: %s", powerLabel(status.Observation))
	a.printf("  Power: %s", status.PowerSource)
	a.printf("  Sleep setting: disablesleep=%d", status.LiveDisableSleep)
	if status.Record != nil {
		a.printf("  Saved setting: disablesleep=%d", status.Record.OriginalDisableSleep)
	}
}

func (a App) printShutdown(status shutdown.Status) {
	if status.Record == nil {
		a.printf("  Shutdown: Not scheduled")
		return
	}
	a.printf("  Shutdown: %s", shutdownLabel(status.Observation))
	a.printf("  Scheduled for: %s", a.formatTime(status.Record.ScheduledAt))
	a.printf("  Action: %s", status.Record.ID)
}

func (a App) ShutdownAfter(value string) error {
	seconds, err := duration.ParseShutdown(value)
	if err != nil {
		return err
	}
	rec, err := a.Shutdown.Plan(time.Duration(seconds) * time.Second)
	if err != nil {
		return err
	}
	a.printf("Scheduling shutdown for %s…", a.formatTime(rec.ScheduledAt))
	committed, err := a.Shutdown.Commit(rec.ID)
	if err != nil {
		return err
	}
	a.printf("✓ Shutdown scheduled for %s.", a.formatTime(committed.ScheduledAt))
	a.printf("  Host: %s", a.Host)
	a.printf("  Cancel it with: teaway shutdown cancel")
	return nil
}

func (a App) ShutdownStatus() error {
	status, err := a.Shutdown.Status()
	if err != nil {
		return err
	}
	a.printShutdown(status)
	return nil
}

func (a App) ShutdownCancel(actionID string) error {
	if actionID == "" {
		status, err := a.Shutdown.Status()
		if err != nil {
			return err
		}
		if status.Record == nil {
			return teaerr.NoShutdown()
		}
		actionID = status.Record.ID
	}
	rec, err := a.Shutdown.Cancel(actionID)
	if err != nil {
		return err
	}
	a.printf("✓ Scheduled shutdown cancelled.")
	a.printf("  Action: %s", rec.ID)
	return nil
}

func (a App) AuthStatus() error {
	status, detail, err := a.Auth.Status()
	if err != nil {
		return err
	}
	switch status {
	case privilege.AuthUnregistered:
		a.printf("authorization: unregistered")
		a.printf("mode: ordinary sudo with the system credential cache")
	case privilege.AuthRegistered:
		a.printf("authorization: registered")
		a.printf("helper version: %s", detail)
		a.printf("mode: passwordless narrow helper")
	case privilege.AuthNeedsRepair:
		a.printf("authorization: needs-repair")
		a.printf("detail: %s", detail)
	}
	touch, touchDetail := a.Auth.TouchID()
	switch touch {
	case privilege.TouchIDEnabled:
		a.printf("touch id for sudo: configured")
	case privilege.TouchIDDisabled:
		a.printf("touch id for sudo: not configured")
		a.printf("touch id note: macOS PAM controls this; teaway does not modify PAM")
	default:
		a.printf("touch id for sudo: unknown")
		a.printf("touch id detail: %s", touchDetail)
	}
	return nil
}

func (a App) AuthRegister() error {
	a.printf("Set up passwordless Teaway controls")
	a.printf("  macOS will ask for your account password once.")
	a.printf("  Password input is hidden; no characters appear while you type.")
	a.printf("  Teaway never reads or stores your password.")
	a.printf("  After setup, only awake-mode and teaway-owned shutdown operations run without a password.")
	helper, sudoers, ver, err := a.Auth.Register()
	if err != nil {
		return err
	}
	a.printf("✓ Passwordless Teaway controls are ready.")
	a.printf("  Helper version: %s", ver)
	a.printf("  Helper: %s", helper)
	a.printf("  Sudoers rule: %s", sudoers)
	a.printf("  Scope: awake mode and teaway-owned shutdown operations only")
	a.printf("  This permission is available to processes running as this macOS user.")
	return nil
}

func (a App) AuthUnregister() error {
	if err := a.Auth.Unregister(); err != nil {
		return err
	}
	a.printf("authorization: unregistered")
	return nil
}

func (a App) Version() {
	a.printf("teaway %s", version.Current)
}

func (a App) Snapshot() (power.Status, shutdown.Status, privilege.AuthStatus, error) {
	p, err := a.Power.Status()
	if err != nil {
		return power.Status{}, shutdown.Status{}, "", err
	}
	sh, err := a.Shutdown.Status()
	if err != nil {
		return p, shutdown.Status{}, "", err
	}
	auth, _, err := a.Auth.Status()
	if err != nil {
		return p, sh, "", err
	}
	return p, sh, auth, nil
}

func powerLabel(obs power.Observation) string {
	switch obs {
	case power.Off:
		return "Off"
	case power.On:
		return "On — managed by teaway"
	case power.Borrowed:
		return "On — teaway is preserving an existing setting"
	case power.External:
		return "On — controlled outside teaway"
	case power.NeedsRecovery:
		return "Needs recovery — run `teaway off`"
	default:
		return "Conflict — inspect before making changes"
	}
}

func shutdownLabel(obs shutdown.Observation) string {
	switch obs {
	case shutdown.None:
		return "Not scheduled"
	case shutdown.Planned:
		return "Being prepared"
	case shutdown.Scheduled:
		return "Scheduled"
	case shutdown.Missing:
		return "No longer present in macOS"
	case shutdown.NeedsRecovery:
		return "Needs recovery"
	default:
		return "Conflict"
	}
}

func FormatError(err error) string {
	if typed, ok := teaerr.As(err); ok {
		msg := "teaway: " + typed.Message
		if typed.Repair != "" {
			msg += "\n" + typed.Repair
		}
		return msg
	}
	return "teaway: " + err.Error()
}
