# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/generators/pi_browser_taskbar/install_generator"

class RailsGeneratorTest < Minitest::Test
  Generator = PiBrowserTaskbar::Generators::InstallGenerator

  def test_discovers_and_idempotently_installs_every_marked_host_seam
    in_app do |root|
      assert_equal :installed, Generator.run!(root)
      first = tree(root)
      assert_equal :current, Generator.run!(root)
      assert_equal first, tree(root)

      routes = File.read(File.join(root, "config/routes.rb"))
      layout = File.read(File.join(root, "app/views/layouts/application.html.erb"))
      initializer = File.read(File.join(root, "config/initializers/pi_browser_taskbar.rb"))
      assert_includes routes, "pi-browser-taskbar:start routes"
      assert_includes routes, "Rails.env.development?"
      assert_includes layout, "pi-browser-taskbar:start layout"
      assert_operator layout.index("pi_browser_taskbar_tags"), :<, layout.index("</head>")
      assert_includes initializer, "pi-browser-taskbar:start configuration"
      assert_includes initializer, 'config.mount_path = "/dev/pi-browser-taskbar"'
    end
  end

  def test_explicit_layout_and_normalized_mount_install_nonstandard_application
    in_app do |root|
      conventional = File.join(root, "app/views/layouts/application.html.erb")
      custom = File.join(root, "app/views/shells/internal.html.erb")
      FileUtils.mkdir_p(File.dirname(custom))
      File.rename(conventional, custom)

      capture_io do
        Generator.start(
          ["--layout", "app/views/shells/internal.html.erb", "--mount", "/internal/pi/"],
          destination_root: root
        )
      end

      assert_includes File.read(custom), "pi_browser_taskbar_tags"
      assert_includes File.read(File.join(root, "config/routes.rb")), '=> "/internal/pi"'
      assert_includes File.read(File.join(root, "config/initializers/pi_browser_taskbar.rb")), 'config.mount_path = "/internal/pi"'
    end
  end

  def test_explicit_second_layout_is_added_without_duplicating_existing_seams
    in_app do |root|
      second = File.join(root, "app/views/layouts/admin.html.erb")
      File.write(second, layout_source("Admin"))
      Generator.run!(root)

      assert_equal :installed, Generator.run!(root, layout: "app/views/layouts/admin.html.erb")
      assert_includes File.read(second), "pi_browser_taskbar_tags"
      assert_equal 1, File.read(File.join(root, "config/routes.rb")).scan("pi-browser-taskbar:start routes").length
      assert_equal :current, Generator.run!(root, layout: "app/views/layouts/admin.html.erb")
    end
  end

  def test_explicit_layout_must_not_resolve_outside_the_host
    in_app do |root|
      Dir.mktmpdir("external-layout") do |external|
        external_layout = File.join(external, "outside.html.erb")
        File.write(external_layout, layout_source)
        link = File.join(root, "app/views/layouts/outside.html.erb")
        File.symlink(external_layout, link)
        before = tree(root)

        error = assert_raises(ArgumentError) { Generator.run!(root, layout: "app/views/layouts/outside.html.erb") }
        assert_match(/outside the host root/, error.message)
        assert_equal before, tree(root)
      end
    end
  end

  def test_invalid_mount_paths_stop_before_writing
    ["dev/pi", "/", "/dev/../pi", "https://example.test/pi", "/dev/pi?x=1", "/dev/%2e%2e/pi"].each do |mount|
      in_app do |root|
        before = tree(root)
        error = assert_raises(ArgumentError) { Generator.run!(root, mount: mount) }
        assert_match(/mount/, error.message)
        assert_equal before, tree(root)
      end
    end
  end

  def test_api_only_non_erb_multiple_layout_and_unclear_head_discovery_refuse_every_write
    cases = {
      api_only: ->(root) { File.write(File.join(root, "config/application.rb"), "config.api_only = true\n") },
      non_erb: ->(root) { File.rename(File.join(root, "app/views/layouts/application.html.erb"), File.join(root, "app/views/layouts/application.html.haml")) },
      multiple: ->(root) { File.write(File.join(root, "app/views/layouts/application.mobile.erb"), layout_source) },
      unclear_head: ->(root) { File.write(File.join(root, "app/views/layouts/application.html.erb"), "<html><body><%= yield %></body></html>\n") }
    }

    cases.each_value do |mutate|
      in_app do |root|
        mutate.call(root)
        before = tree(root)
        error = assert_raises(ArgumentError) { Generator.run!(root) }
        assert_match(/--layout|API-only|head/i, error.message)
        assert_equal before, tree(root)
      end
    end
  end

  def test_unsupported_erb_syntax_refuses_every_write
    in_app do |root|
      layout = File.join(root, "app/views/layouts/application.html.erb")
      File.write(layout, "<html><head><%= ( %></head><body></body></html>\n")
      before = tree(root)

      error = assert_raises(ArgumentError) { Generator.run!(root) }
      assert_match(/ERB.*syntax/i, error.message)
      assert_equal before, tree(root)
    end
  end

  def test_mount_precedes_global_fallback_and_repositions_an_existing_block
    in_app do |root|
      routes = File.join(root, "config/routes.rb")
      File.write(routes, <<~RUBY)
        Rails.application.routes.draw do
          root "home#index"
          match "*path" => "catch_all#resolve", via: :all
        end
      RUBY

      assert_equal :installed, Generator.run!(root)
      source = File.read(routes)
      assert_operator source.index("Pi::Browser::Taskbar::Rails::Engine"), :<, source.index('match "*path"')

      block = source[/  # pi-browser-taskbar:start routes\n.*?  # pi-browser-taskbar:end routes\n/m]
      File.write(routes, source.sub(block, "").sub("\nend\n", "\n#{block}end\n"))

      assert_equal :installed, Generator.run!(root)
      source = File.read(routes)
      assert_operator source.index("Pi::Browser::Taskbar::Rails::Engine"), :<, source.index('match "*path"')
    end
  end

  def test_mount_precedes_an_inline_global_fallback
    in_app do |root|
      routes = File.join(root, "config/routes.rb")
      File.write(routes, <<~RUBY)
        Rails.application.routes.draw do match "*path" => "catch_all#resolve", via: :all
        end
      RUBY

      assert_equal :installed, Generator.run!(root)
      source = File.read(routes)
      assert_operator source.index("Pi::Browser::Taskbar::Rails::Engine"), :<, source.index('match "*path"')
    end
  end

  def test_commented_draw_signature_is_not_a_routes_block
    in_app do |root|
      routes = File.join(root, "config/routes.rb")
      File.write(routes, <<~RUBY)
        # Rails.application.routes.draw do
        if true
        end
      RUBY
      before = tree(root)

      error = assert_raises(ArgumentError) { Generator.run!(root) }
      assert_match(/routes\.draw block/, error.message)
      assert_equal before, tree(root)
    end
  end

  def test_route_conflict_and_unsupported_ruby_syntax_refuse_every_write
    [
      'Rails.application.routes.draw do\n  get "/dev/pi-browser-taskbar", to: "home#index"\nend\n',
      "Rails.application.routes.draw do\n  broken(\nend\n"
    ].each do |routes_source|
      in_app do |root|
        File.write(File.join(root, "config/routes.rb"), routes_source.gsub("\\n", "\n"))
        before = tree(root)
        error = assert_raises(ArgumentError) { Generator.run!(root) }
        assert_match(/route|syntax/i, error.message)
        assert_equal before, tree(root)
      end
    end
  end

  def test_route_conflict_added_after_install_refuses_update_without_partial_writes
    in_app do |root|
      Generator.run!(root)
      routes = File.join(root, "config/routes.rb")
      File.write(routes, File.read(routes).sub("Rails.application.routes.draw do", "Rails.application.routes.draw do\n  get \"/dev/pi-browser-taskbar\", to: \"home#index\""))
      before = tree(root)

      error = assert_raises(ArgumentError) { Generator.run!(root) }
      assert_match(/route conflict/, error.message)
      assert_equal before, tree(root)
    end
  end

  def test_recognized_generated_initializer_updates_while_host_code_is_preserved
    in_app do |root|
      Generator.run!(root)
      initializer = File.join(root, "config/initializers/pi_browser_taskbar.rb")
      source = File.read(initializer)
      old_body = source.sub("# pi-browser-taskbar:start configuration", "# pi-browser-taskbar:start configuration\n# old generated release")
      File.write(initializer, Generator.refresh_initializer_checksum(old_body))
      routes = File.join(root, "config/routes.rb")
      File.write(routes, File.read(routes).sub("Rails.application.routes.draw do", "Rails.application.routes.draw do\n  # keep host route comment"))

      assert_equal :installed, Generator.run!(root)
      refute_includes File.read(initializer), "old generated release"
      assert_includes File.read(routes), "# keep host route comment"
    end
  end

  def test_edited_generated_section_refuses_update_without_partial_writes
    in_app do |root|
      Generator.run!(root)
      layout = File.join(root, "app/views/layouts/application.html.erb")
      File.write(layout, File.read(layout).sub("pi_browser_taskbar_tags", "edited_taskbar_tags"))
      before = tree(root)

      error = assert_raises(ArgumentError) { Generator.run!(root) }
      assert_match(/edited generated layout.*manual/i, error.message)
      assert_equal before, tree(root)
    end
  end

  def test_uninstall_preflights_every_seam_preserves_host_code_and_repeats_harmlessly
    in_app do |root|
      routes = File.join(root, "config/routes.rb")
      File.write(routes, File.read(routes).sub("routes.draw do", "routes.draw do\n  # keep me"))
      original_routes = File.read(routes)
      original_layout = File.read(File.join(root, "app/views/layouts/application.html.erb"))
      Generator.run!(root)

      assert_equal :uninstalled, Generator.uninstall!(root)
      assert_equal original_routes, File.read(routes)
      assert_includes File.read(routes), "# keep me"
      assert_equal original_layout, File.read(File.join(root, "app/views/layouts/application.html.erb"))
      refute_path_exists File.join(root, "config/initializers/pi_browser_taskbar.rb")
      after_first = tree(root)
      assert_equal :current, Generator.uninstall!(root)
      assert_equal after_first, tree(root)
    end
  end

  def test_uninstall_refuses_one_edited_seam_and_removes_nothing
    in_app do |root|
      Generator.run!(root)
      routes = File.join(root, "config/routes.rb")
      File.write(routes, File.read(routes).sub("Pi::Browser::Taskbar::Rails::Engine", "Edited::Engine"))
      before = tree(root)

      error = assert_raises(ArgumentError) { Generator.uninstall!(root) }
      assert_match(/edited generated routes.*manual/i, error.message)
      assert_equal before, tree(root)
    end
  end

  private

  def in_app
    Dir.mktmpdir("rails-generator") do |root|
      FileUtils.mkdir_p(File.join(root, "config/initializers"))
      FileUtils.mkdir_p(File.join(root, "app/views/layouts"))
      File.write(File.join(root, "config/application.rb"), "module Demo; class Application < Rails::Application; end; end\n")
      File.write(File.join(root, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
      File.write(File.join(root, "app/views/layouts/application.html.erb"), layout_source)
      yield root
    end
  end

  def layout_source(title = "Demo")
    "<!doctype html>\n<html>\n  <head><title>#{title}</title></head>\n  <body><%= yield %></body>\n</html>\n"
  end

  def tree(root)
    Dir[File.join(root, "**/*")].reject { |path| File.directory?(path) }.to_h do |path|
      [path.delete_prefix("#{root}/"), File.binread(path)]
    end
  end
end
