# frozen_string_literal: true

ENV["RAILS_ENV"] = "development"
require "minitest/autorun"
require "action_dispatch/testing/integration"
require_relative "../lib/pi/browser/taskbar/rails"

class TaskbarTestApplication < Rails::Application
  config.eager_load = false
  config.secret_key_base = "test-secret-key-base-" * 8
  config.logger = Logger.new(File::NULL)
  config.hosts.clear
  config.session_store :cookie_store, key: "_taskbar_test"
  config.action_controller.allow_forgery_protection = true
end

Pi::Browser::Taskbar::Rails.configure do |config|
  config.allowed_hosts = ["devbox.test", "2001:db8::1"]
end

class TaskbarHostController < ActionController::Base
  protect_from_forgery with: :exception

  def index
    render html: Pi::Browser::Taskbar::Rails.layout_bootstrap(view_context)
  end

  def annotated
    render inline: "<main>Annotated ERB</main>"
  end
end

TaskbarTestApplication.initialize!

def draw_taskbar_test_routes
  TaskbarTestApplication.routes.draw do
    root to: "taskbar_host#index"
    get "/annotated", to: "taskbar_host#annotated"
    mount Pi::Browser::Taskbar::Rails::Engine => "/dev/pi-browser-taskbar"
  end
end

draw_taskbar_test_routes

