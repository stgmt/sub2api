package domain

// GroupModelsListConfig controls the optional custom /v1/models response list.
type GroupModelsListConfig struct {
	Enabled  bool     `json:"enabled"`
	Explicit bool     `json:"explicit,omitempty"`
	Models   []string `json:"models,omitempty"`
}
