package tui

import (
	"strings"
	"testing"
)

func TestPreviewMenuLooksLikeTheClient(t *testing.T) {
	view := PreviewMenu()
	for _, want := range []string{
		"Teaway",
		"Sleep allowed",
		"Stay awake",
		"Shut down later",
		"Passwordless",
	} {
		if !strings.Contains(view, want) {
			t.Fatalf("missing %q in:\n%s", want, view)
		}
	}
	if !strings.Contains(view, "\x1b[") {
		t.Fatal("menu preview should keep ANSI color")
	}
	if strings.Contains(view, "filter") {
		t.Fatalf("menu should not expose filter chrome:\n%s", view)
	}
}

func TestPreviewShutdownLooksLikeThePicker(t *testing.T) {
	view := PreviewShutdown()
	for _, want := range []string{"Shutdown", "2 hours", "10m", "7d", "●", "Mon 02:36"} {
		if !strings.Contains(view, want) {
			t.Fatalf("missing %q in:\n%s", want, view)
		}
	}
	if !strings.Contains(view, "\x1b[") {
		t.Fatal("shutdown preview should keep ANSI color")
	}
}
