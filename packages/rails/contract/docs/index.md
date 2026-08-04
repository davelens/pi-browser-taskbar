# Conformance Contract v1

## Authority and scope

This directory is the normative shared source for cross-adapter wire behavior. Schemas and fixtures
are test-time authority; they are not a Ruby or Elixir runtime dependency and do not generate
adapter implementation code.

The executable foundation establishes fixture formats and the first task/context shapes. Both
whole-page adapter tracer bullets execute the same black-box HTTP scenario from built artifacts in
clean conventional hosts against a deterministic fake Pi peer. Later tracer bullets extend these
scenarios without moving authority into either adapter.

## Versioning

Every contract artifact declares integer `contract_version: 1`. Product package versions are
independently lockstepped by the root `VERSION` file. A contract version changes only when a client
must branch on incompatible wire behavior.

## Server-owned configuration and activation

Native framework development mode is an immutable activation boundary. Outside Rails development or
a Phoenix `Mix.env() == :dev` compilation, adapters mount no routes, emit no taskbar assets, and own
no Pi process even when `enabled` is configured true. In development, `enabled` defaults to true; an
explicit false compiles or boots routes, assets, and Pi ownership out together. Changes take effect
only after the framework's required restart or recompile.

The complete shared semantic configuration surface is `enabled`, `allowed_hosts`, `executable`,
`project_root`, and `task_timeout`. Framework-native configuration has precedence over matching
`PI_BROWSER_TASKBAR_ENABLED`, `PI_BROWSER_TASKBAR_ALLOWED_HOSTS`,
`PI_BROWSER_TASKBAR_EXECUTABLE`, `PI_BROWSER_TASKBAR_PROJECT_ROOT`, and
`PI_BROWSER_TASKBAR_TASK_TIMEOUT` environment fallbacks, which have precedence over defaults. The
defaults are enabled in development, an empty remote-host allowlist, `pi` resolved from `PATH`, the
canonical host project root, and 1,800 seconds. Timeout values are integer seconds from 60 through
86,400. Environment host lists are comma-separated; native host lists are framework lists.

When enabled, malformed booleans, host entries, executable values, project roots, and timeouts fail
startup with the affected setting name. A disabled adapter need not validate its inactive settings.
Configuration is resolved, canonicalized, and fixed at startup; it is not exposed as a browser API.
Browser requests cannot select or override the executable, `--mode rpc` arguments, inherited server
environment, working directory, timeout, protocol bounds, route behavior, or security behavior.

Adapters resolve the configured project root to an existing canonical directory and spawn the
configured executable directly, without a shell, as `executable --mode rpc
--append-system-prompt <one-shot policy>` in that directory. The fixed policy says:

```text
You are handling a one-shot browser task with no reply channel. Complete the user's request autonomously without asking follow-up questions. Inspect the repository and use the supplied browser context. Resolve missing details with conservative assumptions. Act directly on implementation requests, but preserve explicit planning and read-only constraints. Do not repeat a failed approach unchanged. If safe completion is impossible, stop and report the exact blocker.
```

This addition preserves Pi's normal project-root context, tools, skills, model, and settings while
making the non-conversational execution boundary explicit. Pi inherits the development server
environment unchanged. A missing or non-executable command produces only the sanitized unavailable
session state; the optional adapter failure does not prevent either host application from booting.

## Remote development access and diagnostics

Every route and asset request must pass both the framework-normalized request host and client peer
checks. A loopback peer may use `localhost`, a syntactically valid subdomain of `.localhost`,
`127.0.0.1`, `::1`, or an explicitly configured exact allowed host. A non-loopback peer is denied
unless the normalized host exactly matches an entry in a non-empty `allowed_hosts` list. Host
normalization lowercases DNS names, removes their optional final dot, and canonicalizes IP literal
spelling before exact comparison.

Allowed-host entries are bare exact DNS names or IPv4/IPv6 literals only. Schemes, ports, paths,
wildcards, suffix patterns, scoped IP literals, empty list entries, and empty comma-separated entries
are startup errors naming `allowed_hosts`. The empty list is the safe default and enables no remote
access. There is no CIDR, wildcard, remote-access boolean, or suffix matching.

Rails uses only `request.host` and `request.remote_ip`; Phoenix uses only `conn.host` and
`conn.remote_ip`. Those values already reflect the host application's framework and trusted-proxy
configuration. Neither adapter reads `Forwarded`, `X-Forwarded-Host`, `X-Forwarded-For`, or similar
headers itself. Proxy deployments must configure the host framework's trusted proxies rather than
expecting a second taskbar-specific forwarding model.

