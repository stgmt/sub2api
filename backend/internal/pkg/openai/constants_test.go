package openai

import "testing"

func TestContextLimitsForModel_KnownFamiliesAndFastAliases(t *testing.T) {
	tests := []struct {
		model  string
		window int
	}{
		{model: "gpt-5.6-luna", window: 1_050_000},
		{model: "gpt-5.6-sol-fast", window: 1_050_000},
		{model: "gpt-5.5-fast", window: 1_050_000},
		{model: "gpt-5.4-mini-fast", window: 272_000},
		{model: "gpt-5.3-codex-spark", window: 272_000},
		{model: "gpt-5.2-fast", window: 272_000},
	}

	for _, tt := range tests {
		t.Run(tt.model, func(t *testing.T) {
			limits, ok := ContextLimitsForModel(tt.model)
			if !ok {
				t.Fatalf("ContextLimitsForModel(%q) returned unknown", tt.model)
			}
			if limits.ContextLength != tt.window || limits.MaxInputTokens != tt.window {
				t.Fatalf("ContextLimitsForModel(%q) = %+v, want window %d", tt.model, limits, tt.window)
			}
			if limits.MaxOutputTokens != 128_000 {
				t.Fatalf("ContextLimitsForModel(%q).MaxOutputTokens = %d, want 128000", tt.model, limits.MaxOutputTokens)
			}
		})
	}
}

func TestContextLimitsForModel_UnknownModelIsOmitted(t *testing.T) {
	if _, ok := ContextLimitsForModel("vendor-private-model"); ok {
		t.Fatal("unknown model received an invented context limit")
	}

	models := []Model{{ID: "vendor-private-model"}}
	enriched := ModelsWithContextLimits(models)
	if enriched[0].ContextLength != 0 || enriched[0].MaxInputTokens != 0 || enriched[0].MaxOutputTokens != 0 {
		t.Fatalf("unknown model was enriched: %+v", enriched[0])
	}
	if models[0].ContextLength != 0 || models[0].MaxInputTokens != 0 || models[0].MaxOutputTokens != 0 {
		t.Fatalf("ModelsWithContextLimits mutated the input: %+v", models[0])
	}
}
