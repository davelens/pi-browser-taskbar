# frozen_string_literal: true

require "minitest/autorun"
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
end
