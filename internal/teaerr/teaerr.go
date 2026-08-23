package teaerr

import (
	"errors"
	"fmt"
	"strings"
)

type Kind int

const (
	KindUsage Kind = iota
	KindInvalidDuration
	KindDurationOutOfRange
	KindStateLocked
	KindStateCorrupt
	KindStatePermission
	KindPowerUnreadable
	KindPowerConflict
	KindPowerRecovery
	KindShutdownExists
	KindNoShutdown
	KindActionIDMismatch
	KindPlanExpired
	KindShutdownConflict
	KindShutdownUnreadable
	KindShutdownVerify
	KindShutdownRecovery
	KindAuthConfig
	KindCommandFailed
	KindRootRefused
)

type Error struct {
	Kind    Kind
	Message string
	Path    string
	Repair  string
}

func (e *Error) Error() string { return e.Message }

func Usage(message string) error {
	return &Error{Kind: KindUsage, Message: message}
}

func InvalidDuration(value string) error {
	return &Error{
		Kind:    KindInvalidDuration,
		Message: fmt.Sprintf("invalid duration: %s; use values such as 30m, 4h, or 1d", value),
	}
}

func DurationOutOfRange(minimum, maximum int) error {
	return &Error{
		Kind:    KindDurationOutOfRange,
		Message: fmt.Sprintf("duration must be between %d and %d seconds", minimum, maximum),
	}
}

func StateLocked() error {
	return &Error{Kind: KindStateLocked, Message: "another teaway operation is updating state"}
}

func StateCorrupt(message string) error {
	return &Error{Kind: KindStateCorrupt, Message: "teaway state is unreadable: " + message}
}

func StatePermission(path, detail, repair string) error {
	return &Error{
		Kind:    KindStatePermission,
		Path:    path,
		Repair:  repair,
		Message: fmt.Sprintf("teaway state is unreadable: %s: %s", path, detail),
	}
}

func PowerUnreadable(detail string) error {
	return &Error{Kind: KindPowerUnreadable, Message: "cannot safely read macOS disablesleep state: " + detail}
}

func PowerConflict(expected, actual int) error {
	return &Error{
		Kind: KindPowerConflict,
		Message: fmt.Sprintf(
			"refusing to change disablesleep because teaway expected %d but macOS reports %d; the recovery record was retained",
			expected,
			actual,
		),
	}
}

func PowerRecovery(detail string) error {
	return &Error{
		Kind:    KindPowerRecovery,
		Message: "power state needs recovery; teaway retained the original disablesleep value. " + detail,
	}
}

func ShutdownExists(id string) error {
	return &Error{
		Kind:    KindShutdownExists,
		Message: fmt.Sprintf("shutdown action %s already exists; cancel it before planning another", id),
	}
}

func NoShutdown() error {
	return &Error{Kind: KindNoShutdown, Message: "no teaway shutdown action is recorded"}
}

func ActionIDMismatch() error {
	return &Error{Kind: KindActionIDMismatch, Message: "action ID does not match the recorded shutdown plan"}
}

func PlanExpired() error {
	return &Error{Kind: KindPlanExpired, Message: "shutdown plan expired; create a new plan before committing"}
}

func ShutdownConflict(detail string) error {
	return &Error{
		Kind:    KindShutdownConflict,
		Message: "refusing to change shutdown state because macOS reports a conflicting event: " + detail,
	}
}

func ShutdownUnreadable(detail string) error {
	return &Error{
		Kind:    KindShutdownUnreadable,
		Message: "cannot safely interpret macOS scheduled power events: " + detail,
	}
}

func ShutdownVerify(id string) error {
	return &Error{
		Kind:    KindShutdownVerify,
		Message: fmt.Sprintf("macOS did not report the exact teaway shutdown after scheduling action %s", id),
	}
}

func ShutdownRecovery(id, detail string) error {
	return &Error{
		Kind: KindShutdownRecovery,
		Message: fmt.Sprintf(
			"HIGH RISK: shutdown action %s may still be active; teaway retained its recovery record. Run 'teaway shutdown status' and then 'teaway shutdown cancel %s'. %s",
			id, id, detail,
		),
	}
}

func AuthConfig(detail string) error {
	return &Error{Kind: KindAuthConfig, Message: "authorization configuration failed: " + detail}
}

func CommandFailed(path string, status int, stderr string) error {
	detail := strings.TrimSpace(stderr)
	message := fmt.Sprintf("command failed (%d): %s", status, path)
	if detail != "" {
		message += ": " + detail
	}
	return &Error{Kind: KindCommandFailed, Message: message}
}

func RootRefused() error {
	return &Error{
		Kind:    KindRootRefused,
		Message: "do not run teaway with sudo. The user-facing CLI must run as your account so state.json stays readable. teaway will ask sudo only for the narrow pmset change.",
	}
}

func IsUsage(err error) bool {
	typed, ok := As(err)
	return ok && typed.Kind == KindUsage
}

func As(err error) (*Error, bool) {
	var typed *Error
	if errors.As(err, &typed) {
		return typed, true
	}
	return nil, false
}
