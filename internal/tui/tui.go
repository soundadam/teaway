package tui

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/user"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"

	"github.com/soundadam/teaway/internal/app"
	"github.com/soundadam/teaway/internal/power"
	"github.com/soundadam/teaway/internal/privilege"
	"github.com/soundadam/teaway/internal/shutdown"
	"github.com/soundadam/teaway/internal/teaerr"
)

func Run(application app.App) error {
	for {
		powerStatus, shutdownStatus, authStatus, err := application.Snapshot()
		if err != nil {
			if typed, ok := teaerr.As(err); ok && typed.Kind == teaerr.KindStatePermission {
				if err := repairPermission(application, typed); err != nil {
					return err
				}
				continue
			}
			return err
		}

		action := ""
		form := huh.NewForm(
			huh.NewGroup(
				huh.NewNote().
					Title("Teaway").
					Description(statusDescription(powerStatus, shutdownStatus, authStatus, application.TimeZone)),
				huh.NewSelect[string]().
					Options(menuOptions(shutdownStatus.Record != nil, authStatus)...).
					Value(&action),
			),
		)
		if err := runForm(application, form); err != nil {
			return ignoreAbort(err)
		}
		switch action {
		case "quit", "":
			fmt.Fprintln(application.Stdout, "Goodbye.")
			return nil
		case "on":
			if abort, err := maybeSetupPasswordless(application, authStatus); abort {
				continue
			} else if err != nil {
				return err
			}
			if err := application.On(); err != nil {
				return err
			}
		case "off":
			if abort, err := maybeSetupPasswordless(application, authStatus); abort {
				continue
			} else if err != nil {
				return err
			}
			if err := application.Off(); err != nil {
				return err
			}
		case "cancel":
			if abort, err := maybeSetupPasswordless(application, authStatus); abort {
				continue
			} else if err != nil {
				return err
			}
			if err := application.ShutdownCancel(""); err != nil {
				return err
			}
		case "auth":
			if err := application.AuthRegister(); err != nil {
				return err
			}
		case "shutdown":
			value, err := pickShutdownDuration(application)
			if errors.Is(err, huh.ErrUserAborted) {
				continue
			}
			if err != nil {
				return err
			}
			if abort, err := maybeSetupPasswordless(application, authStatus); abort {
				continue
			} else if err != nil {
				return err
			}
			if err := application.ShutdownAfter(value); err != nil {
				return err
			}
		}
	}
}

func menuOptions(hasShutdown bool, auth privilege.AuthStatus) []huh.Option[string] {
	opts := []huh.Option[string]{
		huh.NewOption("Keep this Mac awake", "on"),
		huh.NewOption("Allow sleep again", "off"),
		huh.NewOption("Schedule a shutdown", "shutdown"),
	}
	if hasShutdown {
		opts = append(opts, huh.NewOption("Cancel the scheduled shutdown", "cancel"))
	}
	switch auth {
	case privilege.AuthUnregistered:
		opts = append(opts, huh.NewOption("Set up passwordless controls", "auth"))
	case privilege.AuthNeedsRepair:
		opts = append(opts, huh.NewOption("Repair passwordless controls", "auth"))
	}
	return append(opts, huh.NewOption("Quit", "quit"))
}

func needsPasswordlessSetup(auth privilege.AuthStatus) bool {
	return auth == privilege.AuthUnregistered || auth == privilege.AuthNeedsRepair
}

func maybeSetupPasswordless(application app.App, auth privilege.AuthStatus) (aborted bool, err error) {
	if !needsPasswordlessSetup(auth) {
		return false, nil
	}
	setup := true
	affirmative := "Set up now"
	description := "Set up passwordless controls now so later awake and shutdown operations won't ask? Teaway never reads the password; macOS handles the hidden prompt."
	if auth == privilege.AuthNeedsRepair {
		affirmative = "Repair now"
		description = "Passwordless controls need repair. Fix them now so later awake and shutdown operations won't ask? Teaway never reads the password; macOS handles the hidden prompt."
	}
	form := huh.NewForm(
		huh.NewGroup(
			huh.NewConfirm().
				Title("This action needs an administrator password").
				Description(description).
				Affirmative(affirmative).
				Negative("Use sudo").
				Value(&setup),
		),
	)
	if err := runForm(application, form); err != nil {
		if errors.Is(err, huh.ErrUserAborted) {
			return true, nil
		}
		return false, err
	}
	if !setup {
		return false, nil
	}
	return false, application.AuthRegister()
}

