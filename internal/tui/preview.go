package tui

import (
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/soundadam/teaway/internal/power"
	"github.com/soundadam/teaway/internal/privilege"
	"github.com/soundadam/teaway/internal/shutdown"
)

func forcePreviewTerm() {
	lipgloss.SetColorProfile(termenv.TrueColor)
	lipgloss.SetHasDarkBackground(true)
}

func PreviewMenu() string {
	forcePreviewTerm()
	action := ""
	form := newMenuForm(
		power.Status{Observation: power.Off, PowerSource: "AC Power"},
		shutdown.Status{},
		privilege.AuthUnregistered,
		time.FixedZone("CST", 8*3600),
		&action,
	).WithTheme(clientTheme()).WithKeyMap(clientKeyMap()).WithShowHelp(false).WithWidth(40)
	_ = form.Init()
	model, _ := form.Update(tea.WindowSizeMsg{Width: 40, Height: 14})
	return compactPreview(model.View())
}

func PreviewShutdown() string {
	forcePreviewTerm()
	loc := time.FixedZone("CST", 8*3600)
	m := durationPicker{
		index: defaultShutdownIndex(),
		now:   time.Date(2026, 8, 24, 0, 36, 0, 0, loc),
		loc:   loc,
		width: 40,
	}
	return compactPreview(m.View())
}

func compactPreview(view string) string {
	lines := strings.Split(strings.TrimRight(view, "\n"), "\n")
	for i, line := range lines {
		lines[i] = strings.TrimRight(line, " ")
	}
	return strings.Join(lines, "\n") + "\n"
}
