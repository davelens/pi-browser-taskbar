# Contributing

## Verification

Run `npm ci`, `npx playwright install --with-deps chromium firefox webkit`, then `bin/verify` from
the repository root. Do not substitute package-local checks for this command: it is the
clean-checkout acceptance seam for contracts, generated assets, ownership, both native test suites,
both built artifacts, and the packaged browser/accessibility matrix. See the
[browser and accessibility acceptance checklist](accessibility-acceptance.md).

## Ownership rules

- Put framework-neutral browser behavior in `packages/browser-client/`.
- Put normative shared data and prose in `contract/`; never import adapter implementation there.
- Put framework runtime code and its provider in the matching adapter directory.
- Do not share Ruby or Elixir runtime code and do not make adapters depend on one another.
- Keep root orchestration in `tooling/`; it must not become product runtime behavior.

See [architecture](architecture.md) for the complete dependency direction.

## Generated browser assets

Files under `packages/rails/lib/pi/browser/taskbar/rails/assets/` and
`packages/phoenix/priv/static/` are generated. Change Browser Client or package provider source,
run `bin/build`, and commit the resulting assets. `bin/verify` fails when they are stale.

## Contract and documentation changes

The [canonical contract](../contract/docs/index.md), schemas, fixtures, and traceability entry must
advance together. An invalid fixture is evidence only when its manifest entry expects rejection and
the validator reports the intended failure. Adapter guides stay framework-specific and link to the
contract rather than copying shared behavior. Run `bin/build` after changing shared packaged docs;
verification requires every staged copy to be byte-identical and every repository/package link to
resolve.

## Release preparation

Use the protected workflow documented in [coordinated release preparation](releasing.md). Do not
rebuild a prepared candidate or substitute workspace dependencies. Preparation preserves checksums
and provenance without publishing to a registry.

## Examples

Keep Rails and Phoenix scenarios named and selected equivalently. Examples may use only published
dependencies, installers, generated integrations, and ordinary framework code—never direct package
internals, fake-peer hooks, credentials, sensitive prompts, or remote allowlists. Package inspection
must continue to exclude `examples/` from both artifacts.
