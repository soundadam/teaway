package duration

import (
	"regexp"
	"strconv"

	"github.com/soundadam/teaway/internal/teaerr"
)

var pattern = regexp.MustCompile(`^([1-9][0-9]*)([smhd])$`)

const (
	Minute = 60
	Hour   = 3600
	Day    = 86400
)

func Parse(value string) (int, error) {
	match := pattern.FindStringSubmatch(value)
	if match == nil {
		return 0, teaerr.InvalidDuration(value)
	}
	amount, err := strconv.Atoi(match[1])
	if err != nil {
		return 0, teaerr.InvalidDuration(value)
	}
	var multiplier int
	switch match[2] {
	case "s":
		multiplier = 1
	case "m":
		multiplier = Minute
	case "h":
		multiplier = Hour
	case "d":
		multiplier = Day
	default:
		return 0, teaerr.InvalidDuration(value)
	}
	seconds := amount * multiplier
	if amount != 0 && seconds/amount != multiplier {
		return 0, teaerr.InvalidDuration(value)
	}
	return seconds, nil
}

func ParseShutdown(value string) (int, error) {
	seconds, err := Parse(value)
	if err != nil {
		return 0, err
	}
	minimum := 10 * Minute
	maximum := 7 * Day
	if seconds < minimum || seconds > maximum {
		return 0, teaerr.DurationOutOfRange(minimum, maximum)
	}
	return seconds, nil
}
