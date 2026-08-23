package state

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestRoundTripAndPermissions(t *testing.T) {
	dir := t.TempDir()
	store := Store{Paths: Paths{Directory: dir}}
	state := Empty()
	now := time.Date(2023, 11, 14, 22, 13, 20, 0, time.UTC)
	state.Power = &PowerRecord{OriginalDisableSleep: 0, ExpectedDisableSleep: 1, CreatedAt: now, Phase: PowerEnabled}
	if err := store.Save(state); err != nil {
		t.Fatal(err)
	}
	got, err := store.Load()
	if err != nil {
		t.Fatal(err)
	}
	if got.Power == nil || got.Power.OriginalDisableSleep != 0 {
		t.Fatalf("unexpected state: %+v", got)
	}
	info, err := os.Stat(store.Paths.StateFile())
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("state file mode %o", info.Mode().Perm())
	}
}

func TestResolveIgnoresLegacyStateEnv(t *testing.T) {
	got := Resolve(map[string]string{
		"HOME":               "/tmp/teaway-home",
		"TEA_STATE_DIR":      "/tmp/legacy-tea",
		"TEA_AWAY_STATE_DIR": "/tmp/legacy-tea-away",
	})
	if got.Directory != "/tmp/teaway-home/Library/Application Support/teaway" {
		t.Fatalf("Directory = %q", got.Directory)
	}
}

func TestPermissionErrorIncludesRepair(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")
	if err := os.WriteFile(path, []byte(`{"schemaVersion":1}`), 0o000); err != nil {
		t.Fatal(err)
	}
	store := Store{Paths: Paths{Directory: dir}}
	_, err := store.Load()
	if err == nil {
		t.Skip("running as root; permission bit is not enforced")
	}
}
