package shutdown

import "testing"

func TestParseScheduleIndexedEvent(t *testing.T) {
	events, err := ParseSchedule("[0]  shutdown at 11/14/23 22:13:20 by 'teaway:action-1'\n")
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || events[0].Owner != "teaway:action-1" || events[0].Date != "11/14/23 22:13:20" {
		t.Fatalf("%+v", events)
	}
}

func TestParseScheduleNormalizesFourDigitYear(t *testing.T) {
	events, err := ParseSchedule("[0]  shutdown at 11/14/2023 22:13:20 by 'teaway:action-1'\n")
	if err != nil {
		t.Fatal(err)
	}
	if events[0].Date != "11/14/23 22:13:20" {
		t.Fatalf("date %q", events[0].Date)
	}
}
