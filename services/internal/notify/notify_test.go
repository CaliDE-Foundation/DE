package notify

import (
	"testing"
	"time"
)

func TestTimeout(t *testing.T) {
	cases := []struct {
		expire  int32
		urgency byte
		want    time.Duration
	}{
		{-1, UrgencyNormal, DefaultTimeout},
		{0, UrgencyNormal, 0},
		{2500, UrgencyLow, 2500 * time.Millisecond},
		{2500, UrgencyCritical, 0},
		{-1, UrgencyCritical, 0},
	}
	for _, c := range cases {
		if got := Timeout(c.expire, c.urgency); got != c.want {
			t.Errorf("Timeout(%d, %d) = %v, want %v", c.expire, c.urgency, got, c.want)
		}
	}
}

func TestIcon(t *testing.T) {
	cases := []struct{ appIcon, entry, want string }{
		{"mail-unread", "org.gnome.Evolution", "mail-unread"},
		{"file:///tmp/a.png", "", "/tmp/a.png"},
		{"", "org.gnome.TextEditor", "org.gnome.TextEditor.desktop"},
		{"", "firefox.desktop", "firefox.desktop"},
		{"", "", ""},
	}
	for _, c := range cases {
		if got := Icon(c.appIcon, c.entry); got != c.want {
			t.Errorf("Icon(%q, %q) = %q, want %q", c.appIcon, c.entry, got, c.want)
		}
	}
}

func TestStoreIDsAndReplace(t *testing.T) {
	s := NewStore()
	a := s.Add(0, 0, nil)
	b := s.Add(0, 0, nil)
	if a == 0 || b == 0 || a == b {
		t.Fatalf("expected distinct non-zero IDs, got %d and %d", a, b)
	}
	if got := s.Add(a, 0, nil); got != a {
		t.Errorf("replacing %d gave new ID %d", a, got)
	}
	if got := s.Add(999, 0, nil); got == 999 {
		t.Errorf("replacing an unknown ID must allocate a new one")
	}
	if !s.Remove(a) || s.Remove(a) || s.Showing(a) {
		t.Errorf("Remove should succeed once and clear the notification")
	}
}

func TestStoreExpires(t *testing.T) {
	s := NewStore()
	expired := make(chan uint32, 1)
	id := s.Add(0, 10*time.Millisecond, func(id uint32) { expired <- id })
	select {
	case got := <-expired:
		if got != id {
			t.Errorf("expired %d, want %d", got, id)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("notification did not expire")
	}
	if s.Showing(id) {
		t.Error("expired notification still showing")
	}
}

func TestReplaceRestartsTimer(t *testing.T) {
	s := NewStore()
	expired := make(chan uint32, 2)
	id := s.Add(0, 30*time.Millisecond, func(id uint32) { expired <- id })
	s.Add(id, 0, nil) // replaced with one that never expires
	select {
	case <-expired:
		t.Fatal("old timer fired after the notification was replaced")
	case <-time.After(100 * time.Millisecond):
	}
	if !s.Showing(id) {
		t.Error("replaced notification should still be showing")
	}
}
