# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/generators/pi_browser_taskbar/install_generator"

class RailsGeneratorTest < Minitest::Test
  Generator = PiBrowserTaskbar::Generators::InstallGenerator

  def test_happy_path_and_idempotence
    in_app do |root|
      first = Generator.plan!(root)
      first.each { |path, source| FileUtils.mkdir_p(File.dirname(path)); File.write(path, source) }
      second = Generator.plan!(root)

      assert_equal first, second
      assert_includes File.read(File.join(root, "config/routes.rb")), Generator::ROUTE
      assert_includes File.read(File.join(root, "app/views/layouts/application.html.erb")), Generator::LAYOUT
      assert_equal Generator::INITIALIZER, File.read(File.join(root, "config/initializers/pi_browser_taskbar.rb"))
    end
  end

  def test_preflight_failure_makes_no_partial_write
    in_app(layout: "<html>no body close</html>\n") do |root|
      routes = File.join(root, "config/routes.rb")
      before = File.read(routes)

      assert_raises(ArgumentError) { Generator.start([], destination_root: root).install }
      assert_equal before, File.read(routes)
      refute_path_exists File.join(root, "config/initializers/pi_browser_taskbar.rb")
    end
  end

  private

  def in_app(layout: "<html><body><%= yield %></body></html>\n")
    Dir.mktmpdir("rails-generator") do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      FileUtils.mkdir_p(File.join(root, "app/views/layouts"))
      File.write(File.join(root, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
      File.write(File.join(root, "app/views/layouts/application.html.erb"), layout)
      yield root
    end
  end
end