Mutations remain protected by each framework's native session-bound CSRF check and return the stable
`invalid_csrf` code with a safe message when rejected. Adapter responses add no permissive CORS
headers. Browser validation failures return `invalid_task` and a fixed safe message rather than
copying attacker-controlled fields or local details.

A non-empty allowlist causes the server bootstrap to expose only a boolean remote-access warning
state, never the host list. When that state is active on an HTTP page, the taskbar persistently warns
that remote HTTP is unencrypted and is suitable only on a trusted network. HTTPS does not show the
unencrypted-transport warning. This development mode provides neither transport encryption nor host
user authentication.

Adapters do not log browser context, prompts, commands, inherited environment, absolute paths, raw
Pi/provider errors, stderr, or protocol records. Rails additionally registers host parameter filters
for `prompt` and `context`; Phoenix's forwarded Plug reads the body without controller parameter
logging. Browser-visible task/session diagnostics and adapter-generated errors use bounded fixed
messages and stable codes only.

## Shared HTTP API and stable errors

Both adapters expose the same JSON API below their generated, application-owned mount base:

- `GET /state` returns the complete current snapshot;
- `POST /tasks` admits one normalized task or rejects it atomically;
- `DELETE /tasks/:id` stops the retained task under the cancellation rules below;
- `POST /session/reset` performs the confirmed session switch described below.

Successful reads and mutations return the complete canonical snapshot and `Cache-Control: no-store`.
Mutation requests are never retried; an ambiguous result is reconciled through `GET /state`. Snapshot
session states are `starting`, `ready`, `busy`, `resetting`, and `unavailable`; retained task states
are `running`, `cancelling`, `completed`, `failed`, and `cancelled`. Clients branch only on contract
version, these enums, and the stable codes below, never presentation messages.

| Stable code | HTTP class | Meaning |
| --- | --- | --- |
| `forbidden` | 403 | Host or client access failed closed. |
| `invalid_csrf` | 422 | The framework-native session CSRF check rejected a mutation. |
| `invalid_task` | 422 | JSON, request shape, normalization, or bounds are invalid. |
| `busy` | 409 | Another task is running or cancelling. |
| `task_not_found` | 404 | The requested task is not retained. |
| `task_not_cancellable` | 409 | The retained task is terminal and cannot be stopped. |
| `reset_while_busy` | 409 | The session cannot reset in its current state. |
| `session_reset_rejected` | 409 | Pi rejected the in-process session switch. |
| `unavailable` | 503 | No verified Pi owner is ready for the operation. |

Error messages are fixed safe presentation text. When canonical state exists, conflict, not-found,
and unavailable responses include it as `snapshot`; callers use the code rather than matching the
message.

## Initial task request

A task request has exactly two fields:

- `prompt`: a non-empty normalized dedicated instruction bounded to 4,000 UTF-8 bytes;
- `context`: required normalized browser reference data conforming to
  `browser-context.v1.schema.json`.

Unknown fields are invalid at every modeled level. The browser representation is reference data,
not instruction text. Native adapters will independently validate and normalize requests before
constructing prompts.

## Normalized browser context

A browser context declares its contract version, sanitized location, optional confident route
metadata, structural page snapshot, zero to eight ordered, selector-unique advisory focus points,
and explicit truncation records. A zero-length focus list means a whole-page task. Every focus point
retains its stable selector, conservative source hint, up to eight outer-to-inner ancestor summaries,
and a bounded subtree; focus never removes the whole-page snapshot.

Location retains only an HTTP(S) origin, path, and unique query names in encounter order. URL
credentials, fragments, and query values are forbidden. Route metadata is either `null` or the
bounded method, pattern, handler, and nullable action supplied by a confident adapter seam.

Snapshot nodes retain only tag, role, accessible name, normalized direct visible text, identifier,
bounded class tokens, `name`/`type`/`placeholder`/`data-testid`, semantic control state, sanitized
HTTP(S) `href`/`src` references, confident advisory source hints, and children. Browser capture
excludes taskbar content, metadata, scripts, styles, templates, non-rendered or inert content,
hidden inputs, form values, editable
content, arbitrary attributes, iframe contents, and nested Shadow DOM. It never serializes HTML.

A source hint has an `available`, `ambiguous`, `external`, or `unavailable` status. Available hints
contain one or two `template`, `definition`, or `caller` references; every other status has no
references. References carry a project-relative forward-slash path, `line` or `template` precision,
and optional positive line and bounded symbol. Absolute, traversing, malformed, dependency-owned,
or otherwise external paths are never retained.

