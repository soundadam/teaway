package tui

import (
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/huh"

	"github.com/soundadam/teaway/internal/power"
	"github.com/soundadam/teaway/internal/privilege"
	"github.com/soundadam/teaway/internal/shutdown"
	"github.com/soundadam/teaway/internal/state"
)

func TestStatusDescriptionIsSituational(t *testing.T) {
	loc := time.FixedZone("CST", 8*3600)
	when := time.Date(2026, 8, 24, 2, 0, 0, 0, loc)

	idle := statusDescription(
		power.Status{Observation: power.Off, PowerSource: "AC Power", LiveDisableSleep: 0},
		shutdown.Status{},
		privilege.AuthRegistered,
		loc,
	)
	if !strings.Contains(idle, "Sleep is allowed") {
		t.Fatalf("idle status should describe allowed sleep:\n%s", idle)
	}
	for _, leftover := range []string{"disablesleep", "Passwordless", "Not scheduled", "Awake", "Power"} {
		if strings.Contains(idle, leftover) {
			t.Fatalf("idle status should omit %q:\n%s", leftover, idle)
		}
	}

	busy := statusDescription(
		power.Status{Observation: power.On, PowerSource: "Battery Power", LiveDisableSleep: 1},
		shutdown.Status{
			Observation: shutdown.Scheduled,
			Record:      &state.ShutdownRecord{ScheduledAt: when},
		},
		privilege.AuthNeedsRepair,
		loc,
	)
	for _, want := range []string{
		"This Mac stays awake",
		"On battery",
		"Shutdown scheduled",
		"2026-08-24 02:00:00 +08:00",
		"Passwordless controls need repair",
	} {
		if !strings.Contains(busy, want) {
			t.Fatalf("missing %q in:\n%s", want, busy)
		}
	}
	if strings.Contains(busy, "disablesleep") {
		t.Fatalf("TUI status should not dump native sleep keys:\n%s", busy)
	}
}

func TestMenuOptionsDependOnState(t *testing.T) {
	idle := optionValues(menuOptions(false, privilege.AuthRegistered))
	if containsValue(idle, "cancel") || containsValue(idle, "auth") || containsValue(idle, "refresh") {
		t.Fatalf("ready idle menu should omit cancel, auth, and refresh: %v", idle)
	}
	unregistered := optionValues(menuOptions(false, privilege.AuthUnregistered))
	if !containsValue(unregistered, "auth") {
		t.Fatalf("unregistered menu should offer auth: %v", unregistered)
	}
	busy := optionValues(menuOptions(true, privilege.AuthNeedsRepair))
	if !containsValue(busy, "cancel") || !containsValue(busy, "auth") {
		t.Fatalf("repair + shutdown menu should offer cancel and auth: %v", busy)
	}
}

func TestNeedsPasswordlessSetup(t *testing.T) {
	if !needsPasswordlessSetup(privilege.AuthUnregistered) || !needsPasswordlessSetup(privilege.AuthNeedsRepair) {
		t.Fatal("unregistered and needs-repair should prompt")
	}
	if needsPasswordlessSetup(privilege.AuthRegistered) {
		t.Fatal("registered should not prompt")
	}
}

func optionValues(opts []huh.Option[string]) []string {
	out := make([]string, len(opts))
	for i, opt := range opts {
		out[i] = opt.Value
	}
	return out
}

func containsValue(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}
