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
state. Configuration currently accepts `PI_BROWSER_TASKBAR_EXECUTABLE`,
`PI_BROWSER_TASKBAR_RUNTIME_ROOT`, and `PI_BROWSER_TASKBAR_TASK_TIMEOUT` at process startup.

## Build and verify

Run `bin/verify` from the repository root. It tests the native engine/generator/broker, inspects the
built gem, installs that artifact into a clean Rails host, and proves development flow plus
package-absent production isolation.

See the repository [architecture](../../docs/architecture.md) and
[canonical contract](../../contract/docs/index.md).
