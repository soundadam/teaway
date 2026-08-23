package privilege

import (
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/soundadam/teaway/internal/execx"
	"github.com/soundadam/teaway/internal/teaerr"
	"github.com/soundadam/teaway/internal/version"
)

const (
	InternalCommand = "__teaway_privileged"
	HelperDir       = "/Library/PrivilegedHelperTools"
	SudoersDir      = "/etc/sudoers.d"
	HelperName      = "teaway-privileged-helper"
	cmdSet          = "set-disablesleep"
	cmdSchedule     = "schedule-shutdown"
	cmdCancel       = "cancel-shutdown"
)

type Operation struct {
	kind  string
	value string
	date  string
	owner string
}

func SetDisableSleep(value int) Operation {
	return Operation{kind: cmdSet, value: strconv.Itoa(value)}
}

func ScheduleShutdown(date, owner string) Operation {
	return Operation{kind: cmdSchedule, date: date, owner: owner}
}

func CancelShutdown(date, owner string) Operation {
	return Operation{kind: cmdCancel, date: date, owner: owner}
}

func (o Operation) helperArgs() []string {
	switch o.kind {
	case cmdSet:
		return []string{cmdSet, o.value}
	case cmdSchedule:
		return []string{cmdSchedule, o.date, o.owner}
	case cmdCancel:
		return []string{cmdCancel, o.date, o.owner}
	default:
		return nil
	}
}

func (o Operation) pmsetArgs() []string {
	switch o.kind {
	case cmdSet:
		return []string{"-a", "disablesleep", o.value}
	case cmdSchedule:
		return []string{"schedule", "shutdown", o.date, o.owner}
	case cmdCancel:
		return []string{"schedule", "cancel", "shutdown", o.date, o.owner}
	default:
		return nil
	}
}

func HelperPath(uid int) string {
	return filepath.Join(HelperDir, fmt.Sprintf("com.soundadam.teaway.helper.%d", uid))
}

func SudoersPath(uid int) string {
	return filepath.Join(SudoersDir, fmt.Sprintf("soundadam-teaway-%d", uid))
}

func LegacySudoersPath(uid int) string {
	return filepath.Join(SudoersDir, fmt.Sprintf("com.soundadam.teaway.%d", uid))
}

type Executor struct {
	Runner execx.Runner
	UID    int
	Exists func(string) bool
}

func (e Executor) exists(path string) bool {
	if e.Exists != nil {
		return e.Exists(path)
	}
	_, err := os.Stat(path)
	return err == nil
}

func (e Executor) helperUsable() bool {
	helper, sudoers := HelperPath(e.UID), SudoersPath(e.UID)
	if !e.exists(helper) || !e.exists(sudoers) {
		return false
	}
	result, err := e.Runner.Run(execx.Command{Path: execx.Sudo, Args: []string{"-n", helper, InternalCommand, "version"}})
	if err != nil || result.ExitCode != 0 {
		return false
	}
	return strings.TrimSpace(result.Stdout) == HelperName+" "+version.Current
}

func (e Executor) Authorize() error {
	if e.helperUsable() {
		return nil
	}
	_, err := execx.MustInteractive(e.Runner, execx.Command{Path: execx.Sudo, Args: []string{"-v"}})
	return err
}

func (e Executor) Run(op Operation) error {
	if e.helperUsable() {
		args := append([]string{"-n", HelperPath(e.UID), InternalCommand}, op.helperArgs()...)
		_, err := execx.Must(e.Runner, execx.Command{Path: execx.Sudo, Args: args})
		return err
	}
	args := append([]string{execx.Pmset}, op.pmsetArgs()...)
	_, err := execx.MustInteractive(e.Runner, execx.Command{Path: execx.Sudo, Args: args})
	return err
}

var datePattern = regexp.MustCompile(`^[0-1][0-9]/[0-3][0-9]/[0-9]{2} [0-2][0-9]:[0-5][0-9]:[0-5][0-9]$`)

func ParseRequest(args []string) (kind string, op Operation, ok bool) {
	if len(args) == 0 {
		return "", Operation{}, false
	}
	switch args[0] {
	case "probe":
		return "probe", Operation{}, len(args) == 1
	case "version":
		return "version", Operation{}, len(args) == 1
	case cmdSet:
		if len(args) == 2 && (args[1] == "0" || args[1] == "1") {
			return "op", SetDisableSleep(atoi(args[1])), true
		}
	case cmdSchedule:
		if len(args) == 3 && validDate(args[1]) && validOwner(args[2], false) {
			return "op", ScheduleShutdown(args[1], args[2]), true
		}
	case cmdCancel:
		if len(args) == 3 && validDate(args[1]) && validOwner(args[2], true) {
			return "op", CancelShutdown(args[1], args[2]), true
		}
	}
	return "", Operation{}, false
}

func atoi(v string) int { n, _ := strconv.Atoi(v); return n }

func validDate(value string) bool {
	if !datePattern.MatchString(value) {
		return false
	}
	parsed, err := time.ParseInLocation("01/02/06 15:04:05", value, time.Local)
	return err == nil && parsed.Format("01/02/06 15:04:05") == value
}