func repairPermission(application app.App, typed *teaerr.Error) error {
	fix := false
	form := huh.NewForm(
		huh.NewGroup(
			huh.NewNote().
				Title("Teaway cannot read its state").
				Description(typed.Message+"\n\n"+typed.Repair),
			huh.NewConfirm().
				Title("Fix ownership with sudo now?").
				Description("This runs sudo chown so state.json belongs to your account again. Do not launch teaway with sudo afterward.").
				Value(&fix),
		),
	)
	if err := runForm(application, form); err != nil {
		if err == huh.ErrUserAborted {
			return typed
		}
		return err
	}
	if !fix {
		return typed
	}
	if typed.Path == "" {
		return typed
	}
	u, err := user.Current()
	if err != nil {
		return err
	}
	for _, args := range [][]string{
		{"chown", u.Username, typed.Path},
		{"chmod", "600", typed.Path},
	} {
		cmd := exec.Command("sudo", args...)
		cmd.Stdin = os.Stdin
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return err
		}
	}
	return nil
}

func runForm(application app.App, form *huh.Form) error {
	return form.
		WithTheme(huh.ThemeCharm()).
		WithProgramOptions(programOptions(application)...).
		Run()
}

func runProgram(application app.App, model tea.Model) (tea.Model, error) {
	return tea.NewProgram(model, programOptions(application)...).Run()
}

func programOptions(application app.App) []tea.ProgramOption {
	return []tea.ProgramOption{
		tea.WithOutput(programOutput(application)),
		tea.WithAltScreen(),
		tea.WithReportFocus(),
	}
}

func programOutput(application app.App) io.Writer {
	if application.Stderr != nil {
		return application.Stderr
	}
	return os.Stderr
}

func ignoreAbort(err error) error {
	if errors.Is(err, huh.ErrUserAborted) {
		return nil
	}
	return err
}

func statusDescription(powerStatus power.Status, shutdownStatus shutdown.Status, auth privilege.AuthStatus, loc *time.Location) string {
	lines := []string{awakeSentence(powerStatus)}
	if batteryPower(powerStatus.PowerSource) {
		lines = append(lines, "On battery. Keep it powered if this Mac will sit unattended.")
	}
	if shutdownStatus.Record != nil {
		lines = append(lines, shutdownSentence(shutdownStatus, loc))
	}
	if auth != privilege.AuthRegistered {
		lines = append(lines, passwordlessSentence(auth))
	}
	return strings.Join(lines, "\n")
}

func awakeSentence(status power.Status) string {
	switch status.Observation {
	case power.On:
		return "This Mac stays awake. Teaway will restore the previous sleep setting."
	case power.Borrowed:
		return "This Mac is already staying awake. Teaway is preserving that setting."
	case power.External:
		return "Sleep is already disabled by something else. Teaway will not take it over."
	case power.NeedsRecovery:
		return "Awake mode needs recovery before Teaway can change it safely."
	case power.Conflict:
		return "Awake mode is in conflict. Check `teaway status` before changing it."
	default:
		return "Sleep is allowed. Keep this Mac awake when you need it available."
	}
}

func shutdownSentence(status shutdown.Status, loc *time.Location) string {
	when := formatLocal(status.Record.ScheduledAt, loc)
	switch status.Observation {
	case shutdown.Planned:
		return "A shutdown is being prepared for " + when + "."
	case shutdown.Missing:
		return "The recorded shutdown is missing from macOS · " + when + "."
	case shutdown.NeedsRecovery:
		return "The scheduled shutdown needs recovery · " + when + "."
	case shutdown.Conflict:
		return "The scheduled shutdown is in conflict · " + when + "."
	default:
		return "Shutdown scheduled for " + when + "."
	}
}

func passwordlessSentence(auth privilege.AuthStatus) string {
	if auth == privilege.AuthNeedsRepair {
		return "Passwordless controls need repair. The next change can fix them."
	}
	return "Passwordless controls are not set up. The next change can set them up."
}

func batteryPower(source string) bool {
	return strings.Contains(strings.ToLower(source), "battery")
}

func formatLocal(t time.Time, loc *time.Location) string {
	if loc == nil {
		loc = time.Local
	}
	return t.In(loc).Format("2006-01-02 15:04:05 Z07:00")
}
