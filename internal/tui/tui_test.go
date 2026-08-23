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
		loc,
	)
	if idle != "Sleep allowed" {
		t.Fatalf("idle status:\n%s", idle)
	}

	busy := statusDescription(
		power.Status{Observation: power.On, PowerSource: "Battery Power", LiveDisableSleep: 1},
		shutdown.Status{
			Observation: shutdown.Scheduled,
			Record:      &state.ShutdownRecord{ScheduledAt: when},
		},
		loc,
	)
	for _, want := range []string{
		"Staying awake",
		"On battery",
		"Shutdown · Mon 02:00",
	} {
		if !strings.Contains(busy, want) {
			t.Fatalf("missing %q in:\n%s", want, busy)
		}
	}
	if strings.Contains(busy, "disablesleep") {
		t.Fatalf("TUI status should not dump native sleep keys:\n%s", busy)
	}
}

func TestStatusLinesStayShort(t *testing.T) {
	loc := time.FixedZone("CST", 8*3600)
	when := time.Date(2026, 8, 24, 2, 0, 0, 0, loc)
	text := statusDescription(
		power.Status{Observation: power.On, PowerSource: "Battery Power"},
		shutdown.Status{Observation: shutdown.Scheduled, Record: &state.ShutdownRecord{ScheduledAt: when}},
		loc,
	)
	for _, line := range strings.Split(text, "\n") {
		if len([]rune(line)) > 28 {
			t.Fatalf("status line too long (%d): %q", len([]rune(line)), line)
		}
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
