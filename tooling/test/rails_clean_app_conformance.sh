#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
version=$(<"$root/VERSION")
rails_version=${PI_BROWSER_TASKBAR_TEST_RAILS_VERSION:-8.1.3.1}
puma_mode=${PI_BROWSER_TASKBAR_TEST_PUMA_MODE:-single}
artifact="$root/build/pi-browser-taskbar-rails-$version.gem"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pi-browser-taskbar-rails.XXXXXX")
runtime_root="$tmp/runtime"
broker_root="$runtime_root/pi-browser-taskbar"
gem_home="$tmp/gems"
app="$tmp/demo"
puma_pid="$tmp/puma.pid"
bootstrap_gemfile="$tmp/Gemfile.bootstrap"
original_gem_path=$(ruby -e 'puts Gem.path.join(":")')
cleanup() {
  [[ -f "$puma_pid" ]] && kill "$(<"$puma_pid")" 2>/dev/null || true
  if [[ -f "$broker_root"/*/endpoint.json ]]; then
    ruby -rjson -e 'ARGV.each { |p| Process.kill("TERM", JSON.parse(File.read(p)).fetch("pid")) rescue nil }' "$broker_root"/*/endpoint.json || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

[[ -f "$artifact" ]] || { echo "missing built Rails gem: $artifact" >&2; exit 1; }
cat >"$bootstrap_gemfile" <<RUBY
source "https://rubygems.org"
gem "rails", "= $rails_version"
gem "puma"
RUBY
BUNDLE_GEMFILE="$bootstrap_gemfile" bundle install
PI_BROWSER_TASKBAR_TEST_RAILS_VERSION="$rails_version" BUNDLE_GEMFILE="$bootstrap_gemfile" bundle exec ruby -rbundler -e '
  incompatible = Bundler.load.specs.reject { |spec| spec.required_ruby_version.satisfied_by?(Gem.ruby_version) }
  abort "resolved gems require a different Ruby: #{incompatible.map(&:full_name).join(", ")}" unless incompatible.empty?
  require "rails"
  abort "resolved Rails version differs" unless Rails::VERSION::STRING == ENV.fetch("PI_BROWSER_TASKBAR_TEST_RAILS_VERSION")
  puts "resolved newest Ruby-compatible Rails dependencies"
'
printf 'rails new: generating conventional Rails %s ERB application\n' "$rails_version"
BUNDLE_GEMFILE="$bootstrap_gemfile" bundle exec rails "_${rails_version}_" new "$app" --skip-bundle --skip-active-record --skip-action-mailer \
  --skip-active-storage --skip-action-cable --skip-asset-pipeline --skip-javascript --skip-hotwire --skip-jbuilder \
  --skip-test --skip-system-test --skip-bootsnap

cat >"$app/Gemfile" <<RUBY
source "https://rubygems.org"
gem "rails", "= $rails_version"
gem "puma"
group :development do
  gem "pi-browser-taskbar-rails", "= $version", require: "pi/browser/taskbar/rails"
end
RUBY

gem install "$artifact" --install-dir "$gem_home" --local --ignore-dependencies --no-document >/dev/null
mkdir -p "$runtime_root" "$root/build/conformance" "$root/build/compatibility" "$app/app/views/scenarios"
chmod 700 "$runtime_root"
cp "$root/packages/rails/test/support/fake_pi_rpc" "$tmp/fake_pi_rpc"
chmod +x "$tmp/fake_pi_rpc"
cp "$root/contract/fixtures/scenarios/phoenix-whole-page.json" "$tmp/scenario.json"
cp "$root/contract/fixtures/tasks/minimal-task.json" "$tmp/task.json"
cp "$root/contract/fixtures/scenarios/focused-task.json" "$tmp/focused-scenario.json"
cp "$root/contract/fixtures/tasks/focused-task.json" "$tmp/focused-task.json"
mkdir "$tmp/cancellation-scenarios" "$tmp/reset-scenarios"
cp "$root"/contract/fixtures/scenarios/cancellation-*.json "$tmp/cancellation-scenarios/"
cp "$root"/contract/fixtures/scenarios/session-reset-*.json "$tmp/reset-scenarios/"

# Exercise the checked-in example pages from the generated, artifact-installed host.
cp "$root/examples/rails/config/routes.rb" "$app/config/routes.rb"
cp "$root/examples/rails/app/controllers/scenarios_controller.rb" "$app/app/controllers/scenarios_controller.rb"
cp "$root"/examples/rails/app/views/scenarios/*.erb "$app/app/views/scenarios/"
cat >"$app/app/views/layouts/application.html.erb" <<'ERB'
<!doctype html>
<html><head><title>Demo</title><%= csrf_meta_tags %></head><body><%= yield %></body></html>
ERB

export GEM_HOME="$gem_home"
export GEM_PATH="$gem_home:$original_gem_path"
export SECRET_KEY_BASE="clean-rails-secret-key-base-clean-rails-secret-key-base-clean-rails-secret-key-base"
export PI_BROWSER_TASKBAR_EXECUTABLE="$tmp/fake_pi_rpc"
export XDG_RUNTIME_DIR="$runtime_root"
export PI_BROWSER_TASKBAR_SCENARIO="$tmp/scenario.json"
export PI_BROWSER_TASKBAR_TASK="$tmp/task.json"
export PI_BROWSER_TASKBAR_FOCUSED_SCENARIO="$tmp/focused-scenario.json"
export PI_BROWSER_TASKBAR_FOCUSED_TASK="$tmp/focused-task.json"
export PI_BROWSER_TASKBAR_CANCELLATION_SCENARIOS="$tmp/cancellation-scenarios"
export PI_BROWSER_TASKBAR_RESET_SCENARIOS="$tmp/reset-scenarios"
export PI_BROWSER_TASKBAR_SEMANTICS="$root/build/conformance/rails.json"
export PI_BROWSER_TASKBAR_PUMA_MODE="$puma_mode"
export PI_BROWSER_TASKBAR_PUMA_OBSERVATION="$tmp/puma-observation.json"

(
  cd "$app"
  bundle install --local
)

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
    assert session.response.body.include?("BEGIN app/views/scenarios/index.html.erb"), "ERB template was not annotated"
    assert session.response.body.include?("BEGIN app/views/scenarios/_card.html.erb"), "nested ERB partial was not annotated"
    assert session.response.body.include?("BEGIN app/views/layouts/application.html.erb"), "ERB layout was not annotated"
    assert session.response.body.include?('data-testid="scenario-whole-page"'), "example whole-page selector missing"
    assert session.response.body.include?('data-testid="focus-card"'), "example focus selector missing"
    session.get "/navigation"
    assert session.response.status == 200 && session.response.body.include?('data-testid="navigation-target"'), "example navigation failed"
    session.get "/"
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
    focused_completed = JSON.parse(session.response.body)
    assert focused_completed.dig("task", "output") == focused_scenario.dig("response", "body", "terminal_output"), "focused fake output differed"

    cancellation_scenarios = Dir[File.join(ENV.fetch("PI_BROWSER_TASKBAR_CANCELLATION_SCENARIOS"), "*.json")].to_h do |path|
      [File.basename(path, ".json"), JSON.parse(File.read(path))]
    end
    reset_scenarios = Dir[File.join(ENV.fetch("PI_BROWSER_TASKBAR_RESET_SCENARIOS"), "*.json")].to_h do |path|
      [File.basename(path, ".json"), JSON.parse(File.read(path))]
    end
    completed_cancellation = cancellation_scenarios.fetch("cancellation-completed")
    session.delete "/dev/pi-browser-taskbar/tasks/#{focused_completed.dig("task", "id")}", headers: {"X-CSRF-Token" => token}
    assert session.response.status == completed_cancellation.dig("response", "status"), "completed task cancellation status differed"
    assert JSON.parse(session.response.body).dig("error", "code") == completed_cancellation.dig("response", "body", "error_code"), "completed task cancellation code differed"

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

    held_id = JSON.parse(session.response.body).dig("task", "id")
    wait_until do
      session.get "/dev/pi-browser-taskbar/state"
      JSON.parse(session.response.body).dig("task", "output") == "Implemented the whole-page request."
    end
    busy_reset_scenario = reset_scenarios.fetch("session-reset-busy")
    session.post "/dev/pi-browser-taskbar/session/reset", headers: {"X-CSRF-Token" => token}
    busy_reset = JSON.parse(session.response.body)
    assert session.response.status == busy_reset_scenario.dig("response", "status"), "busy reset status differed"
    assert busy_reset.dig("error", "code") == busy_reset_scenario.dig("response", "body", "error_code"), "busy reset code differed"
    assert busy_reset.dig("snapshot", "task", "id") == held_id, "busy reset changed the retained task"
    busy_reset_status = session.response.status

    wait_until do
      session.get "/dev/pi-browser-taskbar/state"
      JSON.parse(session.response.body).dig("task", "output") == "Implemented the whole-page request."
    end
    wrong_scenario = cancellation_scenarios.fetch("cancellation-wrong-id")
    session.delete "/dev/pi-browser-taskbar/tasks/unknown-task", headers: {"X-CSRF-Token" => token}
    wrong_cancellation = JSON.parse(session.response.body)
    assert session.response.status == wrong_scenario.dig("response", "status"), "unknown task cancellation status differed"
    assert wrong_cancellation.dig("error", "code") == wrong_scenario.dig("response", "body", "error_code"), "unknown task cancellation code differed"

    accepted_scenario = cancellation_scenarios.fetch("cancellation-accepted")
    session.delete "/dev/pi-browser-taskbar/tasks/#{held_id}", headers: {"X-CSRF-Token" => token}
    cancelling = JSON.parse(session.response.body)
    assert session.response.status == accepted_scenario.dig("response", "status"), "cancellation was not accepted"
    assert cancelling.dig("task", "status") == accepted_scenario.dig("response", "body", "task_status"), "task did not enter cancelling"
    assert cancelling.dig("task", "finished_at").nil?, "cancellation finished before agent_settled"

    repeated_scenario = cancellation_scenarios.fetch("cancellation-repeated")
    session.delete "/dev/pi-browser-taskbar/tasks/#{held_id}", headers: {"X-CSRF-Token" => token}
    assert session.response.status == repeated_scenario.dig("response", "status"), "repeated cancellation was not idempotent"
    assert JSON.parse(session.response.body).dig("task", "status") == repeated_scenario.dig("response", "body", "task_status"), "repeated cancellation changed state"

    settled_scenario = cancellation_scenarios.fetch("cancellation-settled")
    cancelled = nil
    wait_until do
      session.get "/dev/pi-browser-taskbar/state"
      cancelled = JSON.parse(session.response.body)
      cancelled.dig("task", "status") == settled_scenario.dig("response", "body", "task_status")
    end
    assert cancelled.dig("session", "status") == settled_scenario.dig("response", "body", "session_status"), "session was not ready after settled cancellation"
    assert cancelled.dig("task", "activity") == settled_scenario.dig("response", "body", "task_activity"), "settled cancellation activity differed"
    session.delete "/dev/pi-browser-taskbar/tasks/#{held_id}", headers: {"X-CSRF-Token" => token}
    assert session.response.status == 200 && JSON.parse(session.response.body).dig("task", "status") == "cancelled", "cancelled task was not idempotent"

    accepted_reset_scenario = reset_scenarios.fetch("session-reset-accepted")
    old_session_id = cancelled.dig("session", "id")
    session.post "/dev/pi-browser-taskbar/session/reset", headers: {"X-CSRF-Token" => token}
    accepted_reset = JSON.parse(session.response.body)
    assert session.response.status == accepted_reset_scenario.dig("response", "status"), "session reset was not accepted"
    assert accepted_reset.dig("session", "status") == accepted_reset_scenario.dig("response", "body", "session_status"), "reset did not return ready"
    assert accepted_reset["task"].nil?, "successful reset retained task feedback"
    assert accepted_reset.dig("session", "id") != old_session_id, "successful reset retained the old session identity"
    accepted_reset_status = session.response.status

    rejected_task = Marshal.load(Marshal.dump(task))
    rejected_task["prompt"] = "reject reset"
    session.post "/dev/pi-browser-taskbar/tasks", params: JSON.generate(rejected_task),
      headers: {"CONTENT_TYPE" => "application/json", "X-CSRF-Token" => token}
    wait_until do
      session.get "/dev/pi-browser-taskbar/state"
      JSON.parse(session.response.body).dig("task", "status") == "completed"
    end
    retained_reset_state = JSON.parse(session.response.body)
    rejected_reset_scenario = reset_scenarios.fetch("session-reset-rejected")
    session.post "/dev/pi-browser-taskbar/session/reset", headers: {"X-CSRF-Token" => token}
    rejected_reset = JSON.parse(session.response.body)
    assert session.response.status == rejected_reset_scenario.dig("response", "status"), "extension-rejected reset status differed"
    assert rejected_reset.dig("error", "code") == rejected_reset_scenario.dig("response", "body", "error_code"), "extension-rejected reset code differed"
    assert rejected_reset["snapshot"] == retained_reset_state, "extension-rejected reset changed retained state"
    rejected_reset_status = session.response.status

    rpc_progress = {
      "agent_start" => "Pi is working", "agent_end" => "Pi finished a turn",
      "tool_start" => "Running read", "tool_update" => "Running read", "tool_end" => "Finished read",
      "compaction_start" => "Compacting conversation", "compaction_end" => "Retrying after compaction",
      "retry_start" => "Retrying request (2/3)", "retry_end" => "Pi is working"
    }.to_h do |event, activity|
      event_task = Marshal.load(Marshal.dump(task)).merge("prompt" => "activity #{event}")
      session.post "/dev/pi-browser-taskbar/tasks", params: JSON.generate(event_task),
        headers: {"CONTENT_TYPE" => "application/json", "X-CSRF-Token" => token}
      task_id = JSON.parse(session.response.body).dig("task", "id")
      observed = nil
      wait_until do
        session.get "/dev/pi-browser-taskbar/state"
        observed = JSON.parse(session.response.body)
        observed.dig("task", "activity") == activity
      end
      raise "#{event} completed before agent_settled" unless observed.dig("task", "status") == "running"
      session.delete "/dev/pi-browser-taskbar/tasks/#{task_id}", headers: {"X-CSRF-Token" => token}
      wait_until do
        session.get "/dev/pi-browser-taskbar/state"
        JSON.parse(session.response.body).dig("task", "status") == "cancelled"
      end
      [event, {"status" => observed.dig("task", "status"), "activity" => observed.dig("task", "activity")}]
    end

    dialog_task = Marshal.load(Marshal.dump(task)).merge("prompt" => "dialog request")
    session.post "/dev/pi-browser-taskbar/tasks", params: JSON.generate(dialog_task),
      headers: {"CONTENT_TYPE" => "application/json", "X-CSRF-Token" => token}
    dialog_id = JSON.parse(session.response.body).dig("task", "id")
    sleep 0.05
    session.delete "/dev/pi-browser-taskbar/tasks/#{dialog_id}", headers: {"X-CSRF-Token" => token}
    wait_until do
      session.get "/dev/pi-browser-taskbar/state"
      JSON.parse(session.response.body).dig("task", "status") == "cancelled"
    end

    bounded_task = Marshal.load(Marshal.dump(task)).merge("prompt" => "bounded output")
    session.post "/dev/pi-browser-taskbar/tasks", params: JSON.generate(bounded_task),
      headers: {"CONTENT_TYPE" => "application/json", "X-CSRF-Token" => token}
    bounded = nil
    wait_until do
      session.get "/dev/pi-browser-taskbar/state"
      bounded = JSON.parse(session.response.body)
      bounded.dig("task", "status") == "completed"
    end
    rpc_output = {"status" => bounded.dig("task", "status"), "bytes" => bounded.dig("task", "output").bytesize,
      "valid_utf8" => bounded.dig("task", "output").valid_encoding?, "suffix" => bounded.dig("task", "output").end_with?("🙂z"),
      "truncated" => bounded.dig("task", "output_truncated")}

    rpc_failures = {
      "rejected command" => "Pi rejected the task", "message error" => "Pi reported a message error",
      "retry failure" => "Pi could not complete the task after retries",
      "compaction failure" => "Pi could not compact the conversation",
      "unexpected response" => "Pi returned an unexpected RPC response",
      "malformed record" => "Pi sent a malformed RPC record", "oversized record" => "Pi sent an oversized RPC record",
      "non-object record" => "Pi sent a non-object RPC record"
    }.to_h do |prompt, expected_error|
      failure_task = Marshal.load(Marshal.dump(task)).merge("prompt" => prompt)
      session.post "/dev/pi-browser-taskbar/tasks", params: JSON.generate(failure_task),
        headers: {"CONTENT_TYPE" => "application/json", "X-CSRF-Token" => token}
      failed = nil
      wait_until do
        session.get "/dev/pi-browser-taskbar/state"
        failed = JSON.parse(session.response.body)
        failed.dig("task", "status") == "failed"
      end
      raise "unsafe or incorrect #{prompt} evidence" unless failed.dig("task", "error") == expected_error
      wait_until do
        session.get "/dev/pi-browser-taskbar/state"
        JSON.parse(session.response.body).dig("session", "status") == "ready"
      end
      [prompt, {"status" => failed.dig("task", "status"), "error" => failed.dig("task", "error")}]
    end

    semantic = {"created_status" => created_status, "created" => created, "completed_status" => 200,
      "completed" => completed, "focus_rejections" => focus_rejections,
      "cancellation" => {"wrong_status" => wrong_scenario.dig("response", "status"), "wrong" => wrong_cancellation,
        "accepted_status" => accepted_scenario.dig("response", "status"), "accepted" => cancelling,
        "settled_status" => settled_scenario.dig("response", "status"), "settled" => cancelled},
      "reset" => {"busy_status" => busy_reset_status, "busy" => busy_reset,
        "accepted_status" => accepted_reset_status, "accepted" => accepted_reset,
        "rejected_status" => rejected_reset_status, "rejected" => rejected_reset},
      "rpc" => {"progress" => rpc_progress, "dialog" => "cancelled", "output" => rpc_output,
        "failures" => rpc_failures}}
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
  RAILS_ENV=development bundle exec ruby conformance.rb
)

port=$(ruby -rsocket -e 'server = TCPServer.new("127.0.0.1", 0); puts server.addr[1]; server.close')
workers=0
preload=false
case "$puma_mode" in
  single) ;;
  clustered) workers=2 ;;
  preloaded) workers=2; preload=true ;;
  phased) workers=2 ;;
  *) echo "unsupported Puma mode: $puma_mode" >&2; exit 1 ;;
esac
cat >"$tmp/puma.rb" <<RUBY
bind "tcp://127.0.0.1:$port"
environment "development"
pidfile "$puma_pid"
state_path "$tmp/puma.state"
activate_control_app "unix://$tmp/pumactl.sock", { auth_token: "matrix-token" }
workers $workers
preload_app! if $preload
RUBY
(
  cd "$app"
  bundle exec puma -C "$tmp/puma.rb" >"$tmp/puma.log" 2>&1 &
)
export PI_BROWSER_TASKBAR_PUMA_URL="http://127.0.0.1:$port"
export PI_BROWSER_TASKBAR_PUMA_WORKERS="$workers"
export PI_BROWSER_TASKBAR_PUMA_PRELOAD="$preload"
(cd "$app" && bundle exec ruby "$root/tooling/test/rails_puma_conformance.rb")
if [[ "$puma_mode" == phased ]]; then
  first_session=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("session_id")' "$PI_BROWSER_TASKBAR_PUMA_OBSERVATION")
  (cd "$app" && bundle exec pumactl -S "$tmp/puma.state" phased-restart)
  (cd "$app" && bundle exec ruby "$root/tooling/test/rails_puma_conformance.rb")
  second_session=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("session_id")' "$PI_BROWSER_TASKBAR_PUMA_OBSERVATION")
  [[ "$first_session" == "$second_session" ]] || { echo "phased Puma replacement lost broker session" >&2; exit 1; }
  ruby -rjson -e 'path = ARGV.fetch(0); value = JSON.parse(File.read(path)).merge("phased_restart" => true, "session_continuity" => true); File.write(path, JSON.pretty_generate(value))' "$PI_BROWSER_TASKBAR_PUMA_OBSERVATION"
fi
master_pid=$(<"$puma_pid")
kill "$master_pid"
for _ in $(seq 1 100); do
  kill -0 "$master_pid" 2>/dev/null || break
  sleep 0.02
done
rm -f "$puma_pid"

# End the development broker before proving that installed, guarded seams are inert in production.
ruby -rjson -e 'ARGV.each { |p| Process.kill("TERM", JSON.parse(File.read(p)).fetch("pid")) rescue nil }' "$broker_root"/*/endpoint.json
for _ in $(seq 1 100); do
  [[ ! -e "$broker_root"/*/endpoint.json ]] && break
  sleep 0.02
done
cat >"$app/production_check.rb" <<'RUBY'
require_relative "config/environment"
raise "development gem loaded in production" if defined?(Pi::Browser::Taskbar::Rails)
routes = Rails.application.routes.routes.map { |route| route.path.spec.to_s }
raise "production mounted taskbar routes" if routes.any? { |path| path.include?("pi-browser-taskbar") }
rendered = ApplicationController.render(inline: "<main>Production</main>", layout: "application")
raise "production emitted taskbar assets" if rendered.include?("pi-browser-taskbar")
raise "production started broker" unless Dir[File.join(ENV.fetch("XDG_RUNTIME_DIR"), "pi-browser-taskbar", "*", "endpoint.json")].empty?
puts "clean Rails production isolation passed"
RUBY
(
  cd "$app"
  RAILS_ENV=production bundle exec ruby production_check.rb
)

# Prove a recognized older generated initializer updates, then remove all owned seams through Rails' inverse.
ruby -I"$gem_home/gems/pi-browser-taskbar-rails-$version/lib" - "$app/config/initializers/pi_browser_taskbar.rb" <<'RUBY'
require "generators/pi_browser_taskbar/install_generator"
path = ARGV.fetch(0)
source = File.read(path).sub("# pi-browser-taskbar:start configuration", "# pi-browser-taskbar:start configuration\n# older generated release")
File.write(path, PiBrowserTaskbar::Generators::InstallGenerator.refresh_initializer_checksum(source))
RUBY
(
  cd "$app"
  RAILS_ENV=development bundle exec ruby bin/rails generate pi_browser_taskbar:install >/dev/null
  ! grep -q "older generated release" config/initializers/pi_browser_taskbar.rb
  RAILS_ENV=development bundle exec ruby bin/rails destroy pi_browser_taskbar:install
  RAILS_ENV=development bundle exec ruby bin/rails destroy pi_browser_taskbar:install >/dev/null
  test ! -e config/initializers/pi_browser_taskbar.rb
  ! grep -R "pi-browser-taskbar:start\|pi_browser_taskbar_tags" config/routes.rb app/views/layouts/application.html.erb
  grep -q 'root "scenarios#index"' config/routes.rb
)
echo "clean Rails update and uninstall conformance passed"

row_id=${PI_BROWSER_TASKBAR_MATRIX_ROW:-local-rails-${rails_version}-ruby-$(ruby -e 'print RUBY_VERSION')}
evidence="$root/build/compatibility/$row_id.json"
(
  cd "$app"
  PI_BROWSER_TASKBAR_ARTIFACT="$artifact" PI_BROWSER_TASKBAR_EVIDENCE="$evidence" bundle exec ruby -rjson -rdigest -rrails -rpi/browser/taskbar/rails -e '
    observation = JSON.parse(File.read(ENV.fetch("PI_BROWSER_TASKBAR_PUMA_OBSERVATION")))
    loaded = Gem.loaded_specs.fetch("pi-browser-taskbar-rails").full_gem_path
    raise "adapter loaded from source workspace" unless loaded.start_with?(ENV.fetch("GEM_HOME"))
    evidence = {
      "schema" => 1,
      "row" => ENV.fetch("PI_BROWSER_TASKBAR_MATRIX_ROW", "local"),
      "platform" => {"engine" => RUBY_ENGINE, "os" => RbConfig::CONFIG.fetch("host_os")},
      "versions" => {"ruby" => RUBY_VERSION, "rails" => Rails::VERSION::STRING,
        "adapter" => Pi::Browser::Taskbar::Rails::VERSION},
      "artifact" => {"sha256" => Digest::SHA256.file(ENV.fetch("PI_BROWSER_TASKBAR_ARTIFACT")).hexdigest,
        "loaded_from_isolated_gem_home" => true},
      "puma" => observation,
      "checks" => %w[generated_app boot route asset mutation annotation uninstall production_disabled no_workspace_fallback]
    }
    File.write(ENV.fetch("PI_BROWSER_TASKBAR_EVIDENCE"), JSON.pretty_generate(evidence) + "\n")
  '
)
echo "Rails compatibility evidence: $evidence"
