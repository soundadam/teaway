package shutdown

import (
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/soundadam/teaway/internal/execx"
	"github.com/soundadam/teaway/internal/privilege"
	"github.com/soundadam/teaway/internal/state"
	"github.com/soundadam/teaway/internal/teaerr"
)

const planLifetime = 5 * time.Minute

type Observation string

const (
	None          Observation = "none"
	Planned       Observation = "planned"
	Scheduled     Observation = "scheduled"
	Missing       Observation = "missing-from-system"
	NeedsRecovery Observation = "needs-recovery"
	Conflict      Observation = "conflict"
)

type Status struct {
	Observation Observation
	Record      *state.ShutdownRecord
}

type Event struct {
	Type  string
	Date  string
	Owner string
}

func (e Event) Summary() string {
	return fmt.Sprintf("%s at %s by '%s'", e.Type, e.Date, e.Owner)
}

type Service struct {
	Store    state.Store
	Runner   execx.Runner
	Priv     privilege.Executor
	Now      func() time.Time
	NewID    func() string
	Location *time.Location
}

func (s Service) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s Service) loc() *time.Location {
	if s.Location != nil {
		return s.Location
	}
	return time.Local
}

func (s Service) id() string {
	if s.NewID != nil {
		return s.NewID()
	}
	return fmt.Sprintf("%d", s.now().UnixNano())
}

func (s Service) formatDate(t time.Time) string {
	return t.In(s.loc()).Format("01/02/06 15:04:05")
}

func (s Service) Plan(after time.Duration) (state.ShutdownRecord, error) {
	var rec state.ShutdownRecord
	err := s.Store.WithLock(func() error {
		st, err := s.Store.Load()
		if err != nil {
			return err
		}
		if existing := st.Shutdown; existing != nil {
			events, err := s.inspect()
			if err != nil {
				return err
			}
			for _, event := range events {
				if event.Owner == existing.Owner {
					return teaerr.ShutdownExists(existing.ID)
				}
			}
		}
		now := s.now()
		rec = state.ShutdownRecord{
			ID:          s.id(),
			Owner:       "teaway:" + s.idKeep(now),
			CreatedAt:   now,
			ScheduledAt: now.Add(after),
			Phase:       state.ShutdownPlanned,
		}
		rec.Owner = "teaway:" + rec.ID
		st.Shutdown = &rec
		return s.Store.Save(st)
	})
	return rec, err
}

func (s Service) idKeep(now time.Time) string { return s.id() }

func (s Service) Commit(actionID string) (state.ShutdownRecord, error) {
	var rec state.ShutdownRecord
	err := s.Store.WithLock(func() error {
		st, err := s.Store.Load()
		if err != nil {
			return err
		}
		if st.Shutdown == nil {
			return teaerr.NoShutdown()
		}
		current := *st.Shutdown
		if current.ID != actionID {
			return teaerr.ActionIDMismatch()
		}
		if current.Phase != state.ShutdownPlanned {
			return teaerr.ShutdownExists(current.ID)
		}
		if err := s.validatePlan(current); err != nil {
			return err
		}
		events, err := s.inspect()
		if err != nil {
			return err
		}
		if conflict := firstConflict(events, Event{}); conflict != nil {
			return teaerr.ShutdownConflict(conflict.Summary())
		}
		date := s.formatDate(current.ScheduledAt)
		tz := s.loc().String()
		current.Phase = state.ShutdownCommitting
		current.SystemScheduleDate = &date
		current.SystemScheduleTimeZone = &tz
		st.Shutdown = &current
		if err := s.Store.Save(st); err != nil {
			return err
		}
		target := Event{Type: "shutdown", Date: date, Owner: current.Owner}
		if err := s.Priv.Authorize(); err != nil {
			return s.recoverAfterFailure(current, &st, err)
		}
		if err := s.Priv.Run(privilege.ScheduleShutdown(date, current.Owner)); err != nil {
			return s.recoverAfterFailure(current, &st, err)
		}
		scheduled, err := s.inspect()
		if err != nil {
			return s.compensate(current, target, &st, err)
		}
		owned := byOwner(scheduled, current.Owner)
		if !containsEvent(owned, target) {
			if len(owned) > 0 {
				return s.compensate(current, owned[0], &st, teaerr.ShutdownVerify(current.ID))
			}
			return s.resetPlan(current, &st, teaerr.ShutdownVerify(current.ID))
		}
		if conflict := firstConflict(scheduled, target); conflict != nil {
			return s.compensate(current, target, &st, teaerr.ShutdownConflict(conflict.Summary()))
		}
		now := s.now()
		current.Phase = state.ShutdownCommitted
		current.CommittedAt = &now
		st.Shutdown = &current
		if err := s.Store.Save(st); err != nil {
			return s.compensate(current, target, &st, err)
		}
		rec = current
		return nil
	})
	return rec, err
}

