package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/soundadam/teaway/internal/app"
	"github.com/soundadam/teaway/internal/teaerr"
	"github.com/soundadam/teaway/internal/tui"
	"github.com/soundadam/teaway/internal/version"
)

func NewRoot() *cobra.Command {
	root := &cobra.Command{
		Use:           "teaway",
		Short:         "Keep this Mac awake, then restore its previous sleep setting when you're done.",
		SilenceUsage:  true,
		SilenceErrors: true,
		Args:          cobra.NoArgs,
		PersistentPreRunE: func(cmd *cobra.Command, args []string) error {
			if os.Geteuid() == 0 {
				return teaerr.RootRefused()
			}
			return nil
		},
		RunE: func(cmd *cobra.Command, args []string) error {
			application, err := app.New(nil, cmd.OutOrStdout(), cmd.ErrOrStderr())
			if err != nil {
				return err
			}
			return tui.Run(application)
		},
	}
	root.CompletionOptions.DisableDefaultCmd = true
	root.AddCommand(
		onCmd(),
		offCmd(),
		statusCmd(),
		shutdownCmd(),
		authCmd(),
		interactiveCmd(),
		versionCmd(),
	)
	return root
}

func Execute() int {
	root := NewRoot()
	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, app.FormatError(err))
		if teaerr.IsUsage(err) {
			return 2
		}
		return 1
	}
	return 0
}

func withApp(fn func(app.App, []string) error) func(*cobra.Command, []string) error {
	return func(cmd *cobra.Command, args []string) error {
		application, err := app.New(nil, cmd.OutOrStdout(), cmd.ErrOrStderr())
		if err != nil {
			return err
		}
		return fn(application, args)
	}
}

func onCmd() *cobra.Command {
	return &cobra.Command{Use: "on", Short: "Disable lid-close sleep and remember the previous setting", Args: cobra.NoArgs, RunE: withApp(func(a app.App, _ []string) error { return a.On() })}
}

func offCmd() *cobra.Command {
	return &cobra.Command{Use: "off", Short: "Restore the sleep setting teaway owns", Args: cobra.NoArgs, RunE: withApp(func(a app.App, _ []string) error { return a.Off() })}
}

func statusCmd() *cobra.Command {
	return &cobra.Command{Use: "status", Short: "Show awake mode, power source, and shutdown state", Args: cobra.NoArgs, RunE: withApp(func(a app.App, _ []string) error { return a.Status() })}
}

func interactiveCmd() *cobra.Command {
	run := withApp(func(a app.App, _ []string) error { return tui.Run(a) })
	cmd := &cobra.Command{Use: "interactive", Aliases: []string{"tui"}, Short: "Open the guided status and action menu", Args: cobra.NoArgs, RunE: run}
	return cmd
}

func versionCmd() *cobra.Command {
	return &cobra.Command{Use: "version", Short: "Print the teaway version", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, args []string) error {
		fmt.Fprintf(cmd.OutOrStdout(), "teaway %s\n", version.Current)
		return nil
	}}
}

func shutdownCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "shutdown", Short: "Schedule or cancel one teaway-owned shutdown"}
	cmd.AddCommand(
		&cobra.Command{Use: "after DURATION", Short: "Schedule a shutdown after a duration such as 30m or 2h", Args: cobra.ExactArgs(1), RunE: withApp(func(a app.App, args []string) error { return a.ShutdownAfter(args[0]) })},
		&cobra.Command{Use: "status", Short: "Show the teaway-owned shutdown", Args: cobra.NoArgs, RunE: withApp(func(a app.App, _ []string) error { return a.ShutdownStatus() })},
		&cobra.Command{Use: "cancel [ACTION_ID]", Short: "Cancel the teaway-owned shutdown", Args: cobra.MaximumNArgs(1), RunE: withApp(func(a app.App, args []string) error {
			id := ""
			if len(args) == 1 {
				id = args[0]
			}
			return a.ShutdownCancel(id)
		})},
	)
	return cmd
}

func authCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "auth", Short: "Inspect or register the narrow passwordless helper"}
	cmd.AddCommand(
		&cobra.Command{Use: "status", Short: "Show helper registration and sudo Touch ID", Args: cobra.NoArgs, RunE: withApp(func(a app.App, _ []string) error { return a.AuthStatus() })},
		&cobra.Command{Use: "register", Short: "Install the narrow passwordless helper", Args: cobra.NoArgs, RunE: withApp(func(a app.App, _ []string) error { return a.AuthRegister() })},
		&cobra.Command{Use: "unregister", Short: "Remove the helper and sudoers rule", Args: cobra.NoArgs, RunE: withApp(func(a app.App, _ []string) error { return a.AuthUnregister() })},
	)
	return cmd
}
