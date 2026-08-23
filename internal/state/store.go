package state

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/user"
	"path/filepath"
	"syscall"
	"time"

	"github.com/soundadam/teaway/internal/teaerr"
	"golang.org/x/sys/unix"
)

const schemaVersion = 1

type PowerPhase string

const (
	PowerEnabling  PowerPhase = "enabling"
	PowerEnabled   PowerPhase = "enabled"
	PowerRestoring PowerPhase = "restoring"
)

type ShutdownPhase string

const (
	ShutdownPlanned    ShutdownPhase = "planned"
	ShutdownCommitting ShutdownPhase = "committing"
	ShutdownCommitted  ShutdownPhase = "committed"
)

type PowerRecord struct {
	OriginalDisableSleep int        `json:"originalDisableSleep"`
	ExpectedDisableSleep int        `json:"expectedDisableSleep"`
	CreatedAt            time.Time  `json:"createdAt"`
	Phase                PowerPhase `json:"phase"`
}

type ShutdownRecord struct {
	ID                     string        `json:"id"`
	Owner                  string        `json:"owner"`
	CreatedAt              time.Time     `json:"createdAt"`
	ScheduledAt            time.Time     `json:"scheduledAt"`
	Phase                  ShutdownPhase `json:"phase"`
	CommittedAt            *time.Time    `json:"committedAt,omitempty"`
	SystemScheduleDate     *string       `json:"systemScheduleDate,omitempty"`
	SystemScheduleTimeZone *string       `json:"systemScheduleTimeZone,omitempty"`
}

type File struct {
	SchemaVersion int             `json:"schemaVersion"`
	Power         *PowerRecord    `json:"power,omitempty"`
	Shutdown      *ShutdownRecord `json:"shutdown,omitempty"`
}

func Empty() File { return File{SchemaVersion: schemaVersion} }

type Paths struct {
	Directory string
}

func (p Paths) StateFile() string { return filepath.Join(p.Directory, "state.json") }
func (p Paths) LockFile() string  { return filepath.Join(p.Directory, "state.lock") }

func Resolve(env map[string]string) Paths {
	if value := env["TEAWAY_STATE_DIR"]; value != "" {
		return Paths{Directory: value}
	}
	home := env["HOME"]
	if home == "" {
		home, _ = os.UserHomeDir()
	}
	if xdg := env["XDG_STATE_HOME"]; xdg != "" {
		return Paths{Directory: filepath.Join(xdg, "teaway")}
	}
	return Paths{Directory: filepath.Join(home, "Library", "Application Support", "teaway")}
}

type Store struct {
	Paths Paths
}

func (s Store) Load() (File, error) {
	path := s.Paths.StateFile()
	_, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return Empty(), nil
	}
	if err != nil {
		return File{}, permissionOr(path, err)
	}
	return decodeFile(path)
}

func (s Store) Save(state File) error {
	if state.SchemaVersion == 0 {
		state.SchemaVersion = schemaVersion
	}
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	path := s.Paths.StateFile()
	if err := s.prepareDir(filepath.Dir(path)); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return permissionOr(path, err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return permissionOr(path, err)
	}
	return permissionOr(path, os.Chmod(path, 0o600))
}

func (s Store) WithLock(fn func() error) error {
	lock := s.Paths.LockFile()
	if err := s.prepareDir(filepath.Dir(lock)); err != nil {
		return err
	}
	fd, err := os.OpenFile(lock, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return teaerr.StateLocked()
	}
	defer func() {
		_ = unix.Flock(int(fd.Fd()), unix.LOCK_UN)
		_ = fd.Close()
	}()
	if err := unix.Flock(int(fd.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		return teaerr.StateLocked()
	}
	return fn()
}

func (s Store) prepareDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return permissionOr(dir, err)
	}
	return os.Chmod(dir, 0o700)
}

func decodeFile(path string) (File, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return File{}, permissionOr(path, err)
	}
	var state File
	if err := json.Unmarshal(data, &state); err != nil {
		return File{}, teaerr.StateCorrupt(path + ": " + err.Error())
	}
	if state.SchemaVersion != schemaVersion {
		return File{}, teaerr.StateCorrupt(fmt.Sprintf("unsupported schema version %d", state.SchemaVersion))
	}
	return state, nil
}

func permissionOr(path string, err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, os.ErrPermission) || isEACCES(err) {
		repair := repairHint(path)
		return teaerr.StatePermission(path, err.Error(), repair)
	}
	return teaerr.StateCorrupt(path + ": " + err.Error())
}

func isEACCES(err error) bool {
	var pathErr *fs.PathError
	if errors.As(err, &pathErr) {
		return errors.Is(pathErr.Err, syscall.EACCES) || errors.Is(pathErr.Err, syscall.EPERM)
	}
	return errors.Is(err, syscall.EACCES) || errors.Is(err, syscall.EPERM)
}

func repairHint(path string) string {
	name := os.Getenv("USER")
	if name == "" {
		if u, err := user.Current(); err == nil {
			name = u.Username
		} else {
			name = "$USER"
		}
	}
	info, err := os.Lstat(path)
	owner := "root"
	if err == nil {
		if stat, ok := info.Sys().(*syscall.Stat_t); ok {
			if u, err := user.LookupId(fmt.Sprintf("%d", stat.Uid)); err == nil {
				owner = u.Username
			}
		}
	}
	return fmt.Sprintf(
		"state.json is owned by %s. This usually happens after `sudo teaway`. Do not run the user-facing CLI with sudo.\nRepair: sudo chown %s %q && sudo chmod 600 %q",
		owner, name, path, path,
	)
}
