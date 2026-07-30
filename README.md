# Pi Browser Taskbar

A development-only, local bridge between Pi and Rails or Phoenix applications.

This repository is a monorepo for two independent packages:

- [`pi-browser-taskbar-rails`](packages/rails/README.md)
- [`pi_browser_taskbar_phoenix`](packages/phoenix/README.md)

Both packages bundle the private, dependency-free Browser Client. Applications consuming either
package do not need Node or a JavaScript package manager.

## Repository foundation

The executable foundation contains versioned contract schemas and fixtures, native package
artifacts, deterministic browser asset generation, and automated ownership checks. The Phoenix
and Rails adapters now include equivalent bounded whole-page flows with up to eight advisory marked
focus points: deterministic sanitized Browser Client capture, fair focus truncation, independent
native normalization, native HTTP security, canonical Pi ownership, and completed fake-Pi output.
Focused tasks attach conservative framework-native source hints: template-level ERB ranges in Rails
and line-level HEEx evidence in Phoenix. Rails uses one external checkout-scoped broker; Phoenix
uses one supervised runtime.

The [canonical contract](contract/docs/index.md) owns shared normative behavior. The
[architecture guide](docs/architecture.md) explains package ownership and dependency direction.

## Verify a clean checkout

Install Ruby, Node, Elixir/Mix, and Hex, then run the single root verification entry point:

```sh
bin/verify
```

It validates contract fixtures (including an intentionally invalid fixture), rejects ownership or
version drift, checks generated assets, runs native package tests, builds both package artifacts,
inspects their contents, installs both built artifacts into clean conventional hosts for
development-flow and production-isolation conformance, and compares adapter semantics while
ignoring only opaque IDs and timestamps. Artifacts are written to `build/`.

To regenerate committed package assets after changing Browser Client or provider source, run:

```sh
bin/build
```

See [contributing](docs/contributing.md) and the
[requirement traceability index](contract/traceability.md) for the acceptance seams established by
this foundation.

## License

Pi Browser Taskbar is available under the [MIT License](LICENSE).
