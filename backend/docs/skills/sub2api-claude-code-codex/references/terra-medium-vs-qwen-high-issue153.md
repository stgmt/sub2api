# Terra vs Qwen: issue #153 implementation benchmark

Controlled on 2026-07-28 against `stgmt/dev-pomogator@91a0601e` with the complete issue #153 body, clean detached worktrees, parallel Claude Code 2.1.219 processes, separate temporary API keys/groups, command-line `--settings`, and no cross-provider fallback.

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

## Decision

- For routine delegated work where latency matters, Terra remains the faster default.
- For issue #153 implementation quality, Qwen-medium is the stronger starting point despite missing the deadline; its executable coverage caught and repaired real engine defects.
- Raising Terra from medium to high did not improve this task: it was slower than Round 1 and still declared completion over a broken BDD integration.
- Lowering Qwen from high to medium did not make it fast: it consumed 3.75x Terra's output tokens and still reached the 90-minute deadline.

Never rank these arms from self-reports alone. The decisive evidence is route-pure `usage_logs`, real Docker BDD, mutation resistance, live agent discoverability, and independent diff review.
