# Provider account sync and protocol-routing refactor

## Status

Analysis and implementation plan. No runtime mutation is authorized by this document.

## Incident summary

DSH correctly sends a streaming OpenAI Responses request through Headroom. For
the Cline Pass route, Headroom forwards the body unchanged and sub2api returns a
short SSE sequence that contains no assistant content. DSH then reports a
completed response with no content.

The immediate failure is produced by a cross-protocol path:

1. `sync-cline-pass-auth.ps1` creates or updates `accounts` through direct SQL.
2. The write bypasses account validation, scheduler/cache invalidation, and the
   OpenAI-compatible upstream capability probe.
3. The Cline account has neither `openai_responses_mode` nor
   `openai_responses_supported` in `extra`.
4. Unknown capability currently defaults to trying `/v1/responses`.
5. Cline Pass exposes Chat Completions, so sub2api falls back to
   `/v1/chat/completions` and translates the result back into Responses SSE.
6. The legacy reactive fallback bridge can emit a successful `response.completed` sequence
   without any `response.output_text.delta`, hiding the protocol failure as an
   empty model answer.

`sync-grok-build-auth.ps1` has the same architectural violation for credential
rotation: it updates `accounts` through SQL and restarts sub2api to refresh
state. Grok must be tested independently; sharing the defect does not prove
that its upstream has the same protocol capabilities as Cline.

## Refactoring target

There must be exactly one service-owned provider synchronization path for
account creation and credential rotation. Scripts may read and normalize host
auth files, but may not mutate `accounts`, memberships, scheduler state, or
capability fields directly. The refactor removes the SQL synchronizers,
restart-based invalidation, optimistic Responses routing, and empty-success
fallback behavior. It does not preserve a compatibility path, feature flag, or
automatic fallback to any of those mechanisms.

The service operation must be idempotent and transactional. It must:

- upsert the provider account by stable provider/source identity;
- preserve provider-owned refresh state when the incoming credential has not
  changed;
- validate platform, account type, base URL, and safe credential shape;
- create or repair group membership and model restrictions;
- establish an explicit protocol capability contract;
- commit durable state first, then reload the scheduler/account snapshot by
  committed account revision without restarting the process;
- return safe structured results without credentials;
- expose whether credentials, membership, models, or capabilities changed.

The database transaction and in-memory reload are deliberately separate. The
transaction atomically commits account, membership, model policy, capability,
and a monotonically increasing account revision. After commit, the service
reloads that exact revision. A failed reload returns a degraded result and
leaves a durable reconciliation record for bounded retry; it never rolls back
committed credentials, restarts the process, or falls back to SQL.

## Work plan

### 1. Capture contracts before changing code

- Add fixtures for Cline Pass and Grok Build auth payloads with fake secrets.
- Record current account rows using only non-secret fields: platform, type,
  auth source, base URL, capability mode/result, status, schedulability, group
  membership, and model restrictions.
- Add upstream protocol probes for each provider:
  `/v1/responses` streaming and buffered, `/v1/chat/completions` streaming and
  buffered, text, reasoning, tool call, finish reason, usage, and error shape.
- Classify Cline and Grok independently. Never infer Grok from Cline or native
  xAI documentation when the configured endpoint is `cli-chat-proxy.grok.com`.

### 2. Add the only provider sync service and API

- Introduce a provider-sync service input that contains normalized provider
  identity, credentials, endpoint, intended group, models, and an explicit
  capability policy.
- Add a loopback/private-network endpoint dedicated to host synchronizers.
  Authenticate it with a separate runtime-generated service credential having
  only `provider:sync`; do not accept browser sessions, ordinary user keys, or
  broad admin JWTs. Store the credential in the existing protected runtime
  environment and never copy it into Git, DSH settings, logs, or script output.
  Reuse the account service and repositories rather than exposing a generic
  SQL payload endpoint.
- Put account upsert, membership repair, model restrictions, capability state,
  and account revision behind one service transaction. Perform scheduler/cache
  reload after commit and prove the loaded revision matches the committed one.