func (s Service) After(after time.Duration) (state.ShutdownRecord, error) {
	planned, err := s.Plan(after)
	if err != nil {
		return planned, err
	}
	return s.Commit(planned.ID)
}

func (s Service) Status() (Status, error) {
	var status Status
	err := s.Store.WithLock(func() error {
		st, err := s.Store.Load()
		if err != nil {
			return err
		}
		if st.Shutdown == nil {
			status = Status{Observation: None}
			return nil
		}
		rec := *st.Shutdown
		events, err := s.inspect()
		if err != nil {
			return err
		}
		owned := byOwner(events, rec.Owner)
		if len(owned) == 0 {
			st.Shutdown = nil
			if err := s.Store.Save(st); err != nil {
				return err
			}
			status = Status{Observation: None}
			return nil
		}
		if len(owned) > 1 || (len(owned) == 1 && owned[0].Type != "shutdown") {
			status = Status{Observation: Conflict, Record: &rec}
			return nil
		}
		target := Event{}
		if rec.SystemScheduleDate != nil {
			target = Event{Type: "shutdown", Date: *rec.SystemScheduleDate, Owner: rec.Owner}
		}
		exact := rec.SystemScheduleDate != nil && containsEvent(owned, target)
		unrelated := false
		for _, event := range events {
			if event.Owner == rec.Owner {
				continue
			}
			if event.Type == "shutdown" || recognizedOwner(event.Owner) {
				unrelated = true
			}
		}
		if unrelated || (len(owned) > 0 && !exact && rec.SystemScheduleDate != nil) {
			status = Status{Observation: Conflict, Record: &rec}
			return nil
		}
		switch rec.Phase {
		case state.ShutdownPlanned, state.ShutdownCommitting:
			status = Status{Observation: NeedsRecovery, Record: &rec}
		case state.ShutdownCommitted:
			obs := Conflict
			if exact {
				obs = Scheduled
			}
			status = Status{Observation: obs, Record: &rec}
		}
		return nil
	})
	return status, err
}

func (s Service) Cancel(actionID string) (state.ShutdownRecord, error) {
	var rec state.ShutdownRecord
	err := s.Store.WithLock(func() error {
		st, err := s.Store.Load()
		if err != nil {
			return err
		}
		if st.Shutdown == nil {
			return teaerr.NoShutdown()
		}
		current := *st.Shutdown
		if current.ID != actionID {
			return teaerr.ActionIDMismatch()
		}
		events, err := s.inspect()
		if err != nil {
			return err
		}
		owned := byOwner(events, current.Owner)
		if len(owned) > 1 || (len(owned) == 1 && owned[0].Type != "shutdown") {
			summaries := make([]string, 0, len(owned))
			for _, event := range owned {
				summaries = append(summaries, event.Summary())
			}
			return teaerr.ShutdownConflict(strings.Join(summaries, "; "))
		}
		if len(owned) == 1 {
			event := owned[0]
			if err := s.Priv.Authorize(); err != nil {
				return teaerr.ShutdownRecovery(current.ID, "the exact teaway event could not be cancelled: "+err.Error())
			}
			if err := s.Priv.Run(privilege.CancelShutdown(event.Date, event.Owner)); err != nil {
				return teaerr.ShutdownRecovery(current.ID, "the exact teaway event could not be cancelled: "+err.Error())
			}
			remaining, err := s.inspect()
			if err != nil {
				return teaerr.ShutdownRecovery(current.ID, "cancellation returned success, but its result could not be verified: "+err.Error())
			}
			if len(byOwner(remaining, current.Owner)) > 0 {
				return teaerr.ShutdownRecovery(current.ID, "macOS still reports an event with this teaway owner after cancellation")
			}
		}
		st.Shutdown = nil
		if err := s.Store.Save(st); err != nil {
			return err
		}
		rec = current
		return nil
	})
	return rec, err
}

func (s Service) inspect() ([]Event, error) {
	result, err := execx.Must(s.Runner, execx.Command{Path: execx.Pmset, Args: []string{"-g", "sched"}})
	if err != nil {
		return nil, err
	}
	return ParseSchedule(result.Stdout)
}

func (s Service) validatePlan(rec state.ShutdownRecord) error {
	age := s.now().Sub(rec.CreatedAt)
	if age < 0 || age > planLifetime || !rec.ScheduledAt.After(s.now()) {
		return teaerr.PlanExpired()
	}
	return nil
}

