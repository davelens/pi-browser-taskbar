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

  def test_engine_has_no_routes_outside_development
    lib = File.expand_path("../lib", __dir__)
    script = 'require "pi/browser/taskbar/rails"; abort unless Pi::Browser::Taskbar::Rails::Engine.routes.routes.empty?'
    _output, status = Open3.capture2e({"RAILS_ENV" => "production"}, RbConfig.ruby, "-I#{lib}", "-e", script)

    assert status.success?
  end
end

Dir[File.join(__dir__, "*_test.rb")].sort.each do |path|
  require path unless path == __FILE__
end
