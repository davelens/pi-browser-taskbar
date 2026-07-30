#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
version=$(<"$root/VERSION")
rails_version=${PI_BROWSER_TASKBAR_TEST_RAILS_VERSION:-8.1.3}
artifact="$root/build/pi-browser-taskbar-rails-$version.gem"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pi-browser-taskbar-rails.XXXXXX")
runtime_root="$tmp/runtime"
broker_root="$runtime_root/pi-browser-taskbar"
gem_home="$tmp/gems"
app="$tmp/demo"
original_gem_path=$(ruby -e 'puts Gem.path.join(":")')
cleanup() {
  if [[ -f "$broker_root"/*/endpoint.json ]]; then
    ruby -rjson -e 'ARGV.each { |p| Process.kill("TERM", JSON.parse(File.read(p)).fetch("pid")) rescue nil }' "$broker_root"/*/endpoint.json || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

if ! gem list -i rails -v "$rails_version" >/dev/null; then
  gem install rails -v "$rails_version" --no-document
fi
gem install "$artifact" --install-dir "$gem_home" --local --no-document >/dev/null
mkdir -p "$app/config/environments" "$app/config/initializers" "$app/app/controllers" "$app/app/views/layouts" "$app/app/views/home" "$app/bin" "$runtime_root" "$root/build/conformance"
chmod 700 "$runtime_root"
cp "$root/packages/rails/test/support/fake_pi_rpc" "$tmp/fake_pi_rpc"
chmod +x "$tmp/fake_pi_rpc"
cp "$root/contract/fixtures/scenarios/phoenix-whole-page.json" "$tmp/scenario.json"
cp "$root/contract/fixtures/tasks/minimal-task.json" "$tmp/task.json"
cp "$root/contract/fixtures/scenarios/focused-task.json" "$tmp/focused-scenario.json"
cp "$root/contract/fixtures/tasks/focused-task.json" "$tmp/focused-task.json"

cat >"$app/config/application.rb" <<'RUBY'
require "rails"
require "action_controller/railtie"
require "action_view/railtie"
require "pi/browser/taskbar/rails" if Rails.env.development?

module Demo
  class Application < Rails::Application
    config.load_defaults 7.1
    config.eager_load = false
    config.secret_key_base = "clean-rails-secret-key-base-" * 8
    config.hosts.clear
    config.session_store :cookie_store, key: "_clean_rails"
    config.action_controller.allow_forgery_protection = true
    config.action_dispatch.show_exceptions = :none
  end
end
RUBY
cat >"$app/config/environment.rb" <<'RUBY'
require_relative "application"
Rails.application.initialize!
RUBY
cat >"$app/config/routes.rb" <<'RUBY'
Rails.application.routes.draw do
  root "home#index"
end
RUBY
cat >"$app/app/controllers/application_controller.rb" <<'RUBY'
class ApplicationController < ActionController::Base
end
RUBY
cat >"$app/app/controllers/home_controller.rb" <<'RUBY'
class HomeController < ApplicationController
  def index
  end
end
RUBY
cat >"$app/app/views/home/index.html.erb" <<'ERB'
<main><h1>Cards</h1></main>
ERB
cat >"$app/app/views/layouts/application.html.erb" <<'ERB'
<!doctype html>
<html><head><title>Demo</title></head><body><%= yield %></body></html>
ERB
cat >"$app/bin/rails" <<'RUBY'
#!/usr/bin/env ruby
APP_PATH = File.expand_path("../config/application", __dir__)
require "rails/commands"
RUBY
chmod +x "$app/bin/rails"

export GEM_HOME="$gem_home"
export GEM_PATH="$gem_home:$original_gem_path"
export PI_BROWSER_TASKBAR_EXECUTABLE="$tmp/fake_pi_rpc"
export XDG_RUNTIME_DIR="$runtime_root"
export PI_BROWSER_TASKBAR_SCENARIO="$tmp/scenario.json"
export PI_BROWSER_TASKBAR_TASK="$tmp/task.json"
export PI_BROWSER_TASKBAR_FOCUSED_SCENARIO="$tmp/focused-scenario.json"
export PI_BROWSER_TASKBAR_FOCUSED_TASK="$tmp/focused-task.json"
export PI_BROWSER_TASKBAR_SEMANTICS="$root/build/conformance/rails.json"

(
  cd "$app"
  RAILS_ENV=development ruby bin/rails generate pi_browser_taskbar:install
  RAILS_ENV=development ruby bin/rails generate pi_browser_taskbar:install >/dev/null
)

cat >"$app/conformance.rb" <<'RUBY'
require_relative "config/environment"
require "action_dispatch/testing/integration"
require "json"

module CleanRailsConformance
  module_function

  def run
    scenario = JSON.parse(File.read(ENV.fetch("PI_BROWSER_TASKBAR_SCENARIO")))
    task = JSON.parse(File.read(ENV.fetch("PI_BROWSER_TASKBAR_TASK")))
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! "localhost"

    assert Rails.application.config.action_view.annotate_rendered_view_with_filenames == true, "annotation config was not enabled"
    assert ActionView::Base.annotate_rendered_view_with_filenames == true, "effective annotation config was not enabled"
    session.get "/"
    assert session.response.status == 200, "host did not boot"
    assert session.response.body.include?("BEGIN app/views/home/index.html.erb"), "ERB template was not annotated"
    assert session.response.body.include?("BEGIN app/views/layouts/application.html.erb"), "ERB layout was not annotated"
    token = session.response.body[/data-csrf-token="([^"]+)"/, 1]
    assert token && session.response.body.include?("pi_browser_taskbar.js"), "layout bootstrap missing"
    session.get "/dev/pi-browser-taskbar/assets/pi_browser_taskbar.js", headers: {"HTTP_REFERER" => "http://localhost/"}
    assert session.response.status == 200 && session.response.headers["Cache-Control"] == "no-store", "package asset missing: #{session.response.status}"

    wait_until do
      session.get "/dev/pi-browser-taskbar/state"
      JSON.parse(session.response.body).dig("session", "status") == "ready"
    end
    assert session.response.headers["Cache-Control"] == "no-store", "state was cacheable"

    rejected = ActionDispatch::Integration::Session.new(Rails.application)
    rejected.host! "localhost"
    rejected.post "/dev/pi-browser-taskbar/tasks", params: JSON.generate(task), headers: {"CONTENT_TYPE" => "application/json"}
    assert rejected.response.status == 422, "missing native CSRF was accepted"

    session.post "/dev/pi-browser-taskbar/tasks", params: JSON.generate(task),
      headers: {"CONTENT_TYPE" => "application/json", "X-CSRF-Token" => token}
    created_status = session.response.status
    created = JSON.parse(session.response.body)
    expected = scenario.fetch("response")
    assert created_status == expected.fetch("status"), "task was not accepted"
    assert session.response.headers["Cache-Control"] == "no-store", "mutation was cacheable"
    assert created.dig("session", "status") == expected.dig("body", "session_status"), "session was not busy"
    assert created.dig("task", "status") == expected.dig("body", "task_status"), "task was not running"
    assert created.dig("session", "id").to_s.bytesize >= 16, "session id was not opaque"
    assert created.dig("task", "id").to_s.bytesize >= 16, "task id was not opaque"

    completed = nil
    wait_until do
      session.get "/dev/pi-browser-taskbar/state"
      completed = JSON.parse(session.response.body)
      completed.dig("task", "status") == expected.dig("body", "terminal_task_status")
    end
    assert completed.dig("task", "output") == expected.dig("body", "terminal_output"), "fake output differed"

    focused_scenario = JSON.parse(File.read(ENV.fetch("PI_BROWSER_TASKBAR_FOCUSED_SCENARIO")))
    focused_task = JSON.parse(File.read(ENV.fetch("PI_BROWSER_TASKBAR_FOCUSED_TASK")))
    session.post "/dev/pi-browser-taskbar#{focused_scenario.dig("request", "path")}", params: JSON.generate(focused_task),
      headers: {"CONTENT_TYPE" => "application/json", "X-CSRF-Token" => token}
    assert session.response.status == focused_scenario.dig("response", "status"), "focused task was not accepted"
    wait_until do
      session.get "/dev/pi-browser-taskbar/state"
      JSON.parse(session.response.body).dig("task", "status") == focused_scenario.dig("response", "body", "terminal_task_status")
    end
    assert JSON.parse(session.response.body).dig("task", "output") == focused_scenario.dig("response", "body", "terminal_output"), "focused fake output differed"

    duplicate = Marshal.load(Marshal.dump(focused_task))
    duplicate.dig("context", "focus_points") << Marshal.load(Marshal.dump(duplicate.dig("context", "focus_points", 0)))
    invalid_structure = Marshal.load(Marshal.dump(focused_task))
    invalid_structure.dig("context", "focus_points", 0, "source")["status"] = "guessed"
    focus_rejections = [duplicate, invalid_structure].map do |invalid_task|
      session.post "/dev/pi-browser-taskbar/tasks", params: JSON.generate(invalid_task),
        headers: {"CONTENT_TYPE" => "application/json", "X-CSRF-Token" => token}
      body = JSON.parse(session.response.body)
      assert session.response.status == 422 && body.dig("error", "code") == "invalid_task", "invalid focus was accepted"
      {"status" => session.response.status, "code" => body.dig("error", "code")}
    end

    remote = ActionDispatch::Integration::Session.new(Rails.application)
    remote.host! "localhost"
    remote.get "/dev/pi-browser-taskbar/state", headers: {"REMOTE_ADDR" => "192.0.2.2"}
    assert remote.response.status == 403, "non-loopback peer was accepted"
    remote.host! "evil.example"
    remote.get "/dev/pi-browser-taskbar/state", headers: {"REMOTE_ADDR" => "127.0.0.1"}
    assert remote.response.status == 403, "disallowed host was accepted"

    held = Marshal.load(Marshal.dump(task))
    held["prompt"] = "hold this task"
    session.post "/dev/pi-browser-taskbar/tasks", params: JSON.generate(held),
      headers: {"CONTENT_TYPE" => "application/json", "X-CSRF-Token" => token}
    assert session.response.status == 202, "held task was not accepted"
    second = ActionDispatch::Integration::Session.new(Rails.application)
    second.host! "localhost"
    second.get "/"
    second_token = second.response.body[/data-csrf-token="([^"]+)"/, 1]
    second.post "/dev/pi-browser-taskbar/tasks", params: JSON.generate(task),
      headers: {"CONTENT_TYPE" => "application/json", "X-CSRF-Token" => second_token}
    assert second.response.status == 409 && JSON.parse(second.response.body).dig("error", "code") == "busy", "admission was not atomic"
    assert created.dig("session", "id") == JSON.parse(second.response.body).dig("snapshot", "session", "id"), "Rails clients did not share one broker session"

    semantic = {"created_status" => created_status, "created" => created, "completed_status" => 200,
      "completed" => completed, "focus_rejections" => focus_rejections}
    File.write(ENV.fetch("PI_BROWSER_TASKBAR_SEMANTICS"), JSON.pretty_generate(semantic))
    spec = Gem.loaded_specs.fetch("pi-browser-taskbar-rails")
    assert spec.full_gem_path.start_with?(ENV.fetch("GEM_HOME")), "adapter loaded from source workspace"
    puts "loaded Rails gem: #{spec.full_gem_path}"
    puts "clean Rails CSRF and access conformance passed"
    puts "Rails broker ownership conformance passed"
    puts "clean Rails development conformance passed"
  end

  def wait_until
    300.times do
      return if yield
      sleep 0.01
    end
    raise "clean Rails conformance timed out"
  end

  def assert(condition, message)
    raise message unless condition
  end
end

CleanRailsConformance.run
RUBY

(
  cd "$app"
  RAILS_ENV=development ruby conformance.rb
)

# End the development broker before proving a package-absent production boot.
ruby -rjson -e 'ARGV.each { |p| Process.kill("TERM", JSON.parse(File.read(p)).fetch("pid")) rescue nil }' "$broker_root"/*/endpoint.json
for _ in $(seq 1 100); do
  [[ ! -e "$broker_root"/*/endpoint.json ]] && break
  sleep 0.02
done
mv "$gem_home/gems/pi-browser-taskbar-rails-$version" "$tmp/package-removed"

cat >"$app/production_check.rb" <<'RUBY'
require_relative "config/environment"
raise "development gem loaded in production" if defined?(Pi::Browser::Taskbar::Rails)
routes = Rails.application.routes.routes.map { |route| route.path.spec.to_s }
raise "production mounted taskbar routes" if routes.any? { |path| path.include?("pi-browser-taskbar") }
layout = File.read(Rails.root.join("app/views/layouts/application.html.erb"))
rendered = ApplicationController.render(template: "home/index", layout: "application")
raise "production emitted taskbar assets" if rendered.include?("pi-browser-taskbar")
raise "production started broker" unless Dir[File.join(ENV.fetch("XDG_RUNTIME_DIR"), "pi-browser-taskbar", "*", "endpoint.json")].empty?
puts "clean Rails production isolation passed"
RUBY

(
  cd "$app"
  GEM_PATH="$original_gem_path" GEM_HOME="" RAILS_ENV=production ruby production_check.rb
)
