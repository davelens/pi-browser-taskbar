# Pi Browser Taskbar Rails

Development-only Rails adapter for conventional Rails 7.1+ ERB applications. The gem bundles its
Browser Client and serves it from an isolated engine, so consuming applications need no Node or
JavaScript package manager.

Add the gem to the development group, then install the guarded mount, initializer, and layout
bootstrap:

```ruby
group :development do
  gem "pi-browser-taskbar-rails", require: "pi/browser/taskbar/rails"
end
```

```sh
bin/rails generate pi_browser_taskbar:install
```

The generator preflights every file before writing, discovers the single conventional
`app/views/layouts/application.html.erb`, and inserts checksummed, marked configuration, route, and
`<head>` helper seams. API-only applications, non-ERB or ambiguous layouts, unclear `<head>` markup,
route conflicts, unsupported Ruby syntax, and edited generated sections are refused without partial
writes. For a deliberate nonstandard integration, pass a project-relative ERB layout and normalized
mount (a trailing slash is removed):

```sh
bin/rails generate pi_browser_taskbar:install \
  --layout app/views/layouts/internal.html.erb \
  --mount /internal/pi
```

Rerunning reports a current installation or updates only recognized checksummed content. Passing a
second `--layout` adds the same helper to that layout without duplicating the route or initializer;
changing an installed mount requires uninstalling first.

The generated integration is inactive outside development and can boot when the development gem
is absent. In development, Rails validates loopback host/client access and native session CSRF,
then acts only as a client of the external checkout-scoped broker that owns Pi and canonical task
state. Canonical checkout path plus OS user is the broker identity, so Rails reloads, threads, Puma
workers/preload/phased replacement, and concurrent server invocations share one conversation. Each Rails
process keeps one lazy PID-aware connection; forked workers discard inherited descriptors and
reconnect without closing the parent's connection. Verified lock/socket/token election has no
process-local fallback. The broker waits for disconnected work to settle, then starts its five-minute
zero-client grace; normal shutdown reaps its owned Pi process tree. While active in development, the
adapter enables Rails' native rendered-template filename
annotations before ERB compilation and verifies that later application configuration did not disable
them. Focused tasks may include one conservative project-relative ERB template hint; the hint has
template precision only and never claims an exact element or source line. Malformed, overlapping,
external, missing, or browser-displaced annotation boundaries are not guessed.

A submitted prompt includes a bounded sanitized structural snapshot of the current page. While it is
running, **Stop task** sends Pi's abort command and retains an honest cancelling state until Pi
settles; stopping cannot roll back file changes Pi already made. The confirmed **New session** action
uses Pi's in-process session switch, clears retained feedback only after state confirmation, and
preserves the local draft and focus marks; a rejected switch preserves the old session. Visible text
and URL paths may reach the configured Pi/model provider, so do not use it with sensitive datasets.

## Configuration

The generated development initializer can set the complete server-owned configuration surface:

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

In development, `enabled` defaults to true; explicit false disables routes, assets, annotations, and
Pi ownership after a restart. Rails-native values win over matching `PI_BROWSER_TASKBAR_*`
environment fallbacks, which win over defaults. `PI_BROWSER_TASKBAR_ALLOWED_HOSTS` is comma-separated
and `task_timeout` is integer seconds from 60 through 86,400. Invalid active values fail startup with
the setting name; inactive values are not validated when disabled.

Outside Rails development the adapter stays absent regardless of configuration. The executable and
fixed `--mode rpc` arguments are spawned directly in the canonical project root with the development
server environment. Browser requests cannot override process, timeout, route, protocol, or security
configuration. A missing executable reports sanitized unavailable state without preventing Rails
from booting.

Remote access requires a non-empty list of bare exact DNS names or IP literals. Every request uses
Rails' normalized `request.host` and `request.remote_ip`; configure Rails' trusted proxies in the host
application and do not add taskbar-specific forwarding-header handling. Plain HTTP remote access is
only for a trusted network and keeps a persistent unencrypted-access warning in the taskbar. The
adapter retains native session CSRF, adds no permissive CORS headers, filters logged `prompt` and
`context` parameters, and returns fixed safe browser errors. See the shared
[security guide](../../docs/security.md).

## Build and verify

Run `bin/verify` from the repository root. It tests the native engine/generator/broker, inspects the
built gem, installs that artifact into a clean Rails host, and proves development flow plus
package-absent production isolation.

## Uninstall

Use Rails' native inverse command:

```sh
bin/rails destroy pi_browser_taskbar:install
```

Uninstall preflights every recorded route and layout seam, then removes all recognized owned content
or nothing. It is harmless when repeated. It reports the development dependency for manual removal
but does not edit the Gemfile or delete broker runtime artifacts, Pi sessions, credentials, unrelated
routes/assets, or unrelated Action View configuration. If a generated section was edited, follow the
reported marker-specific manual guidance rather than deleting uncertain host code.

See the repository [architecture](../../docs/architecture.md) and
[canonical contract](../../contract/docs/index.md).
