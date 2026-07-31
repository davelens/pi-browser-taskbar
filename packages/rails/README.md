# Pi Browser Taskbar Rails

Development-only Rails adapter for conventional Rails 7.1+ ERB applications. The gem bundles its
Browser Client and serves it from an isolated engine, so consuming applications need no Node or
JavaScript package manager.

Add the gem to the development group, then install the guarded mount, initializer, and layout
bootstrap:

```ruby
group :development do
  gem "pi-browser-taskbar-rails"
end
```

```sh
bin/rails generate pi_browser_taskbar:install
```

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
from booting. Exact remote hosts must be explicitly listed; loopback host/client access is the
default.

## Build and verify

Run `bin/verify` from the repository root. It tests the native engine/generator/broker, inspects the
built gem, installs that artifact into a clean Rails host, and proves development flow plus
package-absent production isolation.

See the repository [architecture](../../docs/architecture.md) and
[canonical contract](../../contract/docs/index.md).