func (s Service) recoverAfterFailure(rec state.ShutdownRecord, st *state.File, cause error) error {
	events, err := s.inspect()
	if err != nil {
		return teaerr.ShutdownRecovery(rec.ID, "scheduling returned an error and macOS state could not be inspected: "+err.Error())
	}
	owned := byOwner(events, rec.Owner)
	shutdowns := shutdownsOnly(owned)
	if len(shutdowns) > 1 {
		return teaerr.ShutdownRecovery(rec.ID, "scheduling returned an error and macOS reports multiple matching owner events")
	}
	if len(shutdowns) == 1 {
		return s.compensate(rec, shutdowns[0], st, cause)
	}
	return s.resetPlan(rec, st, cause)
}

func (s Service) compensate(rec state.ShutdownRecord, event Event, st *state.File, cause error) error {
	if err := s.Priv.Run(privilege.CancelShutdown(event.Date, event.Owner)); err != nil {
		return teaerr.ShutdownRecovery(rec.ID, "automatic compensation could not start: "+err.Error())
	}
	remaining, err := s.inspect()
	if err != nil {
		return teaerr.ShutdownRecovery(rec.ID, "automatic compensation returned success, but verification failed: "+err.Error())
	}
	if len(byOwner(remaining, rec.Owner)) > 0 {
		return teaerr.ShutdownRecovery(rec.ID, "macOS still reports this teaway owner after automatic compensation")
	}
	return s.resetPlan(rec, st, cause)
}

func (s Service) resetPlan(rec state.ShutdownRecord, st *state.File, cause error) error {
	rec.Phase = state.ShutdownPlanned
	rec.CommittedAt = nil
	rec.SystemScheduleDate = nil
	rec.SystemScheduleTimeZone = nil
	st.Shutdown = &rec
	if err := s.Store.Save(*st); err != nil {
		return teaerr.ShutdownRecovery(rec.ID, "no matching macOS event was found, but the committing record could not be reset: "+err.Error())
	}
	return cause
}

var (
	eventLine = regexp.MustCompile(`(?i)^\s*\[[0-9]+\]\s+(sleep|wake|poweron|shutdown|wakeorpoweron)\s+at\s+([0-9]{2}/[0-9]{2}/[0-9]{2}(?:[0-9]{2})?\s+[0-9]{2}:[0-9]{2}:[0-9]{2})\s+by\s+'([^']+)'(?:\s+leeway secs:\s+[0-9]+)?(?:\s+User visible:\s+true)?\s*$`)
	eventPref = regexp.MustCompile(`^\s*\[[0-9]+\]`)
)

func ParseSchedule(output string) ([]Event, error) {
	var events []Event
	for i, raw := range strings.Split(output, "\n") {
		line := raw
		match := eventLine.FindStringSubmatch(line)
		if match == nil {
			if eventPref.MatchString(line) {
				return nil, teaerr.ShutdownUnreadable(fmt.Sprintf("unrecognized event line %d: %s", i+1, strings.TrimSpace(line)))
			}
			lower := strings.ToLower(line)
			if strings.Contains(lower, "teaway:") || strings.Contains(lower, "tea-away:") {
				return nil, teaerr.ShutdownConflict(strings.TrimSpace(line))
			}
			if regexp.MustCompile(`(?i)\bshutdown\b`).MatchString(line) && strings.TrimSpace(line) != "" {
				events = append(events, Event{Type: "shutdown", Date: strings.TrimSpace(line), Owner: "<unindexed-system-event>"})
			}
			continue
		}
		events = append(events, Event{
			Type:  strings.ToLower(match[1]),
			Date:  normalizeDate(match[2]),
			Owner: match[3],
		})
	}
	return events, nil
}

func normalizeDate(value string) string {
	parts := strings.SplitN(value, " ", 2)
	if len(parts) != 2 {
		return value
	}
	dateParts := strings.Split(parts[0], "/")
	if len(dateParts) != 3 || len(dateParts[2]) != 4 {
		return value
	}
	return dateParts[0] + "/" + dateParts[1] + "/" + dateParts[2][2:] + " " + parts[1]
}

func firstConflict(events []Event, allowed Event) *Event {
	for i := range events {
		event := events[i]
		if allowed.Owner != "" && event == allowed {
			continue
		}
		if event.Type == "shutdown" || recognizedOwner(event.Owner) {
			return &event
		}
	}
	return nil
}

func byOwner(events []Event, owner string) []Event {
	var out []Event
	for _, event := range events {
		if event.Owner == owner {
			out = append(out, event)
		}
	}
	return out
}

func shutdownsOnly(events []Event) []Event {
	var out []Event
	for _, event := range events {
		if event.Type == "shutdown" {
			out = append(out, event)
		}
	}
	return out
}

func containsEvent(events []Event, target Event) bool {
	for _, event := range events {
		if event == target {
			return true
		}
	}
	return false
}

func recognizedOwner(owner string) bool {
	return strings.HasPrefix(owner, "teaway:") || strings.HasPrefix(owner, "tea-away:")
}
