# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/pi/browser/taskbar/rails"

class RailsConfigurationTest < Minitest::Test
  SETTINGS = %w[
    PI_BROWSER_TASKBAR_ENABLED
    PI_BROWSER_TASKBAR_ALLOWED_HOSTS
    PI_BROWSER_TASKBAR_EXECUTABLE
    PI_BROWSER_TASKBAR_PROJECT_ROOT
    PI_BROWSER_TASKBAR_TASK_TIMEOUT
  ].freeze

  def setup
    @environment = SETTINGS.to_h { |key| [key, ENV[key]] }
    SETTINGS.each { |key| ENV.delete(key) }
  end

  def teardown
    @environment.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  def test_loads_defaults_and_canonicalizes_the_project_root
    Dir.mktmpdir("taskbar-config") do |root|
      link = "#{root}-link"
      File.symlink(root, link)
      config = Pi::Browser::Taskbar::Rails::Configuration.new
      config.finalize!(default_project_root: link)

      assert_equal true, config.enabled
      assert_equal [], config.allowed_hosts
      assert_equal "pi", config.executable
      assert_equal File.realpath(root), config.project_root
      assert_equal 1_800, config.task_timeout
      assert config.frozen?
    ensure
      File.unlink(link) if link && File.symlink?(link)
    end
  end

  def test_explicit_framework_configuration_wins_over_environment_fallbacks
    ENV.update(
      "PI_BROWSER_TASKBAR_ENABLED" => "false",
      "PI_BROWSER_TASKBAR_ALLOWED_HOSTS" => "ignored.example",
      "PI_BROWSER_TASKBAR_EXECUTABLE" => "ignored-pi",
      "PI_BROWSER_TASKBAR_PROJECT_ROOT" => "/missing",
      "PI_BROWSER_TASKBAR_TASK_TIMEOUT" => "90"
    )

    config = Pi::Browser::Taskbar::Rails::Configuration.new
    config.enabled = true
    config.allowed_hosts = ["DEVBOX.localhost.", "192.0.2.5"]
    config.executable = "pi-explicit"
    config.project_root = Dir.pwd
    config.task_timeout = 120
    config.finalize!(default_project_root: "/missing-default")

    assert_equal ["devbox.localhost", "192.0.2.5"], config.allowed_hosts
    assert_equal "pi-explicit", config.executable
    assert_equal File.realpath(Dir.pwd), config.project_root
    assert_equal 120, config.task_timeout
  end

  def test_environment_fallbacks_are_loaded_when_framework_settings_are_absent
    ENV.update(
      "PI_BROWSER_TASKBAR_ENABLED" => "1",
      "PI_BROWSER_TASKBAR_ALLOWED_HOSTS" => "DEVBOX.localhost., 192.0.2.5",
      "PI_BROWSER_TASKBAR_EXECUTABLE" => "pi-from-env",
      "PI_BROWSER_TASKBAR_PROJECT_ROOT" => Dir.pwd,
      "PI_BROWSER_TASKBAR_TASK_TIMEOUT" => "90"
    )

    config = Pi::Browser::Taskbar::Rails::Configuration.new
    config.finalize!(default_project_root: "/missing-default")

    assert_equal true, config.enabled
    assert_equal ["devbox.localhost", "192.0.2.5"], config.allowed_hosts
    assert_equal "pi-from-env", config.executable
    assert_equal 90, config.task_timeout
  end

  def test_disabled_configuration_skips_inactive_validation
    ENV.update(
      "PI_BROWSER_TASKBAR_ENABLED" => "false",
      "PI_BROWSER_TASKBAR_ALLOWED_HOSTS" => "*",
      "PI_BROWSER_TASKBAR_EXECUTABLE" => "",
      "PI_BROWSER_TASKBAR_PROJECT_ROOT" => "/missing",
      "PI_BROWSER_TASKBAR_TASK_TIMEOUT" => "0"
    )

    config = Pi::Browser::Taskbar::Rails::Configuration.new
    config.finalize!(default_project_root: "/also-missing")

    assert_equal false, config.enabled
  end

  def test_rejects_scoped_ipv6_allowed_hosts
    config = Pi::Browser::Taskbar::Rails::Configuration.new
    config.allowed_hosts = ["fe80::1%lo"]

    error = assert_raises(ArgumentError) do
      config.finalize!(default_project_root: Dir.pwd)
    end
    assert_includes error.message, "allowed_hosts"
  end

  def test_rejects_malformed_active_settings_with_the_setting_name
    invalid = {
      enabled: "maybe",
      allowed_hosts: ["*.example.test"],
      executable: "",
      project_root: "/missing",
      task_timeout: 59
    }

    invalid.each do |setting, value|
      config = Pi::Browser::Taskbar::Rails::Configuration.new
      config.public_send("#{setting}=", value)

      error = assert_raises(ArgumentError) do
        config.finalize!(default_project_root: Dir.pwd)
      end
      assert_includes error.message, setting.to_s
    end
  end
end
