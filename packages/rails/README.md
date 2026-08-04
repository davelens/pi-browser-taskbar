# Pi Browser Taskbar Rails

Development-only Rails adapter for conventional Rails 7.1 through 8.1 ERB applications on MRI/Linux.
The gem includes the Browser Client, so consuming applications need no Node or JavaScript package
manager for the taskbar. Exact release-blocking Ruby/Rails rows and Puma modes are maintained in the
repository's compatibility matrix. Shared wire behavior is defined only by the packaged
[Conformance Contract](contract/docs/index.md).

## Dependency

Add the matching product version to the development group:

```ruby
group :development do
  gem "pi-browser-taskbar-rails", "~> 0.4.1", require: "pi/browser/taskbar/rails"
end
```

## Installer

Install into the conventional application layout and default mount:

```sh
bin/rails generate pi_browser_taskbar:install
```

For a nonstandard application, select the ERB layout and mount explicitly:

```sh
bin/rails generate pi_browser_taskbar:install \
  --layout app/views/layouts/internal.html.erb \
  --mount /internal/pi
```

The generator plans every edit before writing and refuses ambiguous layouts, unsupported templates,
route conflicts, unclear head markup, and edited generated sections.

## Generated integration

The generator owns checksummed sections in a development initializer, `config/routes.rb`, and each
selected ERB layout. The initializer activates the isolated engine and Rails filename annotations;
the layout helper emits package-served assets and bounded bootstrap data. Rails processes connect to
the package broker rather than owning Pi themselves.

## Configuration

Use Rails-native syntax in the generated development initializer:

```ruby
Pi::Browser::Taskbar::Rails.configure do |config|
  config.mount_path = "/dev/pi-browser-taskbar"
  config.enabled = true
  config.allowed_hosts = []
  config.executable = "pi"
  config.project_root = Rails.root.to_s
  config.task_timeout = 1_800
end
```

The matching `PI_BROWSER_TASKBAR_*` environment fallbacks and the normative field semantics are in
[Server-owned configuration and activation](contract/docs/index.md#server-owned-configuration-and-activation).
Restart Rails after a configuration change.

## Verification

Start Rails in development, open a host page, and confirm the lower-left **Page task** launcher is
present. Run a whole-page task, mark an element for a focused task, stop a running task, start a new
session, and follow a Turbo navigation. Repository contributors run `bin/verify` at the monorepo root; `examples/rails/` names the same
scenarios and stable selectors.

## Diagnosis

If the launcher is absent, confirm Rails is in development, the generated route and layout markers
remain intact, and the initializer has not disabled the adapter. If it is unavailable, run
`pi --mode rpc --append-system-prompt "one-shot probe"` from the configured project root and inspect
only the adapter's safe diagnostics. For
host, CSRF, source-hint, busy, and cancellation symptoms, use the packaged [troubleshooting guide](docs/troubleshooting.md).

## Updates

Update the gem within the matching product version, then rerun the generator. It reports a current
installation or updates only recognized checksummed content. Changing an installed mount requires
uninstalling first.

## Security

Rails supplies native session CSRF, normalized host/peer information, filtered request parameters,
and development activation. The shared threat model and remote-access rules are in the packaged
[security guide](docs/security.md); normative invariants remain in the
[Conformance Contract](contract/docs/index.md#remote-development-access-and-diagnostics).

## Uninstall

```sh
bin/rails destroy pi_browser_taskbar:install
```

Uninstall preflights all owned sections and removes all recognized content or nothing. It reports the
development dependency for manual removal and does not delete credentials, sessions, broker runtime
artifacts, or unrelated host code.

## Changelog and example

See the [Rails changelog](CHANGELOG.md) and repository path `examples/rails/` for the executable Rails
ERB/Turbo example.

## Matching-version contract

This adapter version is `0.4.1`. Use the same product version shown by the Phoenix adapter and the
root `VERSION`; the packaged [Conformance Contract](contract/docs/index.md) is the offline normative
reference for both adapters.
