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
	"github.com/charmbracelet/lipgloss"

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
		form := newMenuForm(powerStatus, shutdownStatus, authStatus, application.TimeZone, &action)
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

func newMenuForm(powerStatus power.Status, shutdownStatus shutdown.Status, auth privilege.AuthStatus, loc *time.Location, action *string) *huh.Form {
	return huh.NewForm(
		huh.NewGroup(
			huh.NewNote().
				Title("Teaway").
				Description(statusDescription(powerStatus, shutdownStatus, loc)),
			huh.NewSelect[string]().
				Options(menuOptions(shutdownStatus.Record != nil, auth)...).
				Value(action),
		),
	)
}

func menuOptions(hasShutdown bool, auth privilege.AuthStatus) []huh.Option[string] {
	opts := []huh.Option[string]{
		huh.NewOption("Stay awake", "on"),
		huh.NewOption("Allow sleep", "off"),
		huh.NewOption("Shut down later", "shutdown"),
	}
	if hasShutdown {
		opts = append(opts, huh.NewOption("Cancel shutdown", "cancel"))
	}
	switch auth {
	case privilege.AuthUnregistered:
		opts = append(opts, huh.NewOption("Passwordless", "auth"))
	case privilege.AuthNeedsRepair:
		opts = append(opts, huh.NewOption("Repair helper", "auth"))
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
	affirmative := "Set up"
	description := "macOS will ask. Teaway never sees it."
	if auth == privilege.AuthNeedsRepair {
		affirmative = "Repair"
		description = "The helper is stale. macOS will ask once."
	}
	form := huh.NewForm(
		huh.NewGroup(
			huh.NewConfirm().
				Title("Password").
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
				Title("Can't read state").
				Description(typed.Message),
			huh.NewConfirm().
				Title("Fix ownership?").
				Description("Uses sudo. Don't run teaway with sudo afterward.").
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
		WithTheme(clientTheme()).
		WithKeyMap(clientKeyMap()).
		WithShowHelp(false).
		WithProgramOptions(programOptions(application)...).
		Run()
}

func clientTheme() *huh.Theme {
	theme := huh.ThemeCharm()
	theme.FieldSeparator = lipgloss.NewStyle().SetString("\n")
	active := lipgloss.NewStyle().Foreground(lipgloss.Color("#F780E2"))
	theme.Focused.SelectedOption = active
	theme.Blurred.SelectedOption = active
	return theme
}

func clientKeyMap() *huh.KeyMap {
	keys := huh.NewDefaultKeyMap()
	keys.Select.Filter.SetEnabled(false)
	keys.Select.SetFilter.SetEnabled(false)
	keys.Select.ClearFilter.SetEnabled(false)
	return keys
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

func statusDescription(powerStatus power.Status, shutdownStatus shutdown.Status, loc *time.Location) string {
	lines := []string{awakeSentence(powerStatus)}
	if line := batteryPower(powerStatus.PowerSource); line != "" {
		lines = append(lines, line)
	}
	if shutdownStatus.Record != nil {
		lines = append(lines, shutdownSentence(shutdownStatus, loc))
	}
	return strings.Join(lines, "\n")
}

func awakeSentence(status power.Status) string {
	switch status.Observation {
	case power.On:
		return "Staying awake"
	case power.Borrowed:
		return "Already awake"
	case power.External:
		return "Awake · not ours"
	case power.NeedsRecovery:
		return "Needs recovery"
	case power.Conflict:
		return "In conflict"
	default:
		return "Sleep allowed"
	}
}

func shutdownSentence(status shutdown.Status, loc *time.Location) string {
	when := formatWhen(status.Record.ScheduledAt, loc)
	switch status.Observation {
	case shutdown.Planned:
		return "Shutdown · preparing"
	case shutdown.Missing:
		return "Shutdown · missing"
	case shutdown.NeedsRecovery:
		return "Shutdown · needs recovery"
	case shutdown.Conflict:
		return "Shutdown · conflict"
	default:
		return "Shutdown · " + when
	}
}

func batteryPower(source string) string {
	if strings.Contains(strings.ToLower(source), "battery") {
		return "On battery"
	}
	return ""
}

func formatWhen(t time.Time, loc *time.Location) string {
	if loc == nil {
		loc = time.Local
	}
	return t.In(loc).Format("Mon 15:04")
}
