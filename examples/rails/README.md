# Rails ERB/Turbo example

A small conventional Rails application using nested ERB partials, Turbo navigation, and only the
public gem dependency plus generator seam. It defines the same named scenarios and stable selectors
as the Phoenix example.

## Run

From this directory:

```sh
bundle install
SECRET_KEY_BASE="$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')" \
  bin/rails generate pi_browser_taskbar:install
SECRET_KEY_BASE="$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')" \
  bin/rails server
```

Open `http://localhost:3000`. The checked-in dependency uses the local workspace through Bundler's
public gem seam. Release acceptance replaces it with the installed
`build/pi-browser-taskbar-rails-0.1.0.gem` in a clean copy; no source-workspace path is permitted.

## Equivalent named scenarios

| Scenario | Action | Stable selector |
| --- | --- | --- |
| `whole-page` | Submit from the index with no marks. | `[data-testid="scenario-whole-page"]` |
| `focused-card` | Mark the nested card, then submit. | `[data-testid="focus-card"]` |
| `cancellation` | Start a task, choose **Stop task**, and wait for **Stopped**. | `[data-testid="scenario-whole-page"]` |
| `reset` | Confirm **New session** after terminal output. | `[data-testid="scenario-whole-page"]` |
| `navigation` | Follow the Turbo link during idle and active states. | `[data-testid="navigation-target"]` |
| `fail-closed` | Boot with `RAILS_ENV=production`; no taskbar route, asset, or process exists. | `[data-testid="scenario-whole-page"]` |

The prompts are entered manually in the package UI; the example stores no prompts, credentials,
remote allowlist, fake Pi peer, or taskbar runtime hook.

## Verify and uninstall

The root `bin/verify` installs the built gem into a clean conventional host, exercises whole-page,
focus, cancellation, reset, navigation reconciliation, and non-development isolation, and confirms
that the loaded gem path is outside the source workspace. Remove this example's generated seams with:

```sh
SECRET_KEY_BASE="$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')" \
  bin/rails destroy pi_browser_taskbar:install
```

Then remove the development dependency manually.
