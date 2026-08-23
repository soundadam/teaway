package tui

import (
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/lipgloss"

	"github.com/soundadam/teaway/internal/app"
	"github.com/soundadam/teaway/internal/duration"
)

// Logarithmic-ish stops inside the product bounds of 10 minutes–7 days.
var shutdownSteps = []string{
	"10m", "15m", "30m", "1h", "2h", "4h", "8h", "12h", "1d", "2d", "3d", "5d", "7d",
}

const defaultShutdownStep = "2h"

var majorStepIndexes = []int{0, 3, 8, 12} // 10m, 1h, 1d, 7d

type durationPicker struct {
	index     int
	width     int
	now       time.Time
	loc       *time.Location
	custom    bool
	confirmed bool
	canceled  bool
}

func defaultShutdownIndex() int {
	for i, step := range shutdownSteps {
		if step == defaultShutdownStep {
			return i
		}
	}
	return 0
}

func pickShutdownDuration(application app.App) (string, error) {
	now := time.Now()
	if application.Now != nil {
		now = application.Now()
	}
	loc := application.TimeZone
	if loc == nil {
		loc = time.Local
	}
	model, err := runProgram(application, durationPicker{
		index: defaultShutdownIndex(),
		now:   now,
		loc:   loc,
		width: 80,
	})
	if err != nil {
		if err == tea.ErrInterrupted {
			return "", huh.ErrUserAborted
		}
		return "", err
	}
	picked, ok := model.(durationPicker)
	if !ok || picked.canceled {
		return "", huh.ErrUserAborted
	}
	if picked.custom {
		return askCustomDuration(application)
	}
	return shutdownSteps[picked.index], nil
}

func askCustomDuration(application app.App) (string, error) {
	value := ""
	form := huh.NewForm(
		huh.NewGroup(
			huh.NewInput().
				Title("Custom delay").
				Description("Examples: 45m, 3h, 2d. Between 10 minutes and 7 days.").
				Placeholder("90m").
				Value(&value).
				Validate(func(in string) error {
					_, err := duration.ParseShutdown(strings.TrimSpace(in))
					return err
				}),
		),
	)
	if err := runForm(application, form); err != nil {
		return "", err
	}
	return strings.TrimSpace(value), nil
}

func (m durationPicker) Init() tea.Cmd { return nil }

func (m durationPicker) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		return m, nil
	case tea.KeyMsg:
		switch msg.String() {
		case "left", "h", "backspace":
			if m.index > 0 {
				m.index--
			}
		case "right", "l":
			if m.index < len(shutdownSteps)-1 {
				m.index++
			}
		case "home":
			m.index = 0
		case "end":
			m.index = len(shutdownSteps) - 1
		case "c":
			m.custom = true
			return m, tea.Quit
		case "enter":
			m.confirmed = true
			return m, tea.Quit
		case "esc", "q", "ctrl+c":
			m.canceled = true
			return m, tea.Quit
		}
	}
	return m, nil
}

func (m durationPicker) View() string {
	step := shutdownSteps[m.index]
	seconds, _ := duration.ParseShutdown(step)
	at := m.now.Add(time.Duration(seconds) * time.Second).In(m.loc)

	title := titleStyle.Render("Schedule a shutdown")
	pill := pillStyle.Render(humanDuration(step))
	around := faintStyle.Render("around " + at.Format("Mon 15:04 · 2006-01-02"))
	trackWidth := m.trackWidth()
	labels := placeTickLabels(trackWidth)
	track := knobStyle.Render(renderTrack(m.index, trackWidth))
	help := faintStyle.Render("← → step    c custom    enter schedule    esc back")

	return lipgloss.JoinVertical(lipgloss.Left,
		title,
		"",
		"  "+pill,
		"  "+around,
		"",
		"  "+labels,
		"  "+track,
		"",
		"  "+help,
	)
}

func (m durationPicker) trackWidth() int {
	w := m.width - 4
	if w < 24 {
		w = 24
	}
	if w > 56 {
		w = 56
	}
	return w
}

func renderTrack(index, width int) string {
	n := len(shutdownSteps)
	if width < 2 {
		width = 2
	}
	cells := make([]rune, width)
	for i := range cells {
		cells[i] = '─'
	}
	for _, idx := range majorStepIndexes {
		pos := stepPosition(idx, n, width)
		cells[pos] = '┼'
	}
	cells[0] = '├'
	cells[width-1] = '┤'
	cells[stepPosition(index, n, width)] = '●'
	return string(cells)
}

func stepPosition(index, n, width int) int {
	if n <= 1 {
		return 0
	}
	return index * (width - 1) / (n - 1)
}

func placeTickLabels(width int) string {
	row := []rune(strings.Repeat(" ", width))
	n := len(shutdownSteps)
	type tick struct {
		index int
		text  string
	}
	for _, label := range []tick{
		{0, "10m"},
		{3, "1h"},
		{8, "1d"},
		{n - 1, "7d"},
	} {
		text := []rune(label.text)
		pos := stepPosition(label.index, n, width)
		start := pos
		switch {
		case label.index == n-1:
			start = width - len(text)
		case label.index != 0:
			start = pos - len(text)/2
		}
		if start < 0 {
			start = 0
		}
		if start+len(text) > width {
			start = width - len(text)
		}
		copy(row[start:], text)
	}
	return string(row)
}

func humanDuration(value string) string {
	if value == "" {
		return value
	}
	amount, unit := value[:len(value)-1], value[len(value)-1]
	switch unit {
	case 'm':
		if amount == "1" {
			return "1 minute"
		}
		return amount + " minutes"
	case 'h':
		if amount == "1" {
			return "1 hour"
		}
		return amount + " hours"
	case 'd':
		if amount == "1" {
			return "1 day"
		}
		return amount + " days"
	default:
		return value
	}
}

var (
	titleStyle = lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#5A56E0", Dark: "#7571F9"}).
			Bold(true)
	pillStyle = lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#FFFDF5", Dark: "#FFFDF5"}).
			Background(lipgloss.Color("#F780E2")).
			Padding(0, 1)
	knobStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#F780E2"))
	faintStyle = lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "243", Dark: "243"})
)
