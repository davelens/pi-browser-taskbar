# frozen_string_literal: true

require "fileutils"
require "rubygems/package"
require "stringio"
require "tmpdir"
require "zlib"

class ArtifactVerifier
  def initialize(root)
    @root = File.expand_path(root)
    @version = File.read(File.join(@root, "VERSION")).strip
  end

  def run
    verify_gem
    verify_hex
    verify_hex_docs
    puts "package and documentation artifacts are self-contained and version-aligned"
  end

  private

  def verify_gem
    path = File.join(@root, "build/pi-browser-taskbar-rails-#{@version}.gem")
    raise "missing Rails artifact #{path}" unless File.file?(path)

    package = Gem::Package.new(path)
    raise "Rails artifact version drift" unless package.spec.version.to_s == @version
    dependencies = package.spec.runtime_dependencies
    unless dependencies.length == 1 && dependencies.first.name == "rails" && dependencies.first.requirement.to_s == ">= 7.1, < 8.2"
      raise "Rails artifact compatibility dependency drift"
    end
    repository = "https://github.com/davelens/pi-browser-taskbar"
    unless package.spec.metadata["source_code_uri"] == "#{repository}/tree/v#{@version}" &&
        package.spec.metadata["changelog_uri"] == "#{repository}/blob/v#{@version}/packages/rails/CHANGELOG.md"
      raise "Rails artifact versioned metadata links drift"
    end

    Dir.mktmpdir("pi-browser-taskbar-gem") do |directory|
      package.extract_files(directory)
      files = package.spec.files
      asset = "lib/pi/browser/taskbar/rails/assets/pi_browser_taskbar.js"
      required = [
        "lib/pi/browser/taskbar/rails/engine.rb",
        "lib/pi/browser/taskbar/rails/routes.rb",
        "lib/pi/browser/taskbar/rails/task.rb",
        "lib/pi/browser/taskbar/rails/broker.rb",
        "lib/pi/browser/taskbar/rails/broker_launcher.rb",
        "lib/generators/pi_browser_taskbar/install_generator.rb"
      ]
      missing = required - files
      raise "Rails artifact omits runtime entries: #{missing.join(", ")}" unless missing.empty?
      verify_contents("Rails", files, asset)
      verify_license("Rails", File.read(File.join(directory, "LICENSE")))
      verify_shared_docs("Rails") { |path| File.binread(File.join(directory, path)) }
      verify_bootstrap("Rails", File.read(File.join(directory, asset)), "rails")
    end
  end

  def verify_hex
    path = File.join(@root, "build/pi_browser_taskbar_phoenix-#{@version}.tar")
    raise "missing Phoenix artifact #{path}" unless File.file?(path)

    outer = tar_entries(File.open(path, "rb"))
    contents = outer.fetch("contents.tar.gz") { raise "Phoenix artifact has no contents.tar.gz" }
    metadata = outer.fetch("metadata.config") { raise "Phoenix artifact has no metadata.config" }
    unless metadata.include?(%({<<"name">>,<<"pi_browser_taskbar_phoenix">>})) &&
        metadata.include?(%({<<"version">>,<<"#{@version}">>})) &&
        metadata.include?(%({<<"elixir">>,<<">= 1.11.0">>})) &&
        metadata.include?(%({<<"requirement">>,<<">= 1.7.0 and < 2.0.0">>})) &&
        metadata.scan(%({<<"repository">>,<<"hexpm">>})).length == 2
      raise "Phoenix artifact metadata drift"
    end
    files = tar_entries(StringIO.new(Zlib::GzipReader.new(StringIO.new(contents)).read))
    asset = "priv/static/pi_browser_taskbar.js"
    required = %w[
      lib/pi_browser_taskbar_phoenix.ex
      lib/pi_browser_taskbar_phoenix/runtime.ex
      lib/pi_browser_taskbar_phoenix/endpoint.ex
      lib/pi_browser_taskbar_phoenix/installer.ex
      lib/mix/tasks/pi_browser_taskbar.install.ex
    ]
    missing = required - files.keys
    raise "Phoenix artifact omits runtime entries: #{missing.join(", ")}" unless missing.empty?
    verify_contents("Phoenix", files.keys, asset)
    verify_license("Phoenix", files.fetch("LICENSE"))
    verify_shared_docs("Phoenix") { |path| files.fetch(path) }
    verify_bootstrap("Phoenix", files.fetch(asset), "phoenix")

    mix = files.fetch("mix.exs")
    raise "Phoenix artifact version drift" unless mix.include?(%(version: "#{@version}"))
    raise "Phoenix artifact unexpectedly requires Node" if files.key?("package.json")
  end

  def verify_hex_docs
    path = File.join(@root, "build/pi_browser_taskbar_phoenix-docs-#{@version}.tar.gz")
    raise "missing preserved Phoenix documentation artifact #{path}" unless File.file?(path)

    files = Zlib::GzipReader.open(path) { |gzip| tar_entries(gzip) }
    raise "Phoenix documentation artifact omits index.html" unless files.key?("index.html")
    raise "Phoenix documentation artifact unexpectedly contains credentials" if files.keys.any? { |name| name.match?(/credentials|\.env|\.key\z/i) }
  end

  def tar_entries(io)
    Gem::Package::TarReader.new(io).each_with_object({}) do |entry, entries|
      entries[entry.full_name] = entry.file? ? entry.read : nil
    end
  end

  def verify_contents(label, files, asset)
    required = [asset, asset.sub(/\.js\z/, ".css"), "README.md", "CHANGELOG.md", "LICENSE",
      "contract/docs/index.md", "contract/traceability.md", "contract/traceability.json",
      "docs/accessibility-acceptance.md", "docs/security.md", "docs/troubleshooting.md"]
    missing = required - files
    raise "#{label} artifact omits required content: #{missing.join(", ")}" unless missing.empty?

    top_level = label == "Rails" ? %w[README.md CHANGELOG.md LICENSE] : %w[.formatter.exs mix.exs README.md CHANGELOG.md LICENSE]
    prefixes = label == "Rails" ? %w[lib contract docs] : %w[lib priv contract docs]
    allowed = files.select do |file|
      top_level.include?(file) || prefixes.any? { |prefix| file == prefix || file.start_with?("#{prefix}/") }
    end
    unexpected = files - allowed
    raise "#{label} artifact contains files outside its allowlist: #{unexpected.join(", ")}" unless unexpected.empty?

    secret_like = files.grep(%r{(?:\A|/)(?:\.env(?:\..*)?|\.npmrc|credentials(?:\.yml\.enc)?|hex\.config|master\.key|id_(?:rsa|dsa|ecdsa|ed25519)|[^/]+\.(?:pem|key|p12|pfx))\z}i)
    raise "#{label} artifact contains secret-like files: #{secret_like.join(", ")}" unless secret_like.empty?

    forbidden = files.grep(%r{(^|/)(examples|tooling|browser-client|node_modules)(/|$)})
    forbidden += label == "Rails" ? files.grep(/phoenix/i) : files.grep(/(?:^|[\/_-])rails(?:[\/_-]|$)/i)
    raise "#{label} artifact leaks unrelated content: #{forbidden.uniq.join(", ")}" unless forbidden.empty?
  end

  def verify_shared_docs(label)
    %w[contract/docs/index.md contract/traceability.md contract/traceability.json docs/accessibility-acceptance.md docs/security.md docs/troubleshooting.md].each do |path|
      raise "#{label} staged #{path} differs from canonical source" unless yield(path) == File.binread(File.join(@root, path))
    end
  end

  def verify_license(label, contents)
    root_license = File.read(File.join(@root, "LICENSE"))
    raise "#{label} artifact license differs from root LICENSE" unless contents == root_license
  end

  def verify_bootstrap(label, source, framework)
    raise "#{label} bootstrap version drift" unless source.include?(%(productVersion: "#{@version}"))
    raise "#{label} bootstrap has wrong provider" unless source.include?(%(framework: "#{framework}"))
    if source.match?(/^\s*(import|export)\s|\b(?:import|require)\s*\(/m)
      raise "#{label} bootstrap retains module imports"
    end
  end
end

ArtifactVerifier.new(File.expand_path("..", __dir__)).run if $PROGRAM_NAME == __FILE__
