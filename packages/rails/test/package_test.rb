# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require_relative "../lib/pi/browser/taskbar/rails"

class PackageTest < Minitest::Test
  def test_exposes_lockstep_version
    assert_equal "0.1.0", Pi::Browser::Taskbar::Rails::VERSION
  end

  def test_exposes_prebuilt_browser_asset
    asset = Pi::Browser::Taskbar::Rails.browser_asset_path

    assert_path_exists asset
    assert_includes File.read(asset), 'productVersion: "0.1.0"'
    assert_includes File.read(asset), 'framework: "rails"'
  end

  def test_engine_has_no_routes_or_annotation_change_outside_development
    lib = File.expand_path("../lib", __dir__)
    script = <<~'RUBY'
      require "pi/browser/taskbar/rails"
      ActionView::Base.annotate_rendered_view_with_filenames = false
      class DisabledTaskbarApplication < Rails::Application
        config.eager_load = false
        config.secret_key_base = "disabled-taskbar-secret-key-base-" * 8
      end
      DisabledTaskbarApplication.initialize!
      abort unless Pi::Browser::Taskbar::Rails::Engine.routes.routes.empty?
      abort if ActionView::Base.annotate_rendered_view_with_filenames
    RUBY
    _output, status = Open3.capture2e({"RAILS_ENV" => "production"}, RbConfig.ruby, "-I#{lib}", "-e", script)

    assert status.success?
  end

  def test_startup_fails_if_later_configuration_disables_required_annotations
    lib = File.expand_path("../lib", __dir__)
    script = <<~'RUBY'
      require "pi/browser/taskbar/rails"
      class ConflictingTaskbarApplication < Rails::Application
        config.eager_load = false
        config.secret_key_base = "conflicting-taskbar-secret-key-base-" * 8
        initializer "host.disable_annotations", after: "pi_browser_taskbar.enable_erb_annotations" do |app|
          app.config.action_view.annotate_rendered_view_with_filenames = false
          ActionView::Base.annotate_rendered_view_with_filenames = false
        end
      end
      ConflictingTaskbarApplication.initialize!
    RUBY
    output, status = Open3.capture2e({"RAILS_ENV" => "development"}, RbConfig.ruby, "-I#{lib}", "-e", script)

    refute status.success?
    assert_includes output, "config.action_view.annotate_rendered_view_with_filenames = true"
  end
end

Dir[File.join(__dir__, "*_test.rb")].sort.each do |path|
  require path unless path == __FILE__
end