class RailsEngineTest < ActionDispatch::IntegrationTest
  class FakeBroker
    attr_reader :submissions

    def initialize
      @submissions = []
    end

    def snapshot
      {"snapshot" => snapshot_value("ready", nil)}
    end

    def submit(task)
      @submissions << task
      {"result" => "accepted", "snapshot" => snapshot_value("busy", "running")}
    end

    def reset
      {"result" => "accepted", "snapshot" => snapshot_value("ready", nil)}
    end

    def cancel(id)
      case id
      when "opaque-task"
        {"result" => "accepted", "snapshot" => snapshot_value("busy", "cancelling")}
      when "cancelled-task"
        {"result" => "cancelled", "snapshot" => snapshot_value("ready", "cancelled")}
      when "completed-task"
        {"result" => "not_cancellable", "snapshot" => snapshot_value("ready", "completed")}
      else
        {"result" => "not_found", "snapshot" => snapshot_value("ready", nil)}
      end
    end

    private

    def snapshot_value(session_status, task_status)
      {
        "contract_version" => 1,
        "session" => {"id" => "opaque-session", "status" => session_status, "model" => "test/fake", "error" => nil},
        "task" => task_status && {"id" => "opaque-task", "prompt" => "Explain", "status" => task_status, "output" => "", "output_truncated" => false, "activity" => "Starting Pi", "error" => nil, "started_at" => Time.now.utc.iso8601, "finished_at" => nil}
      }
    end
  end

  def setup
    @broker = FakeBroker.new
    Pi::Browser::Taskbar::Rails.instance_variable_set(:@broker_client, @broker)
    host! "localhost"
  end

  def teardown
    Pi::Browser::Taskbar::Rails.instance_variable_set(:@broker_client, nil)
  end

  def test_process_keeps_one_lazy_client_across_application_reload
    first = Pi::Browser::Taskbar::Rails.broker_client
    TaskbarTestApplication.reloader.reload!
    assert_same first, Pi::Browser::Taskbar::Rails.broker_client
  ensure
    draw_taskbar_test_routes
  end

  def test_active_adapter_enables_native_erb_annotations_before_templates_compile
    assert_equal true, TaskbarTestApplication.config.action_view.annotate_rendered_view_with_filenames
    assert_equal true, ActionView::Base.annotate_rendered_view_with_filenames

    get "/annotated"
    assert_response :ok
    assert_match(/<!-- BEGIN .*inline template\n--><main>Annotated ERB<\/main><!-- END .*inline template -->/m, response.body)
  end

  def test_engine_routes_assets_layout_and_no_store_snapshot
    get "/"
    assert_response :ok
    assert_includes response.body, "data-pi-browser-taskbar-bootstrap"
    assert_includes response.body, "data-contract-version=\"1\""
    assert_match(/data-csrf-token="[^"]+"/, response.body)
    assert_includes response.body, 'data-remote-access="true"'

    get "/dev/pi-browser-taskbar/state"
    assert_response :ok
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "ready", JSON.parse(response.body).dig("session", "status")
    assert_nil response.headers["Access-Control-Allow-Origin"]

    get "/dev/pi-browser-taskbar/assets/pi_browser_taskbar.js"
    assert_response :ok
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_includes response.body, 'framework: "rails"'
  end

  def test_mutation_uses_native_session_bound_csrf
    task = File.read(File.expand_path("../../../contract/fixtures/tasks/minimal-task.json", __dir__))
    post "/dev/pi-browser-taskbar/tasks", params: task, headers: {"CONTENT_TYPE" => "application/json"}
    assert_response :unprocessable_entity
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_empty @broker.submissions

    get "/"
    token = response.body[/data-csrf-token="([^"]+)"/, 1]
    post "/dev/pi-browser-taskbar/tasks", params: task,
      headers: {"CONTENT_TYPE" => "application/json", "X-CSRF-Token" => token}
    assert_response :accepted
    assert_equal "Explain the cards page.", @broker.submissions.first["prompt"]
  end

  def test_session_reset_route_uses_csrf_and_returns_the_complete_ready_snapshot
    post "/dev/pi-browser-taskbar/session/reset"
    assert_response :unprocessable_entity

    get "/"
    token = response.body[/data-csrf-token="([^"]+)"/, 1]
    post "/dev/pi-browser-taskbar/session/reset", headers: {"X-CSRF-Token" => token}
    assert_response :accepted
    assert_equal "ready", JSON.parse(response.body).dig("session", "status")
    assert_nil JSON.parse(response.body)["task"]
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  def test_cancellation_route_uses_csrf_and_shared_status_errors
    delete "/dev/pi-browser-taskbar/tasks/opaque-task"
    assert_response :unprocessable_entity

    get "/"
    token = response.body[/data-csrf-token="([^"]+)"/, 1]
    headers = {"X-CSRF-Token" => token}

    delete "/dev/pi-browser-taskbar/tasks/opaque-task", headers: headers
    assert_response :accepted
    assert_equal "cancelling", JSON.parse(response.body).dig("task", "status")

    delete "/dev/pi-browser-taskbar/tasks/cancelled-task", headers: headers
    assert_response :ok
    assert_equal "cancelled", JSON.parse(response.body).dig("task", "status")

    delete "/dev/pi-browser-taskbar/tasks/completed-task", headers: headers
    assert_response :conflict
    assert_equal "task_not_cancellable", JSON.parse(response.body).dig("error", "code")

    delete "/dev/pi-browser-taskbar/tasks/unknown-task", headers: headers
    assert_response :not_found
    assert_equal "task_not_found", JSON.parse(response.body).dig("error", "code")
  end

  def test_access_uses_framework_normalized_host_and_peer_with_exact_remote_opt_in
    ["localhost", "tools.localhost", "127.0.0.1", "DEVBOX.TEST."].each do |host|
      host! host
      get "/dev/pi-browser-taskbar/state", headers: {"REMOTE_ADDR" => "127.0.0.1"}
      assert_response :ok, "expected loopback access for #{host}"
    end

    get "/dev/pi-browser-taskbar/state", headers: {"HTTP_HOST" => "[::1]", "REMOTE_ADDR" => "::1"}
    assert_response :ok

    host! "devbox.test"
    get "/dev/pi-browser-taskbar/state", headers: {"REMOTE_ADDR" => "192.0.2.10"}
    assert_response :ok

    get "/dev/pi-browser-taskbar/state",
      headers: {"HTTP_HOST" => "[2001:0DB8:0:0:0:0:0:1]", "REMOTE_ADDR" => "192.0.2.10"}
    assert_response :ok

    host! "localhost"
    get "/dev/pi-browser-taskbar/state", headers: {"REMOTE_ADDR" => "192.0.2.10"}
    assert_response :forbidden
    assert_equal "no-store", response.headers["Cache-Control"]

    host! "evil.example"
    get "/dev/pi-browser-taskbar/state", headers: {"REMOTE_ADDR" => "127.0.0.1"}
    assert_response :forbidden
    assert_equal "forbidden", JSON.parse(response.body).dig("error", "code")

    host! "localhost"
    get "/dev/pi-browser-taskbar/state",
      headers: {"REMOTE_ADDR" => "127.0.0.1", "X-Forwarded-For" => "192.0.2.10"}
    assert_response :forbidden
  end

  def test_invalid_browser_input_returns_only_a_stable_safe_error
    get "/"
    token = response.body[/data-csrf-token="([^"]+)"/, 1]
    task = JSON.parse(File.read(File.expand_path("../../../contract/fixtures/tasks/minimal-task.json", __dir__)))
    task["credential=/absolute/secret"] = true

    post "/dev/pi-browser-taskbar/tasks", params: JSON.generate(task),
      headers: {"CONTENT_TYPE" => "application/json", "X-CSRF-Token" => token}

    assert_response :unprocessable_entity
    assert_equal({"code" => "invalid_task", "message" => "Task request is invalid"}, JSON.parse(response.body)["error"])
    refute_includes response.body, "credential"
    refute_includes response.body, "/absolute/secret"
  end

  def test_host_parameter_logging_filters_prompt_and_browser_context
    filter = ActiveSupport::ParameterFilter.new(TaskbarTestApplication.config.filter_parameters)
    filtered = filter.filter("prompt" => "secret command", "context" => {"path" => "/private"})

    assert_equal "[FILTERED]", filtered["prompt"]
    assert_equal "[FILTERED]", filtered["context"]
  end
end
