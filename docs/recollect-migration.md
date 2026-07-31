# Recollect migration

Recollect consumes the Phoenix adapter through the same dependency, installer, configuration, and
HTTP seams as any other host. Its former application-local taskbar is prior art, not a compatibility
API.

## Install and prove parity before removal

1. In this repository, run `bin/verify`. This builds the Hex archive, extracts its public contents to
   `build/pi_browser_taskbar_phoenix`, installs that artifact into a clean Phoenix host, and runs
   shared conformance.
2. In Recollect, add the extracted artifact as a development-only, non-runtime dependency:

   ```elixir
   {:pi_browser_taskbar_phoenix,
    path: "../pi-browser-taskbar/build/pi_browser_taskbar_phoenix",
    only: :dev,
    runtime: false}
   ```

3. Run `MIX_ENV=dev mix deps.get` and `MIX_ENV=dev mix pi_browser_taskbar.install`. Keep the local
   implementation in place temporarily; the package mount does not reuse `/dev/pi`.
4. Exercise the package route, assets, task lifecycle, normalized context, and layout bootstrap
   against the shared fake peer, then run Recollect's existing local controller, lifecycle,
   validation/prompt, and Browser Client tests.
5. Only after both suites pass, remove Recollect's local runtime, validation, controller/access
   modules, `/dev/pi` routes, browser assets, fake peer, old tests, and old configuration.
6. Run Recollect's `bin/verify-pi-browser-taskbar`, full tests, asset build, and precommit checks.

There is no compatibility route, configuration alias, or payload translation period.

## Configuration map

| Recollect-local setting | Package setting |
| --- | --- |
| `PI_EXECUTABLE` | `PI_BROWSER_TASKBAR_EXECUTABLE` |
| `PI_TASKBAR_ALLOWED_HOSTS` plus `PI_TASKBAR_ALLOW_REMOTE_ACCESS` | `PI_BROWSER_TASKBAR_ALLOWED_HOSTS`; a non-empty exact-host list is the single remote opt-in |
| `Recollect.DevTools.PiAgent` `cwd` | `config :recollect, :pi_browser_taskbar, project_root: ...` or `PI_BROWSER_TASKBAR_PROJECT_ROOT` |
| millisecond `task_timeout_ms` | integer-second `task_timeout` or `PI_BROWSER_TASKBAR_TASK_TIMEOUT` |
| `:pi_taskbar` compile flag | package `enabled` or `PI_BROWSER_TASKBAR_ENABLED` |

The old `/dev/pi/tasks` payload and responses are replaced by the versioned package API below
`/dev/pi-browser-taskbar`. The Browser Client uses that API directly. Recollect does not authorize
these developer routes through application users; the package owns exact host/peer access and native
session CSRF.

## Rollback

Stop the development server before rollback. If the migration is still one isolated Recollect
commit, revert that commit: it restores the complete local implementation and removes the generated
package integration and dependency together. Rebuild assets, clean/recompile development code, run
the restored focused tests, and start the server only after they pass.

For a manual rollback, keep the package dependency available while running
`MIX_ENV=dev mix pi_browser_taskbar.install --uninstall`. Then restore every removed local path and
old configuration from the pre-migration revision, remove the dependency, run `mix deps.get`, rebuild
assets, and run the focused and full Recollect suites. Do not leave both mounts active as a steady
state. Rolling back Recollect does not alter package artifacts, Pi credentials, or registry state.
