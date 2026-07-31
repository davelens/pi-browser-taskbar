# Troubleshooting

Use the adapter guide for framework commands and the
[Conformance Contract](../contract/docs/index.md) for normative statuses and stable errors. Do not
paste browser context, raw provider records, credentials, or absolute project paths into an issue.

## Launcher is absent

Confirm the host is running in native development mode and the adapter is enabled. Check that the
installer-owned route, layout, and configuration markers are intact. Rails must load the development
gem and keep rendered-template filename annotations enabled. Phoenix must compile with `MIX_ENV=dev`
and supervise its generated integration immediately before the endpoint.

## Launcher says Unavailable

From the configured project root, confirm the configured executable can start as `pi --mode rpc`.
Restart or recompile after correcting startup-fixed configuration. A missing executable is expected
to leave the host application running while the taskbar remains unavailable.

## Request is forbidden

Try the host through `localhost`, a valid `*.localhost` name, `127.0.0.1`, or `::1`. For deliberate
remote development, follow the [security guide](security.md). Configure proxy trust in Rails or
Phoenix itself; the adapters do not interpret forwarding headers.

## Mutation reports invalid CSRF

Reload the host page to obtain bootstrap data from the current framework session. Do not call taskbar
mutation routes from a hand-built cross-origin client. The packages intentionally preserve native
session-bound CSRF checks.

## Task is busy or will not stop

Another tab or server process may own the one active task. Read canonical state and wait, or use
**Stop task** once. Cancellation remains pending until Pi settles and cannot undo file changes. If Pi
does not settle before the bounded cancellation deadline, the adapter replaces its owned process and
reports a new session when ready.

## Source hint is unavailable or ambiguous

Hints are advisory and conservative. Rails requires intact native ERB filename annotations and only
claims template precision. Phoenix uses valid project-owned HEEx debug evidence. Browser DOM repair,
stale markup, dependency templates, malformed annotations, or overlapping evidence correctly produce
non-available classifications rather than guesses.

## Report a reproducible problem

Run `bin/verify`, include the adapter/version, framework/language versions, stable error code, and the
smallest safe reproduction. State whether the problem occurs in the matching repository example.
Exclude prompts, captured page data, Pi credentials, inherited environment, and raw logs.
