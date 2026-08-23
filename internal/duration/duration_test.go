package duration

import "testing"

func TestParseSupportedUnits(t *testing.T) {
	cases := map[string]int{"90s": 90, "30m": 1800, "4h": 14400, "2d": 172800}
	for in, want := range cases {
		got, err := Parse(in)
		if err != nil {
			t.Fatalf("Parse(%q): %v", in, err)
		}
		if got != want {
			t.Fatalf("Parse(%q)=%d want %d", in, got, want)
		}
	}
}

func TestParseRejectsInvalid(t *testing.T) {
	for _, in := range []string{"", "0m", "1.5h", "30", "-1h", "1w"} {
		if _, err := Parse(in); err == nil {
			t.Fatalf("Parse(%q) succeeded", in)
		}
	}
}

func TestParseShutdownBounds(t *testing.T) {
	got, err := ParseShutdown("10m")
	if err != nil || got != 600 {
		t.Fatalf("ParseShutdown(10m)=%d %v", got, err)
	}
	if _, err := ParseShutdown("9m"); err == nil {
		t.Fatal("expected 9m to fail")
	}
}
