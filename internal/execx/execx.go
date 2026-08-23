package execx

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/soundadam/teaway/internal/teaerr"
)

const (
	Pmset   = "/usr/bin/pmset"
	Sudo    = "/usr/bin/sudo"
	Install = "/usr/bin/install"
	Cmp     = "/usr/bin/cmp"
	Rm      = "/bin/rm"
	Visudo  = "/usr/sbin/visudo"
)

type Command struct {
	Path string
	Args []string
}

func (c Command) String() string {
	return c.Path + " " + strings.Join(c.Args, " ")
}

type Result struct {
	ExitCode int
	Stdout   string
	Stderr   string
}

type Runner interface {
	Run(cmd Command) (Result, error)
	RunInteractive(cmd Command) (Result, error)
}

type System struct{}

func (System) Run(cmd Command) (Result, error) {
	command := exec.Command(cmd.Path, cmd.Args...)
	command.Stdin = nil
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	err := command.Run()
	result := Result{Stdout: stdout.String(), Stderr: stderr.String()}
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			result.ExitCode = exitErr.ExitCode()
			return result, nil
		}
		return result, err
	}
	return result, nil
}

func (System) RunInteractive(cmd Command) (Result, error) {
	command := exec.Command(cmd.Path, cmd.Args...)
	command.Stdin = os.Stdin
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	err := command.Run()
	result := Result{}
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			result.ExitCode = exitErr.ExitCode()
			return result, nil
		}
		return result, err
	}
	return result, nil
}

func Must(runner Runner, cmd Command) (Result, error) {
	result, err := runner.Run(cmd)
	if err != nil {
		return result, err
	}
	if result.ExitCode != 0 {
		return result, teaerr.CommandFailed(cmd.Path, result.ExitCode, result.Stderr)
	}
	return result, nil
}

func MustInteractive(runner Runner, cmd Command) (Result, error) {
	result, err := runner.RunInteractive(cmd)
	if err != nil {
		return result, err
	}
	if result.ExitCode != 0 {
		return result, teaerr.CommandFailed(cmd.Path, result.ExitCode, result.Stderr)
	}
	return result, nil
}

type Fake struct {
	RunFn         func(Command) (Result, error)
	InteractiveFn func(Command) (Result, error)
	Calls         []Command
	Interactive   []Command
}

func (f *Fake) Run(cmd Command) (Result, error) {
	f.Calls = append(f.Calls, cmd)
	if f.RunFn == nil {
		return Result{}, fmt.Errorf("unexpected command: %s", cmd)
	}
	return f.RunFn(cmd)
}

func (f *Fake) RunInteractive(cmd Command) (Result, error) {
	f.Interactive = append(f.Interactive, cmd)
	if f.InteractiveFn == nil {
		return Result{}, fmt.Errorf("unexpected interactive command: %s", cmd)
	}
	return f.InteractiveFn(cmd)
}
