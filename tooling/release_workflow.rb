# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"

class ReleaseWorkflow
  class Failure < StandardError; end
  class Retryable < Failure; end
  class Permanent < Failure; end

  STAGES = %w[prepared hex_package_verified hex_docs_verified rubygems_verified tagged announced].freeze

  class Candidate
    attr_reader :directory, :manifest, :manifest_sha256

    def initialize(directory)
      @directory = File.expand_path(directory)
      manifest_path = File.join(@directory, "release-manifest.json")
      @manifest = JSON.parse(File.read(manifest_path))
      @manifest_sha256 = Digest::SHA256.file(manifest_path).hexdigest
      validate!
    rescue Errno::ENOENT, JSON::ParserError, KeyError, TypeError, NoMethodError => error
      raise Permanent, "preserved release candidate is invalid: #{error.message}"
    end

    def version = manifest.fetch("product_version")
    def source_commit = manifest.dig("source", "commit")
    def repository = manifest.dig("source", "repository")
    def tag = "v#{version}"
    def rails = artifact("rails")
    def hex = artifact("phoenix")
    def hex_docs = manifest.fetch("hex_docs")

    def path(entry)
      File.join(directory, entry.fetch("filename"))
    end

    private

    def artifact(distribution)
      manifest.fetch("artifacts").find { |item| item["distribution"] == distribution } ||
        raise(Permanent, "release manifest omits the #{distribution} artifact")
    end

    def validate!
      raise Permanent, "unsupported release manifest version" unless manifest["manifest_version"] == 1
      raise Permanent, "release version must be semantic x.y.z" unless version.match?(/\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z/)
      raise Permanent, "release source commit must be a full lowercase Git SHA" unless source_commit&.match?(/\A[0-9a-f]{40}\z/)
      raise Permanent, "release source ref must be protected main" unless manifest.dig("source", "ref") == "refs/heads/main"

      [rails, hex, hex_docs].each do |entry|
        filename = entry.fetch("filename")
        raise Permanent, "release artifact filename is unsafe" unless File.basename(filename) == filename
        artifact_path = path(entry)
        raise Permanent, "preserved release artifact #{filename} is missing" unless File.file?(artifact_path)
        raise Permanent, "preserved release artifact #{filename} byte count mismatches its manifest" unless File.size(artifact_path) == entry.fetch("bytes")
        digest = Digest::SHA256.file(artifact_path).hexdigest
        raise Permanent, "preserved release artifact #{filename} checksum mismatches its manifest" unless secure_equal?(digest, entry.fetch("sha256"))
        raise Permanent, "preserved release artifact #{filename} version mismatches the release" unless entry.fetch("version") == version
      end
    end

    def secure_equal?(left, right)
      right = right.to_s
      left.bytesize == right.bytesize && left.bytes.zip(right.bytes).all? { |a, b| a == b }
    end
  end

  module State
    module_function

    def initial(candidate, now, break_glass: nil)
      document = {
        "state_version" => 1,
        "manifest_sha256" => candidate.manifest_sha256,
        "product_version" => candidate.version,
        "source_commit" => candidate.source_commit,
        "stage" => "prepared",
        "checkpoints" => [{"stage" => "prepared", "at" => now}]
      }
      document["break_glass"] = break_glass if break_glass
      document
    end

    def load(path, candidate)
      document = JSON.parse(File.read(path))
      raise Permanent, "unsupported release state version" unless document["state_version"] == 1
      raise Permanent, "release state belongs to a different manifest" unless document["manifest_sha256"] == candidate.manifest_sha256
      raise Permanent, "release state belongs to a different version or source commit" unless document.values_at("product_version", "source_commit") == [candidate.version, candidate.source_commit]
      raise Permanent, "release state has an unknown checkpoint" unless STAGES.include?(document["stage"])
      checkpoints = document["checkpoints"]
      valid_checkpoints = checkpoints.is_a?(Array) && checkpoints.all? { |item| item.is_a?(Hash) && STAGES.include?(item["stage"]) && item["at"].is_a?(String) }
      raise Permanent, "release state checkpoint history is invalid" unless valid_checkpoints
      raise Permanent, "release version is recorded incomplete; prepare a coordinated patch after incident handling" if document["incomplete"]
      document
    rescue Errno::ENOENT
      raise Permanent, "release state is missing; use constrained break-glass resume with the exact manifest digest"
    rescue JSON::ParserError, KeyError, TypeError => error
      raise Permanent, "release state is invalid: #{error.message}"
    end
  end

  def initialize(candidate:, state_path:, registry:, github:, checkpoint: ->(_state) {}, now: -> { Time.now.utc.iso8601 }, sleeper: ->(seconds) { sleep(seconds) }, retries: 7, retry_delays: [2, 5, 10, 20, 30, 45])
    @candidate = candidate
    @state_path = state_path
    @registry = registry
    @github = github
    @checkpoint = checkpoint
    @now = now
    @sleeper = sleeper
    @retries = retries
    @retry_delays = retry_delays
  end

  def publish_resume
    @state = State.load(@state_path, @candidate)
    run_publish
  rescue Permanent => error
    record_incomplete(error) if @state && stage_index(@state.fetch("stage")) >= stage_index("hex_package_verified")
    raise
  end

  def break_glass_resume(expected_manifest_sha256:, reason:)
    raise Permanent, "break-glass reason is required" if reason.to_s.strip.empty?
    raise Permanent, "break-glass manifest digest does not match the preserved candidate" unless expected_manifest_sha256 == @candidate.manifest_sha256
    raise Permanent, "break-glass recovery only applies when release-state.json is missing" if File.exist?(@state_path)

    @state = State.initial(@candidate, @now.call, break_glass: {"reason" => reason.to_s.strip, "at" => @now.call})
    persist
    run_publish
  rescue Permanent => error
    record_incomplete(error) if @state && stage_index(@state.fetch("stage")) >= stage_index("hex_package_verified")
    raise
  end

  def verify
    @state = State.load(@state_path, @candidate)
    verify_registries
    @github.verify_tag(@candidate) if reached?("tagged")
    @github.verify_announcement(@candidate) if reached?("announced")
    true
  end

  private

  def run_publish
    reconcile("hex_package_verified", -> { @registry.hex_package(@candidate) }, -> { @registry.publish_hex_package(@candidate) }, -> { @registry.verify_hex_package(@candidate) })
    reconcile("hex_docs_verified", -> { @registry.hex_docs(@candidate) }, -> { @registry.publish_hex_docs(@candidate) }, -> { @registry.verify_hex_docs(@candidate) })
    reconcile("rubygems_verified", -> { @registry.rubygem(@candidate) }, -> { @registry.publish_rubygem(@candidate) }, -> { @registry.verify_rubygem(@candidate) })

    # Recheck every public surface immediately before the irreversible announcement gates.
    verify_registries
    unless reached?("tagged")
      @github.ensure_tag(@candidate)
      advance("tagged")
    end
    @github.verify_tag(@candidate)
    unless reached?("announced")
      @github.announce(@candidate)
      advance("announced")
    end
    @github.verify_announcement(@candidate)
    true
  end

  def reconcile(stage, observe, publish, verify)
    return if reached?(stage)

    status = retry_read(&observe)
    publish.call if status == :absent
    retry_read(&verify)
    advance(stage)
  end

  def verify_registries
    retry_read { @registry.verify_hex_package(@candidate) }
    retry_read { @registry.verify_hex_docs(@candidate) }
    retry_read { @registry.verify_rubygem(@candidate) }
  end

  def retry_read
    attempts = 0
    begin
      attempts += 1
      yield
    rescue Retryable
      raise if attempts >= @retries

      @sleeper.call(@retry_delays.fetch(attempts - 1, @retry_delays.last))
      retry
    end
  end

  def reached?(stage)
    stage_index(@state.fetch("stage")) >= stage_index(stage)
  end

  def stage_index(stage)
    STAGES.index(stage) || raise(Permanent, "unknown release checkpoint #{stage.inspect}")
  end

  def advance(stage)
    @state["stage"] = stage
    @state.fetch("checkpoints") << {"stage" => stage, "at" => @now.call}
    persist
  end

  def record_incomplete(error)
    return if @state["incomplete"]

    @state["incomplete"] = {"at" => @now.call, "reason" => error.message}
    persist
  end

  def persist
    temporary = "#{@state_path}.tmp"
    File.write(temporary, JSON.pretty_generate(@state) + "\n")
    File.rename(temporary, @state_path)
    @checkpoint.call(@state)
  end
end
