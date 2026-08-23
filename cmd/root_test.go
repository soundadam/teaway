package cmd

import (
	"bytes"
	"strings"
	"testing"

	"github.com/soundadam/teaway/internal/version"
)

func TestVersionCommand(t *testing.T) {
	root := NewRoot()
	buf := new(bytes.Buffer)
	root.SetOut(buf)
	root.SetErr(buf)
	root.SetArgs([]string{"version"})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	got := strings.TrimSpace(buf.String())
	want := "teaway " + version.Current
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}