func validOwner(value string, allowLegacy bool) bool {
	prefixes := []string{"teaway:"}
	if allowLegacy {
		prefixes = append(prefixes, "tea-away:")
	}
	for _, prefix := range prefixes {
		if !strings.HasPrefix(value, prefix) {
			continue
		}
		id := strings.TrimPrefix(value, prefix)
		if len(id) < 1 || len(id) > 80 {
			return false
		}
		for i := 0; i < len(id); i++ {
			b := id[i]
			if !(b >= '0' && b <= '9' || b >= 'A' && b <= 'Z' || b >= 'a' && b <= 'z' || b == '-') {
				return false
			}
		}
		return true
	}
	return false
}

func RunHelper(args []string) int {
	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "teaway: teaway privileged helper must run as root")
		return 77
	}
	kind, op, ok := ParseRequest(args)
	if !ok {
		fmt.Fprintln(os.Stderr, "teaway: invalid teaway privileged helper request")
		return 64
	}
	switch kind {
	case "probe":
		fmt.Println("ok")
		return 0
	case "version":
		fmt.Println(HelperName + " " + version.Current)
		return 0
	default:
		result, err := (execx.System{}).Run(execx.Command{Path: execx.Pmset, Args: op.pmsetArgs()})
		if err != nil {
			fmt.Fprintln(os.Stderr, "teaway:", err)
			return 1
		}
		fmt.Fprint(os.Stdout, result.Stdout)
		fmt.Fprint(os.Stderr, result.Stderr)
		return result.ExitCode
	}
}

type AuthStatus string

const (
	AuthUnregistered AuthStatus = "unregistered"
	AuthRegistered   AuthStatus = "registered"
	AuthNeedsRepair  AuthStatus = "needs-repair"
)

type TouchIDStatus string

const (
	TouchIDEnabled  TouchIDStatus = "enabled"
	TouchIDDisabled TouchIDStatus = "disabled"
	TouchIDUnknown  TouchIDStatus = "unknown"
)

type Registration struct {
	Runner     execx.Runner
	Executable string
	UserName   string
	UID        int
	Exists     func(string) bool
	ReadFile   func(string) (string, error)
}

func CurrentUser() (string, int, error) {
	u, err := user.Current()
	if err != nil {
		return "", 0, err
	}
	uid, _ := strconv.Atoi(u.Uid)
	return u.Username, uid, nil
}

func (r Registration) exists(path string) bool {
	if r.Exists != nil {
		return r.Exists(path)
	}
	_, err := os.Stat(path)
	return err == nil
}

func (r Registration) Status() (AuthStatus, string, error) {
	helper, sudoers, legacy := HelperPath(r.UID), SudoersPath(r.UID), LegacySudoersPath(r.UID)
	helperOK, sudoersOK, legacyOK := r.exists(helper), r.exists(sudoers), r.exists(legacy)
	if legacyOK && !sudoersOK {
		return AuthNeedsRepair, "the legacy sudoers filename contains dots and is ignored by macOS; run 'teaway auth register'", nil
	}
	if !helperOK && !sudoersOK {
		return AuthUnregistered, "", nil
	}
	if !helperOK {
		return AuthNeedsRepair, "the privileged helper is missing", nil
	}
	if !sudoersOK {
		return AuthNeedsRepair, "the sudoers rule is missing", nil
	}
	result, err := r.Runner.Run(execx.Command{Path: execx.Sudo, Args: []string{"-n", helper, InternalCommand, "version"}})
	if err != nil || result.ExitCode != 0 {
		detail := strings.TrimSpace(result.Stderr)
		if detail == "" {
			detail = "the registered helper is not authorized"
		}
		return AuthNeedsRepair, detail, nil
	}
	fields := strings.Fields(result.Stdout)
	if len(fields) != 2 || fields[0] != HelperName {
		return AuthNeedsRepair, "the registered helper returned an invalid version", nil
	}
	if fields[1] != version.Current {
		return AuthNeedsRepair, fmt.Sprintf("helper version %s does not match teaway %s", fields[1], version.Current), nil
	}
	return AuthRegistered, fields[1], nil
}

func (r Registration) TouchID() (TouchIDStatus, string) {
	read := r.ReadFile
	if read == nil {
		read = func(path string) (string, error) {
			data, err := os.ReadFile(path)
			return string(data), err
		}
	}
	for _, path := range []string{"/etc/pam.d/sudo_local", "/etc/pam.d/sudo"} {
		if !r.exists(path) {
			continue
		}
		contents, err := read(path)
		if err != nil {
			return TouchIDUnknown, err.Error()
		}
		for _, line := range strings.Split(contents, "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			fields := strings.Fields(line)
			if len(fields) >= 3 && fields[0] == "auth" && fields[1] == "sufficient" && fields[2] == "pam_tid.so" {
				return TouchIDEnabled, ""
			}
		}
	}
	return TouchIDDisabled, ""
}

