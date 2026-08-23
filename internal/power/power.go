package power

import (
	"strings"
	"time"

	"github.com/soundadam/teaway/internal/execx"
	"github.com/soundadam/teaway/internal/privilege"
	"github.com/soundadam/teaway/internal/state"
	"github.com/soundadam/teaway/internal/teaerr"
)

type Observation string

const (
	Off           Observation = "off"
	On            Observation = "on"
	External      Observation = "external"
	Borrowed      Observation = "borrowed"
	NeedsRecovery Observation = "needs-recovery"
	Conflict      Observation = "conflict"
)

type Status struct {
	Observation      Observation
	LiveDisableSleep int
	PowerSource      string
	Record           *state.PowerRecord
}

type OffResult struct {
	RestoredDisableSleep int
	HadRecord            bool
}

type Service struct {
	Store  state.Store
	Runner execx.Runner
	Priv   privilege.Executor
	Now    func() time.Time
}

func (s Service) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s Service) On() (state.PowerRecord, error) {
	var record state.PowerRecord
	err := s.Store.WithLock(func() error {
		st, err := s.Store.Load()
		if err != nil {
			return err
		}
		live, err := s.inspectDisableSleep()
		if err != nil {
			return err
		}
		if rec := st.Power; rec != nil {
			if err := validate(*rec); err != nil {
				return err
			}
			switch rec.Phase {
			case state.PowerEnabled:
				if live != rec.ExpectedDisableSleep {
					return teaerr.PowerConflict(rec.ExpectedDisableSleep, live)
				}
				record = *rec
				return nil
			case state.PowerEnabling:
				if live == rec.ExpectedDisableSleep {
					rec.Phase = state.PowerEnabled
					st.Power = rec
					if err := s.saveRecover(st, "macOS is enabled, but the enabled phase could not be saved."); err != nil {
						return err
					}
					record = *rec
					return nil
				}
				if live != rec.OriginalDisableSleep {
					return teaerr.PowerConflict(rec.ExpectedDisableSleep, live)
				}
				updated, err := s.applyEnable(*rec, &st)
				record = updated
				return err
			case state.PowerRestoring:
				return teaerr.PowerRecovery("run 'teaway off' to finish the interrupted restore before enabling again")
			}
		}
		rec := state.PowerRecord{
			OriginalDisableSleep: live,
			ExpectedDisableSleep: 1,
			CreatedAt:            s.now(),
			Phase:                state.PowerEnabling,
		}
		st.Power = &rec
		if err := s.saveRecover(st, "the enabling record could not be saved, so no pmset change was attempted."); err != nil {
			return err
		}
		updated, err := s.applyEnable(rec, &st)
		record = updated
		return err
	})
	return record, err
}

func (s Service) Off() (OffResult, error) {
	var result OffResult
	err := s.Store.WithLock(func() error {
		st, err := s.Store.Load()
		if err != nil {
			return err
		}
		live, err := s.inspectDisableSleep()
		if err != nil {
			return err
		}
		if st.Power == nil {
			result = OffResult{RestoredDisableSleep: live, HadRecord: false}
			return nil
		}
		rec := *st.Power
		if err := validate(rec); err != nil {
			return err
		}
		if live == rec.OriginalDisableSleep || rec.OriginalDisableSleep == rec.ExpectedDisableSleep {
			st.Power = nil
			if err := s.saveRecover(st, "macOS already has the original value, but the recovery record could not be cleared."); err != nil {
				return err
			}
			result = OffResult{RestoredDisableSleep: live, HadRecord: true}
			return nil
		}
		if live != rec.ExpectedDisableSleep {
			return teaerr.PowerConflict(rec.ExpectedDisableSleep, live)
		}
		rec.Phase = state.PowerRestoring
		st.Power = &rec
		if err := s.saveRecover(st, "the restore phase could not be saved, so no pmset change was attempted."); err != nil {
			return err
		}
		if err := s.Priv.Authorize(); err != nil {
			return teaerr.PowerRecovery("authorizing restore failed: " + err.Error())
		}
		if err := s.Priv.Run(privilege.SetDisableSleep(rec.OriginalDisableSleep)); err != nil {
			return teaerr.PowerRecovery("restoring disablesleep failed: " + err.Error())
		}
		verified, err := s.inspectDisableSleep()
		if err != nil {
			return teaerr.PowerRecovery("the restore command ran, but verification failed: " + err.Error())
		}
		if verified != rec.OriginalDisableSleep {
			return teaerr.PowerRecovery("the restore command ran, but macOS reports disablesleep=" + itoa(verified) + " instead of " + itoa(rec.OriginalDisableSleep))
		}
		st.Power = nil
		if err := s.saveRecover(st, "macOS was restored, but the recovery record could not be cleared."); err != nil {
			return err
		}
		result = OffResult{RestoredDisableSleep: rec.OriginalDisableSleep, HadRecord: true}
		return nil
	})
	return result, err
}

