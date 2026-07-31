# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "rubygems/package"
require "stringio"
require "tmpdir"
require "zlib"

class ReleaseGate
  class Failure < StandardError; end

  ASSETS = {
    "rails" => %w[
      packages/rails/lib/pi/browser/taskbar/rails/assets/pi_browser_taskbar.js
      packages/rails/lib/pi/browser/taskbar/rails/assets/pi_browser_taskbar.css
    ],
    "phoenix" => %w[
      packages/phoenix/priv/static/pi_browser_taskbar.js
      packages/phoenix/priv/static/pi_browser_taskbar.css
    ]
  }.freeze

  def initialize(root)
    @root = File.expand_path(root)
    @version = read("VERSION").strip
  end

  def prepare(output:, source_commit:, source_ref:, repository:, workflow_run:, workflow_attempt:, verify_workspace: true, require_acceptance: true)
    verify_source_identity(source_commit, verify_workspace)
    require_value(source_ref, "source ref")
    require_value(repository, "repository")
    require_value(workflow_run, "workflow run")
    require_value(workflow_attempt, "workflow attempt")

    artifacts = [rails_artifact, phoenix_artifact]
    directory = File.expand_path(output)
    FileUtils.rm_rf(directory)
    FileUtils.mkdir_p(directory)

    manifest = {
      "manifest_version" => 1,
      "product_version" => @version,
      "contract_version" => contract_version,
      "source" => {"repository" => repository, "ref" => source_ref, "commit" => source_commit},
      "workflow" => {"run" => workflow_run, "attempt" => workflow_attempt},
      "build_environment" => build_environment,
      "generated_assets" => generated_assets,
      "acceptance_inputs" => acceptance_inputs(require_acceptance),
      "artifacts" => artifacts
    }
    File.write(File.join(directory, "release-manifest.json"), JSON.pretty_generate(manifest) + "\n")
    File.write(File.join(directory, "SHA256SUMS"), artifacts.map { |item| "#{item.fetch("sha256")}  #{item.fetch("filename")}" }.join("\n") + "\n")
    File.write(File.join(directory, "RELEASE_NOTES.md"), release_notes)
    artifacts.each { |item| FileUtils.cp(File.join(@root, "build", item.fetch("filename")), directory) }
    puts "prepared immutable release inputs for #{@version} from #{source_commit}"
  end

  def verify_check_runs(path, source_commit)
    document = JSON.parse(File.read(path))
    runs = document.fetch("check_runs")
    expected = ["verify"] + compatibility_check_names
    failures = expected.filter_map do |name|
      matches = runs.select { |run| run["name"] == name && run["head_sha"] == source_commit }
      latest = matches.max_by { |run| run.fetch("id", 0) }
      if latest.nil?
        "#{name}: missing for #{source_commit}"
      elsif latest["status"] != "completed" || latest["conclusion"] != "success"
        "#{name}: #{latest["status"]}/#{latest["conclusion"]}"
      end
    end
    raise Failure, "release acceptance checks are incomplete:\n#{failures.join("\n")}" unless failures.empty?
    true
  rescue JSON::ParserError, KeyError => error
    raise Failure, "check-run response is invalid: #{error.message}"
  end

  def verify_manual_evidence(evidence_root = File.join(@root, "release/evidence"))
    paths = {
      "accessibility" => File.join(evidence_root, "accessibility.json"),
      "real Pi" => File.join(evidence_root, "real-pi.json")
    }
    missing = paths.reject { |_label, path| File.file?(path) }.keys
    raise Failure, "manual release evidence is pending: record #{missing.join(" and ")} evidence under release/evidence; automation cannot mark these gates passed" unless missing.empty?

    expected_artifacts = {
      "rails" => rails_artifact.fetch("sha256"),
      "phoenix" => phoenix_artifact.fetch("sha256")
    }
    paths.each do |label, path|
      evidence = JSON.parse(File.read(path))
      raise Failure, "#{label} evidence product_version must equal #{@version}" unless evidence["product_version"] == @version
      raise Failure, "#{label} evidence result must be passed" unless evidence["result"] == "passed"
      raise Failure, "#{label} evidence must identify the tester and date" if evidence.values_at("tester", "date").any? { |value| value.to_s.strip.empty? }
      raise Failure, "#{label} evidence artifact checksums do not match this candidate" unless evidence["artifacts"] == expected_artifacts
      raise Failure, "#{label} evidence must cover both clean examples" unless evidence["examples"]&.sort == %w[phoenix rails]
      if label == "accessibility"
        raise Failure, "accessibility evidence must identify the assistive-technology pairing" if evidence["pairing"].to_s.strip.empty?
      else
        expected_flows = %w[cancellation new-session task]
        valid_flows = %w[rails phoenix].all? { |adapter| evidence.dig("flows", adapter)&.sort == expected_flows }
        raise Failure, "real Pi evidence must cover task, cancellation, and new-session in both examples" unless valid_flows
      end
    rescue JSON::ParserError => error
      raise Failure, "#{label} evidence is invalid JSON: #{error.message}"
    end
    true
  end

  private

  def compatibility_check_names
    compatibility = JSON.parse(read("tooling/compatibility.json"))
    rails = compatibility.dig("rails", "release_rows").map { |row| "#{row.fetch("id")} / Puma #{row.fetch("puma")}" }
    phoenix = compatibility.dig("phoenix", "release_rows").map { |row| row.fetch("id") }
    rails + phoenix
  end

  def rails_artifact
    filename = "pi-browser-taskbar-rails-#{@version}.gem"
    path = build_path(filename)
    package = Gem::Package.new(path)
    fail!("Rails artifact version differs from #{@version}") unless package.spec.version.to_s == @version
    assets = artifact_asset_digests(path, "rails")
    verify_packaged_assets("rails", assets)
    {
      "distribution" => "rails",
      "name" => package.spec.name,
      "version" => package.spec.version.to_s,
      "platform" => package.spec.platform.to_s,
      "filename" => filename,
      "bytes" => File.size(path),
      "sha256" => Digest::SHA256.file(path).hexdigest,
      "files" => package.spec.files.sort,
      "assets" => assets
    }
  end

  def phoenix_artifact
    filename = "pi_browser_taskbar_phoenix-#{@version}.tar"
    path = build_path(filename)
    outer = tar_entries(File.binread(path))
    metadata = outer.fetch("metadata.config") { fail!("Phoenix artifact omits metadata.config") }
    name = metadata[/\{<<"name">>,<<"([^"]+)">>\}/, 1]
    version = metadata[/\{<<"version">>,<<"([^"]+)">>\}/, 1]
    fail!("Phoenix artifact metadata version differs from #{@version}") unless version == @version
    contents = Zlib::GzipReader.new(StringIO.new(outer.fetch("contents.tar.gz") { fail!("Phoenix artifact omits contents.tar.gz") })).read
    files = tar_entries(contents)
    assets = {
      "priv/static/pi_browser_taskbar.js" => Digest::SHA256.hexdigest(files.fetch("priv/static/pi_browser_taskbar.js")),
      "priv/static/pi_browser_taskbar.css" => Digest::SHA256.hexdigest(files.fetch("priv/static/pi_browser_taskbar.css"))
    }
    verify_packaged_assets("phoenix", assets)
    {
      "distribution" => "phoenix",
      "name" => name,
      "version" => version,
      "filename" => filename,
      "bytes" => File.size(path),
      "sha256" => Digest::SHA256.file(path).hexdigest,
      "files" => files.select { |_file, value| value }.keys.sort,
      "assets" => assets
    }
  end

  def artifact_asset_digests(path, distribution)
    entries = {}
    Dir.mktmpdir("release-gem") do |directory|
      Gem::Package.new(path).extract_files(directory)
      ASSETS.fetch(distribution).each do |source|
        packaged = source.sub(%r{\Apackages/rails/}, "")
        entries[packaged] = Digest::SHA256.file(File.join(directory, packaged)).hexdigest
      end
    end
    entries
  end

  def verify_packaged_assets(distribution, assets)
    source_digests = ASSETS.fetch(distribution).to_h do |path|
      packaged = path.sub(%r{\Apackages/(?:rails|phoenix)/}, "")
      [packaged, Digest::SHA256.file(File.join(@root, path)).hexdigest]
    end
    fail!("#{distribution} artifact assets differ from committed generated assets") unless assets == source_digests
  end

  def generated_assets
    ASSETS.flat_map do |distribution, paths|
      paths.map do |path|
        {"distribution" => distribution, "path" => path, "sha256" => Digest::SHA256.file(File.join(@root, path)).hexdigest}
      end
    end
  end

  def acceptance_inputs(required)
    paths = {
      "browser_automation" => File.join(@root, "build/browser-acceptance/automated.json"),
      "rails_clean_artifact" => File.join(@root, "build/conformance/rails.json"),
      "phoenix_clean_artifact" => File.join(@root, "build/conformance/phoenix.json"),
      "accessibility_manual" => File.join(@root, "release/evidence/accessibility.json"),
      "real_pi_manual" => File.join(@root, "release/evidence/real-pi.json"),
      "commit_check_runs" => ENV["RELEASE_CHECK_RUNS"]
    }
    missing = paths.select { |_name, path| path.to_s.empty? || !File.file?(path) }.keys
    fail!("release acceptance inputs are missing: #{missing.join(", ")}") if required && !missing.empty?
    paths.filter_map do |name, path|
      next unless path && File.file?(path)
      {"name" => name, "sha256" => Digest::SHA256.file(path).hexdigest}
    end
  end

  def build_environment
    {
      "ruby" => RUBY_DESCRIPTION,
      "rubygems" => Gem::VERSION,
      "source_date_epoch" => ENV.fetch("SOURCE_DATE_EPOCH", "946684800"),
      "node" => command("node", "--version"),
      "elixir" => command("elixir", "--short-version"),
      "otp" => command("elixir", "-e", "IO.write(System.otp_release())"),
      "hex" => command("mix", "hex.info").lines.first.to_s.sub("Hex:", "").strip
    }
  end

  def command(*arguments)
    IO.popen(arguments, err: File::NULL, &:read).strip
  rescue Errno::ENOENT
    "unavailable"
  end

  def contract_version
    source = read("contract/docs/index.md")
    version = source[/contract_version:\s*(\d+)/, 1]&.to_i
    fail!("canonical contract does not declare contract_version") unless version
    version
  end

  def release_notes
    rails = changelog_entries("packages/rails/CHANGELOG.md")
    phoenix = changelog_entries("packages/phoenix/CHANGELOG.md")
    <<~MARKDOWN
      # Pi Browser Taskbar #{@version}

      Coordinated Rails and Phoenix release from the source commit recorded in `release-manifest.json`.

      ## Rails adapter

      #{rails}

      ## Phoenix adapter

      #{phoenix}
    MARKDOWN
  end

  def changelog_entries(path)
    section = read(path)[/^## #{Regexp.escape(@version)}[^\n]*\n(.*?)(?=^## |\z)/m, 1]
    fail!("#{path} has no #{@version} release notes") if section.to_s.strip.empty?
    section.strip
  end

  def verify_source_identity(source_commit, verify_workspace)
    fail!("source commit must be a full lowercase Git SHA") unless source_commit.match?(/\A[0-9a-f]{40}\z/)
    head = git("rev-parse", "HEAD")
    fail!("source commit #{source_commit} differs from checked-out HEAD #{head}") unless source_commit == head
    if verify_workspace
      fail!("workspace changes prevent release preparation") unless git("status", "--porcelain").empty?
    end
  end

  def git(*arguments)
    IO.popen(["git", "-C", @root, *arguments], &:read).strip
  end

  def tar_entries(contents)
    Gem::Package::TarReader.new(StringIO.new(contents)).each_with_object({}) do |entry, entries|
      entries[entry.full_name] = entry.file? ? entry.read : nil
    end
  end

  def build_path(filename)
    path = File.join(@root, "build", filename)
    fail!("missing built artifact #{path}; run tooling/build_packages.sh exactly once") unless File.file?(path)
    path
  end

  def read(path)
    File.read(File.join(@root, path))
  end

  def require_value(value, label)
    fail!("#{label} is required") if value.to_s.strip.empty?
  end

  def fail!(message)
    raise Failure, message
  end
end
