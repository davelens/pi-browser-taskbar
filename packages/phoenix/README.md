# Pi Browser Taskbar Phoenix

Development-only Phoenix adapter for conventional Phoenix 1.7+ controller-HEEx and LiveView
applications. The Hex package includes the Browser Client, so consuming applications need no Node or
JavaScript package manager for the taskbar. Shared wire behavior is defined only by the packaged
[Conformance Contract](contract/docs/index.md).

## Dependency

Add the matching product version only in development. `runtime: false` leaves startup to the
generated host integration:

```elixir
{:pi_browser_taskbar_phoenix, "~> 0.4.1", only: :dev, runtime: false}
```

## Installer

```sh
MIX_ENV=dev mix deps.get
MIX_ENV=dev mix pi_browser_taskbar.install
```

For an umbrella or nonstandard host, pass the application root and any ambiguous application, web,
endpoint, router, layout, or mount options. Run `mix help pi_browser_taskbar.install` for the exact
flags. The installer plans every edit before writing and refuses ambiguous discovery, collisions,
annotation conflicts, unsupported layouts, and edited generated sections.

## Generated integration

The installer creates one host-owned `MyAppWeb.PiBrowserTaskbar` module and marked sections for its
supervised child, router expansion, root-layout bootstrap, and HEEx debug annotations. Its
non-development branch has no package reference, routes, assets, or runtime process. The development
branch starts the package supervisor immediately before the endpoint and uses a package-owned native
session/CSRF pipeline.

## Configuration

Use application-native syntax in `config/dev.exs`:

```elixir
config :my_app, :pi_browser_taskbar,
  enabled: true,
  allowed_hosts: [],
  executable: "pi",
  project_root: File.cwd!(),
  task_timeout: 1_800
```

The matching `PI_BROWSER_TASKBAR_*` environment fallbacks and the normative field semantics are in
[Server-owned configuration and activation](contract/docs/index.md#server-owned-configuration-and-activation).
Recompile the development application after a configuration change.

## Verification

Start Phoenix in development, open a host page, and confirm the lower-left **Page task** launcher is
present. Run a whole-page task, mark an element for a focused task, stop a running task, start a new
session, and follow controller and LiveView navigation. Repository contributors run `bin/verify` at
the monorepo root; `examples/phoenix/` names the same scenarios and stable selectors.

## Diagnosis

If the launcher is absent, confirm `MIX_ENV=dev`, the generated markers remain intact, and the
integration is supervised before the endpoint. If it is unavailable, run
`pi --mode rpc --append-system-prompt "one-shot probe"` from the configured project root and inspect
only the adapter's safe diagnostics. For host, CSRF, source-hint,
busy, and cancellation symptoms, use the packaged [troubleshooting guide](docs/troubleshooting.md).

## Updates

Update the development dependency within the matching product version, fetch dependencies, and rerun
the installer. It reports a current installation or updates only recognized marked content.

## Security

Phoenix supplies native session CSRF, normalized host/peer information, request-body log isolation,
and compile-time development activation. The shared threat model and remote-access rules are in the
packaged [security guide](docs/security.md); normative invariants remain in the
[Conformance Contract](contract/docs/index.md#remote-development-access-and-diagnostics).

## Uninstall

Keep the development dependency available while running:

```sh
MIX_ENV=dev mix pi_browser_taskbar.install --uninstall
```

Uninstall preflights all owned sections and removes only recognized generated content. Remove the
dependency from `mix.exs` manually afterward. Pre-existing annotation configuration, credentials,
sessions, and unrelated host code are not removed.

## Changelog and example

See the [Phoenix changelog](CHANGELOG.md) and repository path `examples/phoenix/` for the executable
controller-HEEx/LiveView example.

## Matching-version contract

This adapter version is `0.4.1`. Use the same product version shown by the Rails adapter and the root
`VERSION`; the packaged [Conformance Contract](contract/docs/index.md) is the offline normative
reference for both adapters.
