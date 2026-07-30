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

- `prompt`: a non-empty dedicated instruction, initially bounded to 4,000 characters by schema;
- `context`: required normalized browser reference data conforming to
  `browser-context.v1.schema.json`.

Unknown fields are invalid at every modeled level. The browser representation is reference data,
not instruction text. Native adapters will independently validate and normalize requests before
constructing prompts.

## Initial browser context

A browser context declares its contract version, sanitized location, optional route metadata,
structural page snapshot, zero to eight advisory focus points, and explicit truncation records. A
zero-length focus list means a whole-page task. The schema is deliberately smaller than the final
normalized-context contract and will grow through contract fixtures before native implementation.

## Fixture manifest

`fixtures/manifest.json` is the only fixture registry. Each entry identifies a schema, a repository-
relative JSON file, and whether validation must succeed. An entry expecting rejection must include
an error fragment and is considered passing only when the validator rejects it for that reason.
This prevents an invalid fixture from becoming inert sample data.

The first negative fixture adds an unknown top-level browser-context property, proving that
`additionalProperties: false` is executable.

## Other executable formats

HTTP scenarios, prompt goldens, and Pi RPC transcript formats are versioned alongside browser
context. An HTTP scenario may name a contract task fixture as its request body. The deterministic
fake RPC peer replays transcript `receive`/`send` steps. Both packages execute the whole-page scenario from `POST /tasks` through `agent_settled` and the
canonical completed state. Root conformance rejects semantic drift except opaque IDs and timestamps.

See the [traceability index](../traceability.md) for normative parent sections and their eventual
acceptance seams.
