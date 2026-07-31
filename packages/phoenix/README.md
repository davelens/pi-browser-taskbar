# Pi Browser Taskbar Phoenix

Development-only Phoenix adapter with a prebuilt, dependency-free Browser Client. A consuming
application does not need Node or a JavaScript package manager.

## Install in a conventional Phoenix application

Add the package only to development. `runtime: false` prevents Mix from auto-starting the package;
the generated host integration owns its one supervised runtime explicitly.

```elixir
# mix.exs
defp deps do
  [
    {:pi_browser_taskbar_phoenix, "~> 0.1.0", only: :dev, runtime: false}
  ]
end
```

Then run:

```sh
MIX_ENV=dev mix deps.get
MIX_ENV=dev mix pi_browser_taskbar.install
```

The installer discovers the OTP application, web namespace, endpoint, router, application
supervisor, and root HEEx layout before writing. It then idempotently adds:

- one host-owned `MyAppWeb.PiBrowserTaskbar` integration module containing installation metadata;
- that integration as a supervised child immediately before `MyAppWeb.Endpoint`;
- `/dev/pi-browser-taskbar` through package-owned, application-prefixed Phoenix route helpers and a
  session/CSRF pipeline;
- one root-layout bootstrap outside LiveView-owned DOM;
- development-only `Phoenix.LiveView` HEEx debug annotations for advisory source hints.

Every owned host section is marked. All paths, source shapes, conflicts, and generated checksums are
preflighted before staged writes, and changed Elixir files are formatted. Re-running the command is
an idempotent update when generated content is intact. Edited generated sections, route/helper
collisions, conflicting annotation settings, unsupported layouts, and ambiguous discovery stop
without updating any host file.

For an umbrella or nonstandard host, select its application root and provide the ambiguous seams:

```sh
MIX_ENV=dev mix pi_browser_taskbar.install \
  --root . --app my_app --web MyAppWeb --endpoint MyAppWeb.Endpoint \
  --application lib/my_app/application.ex --router lib/my_app_web/router.ex \
  --layout lib/my_app_web/components/layouts/root.html.heex \
  --mount /dev/pi-browser-taskbar
```

Options accept router modules or source paths; application and layout options are source paths.
The installer refuses to guess when more than one candidate remains and reports the option needed.

The router mount deliberately uses a package-owned pipeline with Phoenix's `:fetch_session` and
`:protect_from_forgery` plugs. This preserves the native session-bound CSRF seam without inheriting
a conventional HTML-only `:accepts` plug for the JSON API. The package also checks the
framework-normalized host and peer address on every route.

The generated module has a dependency-free non-development branch. Therefore test and production
can compile and boot without this development-only dependency; those builds expand no routes,
emit no assets, and start no taskbar process.

## Use

Restart the development server, open any page, and use the lower-left **Page task** composer. A
prompt with no marks submits a bounded sanitized whole-page structural snapshot. Visible text and
URL paths may reach the configured Pi/model provider, so do not use it with sensitive datasets. The
package admits one task at a time to one persistent `pi --mode rpc` process and retains the latest
terminal output. While a task is running, **Stop task** sends Pi's abort command and remains
cancelling until Pi settles. Stopping cannot roll back file changes Pi already made. The confirmed
**New session** action uses Pi's in-process session switch, clears retained feedback only after state
confirmation, and preserves the local draft and focus marks; a rejected switch preserves the old
session.

## Configuration

Configuration is keyed by the host OTP application:

```elixir
# config/dev.exs
config :my_app, :pi_browser_taskbar,
  enabled: true,
  allowed_hosts: [],
  executable: "pi",
  project_root: File.cwd!(),
  task_timeout: 1_800
```

In development, `enabled` defaults to true; explicit false disables routes, assets, and Pi ownership
after recompilation. These five fields are the complete server-owned semantic configuration surface.
Explicit application configuration wins over matching `PI_BROWSER_TASKBAR_*` environment fallbacks,
which win over defaults; `PI_BROWSER_TASKBAR_ALLOWED_HOSTS` is comma-separated. `task_timeout` is
integer seconds from 60 through 86,400. Invalid active values fail startup with the setting name;
inactive values are not validated when disabled.

Outside `Mix.env() == :dev` the generated dependency-free branch stays absent regardless of
configuration. It retains only host installation metadata and stubs, and does not reference the
package. The executable and fixed `--mode rpc` arguments are spawned directly in the canonical
project root with the development server environment. Browser requests cannot override process,
timeout, route, protocol, or security configuration. A missing executable reports sanitized
unavailable state without preventing the host endpoint from booting.

Remote access requires a non-empty list of bare exact DNS names or IP literals. Every request uses
Plug's normalized `conn.host` and `conn.remote_ip`; configure trusted proxies in the host endpoint and
do not add taskbar-specific forwarding-header handling. Plain HTTP remote access is only for a
trusted network and keeps a persistent unencrypted-access warning in the taskbar. The adapter retains
native session CSRF, adds no permissive CORS headers, and returns fixed safe browser errors without
logging request bodies or Pi records. See the shared [security guide](../../docs/security.md).

## Uninstall

Keep the development dependency available while running the inverse installer:

```sh
MIX_ENV=dev mix pi_browser_taskbar.install --uninstall
```

For a nonstandard installation, `--web` can select its generated integration if more than one exists.
Uninstall verifies the integration checksum and every marked host seam before changing anything,
then removes only recognized generated content and formats affected Elixir files. Repeating it is
harmless. If generated content was edited or metadata is missing, it stops with precise manual
removal guidance rather than deleting ambiguous content. Pre-existing annotation configuration is
never removed. Remove the development dependency from `mix.exs` manually after successful uninstall;
the installer never guesses at dependency declarations.

## Build and verify

Run `bin/verify` from the repository root. It validates contracts and generated assets, runs native
and Browser Client tests, builds the Hex package, and inspects its contents.

See the repository [architecture](../../docs/architecture.md) and
[canonical contract](../../contract/docs/index.md).
