# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "open3"
require "tmpdir"
require "uri"
require_relative "release_workflow"

class ReleaseRegistry
  HEX_API = "https://hex.pm/api".freeze
  HEX_REPO = "https://repo.hex.pm".freeze
  RUBYGEMS_API = "https://rubygems.org".freeze

  def hex_package(candidate)
    release = hex_release(candidate)
    return :absent unless release

    compare!("Hex package", release.fetch("checksum"), candidate.hex.fetch("sha256"))
    metadata!("Hex package", release, candidate.hex)
    :identical
  end

  def publish_hex_package(candidate)
    hex_write("#{HEX_API}/publish?replace=false", File.binread(candidate.path(candidate.hex)), "Hex package")
  end

  def verify_hex_package(candidate)
    release = hex_release(candidate)
    raise ReleaseWorkflow::Retryable, "Hex package is not publicly available yet" unless release

    compare!("Hex package", release.fetch("checksum"), candidate.hex.fetch("sha256"))
    metadata!("Hex package", release, candidate.hex)
    public_bytes!("Hex package", "#{HEX_REPO}/tarballs/#{candidate.hex.fetch("name")}-#{candidate.version}.tar", candidate.hex.fetch("sha256"))
    Dir.mktmpdir("release-hex-fetch") do |directory|
      output = File.join(directory, "package")
      run!({"HEX_API_KEY" => nil}, "mix", "hex.package", "fetch", candidate.hex.fetch("name"), candidate.version, "--unpack", "--output", output, label: "Hex clean public fetch")
      raise ReleaseWorkflow::Permanent, "Hex clean public fetch did not unpack the expected package" unless File.file?(File.join(output, "mix.exs"))
    end
    true
  end

  def hex_docs(candidate)
    return :absent unless hex_docs_present?(candidate)

    public_bytes!("Hex documentation", docs_archive_url(candidate), candidate.hex_docs.fetch("sha256"))
    :identical
  end

  def publish_hex_docs(candidate)
    entry = candidate.hex_docs
    name = candidate.hex.fetch("name")
    hex_write("#{HEX_API}/packages/#{name}/releases/#{candidate.version}/docs", File.binread(candidate.path(entry)), "Hex documentation")
  end

  def verify_hex_docs(candidate)
    raise ReleaseWorkflow::Retryable, "Hex documentation is not publicly available yet" unless hex_docs_present?(candidate)

    public_bytes!("Hex documentation", docs_archive_url(candidate), candidate.hex_docs.fetch("sha256"))
    response = request("https://hexdocs.pm/#{candidate.hex.fetch("name")}/#{candidate.version}/index.html", redirects: 2)
    raise ReleaseWorkflow::Retryable, "Hex documentation index is not publicly readable yet" unless response.is_a?(Net::HTTPSuccess)
    true
  end

  def rubygem(candidate)
    release = rubygem_release(candidate)
    return :absent unless release

    compare!("RubyGems package", release.fetch("sha"), candidate.rails.fetch("sha256"))
    metadata!("RubyGems package", release, candidate.rails)
    :identical
  end

  def publish_rubygem(candidate)
    raise ReleaseWorkflow::Permanent, "RubyGems trusted-publishing credential is unavailable" if ENV["GEM_HOST_API_KEY"].to_s.empty?

    _output, _error, status = Open3.capture3("gem", "push", candidate.path(candidate.rails), "--host", RUBYGEMS_API)
    raise ReleaseWorkflow::Retryable, "RubyGems publication result is ambiguous; resume to reconcile public state" unless status.success?
    true
  rescue Errno::ENOENT
    raise ReleaseWorkflow::Permanent, "RubyGems publishing tool is unavailable"
  end

  def verify_rubygem(candidate)
    release = rubygem_release(candidate)
    raise ReleaseWorkflow::Retryable, "RubyGems package is not publicly available yet" unless release

    compare!("RubyGems package", release.fetch("sha"), candidate.rails.fetch("sha256"))
    metadata!("RubyGems package", release, candidate.rails)
    public_bytes!("RubyGems package", release.fetch("gem_uri"), candidate.rails.fetch("sha256"))
    Dir.mktmpdir("release-gem-install") do |directory|
      run!({"GEM_HOST_API_KEY" => nil}, "gem", "install", candidate.rails.fetch("name"), "--version", candidate.version,
        "--platform", candidate.rails.fetch("platform", "ruby"), "--source", RUBYGEMS_API, "--install-dir", directory,
        "--ignore-dependencies", "--no-document", label: "RubyGems clean public install")
      specs = Dir.glob(File.join(directory, "specifications", "#{candidate.rails.fetch("name")}-#{candidate.version}*.gemspec"))
      raise ReleaseWorkflow::Permanent, "RubyGems clean public install did not install the expected package" if specs.empty?
    end
    true
  end

  private

  def hex_release(candidate)
    response = request("#{HEX_API}/packages/#{candidate.hex.fetch("name")}/releases/#{candidate.version}")
    return nil if response.is_a?(Net::HTTPNotFound)
    release = response_json(response, "Hex package")
    required = release.is_a?(Hash) && release.key?("checksum") && release.key?("version") && [true, false].include?(release["has_docs"])
    required &&= release.key?("name") || release.dig("meta", "app")
    raise ReleaseWorkflow::Permanent, "Hex package registry metadata is unverifiable; no write attempted" unless required
    release
  end

  def hex_docs_present?(candidate)
    release = hex_release(candidate)
    release && release["has_docs"] == true
  end

  def rubygem_release(candidate)
    name = candidate.rails.fetch("name")
    response = request("#{RUBYGEMS_API}/api/v2/rubygems/#{name}/versions/#{candidate.version}.json")
    return nil if response.is_a?(Net::HTTPNotFound)
    release = response_json(response, "RubyGems package")
    required = release.is_a?(Hash) && %w[name version sha platform gem_uri].all? { |field| release.key?(field) }
    raise ReleaseWorkflow::Permanent, "RubyGems package registry metadata is unverifiable; no write attempted" unless required
    release
  end

  def response_json(response, label)
    unless response.is_a?(Net::HTTPSuccess)
      raise ReleaseWorkflow::Retryable, "#{label} registry query returned HTTP #{response.code}; no write attempted"
    end
    JSON.parse(response.body)
  rescue JSON::ParserError
    raise ReleaseWorkflow::Permanent, "#{label} registry metadata is unverifiable; no write attempted"
  end

  def metadata!(label, release, expected)
    actual_name = release["name"] || release.dig("meta", "app")
    actual_version = release["version"]
    raise ReleaseWorkflow::Permanent, "#{label} public metadata mismatches the preserved candidate" unless actual_name == expected.fetch("name") && actual_version == expected.fetch("version")
    if expected["platform"] && release["platform"] != expected["platform"]
      raise ReleaseWorkflow::Permanent, "#{label} public platform mismatches the preserved candidate"
    end
  end

  def compare!(label, actual, expected)
    raise ReleaseWorkflow::Permanent, "#{label} public artifact checksum mismatches the preserved candidate" unless actual.to_s.downcase == expected
  end

  def docs_archive_url(candidate)
    "#{HEX_REPO}/docs/#{candidate.hex.fetch("name")}-#{candidate.version}.tar.gz"
  end

  def public_bytes!(label, url, expected_sha256)
    response = request(url, redirects: 2)
    raise ReleaseWorkflow::Retryable, "#{label} public artifact is not readable yet" unless response.is_a?(Net::HTTPSuccess)

    compare!(label, Digest::SHA256.hexdigest(response.body), expected_sha256)
  end

  def hex_write(url, body, label)
    key = ENV["HEX_API_KEY"]
    raise ReleaseWorkflow::Permanent, "protected Hex publishing credential is unavailable" if key.to_s.empty?

    response = request(url, method: :post, body: body, headers: {"authorization" => key, "content-type" => "application/octet-stream"})
    return true if response.is_a?(Net::HTTPSuccess)
    raise ReleaseWorkflow::Retryable, "#{label} publication result is ambiguous; resume to reconcile public state" if response.code.to_i >= 500

    raise ReleaseWorkflow::Permanent, "#{label} registry rejected the preserved artifact with HTTP #{response.code}; no retry write attempted"
  rescue Net::OpenTimeout, Net::ReadTimeout, IOError, SystemCallError
    raise ReleaseWorkflow::Retryable, "#{label} publication result is ambiguous; resume to reconcile public state"
  end

  def request(url, method: :get, body: nil, headers: {}, redirects: 0)
    uri = URI(url)
    request = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
    headers.each { |name, value| request[name] = value }
    request.body = body if body
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 30) { |http| http.request(request) }
    if response.is_a?(Net::HTTPRedirection) && redirects.positive?
      location = response["location"]
      raise ReleaseWorkflow::Permanent, "public registry redirect is unverifiable" unless location
      return request(location, redirects: redirects - 1)
    end
    response
  rescue Net::OpenTimeout, Net::ReadTimeout, IOError, SystemCallError
    raise ReleaseWorkflow::Retryable, "public registry request timed out; no credential or response body was logged"
  end

  def run!(environment, *arguments, label:)
    _output, _error, status = Open3.capture3(environment, *arguments)
    raise ReleaseWorkflow::Retryable, "#{label} failed; retry is bounded and command output remains redacted" unless status.success?
    true
  rescue Errno::ENOENT
    raise ReleaseWorkflow::Permanent, "#{label} tool is unavailable"
  end