- Make capability state first-class and auditable. Store mode, result,
  `endpoint_fingerprint`, `auth_source`, `probed_at`, `expires_at`, and
  `probe_revision`. The fingerprint covers normalized scheme/host/base path and
  provider source but never credentials. An absent, expired, or mismatched
  result is unknown and unschedulable for protocol-dependent traffic until a
  dedicated probe resolves it; it must not mean Responses-compatible.
- Define credential-change semantics so refresh tokens generated by sub2api are
  retained only when they still belong to the same incoming identity.

### 3. Replace Cline and Grok synchronizers

- Replace `Invoke-PsqlScript` and embedded SQL in
  `sync-cline-pass-auth.ps1` with the provider-sync API.
- Replace direct SQL credential updates in `sync-grok-build-auth.ps1` with the
  same API.
- Keep `-CheckOnly`, secret redaction, auth-file parsing, and safe JSON output.
- Remove restart-as-cache-invalidation. A restart remains a deployment action,
  not part of credential synchronization.
- Fail closed when the API is unavailable or returns an unknown schema; never
  fall back to SQL.
- Add a migration/repair command that brings existing Cline and Grok rows under
  the new contract without rotating credentials.
- Delete `Invoke-PsqlScript`, embedded account SQL, and restart helpers from
  both synchronizers in the same change. Add structural tests that fail if
  provider scripts regain `psql`, account DML, direct group-membership DML, or
  synchronization-triggered restart calls.
- Do not retain legacy flags, hidden environment switches, or a dual-write
  period. The old scripts stop being valid at cutover.

### 4. Correct protocol routing

- Set Cline Pass to `force_chat_completions` unless a current live probe proves
  its configured endpoint supports Responses.
- Set Grok Build from its own live probe result. Do not share Cline's setting.
- Remove request-time "try Responses, catch unsupported, retry Chat" routing.
  Select the upstream protocol once from the validated capability contract and
  invoke only that endpoint. Chat-only providers use the explicit tested
  Responses-to-Chat adapter directly; that adapter is protocol translation,
  not an error fallback.
- Change unknown capability handling for custom OpenAI-compatible endpoints so
  it does not optimistically select Responses without evidence.
- Determine support only with a dedicated canonical capability probe, never
  from a user request. A 404 is definitive only when the probe proves the
  endpoint path itself is unsupported; model-not-found, authentication,
  malformed request, proxy routing, and transient failures remain probe errors.
  Persist the result against the endpoint fingerprint with an expiry and
  bounded re-probe. User traffic never mutates capability state.
- Log one safe routing decision containing account ID, provider, endpoint host,
  capability source, inbound protocol, and selected upstream protocol.

### 5. Make the Responses-to-Chat bridge fail honestly

- Preserve `stream:true` explicitly when converting a streaming Responses
  request to Chat Completions; do not depend on a zero-value field with
  `omitempty`.
- Require client-consumable output before emitting successful completion:
  output text or a complete tool call. Reasoning-only, usage-only, and
  lifecycle-only streams are not successful DSH agent responses.
- If a streaming upstream ends without client-consumable output, emit one
  protocol-valid `response.failed` terminal event and no
  `response.completed`. If a buffered upstream ends that way, return HTTP 502
  with a safe structured upstream-protocol error. Never synthesize an empty
  assistant message.
- Preserve reasoning, tool-call arguments, finish reason, usage, provider
  metadata, cancellation, and upstream errors in both streaming and buffered
  paths.
- Emit exactly one terminal Responses event and verify that Headroom does not
  rewrite or suppress it.

### 6. DSH and Headroom boundaries

- Keep DSH provider `api: openai-responses`; installed DSH intentionally sends
  `stream:true` and should not contain provider-specific fallback logic.
- Keep Headroom unchanged unless a failing proof identifies a Headroom-owned
  defect. Its existing trace already proves the relevant route is streaming
  and body-transparent. New routing diagnostics belong in sub2api: inbound
  `stream`, selected upstream protocol, consumable-output count, terminal event,
  capability source, and account revision. Do not log prompts, tools,
  credentials, or full bodies.
