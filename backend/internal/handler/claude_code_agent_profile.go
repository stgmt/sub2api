package handler

import (
	"crypto/sha256"
	"sync"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
)

const (
	claudeCodeAgentRoleSourceSystemComposite = "system_composite"
	claudeCodeAgentRoleSourceSessionCache    = "session_cache"
	claudeCodeAgentRoleSourceGenericSDKCLI   = "generic_sdk_cli"
)

type claudeCodeAgentProfile struct {
	Model           string
	ReasoningEffort string
	Role            service.ClaudeCodeAgentRole
	Source          string
}

type claudeCodeAgentRoleSessionEntry struct {
	role      service.ClaudeCodeAgentRole
	expiresAt time.Time
	sequence  uint64
}

type claudeCodeAgentRoleSessionCache struct {
	mu         sync.Mutex
	entries    map[[sha256.Size]byte]claudeCodeAgentRoleSessionEntry
	ttl        time.Duration
	maxEntries int
	now        func() time.Time
	nextSeq    uint64
}

var defaultClaudeCodeAgentRoleSessionCache = newClaudeCodeAgentRoleSessionCache(30*time.Minute, 4096, time.Now)

func newClaudeCodeAgentRoleSessionCache(ttl time.Duration, maxEntries int, now func() time.Time) *claudeCodeAgentRoleSessionCache {
	if ttl <= 0 {
		ttl = 30 * time.Minute
	}
	if maxEntries <= 0 {
		maxEntries = 4096
	}
	if now == nil {
		now = time.Now
	}
	return &claudeCodeAgentRoleSessionCache{
		entries:    make(map[[sha256.Size]byte]claudeCodeAgentRoleSessionEntry),
		ttl:        ttl,
		maxEntries: maxEntries,
		now:        now,
	}
}

func (cache *claudeCodeAgentRoleSessionCache) Remember(sessionID string, role service.ClaudeCodeAgentRole) {
	if cache == nil || sessionID == "" || role == service.ClaudeCodeAgentRoleUnknown {
		return
	}
	now := cache.now()
	key := sha256.Sum256([]byte(sessionID))

	cache.mu.Lock()
	defer cache.mu.Unlock()
	cache.purgeExpired(now)
	if _, exists := cache.entries[key]; !exists && len(cache.entries) >= cache.maxEntries {
		cache.evictOldest()
	}
	cache.nextSeq++
	cache.entries[key] = claudeCodeAgentRoleSessionEntry{role: role, expiresAt: now.Add(cache.ttl), sequence: cache.nextSeq}
}

func (cache *claudeCodeAgentRoleSessionCache) Lookup(sessionID string) service.ClaudeCodeAgentRole {
	if cache == nil || sessionID == "" {
		return service.ClaudeCodeAgentRoleUnknown
	}
	now := cache.now()
	key := sha256.Sum256([]byte(sessionID))

	cache.mu.Lock()
	defer cache.mu.Unlock()
	entry, exists := cache.entries[key]
	if !exists {
		return service.ClaudeCodeAgentRoleUnknown
	}
	if !entry.expiresAt.After(now) {
		delete(cache.entries, key)
		return service.ClaudeCodeAgentRoleUnknown
	}
	return entry.role
}

func (cache *claudeCodeAgentRoleSessionCache) purgeExpired(now time.Time) {
	for key, entry := range cache.entries {
		if !entry.expiresAt.After(now) {
			delete(cache.entries, key)
		}
	}
}

func (cache *claudeCodeAgentRoleSessionCache) evictOldest() {
	var oldestKey [sha256.Size]byte
	var oldestSequence uint64
	found := false
	for key, entry := range cache.entries {
		if !found || entry.sequence < oldestSequence {
			oldestKey = key
			oldestSequence = entry.sequence
			found = true
		}
	}
	if found {
		delete(cache.entries, oldestKey)
	}
}

func resolveClaudeCodeAgentProfile(
	c *gin.Context,
	body []byte,
	group *service.Group,
	cache *claudeCodeAgentRoleSessionCache,
) (claudeCodeAgentProfile, bool) {
	if group == nil || !isClaudeCodeSDKCLIRequest(c) {
		return claudeCodeAgentProfile{}, false
	}

	detection := service.DetectClaudeCodeAgentRole(c.GetHeader("User-Agent"), body)
	role := detection.Role
	source := ""
	if role != service.ClaudeCodeAgentRoleUnknown {
		cache.Remember(detection.SessionID, role)
		source = claudeCodeAgentRoleSourceSystemComposite
	} else if cachedRole := cache.Lookup(detection.SessionID); cachedRole != service.ClaudeCodeAgentRoleUnknown {
		role = cachedRole
		source = claudeCodeAgentRoleSourceSessionCache
	}

	if role == service.ClaudeCodeAgentRolePlan {
		model, effort := group.ResolveMessagesDispatchPlanProfile()
		if model != "" || effort != "" {
			return claudeCodeAgentProfile{Model: model, ReasoningEffort: effort, Role: role, Source: source}, true
		}
	}

	model, effort := group.ResolveMessagesDispatchSDKCLIProfile()
	if model == "" && effort == "" {
		return claudeCodeAgentProfile{}, false
	}
	return claudeCodeAgentProfile{
		Model:           model,
		ReasoningEffort: effort,
		Role:            service.ClaudeCodeAgentRoleUnknown,
		Source:          claudeCodeAgentRoleSourceGenericSDKCLI,
	}, true
}
