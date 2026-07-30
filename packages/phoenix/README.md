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

The installer plans all changes before writing and idempotently adds:

- one host-owned `MyAppWeb.PiBrowserTaskbar` integration module;
- that integration as a supervised child immediately before `MyAppWeb.Endpoint`;
- `/dev/pi-browser-taskbar` through a package-owned Phoenix session/CSRF pipeline;
- one root-layout bootstrap outside LiveView-owned DOM.

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
cancelling until Pi settles. Stopping cannot roll back file changes Pi already made.

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

`task_timeout` is in seconds and must be from 60 through 86,400. Explicit application
configuration wins over matching `PI_BROWSER_TASKBAR_*` environment variables. A missing Pi
executable leaves the host running and reports an unavailable taskbar state. Exact remote hosts
must be explicitly listed in `allowed_hosts`; loopback host/client access is the default.

## Build and verify

Run `bin/verify` from the repository root. It validates contracts and generated assets, runs native
and Browser Client tests, builds the Hex package, and inspects its contents.

See the repository [architecture](../../docs/architecture.md) and
[canonical contract](../../contract/docs/index.md).