func (s Service) Status() (Status, error) {
	var status Status
	err := s.Store.WithLock(func() error {
		st, err := s.Store.Load()
		if err != nil {
			return err
		}
		live, err := s.inspectDisableSleep()
		if err != nil {
			return err
		}
		source, err := s.inspectPowerSource()
		if err != nil {
			return err
		}
		if st.Power == nil {
			obs := Off
			if live != 0 {
				obs = External
			}
			status = Status{Observation: obs, LiveDisableSleep: live, PowerSource: source}
			return nil
		}
		rec := *st.Power
		if err := validate(rec); err != nil {
			return err
		}
		var obs Observation
		switch rec.Phase {
		case state.PowerEnabled:
			if live == rec.ExpectedDisableSleep {
				if rec.OriginalDisableSleep == rec.ExpectedDisableSleep {
					obs = Borrowed
				} else {
					obs = On
				}
			} else {
				obs = Conflict
			}
		default:
			if live == rec.ExpectedDisableSleep || live == rec.OriginalDisableSleep {
				obs = NeedsRecovery
			} else {
				obs = Conflict
			}
		}
		status = Status{Observation: obs, LiveDisableSleep: live, PowerSource: source, Record: &rec}
		return nil
	})
	return status, err
}

func (s Service) applyEnable(rec state.PowerRecord, st *state.File) (state.PowerRecord, error) {
	if rec.OriginalDisableSleep != rec.ExpectedDisableSleep {
		if err := s.Priv.Authorize(); err != nil {
			return rec, teaerr.PowerRecovery("authorizing enable failed: " + err.Error())
		}
		if err := s.Priv.Run(privilege.SetDisableSleep(rec.ExpectedDisableSleep)); err != nil {
			return rec, teaerr.PowerRecovery("enabling disablesleep failed: " + err.Error())
		}
	}
	verified, err := s.inspectDisableSleep()
	if err != nil {
		return rec, teaerr.PowerRecovery("the enable command ran, but verification failed: " + err.Error())
	}
	if verified != rec.ExpectedDisableSleep {
		return rec, teaerr.PowerRecovery("the enable command ran, but macOS reports disablesleep=" + itoa(verified) + " instead of " + itoa(rec.ExpectedDisableSleep))
	}
	rec.Phase = state.PowerEnabled
	st.Power = &rec
	if err := s.saveRecover(*st, "macOS is enabled, but the enabled phase could not be saved."); err != nil {
		return rec, err
	}
	return rec, nil
}

func (s Service) inspectDisableSleep() (int, error) {
	result, err := execx.Must(s.Runner, execx.Command{Path: execx.Pmset, Args: []string{"-g"}})
	if err != nil {
		return 0, err
	}
	return ParseDisableSleep(result.Stdout)
}

func (s Service) inspectPowerSource() (string, error) {
	result, err := execx.Must(s.Runner, execx.Command{Path: execx.Pmset, Args: []string{"-g", "batt"}})
	if err != nil {
		return "", err
	}
	return ParsePowerSource(result.Stdout)
}

func (s Service) saveRecover(st state.File, detail string) error {
	if err := s.Store.Save(st); err != nil {
		return teaerr.PowerRecovery(detail + " save error: " + err.Error())
	}
	return nil
}

func validate(rec state.PowerRecord) error {
	if rec.OriginalDisableSleep != 0 && rec.OriginalDisableSleep != 1 {
		return teaerr.PowerUnreadable("the saved teaway power record contains unsupported values")
	}
	if rec.ExpectedDisableSleep != 1 {
		return teaerr.PowerUnreadable("the saved teaway power record contains unsupported values")
	}
	return nil
}

func ParseDisableSleep(output string) (int, error) {
	var values []int
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Fields(line)
		if len(fields) != 2 {
			continue
		}
		key := strings.ToLower(fields[0])
		if key != "sleepdisabled" && key != "disablesleep" {
			continue
		}
		if fields[1] != "0" && fields[1] != "1" {
			return 0, teaerr.PowerUnreadable("the disablesleep line is malformed")
		}
		if fields[1] == "1" {
			values = append(values, 1)
		} else {
			values = append(values, 0)
		}
	}
	if len(values) == 0 {
		return 0, teaerr.PowerUnreadable("pmset did not report disablesleep")
	}
	if len(values) != 1 {
		return 0, teaerr.PowerUnreadable("pmset reported disablesleep more than once")
	}
	return values[0], nil
}

func ParsePowerSource(output string) (string, error) {
	var sources []string
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "Now drawing from ") {
			continue
		}
		start := strings.Index(line, "'")
		end := strings.LastIndex(line, "'")
		if start < 0 || end <= start {
			return "", teaerr.PowerUnreadable("pmset did not report one unambiguous power source")
		}
		sources = append(sources, line[start+1:end])
	}
	if len(sources) != 1 {
		return "", teaerr.PowerUnreadable("pmset did not report one unambiguous power source")
	}
	return sources[0], nil
}

func itoa(v int) string {
	if v == 1 {
		return "1"
	}
	return "0"
}
