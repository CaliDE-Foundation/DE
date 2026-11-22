// Package notify holds the desktop notification rules used by cali-notifyd,
// independent of D-Bus so they can be tested.
package notify

import (
	"strings"
	"sync"
	"time"
)

// DefaultTimeout is how long a banner stays when the app doesn't say.
const DefaultTimeout = 5 * time.Second

// Urgency levels from the freedesktop notification spec.
const (
	UrgencyLow      byte = 0
	UrgencyNormal   byte = 1
	UrgencyCritical byte = 2
)

// Reasons a notification closed, as sent in NotificationClosed.
const (
	ClosedExpired   uint32 = 1
	ClosedDismissed uint32 = 2
	ClosedByCall    uint32 = 3
)

// Notification is one notification as the shell shows it.
type Notification struct {
	ID      uint32
	App     string
	Icon    string
	Summary string
	Body    string
}

// Timeout turns the app's expire_timeout (milliseconds; -1 = server
// default, 0 = never) and urgency into how long to show the notification.
// Zero means it stays until dismissed. Critical notifications always stay.
func Timeout(expireMillis int32, urgency byte) time.Duration {
	switch {
	case urgency == UrgencyCritical, expireMillis == 0:
		return 0
	case expireMillis < 0:
		return DefaultTimeout
	default:
		return time.Duration(expireMillis) * time.Millisecond
	}
}

// Icon picks what the shell should show: the app's icon if given, else its
// desktop file ID (the shell looks up that app's icon), else nothing.
func Icon(appIcon, desktopEntry string) string {
	if appIcon != "" {
		return strings.TrimPrefix(appIcon, "file://")
	}
	if desktopEntry != "" {
		if !strings.HasSuffix(desktopEntry, ".desktop") {
			desktopEntry += ".desktop"
		}
		return desktopEntry
	}
	return ""
}

// Store hands out notification IDs and tracks which are showing.
type Store struct {
	mu     sync.Mutex
	nextID uint32
	active map[uint32]*time.Timer
}

// NewStore returns an empty store.
func NewStore() *Store {
	return &Store{nextID: 1, active: make(map[uint32]*time.Timer)}
}

// Add registers a notification and returns its ID. If replaces is the ID of
// a showing notification, that ID is reused and its old timer stopped.
// onExpire runs after timeout (unless timeout is zero or it's removed first).
func (s *Store) Add(replaces uint32, timeout time.Duration, onExpire func(id uint32)) uint32 {
	s.mu.Lock()
	defer s.mu.Unlock()

	id := replaces
	if old, ok := s.active[id]; ok && id != 0 {
		if old != nil {
			old.Stop()
		}
	} else {
		id = s.nextID
		s.nextID++
		if s.nextID == 0 { // wrapped; 0 is not a valid ID
			s.nextID = 1
		}
	}

	var timer *time.Timer
	if timeout > 0 && onExpire != nil {
		timer = time.AfterFunc(timeout, func() {
			if s.Remove(id) {
				onExpire(id)
			}
		})
	}
	s.active[id] = timer
	return id
}

// Remove forgets a notification. It reports whether it was showing.
func (s *Store) Remove(id uint32) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	timer, ok := s.active[id]
	if !ok {
		return false
	}
	if timer != nil {
		timer.Stop()
	}
	delete(s.active, id)
	return true
}

// Showing reports whether a notification is currently showing.
func (s *Store) Showing(id uint32) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.active[id]
	return ok
}