end

class ReleaseGitHub
  def initialize(candidate:, state_path:)
    @candidate = candidate
    @state_path = state_path
  end

  def verify_release_identity!
    release = release_view
    target = release.fetch("targetCommitish")
    raise ReleaseWorkflow::Permanent, "prepared GitHub Release targets a different source commit" unless target == @candidate.source_commit
    expected = ["release-manifest.json", @candidate.rails.fetch("filename"), @candidate.hex.fetch("filename"), @candidate.hex_docs.fetch("filename")]
    assets = release.fetch("assets").map { |asset| asset.fetch("name") }
    missing = expected - assets
    raise ReleaseWorkflow::Permanent, "prepared GitHub Release omits preserved assets: #{missing.join(", ")}" unless missing.empty?
    true
  end

  def upload_checkpoint
    run!("gh", "release", "upload", @candidate.tag, @state_path, "--clobber", label: "release checkpoint upload")
  end

  def ensure_tag(candidate)
    fetch_tag(candidate.tag)
    type, _error, status = capture("git", "cat-file", "-t", "refs/tags/#{candidate.tag}")
    if status.success?
      raise ReleaseWorkflow::Permanent, "product tag exists but is not annotated" unless type.strip == "tag"
      local_commit, = capture("git", "rev-parse", "refs/tags/#{candidate.tag}^{commit}")
      raise ReleaseWorkflow::Permanent, "product tag points at a different source commit" unless local_commit.strip == candidate.source_commit
    else
      run!("git", "-c", "user.name=github-actions[bot]", "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
        "tag", "-a", candidate.tag, candidate.source_commit, "-m", "Pi Browser Taskbar #{candidate.version}", label: "annotated product tag creation")
    end

    run!("git", "push", "origin", "refs/tags/#{candidate.tag}", label: "annotated product tag push") unless remote_tag_commit(candidate.tag)
    verify_tag(candidate)
  end

  def verify_tag(candidate)
    commit = remote_tag_commit(candidate.tag)
    raise ReleaseWorkflow::Permanent, "product tag is absent or unverifiable" unless commit
    raise ReleaseWorkflow::Permanent, "product tag points at a different source commit" unless commit == candidate.source_commit
    true
  end

  def announce(_candidate)
    release = release_view
    return true unless release.fetch("isDraft")

    run!("gh", "release", "edit", @candidate.tag, "--draft=false", "--latest", label: "GitHub Release announcement")
    verify_announcement(@candidate)
  end

  def verify_announcement(_candidate)
    raise ReleaseWorkflow::Permanent, "GitHub Release remains a draft" if release_view.fetch("isDraft")
    true
  end

  private

  def release_view
    output, _error, status = capture("gh", "release", "view", @candidate.tag, "--json", "isDraft,targetCommitish,assets")
    raise ReleaseWorkflow::Permanent, "prepared GitHub Release is missing or unverifiable" unless status.success?
    JSON.parse(output)
  rescue JSON::ParserError, KeyError, TypeError
    raise ReleaseWorkflow::Permanent, "prepared GitHub Release metadata is invalid"
  end

  def fetch_tag(tag)
    capture("git", "fetch", "--force", "origin", "refs/tags/#{tag}:refs/tags/#{tag}")
  end

  def remote_tag_commit(tag)
    output, _error, status = capture("git", "ls-remote", "origin", "refs/tags/#{tag}^{}")
    raise ReleaseWorkflow::Retryable, "product tag query failed; resume to reconcile exact GitHub state" unless status.success?
    output.lines.first&.split&.first
  end

  def run!(*arguments, label:)
    _output, _error, status = capture(*arguments)
    raise ReleaseWorkflow::Retryable, "#{label} result is ambiguous; resume to reconcile exact GitHub state" unless status.success?
    true
  end

  def capture(*arguments)
    Open3.capture3(*arguments)
  rescue Errno::ENOENT
    ["", "", Struct.new(:success?).new(false)]
  end
end