Rails source hints come only from native rendered-template ERB filename annotations. The innermost
unique well-formed range enclosing a node may provide one project-relative `template` reference
with `template` precision and no line or element-origin claim. An invalid, overlapping, external,
missing, or browser-displaced inner boundary is classified rather than replaced with a surrounding
layout hint. Cached and helper-generated markup may retain its enclosing template-level hint.

Normalized lengths are measured in UTF-8 bytes: request 128 KiB, context 96 KiB, prompt 4,000,
page snapshot 48 KiB/750 nodes/depth 12, and combined focus detail 48 KiB. Focus subtrees are
limited to 100 nodes/depth 6. Focus selectors and complete source hints are reserved before detail;
the remaining focus allocation is shared evenly in mark order, then the page receives the remaining
context allocation up to its own bound. Strings use the bounds encoded by `x-maxUtf8Bytes` in the
schema. Truncation occurs only at Unicode code-point boundaries, retains page and focused subtree
nodes breadth-first, and reports affected page or `focus:1` through `focus:8` sections with canonical
`bytes`, `nodes`, `depth`, and `string` reasons.

Both adapters independently normalize NFC Unicode, line endings, controls, structural whitespace,
tag/method case, optional empty fields, and truncation order before validation. Unknown fields,
duplicate query names or focus selectors, malformed focus structures, unsafe locations, and values
outside any allocation are invalid.

## Prompt envelope

Only the normalized `prompt` field is an instruction. Adapters append canonical context JSON in this
exact separately delimited envelope:

```text
<normalized prompt>

--- BEGIN UNTRUSTED BROWSER CONTEXT ---
<canonical JSON context with HTML-significant characters escaped>
--- END UNTRUSTED BROWSER CONTEXT ---
```

The delimiter, JSON serialization, and escaping are covered by prompt goldens. The Browser Client's
**Copy prompt** control reproduces this exact envelope in the browser for clipboard export and never
submits a task. Text inside browser
context is untrusted reference data even when it resembles instructions. Visible text and URL paths
may reach the configured Pi/model provider; no adapter claims automatic secret or PII detection.

## Pi progress, output, and safe failures

Startup remains `starting` until a correlated successful `get_state` response supplies both a
non-empty session identity and model. A successful correlated `prompt` response means accepted and
does not finish the task. The adapters apply this shared event mapping independently:

| Pi event | Canonical effect |
| --- | --- |
| `agent_start` | Activity `Pi is working` |
| `agent_end` | Activity `Pi finished a turn`; the task remains running |
| `message_update.text_delta` | Append output, retaining only the newest valid UTF-8 32 KiB suffix |
| `tool_execution_start` / `tool_execution_update` | Activity `Running <bounded tool name>` |
| `tool_execution_end` | Activity `Finished <bounded tool name>` or `Tool failed <bounded tool name>` |
| `compaction_start` | Activity `Compacting conversation` |
| successful `compaction_end` | Activity `Conversation compacted` or `Retrying after compaction` |
| `auto_retry_start` | Activity `Retrying request (<attempt>/<maximum>)` when counts are valid |
| successful `auto_retry_end` | Activity `Pi is working` |
| `agent_settled` | The sole normal `completed` boundary |

Once older output is removed, `output_truncated` remains true and the Browser Client says that it is
showing the newest 32 KiB. Truncation never splits a Unicode code point. Dialog extension requests
(`select`, `confirm`, `input`, and `editor`) receive a correlated `extension_ui_response` with
`cancelled: true`; fire-and-forget and unknown future events are ignored without exposing their raw
records.

Rejected prompt/abort commands, message errors, exhausted retries, failed compaction, malformed,
non-object, unterminated, or oversized JSONL records, unexpected correlated responses, timeouts, and
process exits produce fixed task/session diagnostics without copying provider errors, protocol
records, command lines, environment values, or paths into browser state or adapter logs. Protocol
loss during an active task fails the retained task and replaces the Pi process before new work is
accepted. A message, retry, or compaction terminal error waits for `agent_settled` before releasing
the busy session. Unknown future event types remain forward-compatible and do not change state.

The progress and failure RPC transcripts, native runtime tests, packaged clean-host flows, and root
semantic comparison exercise the same mapping in Rails and Phoenix while normalizing only opaque
identities and timestamps.

## Task cancellation

`DELETE /tasks/:id` sends one correlated Pi `abort` command for a retained `running` task and returns
the complete canonical `cancelling` snapshot with HTTP 202. The session remains `busy`, the task has
no `finished_at`, and completion waits for Pi's `agent_settled` event. At that boundary the task
becomes `cancelled`, receives `finished_at` and `Task stopped` activity, and the session returns to
`ready`.

