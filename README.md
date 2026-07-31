# Pi Browser Taskbar

Pi Browser Taskbar is a development-only bridge from a rendered Rails or Phoenix page to one local,
project-scoped Pi coding session. Choose the
[`pi-browser-taskbar-rails`](packages/rails/README.md) gem for Rails ERB/Turbo applications or the
[`pi_browser_taskbar_phoenix`](packages/phoenix/README.md) Hex package for Phoenix
controller-HEEx/LiveView applications. Both distributions contain their private Browser Client and
need no Node or JavaScript package manager for taskbar use.

Do not install the taskbar in production or use it with sensitive datasets. It sends deliberately
submitted visible page text and URL paths to the developer's configured Pi/model provider.

## Documentation

- [Architecture and ownership](docs/architecture.md) explains the independent adapters, private
  Browser Client, canonical contract, examples, and root-tooling boundaries.
- [Security and remote development](docs/security.md) explains the threat model and safe local
  default without redefining the normative wire rules.
- [Troubleshooting](docs/troubleshooting.md) provides symptom-first diagnosis for both adapters.
- [Compatibility](docs/compatibility.md) records claims checked against package metadata and CI
  configuration.
- [Contributing](docs/contributing.md) defines source ownership, generated outputs, and verification.
- [Browser and accessibility acceptance](docs/accessibility-acceptance.md) separates deterministic
  packaged-browser evidence from the required human assistive-technology smoke pass.
- [Coordinated release preparation](docs/releasing.md) defines the protected-main, reproducibility,
  evidence, manifest, checksum, and unpublished-draft gates.
- [Recollect migration](docs/recollect-migration.md) records the one-time install, proof, removal, and
  rollback order.
- [Conformance Contract v1](contract/docs/index.md) is the single normative source for shared API,
  lifecycle, context, prompt, security, stable errors, and conformance semantics.

The conventional [Rails ERB/Turbo example](examples/rails/README.md) and
[Phoenix controller-HEEx/LiveView example](examples/phoenix/README.md) demonstrate equivalent named
scenarios through public package installation seams.

## Architecture at a glance

```text
private Browser Client + adapter provider -> packaged Rails or Phoenix asset
canonical Contract -----------------------> test-time conformance only
built adapter ----------------------------> matching example application
```

The adapters share no runtime code and never depend on one another. Rails uses an external
checkout-scoped broker; Phoenix uses an OTP-supervised runtime. Exact behavior belongs to the
[canonical contract](contract/docs/index.md), not this overview.

## Verify a clean checkout

Install Ruby, Node, Elixir/Mix, and Hex, then run:

```sh
npm ci
npx playwright install --with-deps chromium firefox webkit
bin/verify
```

The command checks contract artifacts, documentation and links, generated shared documents and
Browser Client assets, native suites, package contents, clean artifact-installed host flows, the
packaged Chromium/Firefox/WebKit accessibility matrix, fail-closed non-development boot, and
cross-adapter semantics. Built artifacts are written to
`build/` and examples are deliberately excluded from them. Release candidates additionally use the
[protected preparation workflow](docs/releasing.md), which makes no registry write.

To regenerate committed Browser Client assets and staged offline package documents, run:

```sh
bin/build
```

## Contribution boundaries

Change normative shared behavior only in `contract/` beside its schemas and fixtures. Change generic
browser interaction only in `packages/browser-client/`, and framework behavior only in the matching
adapter. Keep examples on public package seams and root tooling free of runtime behavior. See
[contributing](docs/contributing.md) and the
[requirement traceability index](contract/traceability.md).

## License

Pi Browser Taskbar is available under the [MIT License](LICENSE).