func validUserName(value string) bool {
	if value == "" || len(value) > 64 {
		return false
	}
	for i := 0; i < len(value); i++ {
		b := value[i]
		if !(b >= '0' && b <= '9' || b >= 'A' && b <= 'Z' || b >= 'a' && b <= 'z' || b == '-' || b == '.' || b == '_') {
			return false
		}
	}
	return true
}

func (r Registration) sudoersContents() string {
	prefix := fmt.Sprintf("%s ALL=(root) NOPASSWD: %s %s", r.UserName, HelperPath(r.UID), InternalCommand)
	return strings.Join([]string{
		fmt.Sprintf("# Managed by teaway auth register for uid %d.", r.UID),
		"# The root-owned helper validates every dynamic date and owner argument.",
		prefix + " version",
		prefix + " " + cmdSet + " 0",
		prefix + " " + cmdSet + " 1",
		prefix + " " + cmdSchedule + " *",
		prefix + " " + cmdCancel + " *",
		"",
	}, "\n")
}

func (r Registration) Register() (string, string, string, error) {
	if r.UID == 0 {
		return "", "", "", teaerr.AuthConfig("registration must be run from the target user account, not root")
	}
	if !validUserName(r.UserName) {
		return "", "", "", teaerr.AuthConfig("unsupported macOS short user name: " + r.UserName)
	}
	execPath := r.Executable
	helperPath := HelperPath(r.UID)
	sudoersPath := SudoersPath(r.UID)
	if execPath == helperPath {
		return "", "", "", teaerr.AuthConfig("run registration from the normal teaway executable")
	}
	info, err := os.Stat(execPath)
	if err != nil || info.IsDir() || info.Mode()&0o111 == 0 {
		return "", "", "", teaerr.AuthConfig("cannot resolve the current teaway executable: " + execPath)
	}
	tmp, err := os.MkdirTemp("", "teaway-auth-*")
	if err != nil {
		return "", "", "", err
	}
	defer os.RemoveAll(tmp)
	tmpSudoers := filepath.Join(tmp, "sudoers")
	if err := os.WriteFile(tmpSudoers, []byte(r.sudoersContents()), 0o600); err != nil {
		return "", "", "", err
	}
	if _, err := execx.Must(r.Runner, execx.Command{Path: execx.Visudo, Args: []string{"-c", "-f", tmpSudoers}}); err != nil {
		return "", "", "", err
	}
	if _, err := execx.MustInteractive(r.Runner, execx.Command{Path: execx.Sudo, Args: []string{"-v"}}); err != nil {
		return "", "", "", err
	}
	if _, err := execx.MustInteractive(r.Runner, execx.Command{Path: execx.Sudo, Args: []string{execx.Install, "-d", "-o", "root", "-g", "wheel", "-m", "0755", HelperDir}}); err != nil {
		return "", "", "", err
	}
	if _, err := execx.MustInteractive(r.Runner, execx.Command{Path: execx.Sudo, Args: []string{execx.Install, "-o", "root", "-g", "wheel", "-m", "0755", execPath, helperPath}}); err != nil {
		return "", "", "", err
	}
	if _, err := execx.Must(r.Runner, execx.Command{Path: execx.Cmp, Args: []string{"-s", execPath, helperPath}}); err != nil {
		return "", "", "", err
	}
	if _, err := execx.MustInteractive(r.Runner, execx.Command{Path: execx.Sudo, Args: []string{execx.Install, "-o", "root", "-g", "wheel", "-m", "0440", tmpSudoers, sudoersPath}}); err != nil {
		return "", "", "", err
	}
	if _, err := execx.MustInteractive(r.Runner, execx.Command{Path: execx.Sudo, Args: []string{execx.Visudo, "-c", "-f", sudoersPath}}); err != nil {
		return "", "", "", err
	}
	if _, err := execx.MustInteractive(r.Runner, execx.Command{Path: execx.Sudo, Args: []string{execx.Rm, "-f", LegacySudoersPath(r.UID)}}); err != nil {
		return "", "", "", err
	}
	result, err := execx.Must(r.Runner, execx.Command{Path: execx.Sudo, Args: []string{"-n", helperPath, InternalCommand, "version"}})
	if err != nil {
		return "", "", "", err
	}
	fields := strings.Fields(result.Stdout)
	if len(fields) != 2 || fields[0] != HelperName {
		return "", "", "", teaerr.AuthConfig("the installed helper returned an invalid version")
	}
	if fields[1] != version.Current {
		return "", "", "", teaerr.AuthConfig(fmt.Sprintf("the installed helper version %s does not match teaway %s", fields[1], version.Current))
	}
	return helperPath, sudoersPath, fields[1], nil
}

func (r Registration) Unregister() error {
	if _, err := execx.MustInteractive(r.Runner, execx.Command{Path: execx.Sudo, Args: []string{"-v"}}); err != nil {
		return err
	}
	for _, path := range []string{HelperPath(r.UID), SudoersPath(r.UID), LegacySudoersPath(r.UID)} {
		if _, err := execx.MustInteractive(r.Runner, execx.Command{Path: execx.Sudo, Args: []string{execx.Rm, "-f", path}}); err != nil {
			return err
		}
	}
	return nil
}
