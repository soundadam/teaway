package privilege

import "testing"

func TestParseRequestAcceptsAllowlistedCommands(t *testing.T) {
	if _, op, ok := ParseRequest([]string{"set-disablesleep", "1"}); !ok || op.kind != cmdSet {
		t.Fatal("expected set-disablesleep 1")
	}
	if _, _, ok := ParseRequest([]string{"set-disablesleep", "2"}); ok {
		t.Fatal("rejected disable sleep 2")
	}
	if _, _, ok := ParseRequest([]string{"version"}); !ok {
		t.Fatal("expected version")
	}
}

func TestValidOwnerAndDate(t *testing.T) {
	if !validDate("11/14/23 22:13:20") {
		t.Fatal("expected canonical date")
	}
	if validDate("11/14/2023 22:13:20") {
		t.Fatal("four-digit year should be rejected before normalize")
	}
	if !validOwner("teaway:abc-1", false) {
		t.Fatal("expected teaway owner")
	}
	if validOwner("tea-away:abc-1", false) {
		t.Fatal("legacy owner should require allowLegacy")
	}
	if !validOwner("tea-away:abc-1", true) {
		t.Fatal("legacy owner should be allowed for cancel")
	}
}
