package tui

import (
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/soundadam/teaway/internal/duration"
)

func TestShutdownStepsAreInBounds(t *testing.T) {
	if shutdownSteps[defaultShutdownIndex()] != defaultShutdownStep {
		t.Fatalf("default step %q is not at the default index", defaultShutdownStep)
	}
	for _, step := range shutdownSteps {
		seconds, err := duration.ParseShutdown(step)
		if err != nil {
			t.Fatalf("ParseShutdown(%q): %v", step, err)
		}
		if seconds < 10*duration.Minute || seconds > 7*duration.Day {
			t.Fatalf("%s is outside 10m–7d", step)
		}
	}
}

func TestDurationPickerKeys(t *testing.T) {
	m := durationPicker{
		index: defaultShutdownIndex(),
		now:   time.Date(2026, 8, 23, 16, 0, 0, 0, time.UTC),
		loc:   time.UTC,
		width: 80,
	}
	start := m.index

	m = mustPicker(t, m, tea.KeyMsg{Type: tea.KeyRight})
	if m.index != start+1 {
		t.Fatalf("right: index %d want %d", m.index, start+1)
	}

	m = mustPicker(t, m, tea.KeyMsg{Type: tea.KeyLeft})
	if m.index != start {
		t.Fatalf("left: index %d want %d", m.index, start)
	}

	m = mustPicker(t, m, tea.KeyMsg{Type: tea.KeyDown})
	if m.index != start-1 {
		t.Fatalf("down: index %d want %d", m.index, start-1)
	}
	m = mustPicker(t, m, tea.KeyMsg{Type: tea.KeyUp})
	if m.index != start {
		t.Fatalf("up: index %d want %d", m.index, start)
	}

	m = mustPicker(t, m, tea.KeyMsg{Type: tea.KeyHome})
	if m.index != 0 {
		t.Fatalf("home: index %d", m.index)
	}
	m = mustPicker(t, m, tea.KeyMsg{Type: tea.KeyLeft})
	if m.index != 0 {
		t.Fatal("left at start should clamp")
	}

	m = mustPicker(t, m, tea.KeyMsg{Type: tea.KeyEnd})
	if m.index != len(shutdownSteps)-1 {
		t.Fatalf("end: index %d", m.index)
	}

	m = mustPicker(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'c'}})
	if !m.custom {
		t.Fatal("c should request custom input")
	}

	m.custom = false
	m = mustPicker(t, m, tea.KeyMsg{Type: tea.KeyEnter})
	if !m.confirmed {
		t.Fatal("enter should confirm")
	}

	m.confirmed = false
	m = mustPicker(t, m, tea.KeyMsg{Type: tea.KeyEsc})
	if !m.canceled {
		t.Fatal("esc should cancel")
	}
}

func TestDurationPickerView(t *testing.T) {
	m := durationPicker{
		index: defaultShutdownIndex(),
		now:   time.Date(2026, 8, 23, 16, 0, 0, 0, time.UTC),
		loc:   time.UTC,
		width: 80,
	}
	view := m.View()
	for _, want := range []string{"2 hours", "●", "10m", "7d", "Sun 18:00"} {
		if !strings.Contains(view, want) {
			t.Fatalf("missing %q in:\n%s", want, view)
		}
	}
}

func TestHumanDuration(t *testing.T) {
	cases := map[string]string{"15m": "15 minutes", "1h": "1 hour", "2d": "2 days"}
	for in, want := range cases {
		if got := humanDuration(in); got != want {
			t.Fatalf("humanDuration(%q)=%q want %q", in, got, want)
		}
	}
}

func TestRenderTrackMarksCurrentStep(t *testing.T) {
	track := renderTrack(4, 40)
	if !strings.Contains(track, "●") {
		t.Fatalf("track should include a knob: %q", track)
	}
	if strings.Count(track, "●") != 1 {
		t.Fatalf("expected one knob: %q", track)
	}
}

func mustPicker(t *testing.T, m durationPicker, msg tea.Msg) durationPicker {
	t.Helper()
	next, _ := m.Update(msg)
	picked, ok := next.(durationPicker)
	if !ok {
		t.Fatalf("Update returned %T", next)
	}
	return picked
}
