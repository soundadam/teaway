package tui

import (
	"strings"
	"testing"
)

func TestPreviewMenuLooksLikeTheClient(t *testing.T) {
	view := PreviewMenu()
	for _, want := range []string{
		"Teaway",
		"Sleep is allowed",
		"Keep this Mac awake",
		"Schedule a shutdown",
		"Set up passwordless controls",
	} {
		if !strings.Contains(view, want) {
			t.Fatalf("missing %q in:\n%s", want, view)
		}
	}
	if !strings.Contains(view, "\x1b[") {
		t.Fatal("menu preview should keep ANSI color")
	}
}

func TestPreviewShutdownLooksLikeThePicker(t *testing.T) {
	view := PreviewShutdown()
	for _, want := range []string{"Schedule a shutdown", "2 hours", "10m", "7d", "●"} {
		if !strings.Contains(view, want) {
			t.Fatalf("missing %q in:\n%s", want, view)
		}
	}
	if !strings.Contains(view, "\x1b[") {
		t.Fatal("shutdown preview should keep ANSI color")
	}
}