Cancellation is idempotent: repeating the request while `cancelling` returns the same 202 lifecycle
without sending another abort, and repeating it after `cancelled` returns the retained snapshot with
HTTP 200. A different or forgotten ID returns `404 task_not_found`; a retained `completed` or
`failed` task returns `409 task_not_cancellable`. Error responses include the current snapshot and
all cancellation mutations remain protected by each framework's native CSRF and access checks.
Stopping is not transactional and cannot roll back file changes Pi already made.

## Timeout and process recovery

A configured task timeout fails the active task with retained bounded output and safe diagnostics,
then replaces Pi before accepting more work. Cancellation has its own bounded deadline: if Pi does
not reach `agent_settled`, the task becomes `cancelled` with safe diagnostics and the adapter replaces
the process rather than claiming the old conversation survived.

Replacement sends TERM to the owned Pi process group, waits a bounded interval, escalates to KILL,
and reaps the child before starting a replacement. The public session identity and model are cleared
while replacement is `starting`; a successful startup exposes a new opaque identity. Unexpected exit
while busy preserves terminal task evidence, while idle exit retains no invented task. Startup and
replacement attempts are bounded, ending in `unavailable` when Pi is missing, non-executable, or
repeatedly fails to establish a valid startup state. These failures do not terminate the host
application.

Equivalent Rails and Phoenix fake-Pi runtime scenarios cover task timeout, missed abort settlement,
startup failure, active and idle crashes, successful replacement, exhausted replacement, and owned
child cleanup.

## Rails broker topology

Rails serving processes never own Pi. One gem-packaged external broker owns Pi and canonical task and
session state for the canonical checkout path and OS user. A user-private runtime directory, exclusive
OS lock, Unix socket, atomic endpoint metadata, protocol version, canonical identity, and fresh
instance token make concurrent single-process, threaded, preloaded, clustered, phased, and separate
server invocations converge on the same verified broker. An incompatible or unverifiable live broker
is not terminated, and failure to establish a verified connection is unavailable rather than a
process-local fallback.

Each Rails process lazily retains one PID-aware client outside application reload paths. Reloads keep
the connection; a fork discards only the child's inherited socket and mutex state before lazy
reconnection. The broker remains alive while a client is connected or work is active. Its five-minute
grace begins only after both conditions become false, so disconnected work settles before the timer
starts. Graceful broker shutdown closes and reaps the Pi process group with bounded TERM-to-KILL
cleanup; a broker or Pi replacement truthfully starts a new conversation.

## Browser reconciliation and host navigation

Each mounted Browser Client reads the complete canonical snapshot independently. It polls every 500
milliseconds while the session is `starting`, `resetting`, or `busy`, or the task is `running` or
`cancelling`, and every 30 seconds while stable. Failed reads preserve the last rendered snapshot
and retry with exponential delays bounded between one and 30 seconds. One isolated network failure
stays quiet; repeated network failures or other read errors show a retry indication. Returning
browser visibility triggers an immediate read.

A task, cancellation, or reset mutation is sent exactly once. Any HTTP failure or ambiguous network
result is reconciled with `GET /state`; the client never retries the mutation. This makes admission,
progress, output, cancellation, reset, terminal feedback, and busy controls converge across tabs
without browser-to-browser coordination.

The client appends one Shadow DOM host as a direct body child, marks it permanent for partial
navigation, and reuses an existing host if packaged scripts execute again. Before a body replacement
it moves that host into the incoming body; navigation completion refreshes canonical state. Full
controller/document navigation mounts one new host and reads state. Live page patches leave the host
outside their owned roots. Removed or selector-displaced marked elements are discarded with their
outlines; source hints are captured again from the current DOM at submission rather than retained
across patches. Draft text remains browser-local while a surviving partial-navigation host is reused.

Current-browser acceptance exercises two tabs, ambiguous submission, shared busy,
progress, cancellation, and output, plus idle/active partial navigation, live patching, and full
navigation remounts.

## Corner composer and taskbar accessibility

The Browser Client owns one lower-left launcher and compact composer entirely inside its Shadow DOM.
It uses only native controls, inline taskbar markup, system fonts, and taskbar styles. The open order is
Pi identity/model, task focus and optional removable marks, task instruction, lifecycle feedback, then
footer status, the prompt copy action, and the task action. Zero marks says **Whole page**; one through eight marks remain
advisory focus points with whole-page surroundings.

