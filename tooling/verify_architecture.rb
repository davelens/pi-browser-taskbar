# frozen_string_literal: true

require "json"
require "pathname"

class ArchitectureVerifier
  REQUIRED_MODULES = %w[
    browser-client
    conformance-contract
    rails-adapter
    phoenix-adapter
    examples
    root-tooling
  ].freeze

  REQUIRED_TRACEABILITY_HEADINGS = [
    "Problem Statement",
    "Solution",
    "User Stories",
    "Product and distribution",
    "Ownership boundaries",
    "Shared task API",
    "Pi RPC lifecycle",
    "Normalized browser task context",
    "Source-hint contract",
    "Bounds, truncation, and normalization",
    "Browser Client interaction",
    "Security and configuration",
    "Rails Adapter",
    "Phoenix Adapter",
    "Documentation and examples",
    "Versioning and coordinated release",
    "Implementation sequence and change control",
    "Test philosophy and primary seam",
    "Shared Conformance Contract",
    "Browser Client",
    "Accessibility",
    "Rails-native integration",
    "Phoenix-native integration",
    "Compatibility matrix",
    "Examples, artifacts, documentation, and release",
    "Out of Scope"
  ].freeze

  def initialize(root)
    @root = Pathname(root)
    @errors = []
  end

  def run
    verify_version
    verify_ownership
    verify_negative_dependencies
    verify_traceability

    if @errors.empty?
      puts "architecture, ownership, version, and traceability are consistent"
    else
      warn @errors.join("\n")
      exit 1
    end
  end

  private

  def verify_version
    version = @root.join("VERSION").read.strip
    semantic_version = /\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z/
    error("VERSION must be semantic x.y.z") unless version.match?(semantic_version)

    rails = @root.join("packages/rails/lib/pi/browser/taskbar/rails/version.rb").read[/VERSION = "([^"]+)"/, 1]
    phoenix = @root.join("packages/phoenix/mix.exs").read[/version: "([^"]+)"/, 1]
    phoenix_runtime = @root.join("packages/phoenix/lib/pi_browser_taskbar_phoenix.ex").read[/@version "([^"]+)"/, 1]
    rails_changelog = @root.join("packages/rails/CHANGELOG.md").read
    phoenix_changelog = @root.join("packages/phoenix/CHANGELOG.md").read

    error("Rails package version #{rails.inspect} differs from #{version}") unless rails == version
    error("Phoenix package version #{phoenix.inspect} differs from #{version}") unless phoenix == version
    error("Phoenix runtime version #{phoenix_runtime.inspect} differs from #{version}") unless phoenix_runtime == version
    error("Rails changelog has no #{version} entry") unless rails_changelog.include?("## #{version}")
    error("Phoenix changelog has no #{version} entry") unless phoenix_changelog.include?("## #{version}")

    %w[rails phoenix].each do |adapter|
      readme = @root.join("packages/#{adapter}/README.md").read
      error("#{adapter} guide version differs from #{version}") unless readme.scan(version).length >= 2
      asset = adapter == "rails" ? "packages/rails/lib/pi/browser/taskbar/rails/assets/pi_browser_taskbar.js" : "packages/phoenix/priv/static/pi_browser_taskbar.js"
      error("#{adapter} Browser Client bootstrap version differs from #{version}") unless @root.join(asset).read.include?(%(productVersion: "#{version}"))
    end

    contract = @root.join("contract/docs/index.md").read[/# Conformance Contract v(\d+)/, 1]&.to_i
    error("canonical contract heading and declaration differ") unless contract && @root.join("contract/docs/index.md").read.include?("contract_version: #{contract}")
    @root.glob("contract/schemas/*.json").each do |path|
      schema = JSON.parse(path.read)
      file_version = path.basename.to_s[/\.v(\d+)\.schema\.json\z/, 1]&.to_i
      declared = schema.dig("properties", "contract_version", "const") || file_version
      error("#{relative(path)} contract version #{declared.inspect} differs from #{contract}") unless declared == contract
    end

    license = @root.join("LICENSE").read
    error("Rails packaged license differs from root LICENSE") unless @root.join("packages/rails/LICENSE").read == license
    error("Phoenix packaged license differs from root LICENSE") unless @root.join("packages/phoenix/LICENSE").read == license
  end

  def verify_ownership
    ownership = JSON.parse(@root.join("tooling/ownership.json").read)
    modules = ownership.fetch("modules")
    ids = modules.map { |mod| mod.fetch("id") }
    error("ownership modules must be unique") unless ids.uniq.length == ids.length
    error("ownership modules differ from canonical set") unless ids.sort == REQUIRED_MODULES.sort

    modules.each do |mod|
      mod.fetch("source_roots").each do |source_root|
        error("missing owned source root #{source_root}") unless @root.join(source_root).exist?
      end
      %w[runtime_dependencies build_dependencies test_dependencies].each do |kind|
        mod.fetch(kind).each do |dependency|
          error("#{mod["id"]} has unknown #{kind} #{dependency}") unless ids.include?(dependency)
          error("#{mod["id"]} depends on itself through #{kind}") if dependency == mod["id"]
        end
      end
    end

    detect_cycles(modules)
  rescue JSON::ParserError, KeyError => exception
    error("invalid ownership declaration: #{exception.message}")
  end

  def detect_cycles(modules)
    graph = modules.to_h do |mod|
      dependencies = %w[runtime_dependencies build_dependencies test_dependencies].flat_map do |kind|
        mod.fetch(kind)
      end
      [mod.fetch("id"), dependencies]
    end
    visiting = []
    visited = {}

    visit = lambda do |id|
      if visiting.include?(id)
        error("ownership dependency cycle: #{(visiting.drop_while { |item| item != id } + [id]).join(" -> ")}")
        return
      end
      return if visited[id]

      visiting << id
      graph.fetch(id).each { |dependency| visit.call(dependency) }
      visiting.pop
      visited[id] = true
    end

    graph.each_key { |id| visit.call(id) }
  end

  def verify_negative_dependencies
    browser_source = files_under("packages/browser-client/src")
    scan_for_terms(browser_source, /\b(rails|phoenix|ruby|elixir)\b/i, "Browser Client contains framework knowledge")

    contract_files = files_under("contract")
    executable_contract = contract_files.reject { |path| %w[.json .md].include?(path.extname) }
    executable_contract.each { |path| error("Contract contains implementation file #{relative(path)}") }
    contract_files.select { |path| path.symlink? }.each { |path| error("Contract contains implementation symlink #{relative(path)}") }

    rails_runtime = files_under("packages/rails/lib") + files_under("packages/rails/browser")
    phoenix_runtime = files_under("packages/phoenix/lib") + files_under("packages/phoenix/browser")
    scan_for_terms(rails_runtime, /\bphoenix\b/i, "Rails adapter couples to Phoenix")
    scan_for_terms(phoenix_runtime, /\brails\b/i, "Phoenix adapter couples to Rails")

    rails_spec = Gem::Specification.load(@root.join("packages/rails/pi-browser-taskbar-rails.gemspec").to_s)
    dependencies = rails_spec.runtime_dependencies
    unless dependencies.length == 1 && dependencies.first.name == "rails"
      error("Rails adapter declares a runtime dependency other than its host framework")
    end

    phoenix_mix = @root.join("packages/phoenix/mix.exs").read
    if phoenix_mix.match?(/pi-browser-taskbar-rails|pi_browser_taskbar_rails|packages\/rails/i)
      error("Phoenix adapter declares an adapter-to-adapter dependency")
    end
  end

  def verify_traceability
    trace = JSON.parse(@root.join("contract/traceability.json").read)
    sections = trace.fetch("sections")
    headings = sections.map { |section| section.fetch("heading") }
    missing = REQUIRED_TRACEABILITY_HEADINGS - headings
    extra = headings - REQUIRED_TRACEABILITY_HEADINGS
    error("traceability missing headings: #{missing.join(", ")}") unless missing.empty?
    error("traceability has unexpected headings: #{extra.join(", ")}") unless extra.empty?
    error("traceability headings must be unique") unless headings.uniq.length == headings.length

    sections.each do |section|
      error("traceability owner unknown for #{section["heading"]}") unless REQUIRED_MODULES.include?(section.fetch("owner"))
      error("traceability seam empty for #{section["heading"]}") if section.fetch("acceptance_seam").strip.empty?
      unless %w[foundation future phoenix-slice rails-slice adapter-slices].include?(section.fetch("status"))
        error("traceability status invalid for #{section["heading"]}")
      end
    end

    markdown = @root.join("contract/traceability.md").read
    headings.each { |heading| error("traceability markdown omits #{heading}") unless markdown.include?("| #{heading} |") }
  rescue JSON::ParserError, KeyError => exception
    error("invalid traceability index: #{exception.message}")
  end

  def files_under(relative_root)
    root = @root.join(relative_root)
    return [] unless root.exist?

    root.glob("**/*", File::FNM_DOTMATCH).select(&:file?)
  end

  def scan_for_terms(paths, pattern, message)
    paths.each do |path|
      error("#{message}: #{relative(path)}") if path.read.match?(pattern)
    end
  end

  def relative(path)
    path.relative_path_from(@root)
  end

  def error(message)
    @errors << message
  end
end

ArchitectureVerifier.new(File.expand_path("..", __dir__)).run if $PROGRAM_NAME == __FILE__