- Verify model tags and effort declarations separately from request routing;
  picker visibility is not proof that the upstream accepts the field.

### 7. Test matrix

Unit and contract tests:

- provider sync create, update, unchanged, token-owner change, deleted-account
  recovery, membership repair, cache invalidation, API unavailable, and secret
  redaction;
- scripts contain no `psql`, `INSERT INTO accounts`, or `UPDATE accounts` and
  never restart sub2api after credential-only synchronization;
- capability resolution for explicit yes/no, unknown custom endpoint, forced
  mode, probe expiry, and protocol-level unsupported responses;
- Responses-to-Chat buffered and streaming text, reasoning-only, tool-only,
  mixed content, usage-only tail, empty EOF, malformed SSE, error event,
  cancellation, and client disconnect;
- mutation-style assertions: removing `stream:true`, semantic-output guard, or
  capability persistence must make a test fail.

Live integration tests, separately for Cline and Grok:

- create temporary provider-isolated groups and API keys so the scheduler
  cannot select another account;
- direct sub2api Responses streaming request;
- direct sub2api Responses buffered request;
- DSH through Headroom streaming text request;
- tool-call request with complete arguments;
- a deterministic large-payload integration fixture plus one bounded live
  long-context canary representative of the failing DSH request;
- two consecutive requests proving there is no unsupported-endpoint attempt or
  request-time protocol fallback;
- credential sync while sub2api remains running, followed by a successful
  request proving cache invalidation without restart;
- trace correlation across DSH session ID, Headroom request ID, sub2api usage
  row, account, selected protocol, upstream status, semantic delta, and
  terminal event.
- assert the `usage_logs.account_id`, provider, endpoint host, capability
  fingerprint, and account revision match the isolated target; model output
  alone is not routing proof.

Required success markers:

- at least one semantic Responses event for successful text/tool requests;
- exactly one protocol-valid terminal event;
- DSH leaves `Deep diving` and renders content;
- no `completed response with no content`;
- no Cline `/v1/responses` attempt when its contract is Chat Completions;
- no direct SQL account mutation and no synchronization-triggered restart;
- running image revisions match the tested fork commits.

### 8. Atomic cutover and forward repair

- Build the service/API, data migration, replacement synchronizers, protocol
  routing, bridge corrections, tests, and verifier as one refactor branch.
- Prove both provider-isolated matrices against an ephemeral full stack before
  touching the live database.
- Back up the live database, then run a one-way idempotent migration that adds
  capability metadata and account revisions without rotating credentials. The
  migration must validate every affected Cline/Grok row before commit.
- Deploy the complete sub2api image with the drained replacement script, then
  install only the replacement synchronizers. There is no intermediate live
  state where new backend and old SQL scripts are both accepted.
- Keep provider synchronization disabled until post-cutover revision reload,
  isolated Cline/Grok probes, and DSH-through-Headroom proofs pass. Then enable
  the new synchronizers.
- Delete obsolete SQL-sync documentation, tests, helpers, and watchdog branches
  in the same delivery. Do not preserve dead compatibility code.
- Do not roll back to an image or script that permits direct SQL, optimistic
  Responses routing, or empty-success conversion. If cutover fails before
  irreversible migration, abort without changing live state. If it fails after
  migration, disable provider synchronization and issue a forward repair image;
  preserve credentials and migrated data.

## Repository knowledge to update with the implementation

- Add a new incident ID to `session-failure-registry.md` for service-layer
  bypass plus optimistic protocol capability.
- Add the dated symptom/mechanism/fix/proof entry to the sub2api skill and the
  Headroom gotchas ledger when Headroom owns any changed behavior.
- Update synchronizer contract tests so future direct SQL, restart-based cache
  refresh, or inferred provider capability is rejected.
- Mirror the invariant into the installed local maintainer skill only after the
  repo copy and live runtime have been proven.
