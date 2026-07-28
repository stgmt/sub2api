# Terra medium vs Qwen high: issue #153 benchmark

Controlled on 2026-07-28 against `stgmt/dev-pomogator@91a0601e` with the complete issue #153 body, clean detached worktrees, parallel Claude Code 2.1.219 processes, separate temporary API keys, command-line `--settings`, and no cross-provider fallback.

## Routing incident and fix

Discard the first run: both built-in `Explore` children were Luna because hybrid group 8 still had `sdk_cli_mapped_model=gpt-5.6-luna`. `CLAUDE_CODE_SUBAGENT_MODEL` and `Explore.md` did not override that SDK path. Hybrid v2 must manage the group snapshot and pin SDK CLI to Qwen/high. Prove it with an actual parent `Agent(Explore)` turn, child JSONL, and `usage_logs` User-Agent/account/effort.

## Results

| Metric | Terra medium | Qwen 3.8 Max high |
|---|---:|---:|
| Terminal result | completed, partial | deadline stop at 60m |
| Wall time | 34m 11.6s | >60m |
| Requests | 109 | 76 |
| Input tokens | 2,088,216 | 2,169,403 |
| Output tokens | 36,465 | 100,900 |
| Mean / P95 request | 8.82s / 16.74s | 30.23s / 110.25s |
| Mean first token | 1.82s | 7.11s |
| Child agents | 3 | 0 |

Terra is the speed/default-agent winner. Qwen produced broader FR/AC/BDD coverage but was verbose and did not finish within the budget.

## Quality findings

Terra used a modular 267-line validator and had 4/4 focused unit tests plus a successful mutation check, but omitted BDD/status/max-round enforcement. Its loadable reviewer agent writes `schema: adversarial-review@1` while the validator accepts only `adversarial_review`; the generated workflow cannot pass its own gate.

Qwen implemented the three-round cap, derived verdict, resolvable evidence, persisted status, fixtures, and 12 green Docker BDD scenarios. Its round-cap mutation was killed by the BDD. However, `spec-phase-review.md` lacked YAML frontmatter and was not discoverable by `claude --agent`; its raw-byte revision hash is CRLF/LF-sensitive; and it put roughly 500 lines in `specs-generator-core.mjs`.

Neither candidate was production-ready. Qwen is the better feature-completeness starting point after adding valid agent frontmatter, explicit dispatch, and cross-platform revision normalization. Terra medium remains the better routine delegated model.
