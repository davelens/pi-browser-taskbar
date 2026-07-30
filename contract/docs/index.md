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
Stopping is not transactional and cannot roll back file changes Pi already made. Abort deadlines,
process-tree replacement, and recovery belong to the later recovery capability.

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

The Browser Client presents a persistent secondary **New session** button. It is disabled while work
is running, cancelling, or resetting, changes inline to **Start fresh?** for confirmation, and shows
**Starting a fresh session** while the mutation is pending. Successful reset removes server-retained
feedback without changing the browser-local draft or focus marks.

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
