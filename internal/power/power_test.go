package power

import "testing"

func TestParseDisableSleep(t *testing.T) {
	got, err := ParseDisableSleep("System-wide power settings:\n SleepDisabled 1\n")
	if err != nil || got != 1 {
		t.Fatalf("got %d %v", got, err)
	}
	if _, err := ParseDisableSleep("System-wide power settings:\n"); err == nil {
		t.Fatal("expected missing disablesleep to fail")
	}
}

func TestParsePowerSource(t *testing.T) {
	got, err := ParsePowerSource("Now drawing from 'Battery Power'\n")
	if err != nil || got != "Battery Power" {
		t.Fatalf("got %q %v", got, err)
	}
}
