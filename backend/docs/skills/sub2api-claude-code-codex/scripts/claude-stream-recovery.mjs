#!/usr/bin/env node

const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);

function emit(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

function recoveryUrl() {
  const override = (process.env.HEADROOM_CLAUDE_RECOVERY_URL || "").trim();
  if (override) return override;
  const rawBase = (process.env.ANTHROPIC_BASE_URL || "").trim();
  if (!rawBase) return null;
  const base = new URL(rawBase);
  base.pathname = "/__headroom/claude-recovery/consume";
  base.search = "";
  base.hash = "";
  return base.toString();
}

try {
  const input = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
  const eventName = String(input.hook_event_name || "");
  if (!new Set(["Stop", "SubagentStop"]).has(eventName)) {
    emit({});
    process.exit(0);
  }

  const sessionId = String(input.session_id || "").trim();
  const agentId = String(input.agent_id || "main").trim() || "main";
  const url = recoveryUrl();
  if (!sessionId || !url) {
    emit({});
    process.exit(0);
  }

  const headers = { "content-type": "application/json" };
  const token = (
    process.env.ANTHROPIC_AUTH_TOKEN ||
    process.env.ANTHROPIC_API_KEY ||
    ""
  ).trim();
  if (token) headers.authorization = `Bearer ${token}`;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 2500);
  let response;
  try {
    response = await fetch(url, {
      method: "POST",
      headers,
      body: JSON.stringify({ session_id: sessionId, agent_id: agentId }),
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timer);
  }
  if (!response.ok) {
    emit({});
    process.exit(0);
  }
  const recovery = await response.json();
  if (!recovery?.pending) {
    emit({});
    process.exit(0);
  }

  emit({
    decision: "block",
    reason: [
      "The previous assistant turn was closed at a transport checkpoint before the upstream model finished.",
      "Continue the current task now in this same session without asking the user to repeat the prompt.",
      "Preserve already completed text and side effects; inspect current state before any write or tool call and do not repeat completed actions.",
      "Resume from the exact unfinished step. Mention the recovery only if continuation cannot be completed.",
      `Recovery ${recovery.failure_count}/${recovery.max_attempts}; source request ${recovery.request_id}.`,
    ].join(" "),
  });
} catch {
  // Recovery is fail-open: a broken local hook must never block a healthy turn.
  emit({});
}
