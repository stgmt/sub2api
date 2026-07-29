# Terra vs Qwen: issue #153 implementation benchmark

Controlled on 2026-07-28 and continued on 2026-07-29 against `stgmt/dev-pomogator@91a0601e` with the complete issue #153 body, clean detached worktrees, parallel Claude Code 2.1.219 processes, separate temporary API keys/groups, command-line `--settings`, and no cross-provider fallback.

Public audit trail:

- source task: [dev-pomogator issue #153](https://github.com/stgmt/dev-pomogator/issues/153);
- Terra high research alternative: [draft PR #214](https://github.com/stgmt/dev-pomogator/pull/214);
- Qwen medium merge candidate: [PR #213](https://github.com/stgmt/dev-pomogator/pull/213);
- reproducible launcher and route-isolation checks: [benchmark-issue153-terra-vs-qwen.ps1](https://github.com/stgmt/sub2api/blob/1fb2721e3825490d64746d687821bb06c222f81f/backend/docs/skills/sub2api-claude-code-codex/scripts/benchmark-issue153-terra-vs-qwen.ps1).

## Route isolation is part of the benchmark

Do not trust client `--model`, `--effort`, `CLAUDE_CODE_SUBAGENT_MODEL`, or an agent frontmatter override by themselves. Two discarded preflights proved that group dispatch can still change delegated calls:

1. Hybrid group 8 had `sdk_cli_mapped_model=gpt-5.6-luna`, so built-in `Explore` ignored the client setting and used Luna.
2. The first Terra-high/Qwen-medium preflight pinned only `sdk_cli_*`; built-in `Plan` still followed inherited `plan_mapped_model=gpt-5.6-sol`, while Qwen SDK calls inherited `high`.

For an isolated benchmark, clone each source group into a temporary active group and pin all of these to the arm model/effort:

- `sdk_cli_mapped_model` and `sdk_cli_reasoning_effort`
- `plan_mapped_model` and `plan_reasoning_effort`
- `compact_mapped_model` and `compact_reasoning_effort`
- `opus_mapped_model`, `sonnet_mapped_model`, and `haiku_mapped_model`
- `model_fallbacks={}`

Run a preflight that delegates both built-in `Explore` and `Plan`, then reject the run unless every `usage_logs` row has the expected model and effort. Disable the temporary keys and groups in `finally`.

## Round 1: Terra medium vs Qwen high

| Metric | Terra medium | Qwen 3.8 Max high |
|---|---:|---:|
| Terminal result | completed, partial | deadline stop at 60m |
| Wall time | 34m 11.6s | >60m |
| Requests | 109 | 76 |
| Input tokens | 2,088,216 | 2,169,403 |
| Output tokens | 36,465 | 100,900 |
| Mean / P95 request | 8.82s / 16.74s | 30.23s / 110.25s |
| Mean first token | 1.82s | 7.11s |

Terra was faster, but its generated reviewer schema did not match its validator and it omitted important status/round/BDD integration. Qwen was more complete, but its agent lacked YAML frontmatter, its revision hash was line-ending-sensitive, and it did not finish.

## Round 2: Terra high vs Qwen medium

Both arms started from new clean worktrees and new Claude sessions. The hard deadline was 90 minutes.

| Metric | Terra high | Qwen 3.8 Max medium |
|---|---:|---:|
| Terminal result | completed | killed at deadline during BDD repair |
| Time to terminal/deadline | 43m 26.3s | 90m |
| Requests | 131 | 138 |
| Input tokens | 2,127,498 | 3,298,969 |
| Output tokens | 43,009 | 161,345 |
| Cache-read tokens | 12,962,304 | 10,678,824 |
| Mean request | 9.53s | 27.17s |
| P50 / P95 request | 5.93s / 23.44s | 18.08s / 60.78s |
| Mean first token | 2.52s | 7.66s |
| Changed files | 10 | 16 |
| Approx. added lines | 331 | 789 |

Route proof was exact: all Terra rows were `gpt-5.6-terra-high/high`; all Qwen rows were `qwen3.8-max-preview/medium`. No fallback or transport error occurred.

### Independent quality verification

Terra reported `complete`, but its new Docker BDD scenario could not load:

```text
SyntaxError: ../hooks/before-after.ts does not provide an export named afterEachScenario
```

Terra's syntax and diff checks passed, but the real feature suite did not start. It also omitted a dedicated MCP status field and hashes raw bytes, making the review revision CRLF/LF-sensitive. Its claim that Docker BDD could not run was false on the same machine.

Qwen did not emit a terminal report before the deadline, but its saved diff passed independent verification:

- `ADVREV001`: 14/14 scenarios and 85/85 steps green in Docker.
- Existing phase-runner surface: 4/4 scenarios and 26/26 steps green.
- Focused ESLint, `node --check`, and `git diff --check` green.
- Mutation `MAX_REVIEW_ROUNDS=3 -> 99` was killed by `ADVREV001_07`; the mutation was reverted.
- `claude --agent spec-phase-review` loaded successfully and returned the probe token.
- The revision hash normalizes CRLF/LF and the MCP `get_spec_status` response exposes engine-owned review state.

Residual Qwen risk: the reviewer has broad `Write` capability so the prompt's one-artifact limit is advisory, and the MCP status addition lacks a dedicated regression assertion. The full repository regression suite did not finish before the deadline.

## Completion follow-up: same sessions, verified to the end

The initial deadline table above remains the checkpoint result. On 2026-07-29 both exact Claude sessions were continued without importing the competing diff.

Terra needed two corrective passes. The first repaired the invalid Cucumber hook, added machine-readable MCP state, normalized the recursive revision digest, and enforced repository `file:line` evidence. Independent review then found a second defect: the new broad test reused the existing `SPECGEN004_578` ID. A final eight-minute pass replaced it with seven unique scenarios (`665` through `671`).

Qwen needed one continuation after the 90-minute cutoff. It completed the wider regression and mutation proof pack, committed the implementation, opened PR #213, and passed CI.

| Verified-to-end metric | Terra high | Qwen 3.8 Max medium |
|---|---:|---:|
| Total wall time | **1h 33m 32.6s** | 1h 48m 10s |
| Corrective continuations | 2 | **1** |
| Requests | 267 | **160** |
| Input tokens | **3,594,849** | 4,740,306 |
| Cache-read tokens | 33,432,576 | **13,246,787** |
| Cache-creation tokens | **0** | 5,550,096 |
| Output tokens | **87,431** | 176,548 |
| Mean / P95 request | **9.93s / 22.96s** | 26.27s / 59.61s |
| Mean first token | **2.60s** | 7.74s |
| API-equivalent estimate | **$18.66** | about $33.83 using Qwen 3.7 Max list price as a proxy |

All 267 Terra rows remained `gpt-5.6-terra-high/high`; all 160 Qwen rows remained `qwen3.8-max-preview/medium`. There was no cross-model fallback.

Independent Terra rerun:

- focused review gate: **7/7 scenarios, 44/44 steps**;
- adjacent orchestrator: **3/3 scenarios, 20/20 steps**;
- changed-file ESLint, runtime syntax checks, MCP bundle build, and `git diff --check`: green;
- each new scenario ID occurs exactly once.

Independent Qwen evidence remained broader: **37/37 focused scenarios and 173/173 steps**, **118/118 adjacent scenarios and 352/352 steps**, mutation proof, live agent load, PR #213, and green CI.

## Implementation quality review

This is a separate judgment from speed and token consumption. The review compares the final verified diffs, not either model's self-report.

| Criterion | Terra high | Qwen medium | Better arm |
|---|---|---|---|
| Core clarity | 188-line evaluator with a structured JSON record | 580-line evaluator with a custom regex Markdown parser | **Terra** |
| Canonical project architecture | Adds `INDEPENDENT_REVIEW` to the existing readiness inventory and authoritative verdict path | Adds a parallel finalization/status gate outside the canonical readiness lane | **Terra** |
| Repository evidence | Resolves the cited file, rejects paths outside the repository, and validates the line number | Checks the evidence string shape but does not prove that the file and line exist | **Terra** |
| Revision coverage | Recursively hashes nested Markdown and feature files after newline normalization | Hashes a fixed list of canonical root documents and root feature files | **Terra** |
| Contract completeness | Misses durable activation, stable finding IDs, severity ordering, and robust round escalation | Enforces engine-owned activation, IDs/order, waiver rules, residual risks, and three-round escalation | **Qwen** |
| Backward compatibility | Makes the new readiness lane globally mandatory | Activates the gate through engine-owned `required` state, leaving legacy specs unaffected | **Qwen** |
| Test design and delivery | Seven focused scenarios appended to the large existing feature; no commit/PR/CI in the benchmark run | Dedicated feature suite, mutation proof, adjacent matrix, committed PR, and green CI | **Qwen** |
| Least privilege | Reviewer can call spec-changing tools | Reviewer has broad `Write`; the one-artifact restriction remains advisory | **Neither** |

Source-level audit links:

- Terra's compact evaluator and real evidence resolver: [`adversarial-review.mjs`](https://github.com/stgmt/dev-pomogator/blob/9a23c3374a2b3db6fb1da9234342d4c6ab929889/tools/specs-generator/adversarial-review.mjs);
- Terra's canonical readiness integration: [`readiness-inventory.ts`](https://github.com/stgmt/dev-pomogator/blob/9a23c3374a2b3db6fb1da9234342d4c6ab929889/tools/spec-graph/readiness-inventory.ts);
- Terra reviewer capabilities: [`spec-phase-adversarial-review.md`](https://github.com/stgmt/dev-pomogator/blob/9a23c3374a2b3db6fb1da9234342d4c6ab929889/.claude/agents/spec-phase-adversarial-review.md);
- Qwen's full evaluator and atomic progress state: [`adversarial-review.mjs`](https://github.com/stgmt/dev-pomogator/blob/4df9aebcc71d13d0ac7c0765070e84d422d0bec7/tools/specs-generator/adversarial-review.mjs);
- Qwen's MCP status integration: [`tools.ts`](https://github.com/stgmt/dev-pomogator/blob/4df9aebcc71d13d0ac7c0765070e84d422d0bec7/tools/spec-mcp-server/tools.ts);
- Qwen's dedicated BDD matrix: [`ADVREV001_adversarial-review-gate.feature`](https://github.com/stgmt/dev-pomogator/blob/4df9aebcc71d13d0ac7c0765070e84d422d0bec7/tests/features/plugins/adversarial-review-gate/ADVREV001_adversarial-review-gate.feature).

The code-style winner is **Terra**: smaller core, less parsing machinery, stronger repository evidence, and better use of the project's canonical readiness model. The safer merge candidate is **Qwen**: it covers more of issue #153, preserves legacy behavior, and arrives with materially stronger executable evidence. A production-quality synthesis would keep Terra's structured record and canonical lane, add Qwen's activation/state and mutation coverage, and replace both reviewers' broad write permissions with one narrow `submit_adversarial_review` tool.

## Decision

- Terra high won verified wall time, uncached input/output volume, and per-request latency, but required two external verifier loops and 267 calls.
- Qwen medium made fewer calls and delivered the broader proof pack plus a green PR, but used more wall time and tokens.
- Terra's final engine is stricter about repository evidence resolution and newline-stable recursive digests. Qwen's delivery evidence is broader.
- For routine delegation, Terra is the faster default only when the harness automatically rejects false completion and resumes the same session.
- For high-risk engine work, neither self-report is sufficient; require executable BDD, mutation or adversarial checks, and a delivery boundary such as PR/CI.

Never rank these arms from first self-reports alone. The decisive measurement is time to independently verified completion.