The stable visible states are **Connecting**, **Ready**, **Working**, **Finished**, **Stopped**, and
**Unavailable**. They are exposed as text and programmatic state, not color alone. One atomic polite
live region announces changed activity and terminal results; visible errors use that same announcer so
status, activity, and error elements do not produce duplicate live regions. Bounded output remains
keyboard-scrollable and labelled, and a stopped task retains the warning that existing file changes
were not rolled back.

Opening moves focus to the labelled instruction field; collapse or `Escape` returns focus to the
launcher. **Mark element** exposes pressed state and visible pointer/focus guidance: a keyboard user
may focus a host-page element and press Enter or Space, while `Escape` cancels and returns focus to
**Mark element**. Removing or clearing marks returns focus to a surviving remove control or **Mark
element**. Native buttons cover submission, stopping, and prompt copying. **Copy prompt** writes the
exact [prompt envelope](#prompt-envelope) for the current instruction and freshly captured context to
the browser clipboard without creating, cancelling, or otherwise mutating a task or session; it shows
brief **Copied** text and announces success or a failed clipboard write through the shared announcer.
It first uses the modern browser Clipboard API and falls back to the browser's legacy user-gesture copy
path when that API is unavailable or denied. It is disabled while the instruction is empty or work is
active and does not otherwise depend on Pi
readiness. Active work disables editing, marking, clearing, and copying while leaving **Stop task**
available.

The composer fits the available narrow viewport, caps its block size so content remains scrollable at
200% zoom, and removes animation and transition effects under `prefers-reduced-motion: reduce`.
Automated acceptance extracts each Browser Client from the built gem or Hex archive and runs both
equivalent example surfaces in current Playwright Chromium, Firefox, and WebKit. It covers every
material lifecycle state, whole-page and focused tasks, mark removal/clear, progress/output, stop,
unavailable/network recovery, cross-tab reconciliation, Turbo navigation,
LiveView navigation/patching, taskbar-owned axe results, names/states/live regions, keyboard focus,
Shadow DOM isolation, desktop/narrow reflow, 200% CSS-zoom reflow emulation, and reduced motion. Artifact hashes, exact engine
versions, scope, and scenarios form deterministic build evidence.

The WCAG 2.2 AA target and automated checks apply only to the Shadow-DOM taskbar interface; they
neither test nor claim accessibility for the host application.

## Session reset

`POST /session/reset` is accepted only while the session is `ready`; a running, cancelling, or
already-resetting session returns `409 reset_while_busy` with the unchanged snapshot. An accepted
request enters `resetting`, sends Pi's supported correlated `new_session` command, then sends
`get_state` and returns HTTP 202 only after the replacement is confirmed `ready`. The public session
identity changes and retained task feedback is cleared.

Pi reports an extension veto as a successful `new_session` response with `data.cancelled: true`.
Adapters return `409 session_reset_rejected` and preserve the old session identity and retained task
snapshot exactly. A failed RPC command, invalid confirmation, protocol failure, or process exit during
the switch invokes process replacement as recovery; an ordinary accepted or rejected switch does not
replace the healthy process.

## Fixture manifest

`fixtures/manifest.json` is the only fixture registry. Each entry identifies a schema, a repository-
relative JSON file, and whether validation must succeed. An entry expecting rejection must include
an error fragment and is considered passing only when the validator rejects it for that reason.
This prevents an invalid fixture from becoming inert sample data.

Negative fixtures prove unknown/malformed fields, duplicate query names, URL credentials, path
query/fragment leakage, UTF-8 byte bounds, aggregate node bounds, and the two-source-reference limit
are rejected. Shared source fixtures exercise Phoenix template and definition/caller precision plus
all non-available classifications. Rich whole-page and prompt fixtures exercise every semantic node
section and the trusted-instruction/untrusted-context boundary.

## Other executable formats

HTTP scenarios, prompt goldens, and Pi RPC transcript formats are versioned alongside browser
context. An HTTP scenario may name a contract task fixture as its request body. The deterministic
fake RPC peer replays transcript `receive`/`send` steps. Shared cancellation scenarios cover accepted
and repeated aborts, wrong and completed task IDs, and the settled terminal snapshot. Shared reset
scenarios and transcripts cover accepted, busy, and extension-rejected switches plus mandatory state
confirmation. Both packages execute these flows; root conformance rejects semantic drift except
opaque IDs and timestamps.
Only `prompt` is instructional; context is canonical JSON inside an explicitly untrusted delimiter,
with HTML-significant characters escaped. Visible text and URL paths may reach the developer's
configured Pi/model provider, so the taskbar is unsuitable for sensitive datasets.

See the [traceability index](../traceability.md) for normative parent sections and their eventual
acceptance seams.
