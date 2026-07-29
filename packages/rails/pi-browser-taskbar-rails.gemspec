# frozen_string_literal: true

require_relative "lib/pi/browser/taskbar/rails/version"

Gem::Specification.new do |spec|
  spec.name = "pi-browser-taskbar-rails"
  spec.version = Pi::Browser::Taskbar::Rails::VERSION
  spec.authors = ["Dave Lens"]
  spec.summary = "Development-only Pi browser taskbar adapter for Rails"
  spec.description = "A self-contained Rails adapter for the private Pi Browser Taskbar client."
  spec.homepage = "https://github.com/davelens/pi-browser-taskbar"
  spec.licenses = ["Nonstandard"]
  spec.required_ruby_version = ">= 2.7"

  spec.files = Dir.chdir(__dir__) do
    Dir["CHANGELOG.md", "README.md", "lib/**/*.rb", "lib/**/*.css", "lib/**/*.js"]
  end
  spec.require_paths = ["lib"]

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "#{spec.homepage}/tree/v#{spec.version}",
    "changelog_uri" => "#{spec.homepage}/blob/v#{spec.version}/packages/rails/CHANGELOG.md"
  }
end
