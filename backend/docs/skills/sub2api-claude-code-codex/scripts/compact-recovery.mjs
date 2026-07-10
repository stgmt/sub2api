#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

const mode = (process.argv[2] || "").toLowerCase();
const stateDir = path.join(os.homedir(), ".claude", "compact-recovery");

function readStdin() {
  try {
    return fs.readFileSync(0, "utf8");
  } catch {
    return "";
  }
}

function parseInput() {
  const raw = readStdin().trim();
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

function stableKey(input) {
  const seed =
    input.session_id ||
    input.sessionId ||
    input.transcript_path ||
    input.transcriptPath ||
    input.cwd ||
    "default";
  return crypto.createHash("sha1").update(String(seed)).digest("hex").slice(0, 16);
}

function statePathFor(input) {
  return path.join(stateDir, `${stableKey(input)}.json`);
}

function newestStatePath() {
  if (!fs.existsSync(stateDir)) return "";
  const files = fs.readdirSync(stateDir)
    .filter((name) => name.endsWith(".json"))
    .map((name) => {
      const p = path.join(stateDir, name);
      return { path: p, mtimeMs: fs.statSync(p).mtimeMs };
    })
    .sort((a, b) => b.mtimeMs - a.mtimeMs);
  return files[0]?.path || "";
}

function safeReadJSON(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return {};
  }
}

function writeJSON(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(value, null, 2), "utf8");
}

function truncate(text, maxChars) {
  text = String(text || "").trim();
  if (text.length <= maxChars) return text;
  const head = Math.floor(maxChars * 0.65);
  const tail = maxChars - head;
  return `${text.slice(0, head)}\n[... compact recovery truncated ...]\n${text.slice(-tail)}`;
}

function gitSnapshot(cwd) {
  if (!cwd || !fs.existsSync(cwd)) return "";
  try {
    const status = execFileSync("git", ["-C", cwd, "status", "--short", "--branch"], {
      encoding: "utf8",
      timeout: 2000,
      windowsHide: true,
    });
    const stat = execFileSync("git", ["-C", cwd, "diff", "--stat"], {
      encoding: "utf8",
      timeout: 2000,
      windowsHide: true,
    });
    return truncate([status.trim(), stat.trim()].filter(Boolean).join("\n"), 3500);
  } catch {
    return "";
  }
}

function baseState(input) {
  return {
    session_id: input.session_id || input.sessionId || "",
    transcript_path: input.transcript_path || input.transcriptPath || "",
    cwd: input.cwd || process.env.CLAUDE_PROJECT_DIR || process.cwd(),
    trigger: input.trigger || input.matcher || input.source || "",
    updated_at: new Date().toISOString(),
  };
}

function savePreCompact(input) {
  const file = statePathFor(input);
  const state = {
    ...safeReadJSON(file),
    ...baseState(input),
    precompact_at: new Date().toISOString(),
    needs_inject: false,
    git_snapshot: gitSnapshot(input.cwd || process.env.CLAUDE_PROJECT_DIR || ""),
  };
  writeJSON(file, state);
}

function markPostCompact(input) {
  const file = statePathFor(input);
  const state = {
    ...safeReadJSON(file),
    ...baseState(input),
    postcompact_at: new Date().toISOString(),
    needs_inject: true,
  };
  if (!state.git_snapshot) state.git_snapshot = gitSnapshot(state.cwd);
  writeJSON(file, state);
}

function consumeRecovery(input) {
  const direct = statePathFor(input);
  const file = fs.existsSync(direct) ? direct : newestStatePath();
  if (!file) return "";
  const state = safeReadJSON(file);
  if (!state.needs_inject) return "";
  state.needs_inject = false;
  state.injected_at = new Date().toISOString();
  writeJSON(file, state);

  const lines = [
    "<post-compact-recovery>",
    "A Claude Code compact just completed. Use this as a continuity guard, not as a new task.",
    `- cwd: ${state.cwd || "(unknown)"}`,
    `- compacted_at: ${state.postcompact_at || state.updated_at || "(unknown)"}`,
    state.transcript_path ? `- transcript_path: ${state.transcript_path}` : "",
    "",
    "Rules:",
    "- Treat the latest non-/compact user request as the active intent.",
    "- Do not treat \"produce a compact summary\" as the project task.",
    "- Prefer a # Compact Capsule / Current State / Next Command block when present.",
    "- Before claiming completion, verify files/logs/tests from the live repo.",
  ].filter(Boolean);
  if (state.git_snapshot) {
    lines.push("", "Git snapshot before compact:", "```", state.git_snapshot, "```");
  }
  lines.push("</post-compact-recovery>");
  return lines.join("\n");
}

const input = parseInput();
try {
  if (mode === "precompact") {
    savePreCompact(input);
    process.stdout.write("{}");
  } else if (mode === "postcompact") {
    markPostCompact(input);
    process.stdout.write("{}");
  } else if (mode === "userprompt" || mode === "sessionstart") {
    const additionalContext = consumeRecovery(input);
    if (additionalContext) {
      const hookEventName = mode === "sessionstart" ? "SessionStart" : "UserPromptSubmit";
      process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName, additionalContext } }));
    }
  }
} catch (error) {
  process.stderr.write(`compact-recovery hook failed: ${error?.message || error}\n`);
  process.exit(0);
}
