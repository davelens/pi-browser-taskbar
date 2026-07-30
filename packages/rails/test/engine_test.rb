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
TaskbarTestApplication.routes.draw do
  root to: "taskbar_host#index"
  get "/annotated", to: "taskbar_host#annotated"
  mount Pi::Browser::Taskbar::Rails::Engine => "/dev/pi-browser-taskbar"
end

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
    Pi::Browser::Taskbar::Rails.configuration.allowed_hosts = []
    host! "localhost"
  end

  def teardown
    Pi::Browser::Taskbar::Rails.instance_variable_set(:@broker_client, nil)
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

    get "/dev/pi-browser-taskbar/state"
    assert_response :ok
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "ready", JSON.parse(response.body).dig("session", "status")

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

  def test_rejects_disallowed_host_and_non_loopback_client_before_broker
    get "/dev/pi-browser-taskbar/state", headers: {"REMOTE_ADDR" => "192.0.2.10"}
    assert_response :forbidden
    assert_equal "no-store", response.headers["Cache-Control"]

    host! "evil.example"
    get "/dev/pi-browser-taskbar/state", headers: {"REMOTE_ADDR" => "127.0.0.1"}
    assert_response :forbidden
    assert_equal "forbidden", JSON.parse(response.body).dig("error", "code")
  end
end
