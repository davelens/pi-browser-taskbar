# Phoenix controller-HEEx/LiveView example

A small conventional Phoenix application using controller-rendered HEEx, a nested function
component, LiveView navigation and patches, and only the public Hex dependency plus Mix installer
seam. It defines the same named scenarios and stable selectors as the Rails example.

## Run

From this directory:

```sh
MIX_ENV=dev mix deps.get
MIX_ENV=dev mix pi_browser_taskbar.install
SECRET_KEY_BASE="$(mix phx.gen.secret)" MIX_ENV=dev mix phx.server
```

Open `http://localhost:4000`. The checked-in dependency uses the local workspace through Mix's public
package seam. Release acceptance replaces it with an extracted
`build/pi_browser_taskbar_phoenix-0.2.0.tar` in a clean copy; no source-workspace path is permitted.

## Equivalent named scenarios

| Scenario | Action | Stable selector |
| --- | --- | --- |
| `whole-page` | Submit from the controller page with no marks. | `[data-testid="scenario-whole-page"]` |
| `focused-card` | Mark the nested component, then submit. | `[data-testid="focus-card"]` |
| `cancellation` | Start a task, choose **Stop task**, and wait for **Stopped**. | `[data-testid="scenario-whole-page"]` |
| `navigation` | Follow the LiveView link and patch during idle and active states. | `[data-testid="navigation-target"]` |
| `fail-closed` | Compile with `MIX_ENV=prod`; no taskbar route, asset, or process exists. | `[data-testid="scenario-whole-page"]` |

The prompts are entered manually in the package UI; the example stores no prompts, credentials,
remote allowlist, fake Pi peer, or taskbar runtime hook.

## Verify and uninstall

The root `bin/verify` installs the built archive into a clean conventional host, exercises whole-page,
focus, cancellation, navigation reconciliation, and non-development isolation, and confirms
that the loaded package is outside the source workspace. Remove this example's generated seams while
the development dependency is still available:

```sh
MIX_ENV=dev mix pi_browser_taskbar.install --uninstall
```

Then remove the development dependency manually.
