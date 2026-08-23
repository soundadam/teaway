package tui

import (
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"strings"

	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/lipgloss"

	"github.com/soundadam/teaway/internal/app"
	"github.com/soundadam/teaway/internal/power"
	"github.com/soundadam/teaway/internal/privilege"
	"github.com/soundadam/teaway/internal/shutdown"
	"github.com/soundadam/teaway/internal/teaerr"
)

var (
	titleStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("212"))
	boxStyle   = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(lipgloss.Color("63")).Padding(0, 1)
	mutedStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("245"))
	warnStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("178"))
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
		fmt.Fprintln(application.Stdout, renderStatus(powerStatus, shutdownStatus, authStatus))

		action := "quit"
		form := huh.NewForm(
			huh.NewGroup(
				huh.NewSelect[string]().
					Title("What would you like to do?").
					Options(
						huh.NewOption("Turn awake mode on", "on"),
						huh.NewOption("Turn awake mode off", "off"),
						huh.NewOption("Schedule a shutdown", "shutdown"),
						huh.NewOption("Cancel the scheduled shutdown", "cancel"),
						huh.NewOption("Set up passwordless controls", "auth"),
						huh.NewOption("Refresh status", "refresh"),
						huh.NewOption("Quit", "quit"),
					).
					Value(&action),
			),
		).WithTheme(huh.ThemeCharm())
		if err := form.Run(); err != nil {
			if err == huh.ErrUserAborted {
				return nil
			}
			return err
		}
		switch action {
		case "refresh":
			continue
		case "quit":
			fmt.Fprintln(application.Stdout, "Goodbye.")
			return nil
		case "on":
			return application.On()
		case "off":
			return application.Off()
		case "cancel":
			return application.ShutdownCancel("")
		case "auth":
			return application.AuthRegister()
		case "shutdown":
			value := ""
			ask := huh.NewForm(
				huh.NewGroup(
					huh.NewInput().
						Title("Delay until shutdown").
						Description("Examples: 30m, 2h, 1d. Minimum 10 minutes.").
						Placeholder("2h").
						Value(&value),
				),
			).WithTheme(huh.ThemeCharm())
			if err := ask.Run(); err != nil {
				if err == huh.ErrUserAborted {
					return nil
				}
				return err
			}
			return application.ShutdownAfter(strings.TrimSpace(value))
		}
	}
}

func repairPermission(application app.App, typed *teaerr.Error) error {
	fmt.Fprintln(application.Stdout, boxStyle.Render(
		titleStyle.Render("Teaway cannot read its state")+"\n"+
			typed.Message+"\n\n"+warnStyle.Render(typed.Repair),
	))
	fix := false
	form := huh.NewForm(
		huh.NewGroup(
			huh.NewConfirm().
				Title("Fix ownership with sudo now?").
				Description("This runs sudo chown so state.json belongs to your account again. Do not launch teaway with sudo afterward.").
				Value(&fix),
		),
	).WithTheme(huh.ThemeCharm())
	if err := form.Run(); err != nil {
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

func renderStatus(powerStatus power.Status, shutdownStatus shutdown.Status, auth privilege.AuthStatus) string {
	authLine := "Passwordless controls: not set up"
	switch auth {
	case privilege.AuthRegistered:
		authLine = "Passwordless controls: ready"
	case privilege.AuthNeedsRepair:
		authLine = "Passwordless controls: need repair"
	}
	shutdownLine := "Shutdown: not scheduled"
	if shutdownStatus.Record != nil {
		shutdownLine = fmt.Sprintf("Shutdown: %s", shutdownStatus.Observation)
	}
	body := strings.Join([]string{
		titleStyle.Render("Teaway"),
		mutedStyle.Render("Keep this Mac awake, then restore its previous sleep setting when you're done."),
		"",
		fmt.Sprintf("Awake:  %s", powerStatus.Observation),
		fmt.Sprintf("Power:  %s", powerStatus.PowerSource),
		fmt.Sprintf("Sleep:  disablesleep=%d", powerStatus.LiveDisableSleep),
		shutdownLine,
		authLine,
	}, "\n")
	return boxStyle.Render(body)
}
