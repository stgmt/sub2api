package handler

import (
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/stretchr/testify/require"
)

func TestApplyOpenAIUsageReasoningEffortFallback(t *testing.T) {
	t.Run("Spark never inherits parent effort", func(t *testing.T) {
		inherited := "max"
		result := &service.ForwardResult{
			UpstreamModel:   "gpt-5.3-codex-spark",
			ReasoningEffort: &inherited,
		}

		applyOpenAIUsageReasoningEffortFallback(result, "max", true)
		require.Nil(t, result.ReasoningEffort)
	})

	t.Run("Sol preserves explicit effort fallback", func(t *testing.T) {
		result := &service.ForwardResult{UpstreamModel: "gpt-5.6-sol"}

		applyOpenAIUsageReasoningEffortFallback(result, "max", false)
		require.NotNil(t, result.ReasoningEffort)
		require.Equal(t, "max", *result.ReasoningEffort)
	})
}
