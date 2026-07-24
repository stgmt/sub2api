package service

import (
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/tidwall/gjson"
)

const alibabaTokenPlanUnknownResetCooldown = 5 * time.Minute

var alibabaTokenPlanResetPattern = regexp.MustCompile(`(?i)reset\s+at\s+(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\s+UTC`)

// AlibabaTokenPlanQuotaResetAt recognizes terminal subscription exhaustion.
// The provider omits Retry-After and puts an MM-DD reset in the JSON message.
func AlibabaTokenPlanQuotaResetAt(responseBody []byte, now time.Time) (time.Time, bool) {
	code := strings.TrimSpace(gjson.GetBytes(responseBody, "code").String())
	message := strings.TrimSpace(gjson.GetBytes(responseBody, "message").String())
	if code == "" {
		code = strings.TrimSpace(gjson.GetBytes(responseBody, "error.code").String())
	}
	if message == "" {
		message = strings.TrimSpace(gjson.GetBytes(responseBody, "error.message").String())
	}

	lower := strings.ToLower(message)
	if !strings.EqualFold(code, "Throttling.AllocationQuota") ||
		!strings.Contains(lower, "token-plan") ||
		!strings.Contains(lower, "quota has been exhausted") {
		return time.Time{}, false
	}

	now = now.UTC()
	match := alibabaTokenPlanResetPattern.FindStringSubmatch(message)
	if len(match) != 6 {
		return now.Add(alibabaTokenPlanUnknownResetCooldown), true
	}
	parts := make([]int, 5)
	for i := range parts {
		value, err := strconv.Atoi(match[i+1])
		if err != nil {
			return now.Add(alibabaTokenPlanUnknownResetCooldown), true
		}
		parts[i] = value
	}
	resetAt := time.Date(now.Year(), time.Month(parts[0]), parts[1], parts[2], parts[3], parts[4], 0, time.UTC)
	if int(resetAt.Month()) != parts[0] || resetAt.Day() != parts[1] ||
		resetAt.Hour() != parts[2] || resetAt.Minute() != parts[3] || resetAt.Second() != parts[4] {
		return now.Add(alibabaTokenPlanUnknownResetCooldown), true
	}
	if !resetAt.After(now) {
		resetAt = resetAt.AddDate(1, 0, 0)
	}
	return resetAt, true
}
