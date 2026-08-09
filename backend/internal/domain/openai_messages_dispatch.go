package domain

import (
	"strings"
	"time"
)

// AlibabaTimeWindowConfig limits an Alibaba toggle to a local-time window.
// The router uses the same config for the Claude-compatible messages path so
// the policy survives client model aliases and does not depend on host env.
type AlibabaTimeWindowConfig struct {
	Enabled          bool   `json:"enabled,omitempty"`
	Timezone         string `json:"timezone,omitempty"`
	Start            string `json:"start,omitempty"`
	End              string `json:"end,omitempty"`
	MainModel        string `json:"main_model,omitempty"`
	PlanModel        string `json:"plan_model,omitempty"`
	SubagentModel    string `json:"subagent_model,omitempty"`
	OutOfWindowModel string `json:"out_of_window_model,omitempty"`
	ReasoningEffort  string `json:"reasoning_effort,omitempty"`
}

const defaultAlibabaTimeWindowTimezone = "Europe/Moscow"

// Resolve returns the active model and effort for the supplied instant. The
// 17:00-03:00 shape is intentionally supported as a cross-midnight window.
func (c AlibabaTimeWindowConfig) Resolve(now time.Time, plan, specialized bool) (model, effort string, active bool) {
	if !c.Enabled {
		return "", "", false
	}

	locationName := c.Timezone
	if locationName == "" {
		locationName = defaultAlibabaTimeWindowTimezone
	}
	location, err := time.LoadLocation(locationName)
	if err != nil {
		return "", "", false
	}
	start, err := time.ParseInLocation("15:04", c.Start, location)
	if err != nil {
		return "", "", false
	}
	end, err := time.ParseInLocation("15:04", c.End, location)
	if err != nil {
		return "", "", false
	}

	local := now.In(location)
	minute := local.Hour()*60 + local.Minute()
	startMinute := start.Hour()*60 + start.Minute()
	endMinute := end.Hour()*60 + end.Minute()
	inWindow := minute >= startMinute && minute < endMinute
	if startMinute >= endMinute {
		inWindow = minute >= startMinute || minute < endMinute
	}

	if inWindow {
		if specialized {
			model = c.SubagentModel
		} else if plan {
			model = c.PlanModel
		} else {
			model = c.MainModel
		}
	} else {
		model = c.OutOfWindowModel
	}
	return model, c.ReasoningEffort, strings.TrimSpace(model) != ""
}

// OpenAIMessagesDispatchModelConfig controls how Anthropic /v1/messages
// requests are mapped onto OpenAI/Codex models.
type OpenAIMessagesDispatchModelConfig struct {
	OpusMappedModel            string                  `json:"opus_mapped_model,omitempty"`
	SonnetMappedModel          string                  `json:"sonnet_mapped_model,omitempty"`
	HaikuMappedModel           string                  `json:"haiku_mapped_model,omitempty"`
	FastMappedModel            string                  `json:"fast_mapped_model,omitempty"`
	CompactMappedModel         string                  `json:"compact_mapped_model,omitempty"`
	CompactReasoningEffort     string                  `json:"compact_reasoning_effort,omitempty"`
	PlanMappedModel            string                  `json:"plan_mapped_model,omitempty"`
	PlanReasoningEffort        string                  `json:"plan_reasoning_effort,omitempty"`
	SDKCLIMappedModel          string                  `json:"sdk_cli_mapped_model,omitempty"`
	SDKCLIReasoningEffort      string                  `json:"sdk_cli_reasoning_effort,omitempty"`
	AlibabaTimeWindow          AlibabaTimeWindowConfig `json:"alibaba_time_window,omitempty"`
	ExactModelMappings         map[string]string       `json:"exact_model_mappings,omitempty"`
	ExactModelReasoningEfforts map[string]string       `json:"exact_model_reasoning_efforts,omitempty"`
	ModelFallbacks             map[string][]string     `json:"model_fallbacks,omitempty"`
	AutomaticModelFallbacks    map[string][]string     `json:"automatic_model_fallbacks,omitempty"`
}
