# frozen_string_literal: true

require "digest"
require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../release_workflow"

class ReleaseWorkflowTest < Minitest::Test
  VERSION = "1.2.3"
  COMMIT = "a" * 40

  class FakeRegistry
    attr_reader :writes, :checks
    attr_accessor :hex, :docs, :gem

    def initialize(hex: :absent, docs: :absent, gem: :absent)
      @hex = hex
      @docs = docs
      @gem = gem
      @writes = []
      @checks = []
    end

    def hex_package(candidate)
      observe(:hex, @hex, candidate.hex.fetch("sha256"))
    end

    def publish_hex_package(candidate)
      @writes << :hex
      ambiguous = @hex == :publish_timeout
      @hex = candidate.hex.fetch("sha256")
      raise ReleaseWorkflow::Retryable, "Hex package publication result is ambiguous; resume to reconcile public state" if ambiguous
    end

    def verify_hex_package(candidate)
      @checks << :hex
      exact!(:hex, @hex, candidate.hex.fetch("sha256"))
    end

    def hex_docs(candidate)
      observe(:docs, @docs, candidate.hex_docs.fetch("sha256"))
    end

    def publish_hex_docs(candidate)
      @writes << :docs
      @docs = candidate.hex_docs.fetch("sha256") unless @docs == :timeout
      raise ReleaseWorkflow::Retryable, "Hex documentation publication result is ambiguous; resume to reconcile public state" if @docs == :timeout
    end

    def verify_hex_docs(candidate)
      @checks << :docs
      exact!(:docs, @docs, candidate.hex_docs.fetch("sha256"))
    end

    def rubygem(candidate)
      observe(:gem, @gem, candidate.rails.fetch("sha256"))
    end

    def publish_rubygem(candidate)
      @writes << :gem
      @gem = candidate.rails.fetch("sha256") unless @gem == :timeout
      raise ReleaseWorkflow::Retryable, "RubyGems publication result is ambiguous; resume to reconcile public state" if @gem == :timeout
    end

    def verify_rubygem(candidate)
      @checks << :gem
      exact!(:gem, @gem, candidate.rails.fetch("sha256"))
    end

    private

    def observe(label, value, checksum)
      @checks << label
      return :absent if value == :absent || value == :publish_timeout
      raise ReleaseWorkflow::Retryable, "#{label} public query timed out" if value == :timeout
      raise ReleaseWorkflow::Permanent, "#{label} public artifact checksum mismatches the preserved candidate" unless value == checksum

      :identical
    end

    def exact!(label, value, checksum)
      raise ReleaseWorkflow::Retryable, "#{label} is not publicly available yet" if value == :absent || value == :timeout
      raise ReleaseWorkflow::Permanent, "#{label} public artifact checksum mismatches the preserved candidate" unless value == checksum

      true
    end
  end

  class FakeGitHub
    attr_reader :created_tags, :announcements
    attr_accessor :tag, :announced

    def initialize(tag: nil, announced: false)
      @tag = tag
      @announced = announced
      @created_tags = []
      @announcements = 0
    end

    def ensure_tag(candidate)
      if @tag
        raise ReleaseWorkflow::Permanent, "product tag points at a different source commit" unless @tag == candidate.source_commit
      else
        @tag = candidate.source_commit
        @created_tags << candidate.tag
      end
      true
    end

    def verify_tag(candidate)
      raise ReleaseWorkflow::Permanent, "product tag is absent or mismatched" unless @tag == candidate.source_commit

      true
    end

    def announce(candidate)
      @announcements += 1 unless @announced
      @announced = true
      true
    end

    def verify_announcement(_candidate)
      raise ReleaseWorkflow::Permanent, "GitHub Release remains a draft" unless @announced

      true
    end
  end

  def test_absent_registries_publish_in_order_and_checkpoint_every_state
    with_candidate do |candidate, state_path|
      registry = FakeRegistry.new
      github = FakeGitHub.new
      checkpoints = []

      workflow(candidate, state_path, registry, github, checkpoints).publish_resume

      assert_equal %i[hex docs gem], registry.writes
      assert_equal %w[hex_package_verified hex_docs_verified rubygems_verified tagged announced], checkpoints
      assert_equal [candidate.tag], github.created_tags
      assert_equal 1, github.announcements
      assert_equal "announced", state(state_path).fetch("stage")
    end
  end

  def test_identical_public_artifacts_reconcile_without_writes
    with_candidate do |candidate, state_path|
      registry = FakeRegistry.new(
        hex: candidate.hex.fetch("sha256"),
        docs: candidate.hex_docs.fetch("sha256"),
        gem: candidate.rails.fetch("sha256")
      )
      github = FakeGitHub.new

      workflow(candidate, state_path, registry, github).publish_resume

      assert_empty registry.writes
      assert_equal "announced", state(state_path).fetch("stage")
    end
  end

  def test_mismatch_stops_without_writing_or_announcing
    with_candidate do |candidate, state_path|
      registry = FakeRegistry.new(hex: "0" * 64)
      github = FakeGitHub.new

      error = assert_raises(ReleaseWorkflow::Permanent) { workflow(candidate, state_path, registry, github).publish_resume }

      assert_match(/checksum mismatches/, error.message)
      assert_empty registry.writes
      assert_empty github.created_tags
      assert_equal 0, github.announcements
      assert_equal "prepared", state(state_path).fetch("stage")
    end
  end

  def test_ambiguous_write_resumes_by_reconciling_the_same_artifact
    with_candidate do |candidate, state_path|
      registry = FakeRegistry.new(hex: :publish_timeout)
      github = FakeGitHub.new

      assert_raises(ReleaseWorkflow::Retryable) { workflow(candidate, state_path, registry, github).publish_resume }
      assert_equal [:hex], registry.writes
      assert_equal "prepared", state(state_path).fetch("stage")

      workflow(candidate, state_path, registry, github).publish_resume

      assert_equal %i[hex docs gem], registry.writes
      assert_equal "announced", state(state_path).fetch("stage")
    end
  end

  def test_public_query_retries_are_bounded_without_a_write
    with_candidate do |candidate, state_path|
      registry = FakeRegistry.new(hex: :timeout)
      github = FakeGitHub.new

      assert_raises(ReleaseWorkflow::Retryable) { workflow(candidate, state_path, registry, github).publish_resume }

      assert_equal 4, registry.checks.count(:hex)
      assert_empty registry.writes
      assert_equal "prepared", state(state_path).fetch("stage")
    end
  end

  def test_partial_publication_rolls_forward_only_missing_artifacts
    with_candidate(stage: "hex_package_verified") do |candidate, state_path|
      registry = FakeRegistry.new(hex: candidate.hex.fetch("sha256"))
      github = FakeGitHub.new

      workflow(candidate, state_path, registry, github).publish_resume

      assert_equal %i[docs gem], registry.writes
      assert_equal "announced", state(state_path).fetch("stage")
    end
  end

  def test_tag_and_announcement_are_idempotent
    with_candidate(stage: "rubygems_verified") do |candidate, state_path|
      registry = FakeRegistry.new(
        hex: candidate.hex.fetch("sha256"),
        docs: candidate.hex_docs.fetch("sha256"),
        gem: candidate.rails.fetch("sha256")
      )
      github = FakeGitHub.new(tag: candidate.source_commit, announced: true)

      workflow(candidate, state_path, registry, github).publish_resume

      assert_empty github.created_tags
      assert_equal 0, github.announcements
      assert_equal "announced", state(state_path).fetch("stage")
    end
  end

  def test_announcement_is_gated_on_fresh_public_verification
    with_candidate(stage: "hex_docs_verified") do |candidate, state_path|
      registry = FakeRegistry.new(
        hex: candidate.hex.fetch("sha256"),
        docs: candidate.hex_docs.fetch("sha256"),
        gem: "f" * 64
      )
      github = FakeGitHub.new

      assert_raises(ReleaseWorkflow::Permanent) { workflow(candidate, state_path, registry, github).publish_resume }

      assert_empty github.created_tags
      assert_equal 0, github.announcements
      assert state(state_path).key?("incomplete")
    end
  end

  def test_verify_is_read_only_and_checks_announced_state
    with_candidate(stage: "announced") do |candidate, state_path|
      registry = FakeRegistry.new(
        hex: candidate.hex.fetch("sha256"),
        docs: candidate.hex_docs.fetch("sha256"),
        gem: candidate.rails.fetch("sha256")
      )
      github = FakeGitHub.new(tag: candidate.source_commit, announced: true)

      assert workflow(candidate, state_path, registry, github).verify
      assert_empty registry.writes
      assert_equal %i[hex docs gem], registry.checks
    end
  end

  def test_break_glass_only_recovers_a_missing_checkpoint_for_the_exact_manifest
    with_candidate(create_state: false) do |candidate, state_path|
      registry = FakeRegistry.new(
        hex: candidate.hex.fetch("sha256"),
        docs: candidate.hex_docs.fetch("sha256"),
        gem: candidate.rails.fetch("sha256")
      )
      github = FakeGitHub.new
      release = workflow(candidate, state_path, registry, github)

      assert_raises(ReleaseWorkflow::Permanent) { release.break_glass_resume(expected_manifest_sha256: "0" * 64, reason: "INC-42") }
      assert_raises(ReleaseWorkflow::Permanent) { release.break_glass_resume(expected_manifest_sha256: candidate.manifest_sha256, reason: "") }

      release.break_glass_resume(expected_manifest_sha256: candidate.manifest_sha256, reason: "INC-42")
      assert_equal "announced", state(state_path).fetch("stage")
      assert_equal "INC-42", state(state_path).dig("break_glass", "reason")
      assert_empty registry.writes
    end
  end

  def test_workflow_is_manual_protected_non_cancelling_and_uses_oidc_without_registry_writes_in_ci
    source = File.read(File.join(ROOT, ".github/workflows/coordinated-release.yml"))
    preparation = File.read(File.join(ROOT, ".github/workflows/prepare-release.yml"))

    assert_includes source, "workflow_dispatch:"
    refute_match(/push:/, source)
    assert_includes source, "cancel-in-progress: false"
    assert_includes preparation, "group: coordinated-release"
    assert_includes preparation, "cancel-in-progress: false"
    assert_includes source, "environment: coordinated-release"
    assert_includes source, "id-token: write"
    assert_match(%r{rubygems/configure-rubygems-credentials@[0-9a-f]{40}}, source)
    assert_includes source, "HEX_API_KEY: \${{ inputs.operation != 'verify' && secrets.HEX_API_KEY || '' }}"
    assert_includes source, "ruby tooling/coordinated_release.rb"
    refute_includes File.read(File.join(ROOT, ".github/workflows/verify.yml")), "coordinated_release.rb"
  end

  private

  ROOT = File.expand_path("../..", __dir__)

  def workflow(candidate, state_path, registry, github, checkpoints = [])
    ReleaseWorkflow.new(
      candidate: candidate,
      state_path: state_path,
      registry: registry,
      github: github,
      checkpoint: ->(document) { checkpoints << document.fetch("stage") },
      now: -> { "2026-07-31T00:00:00Z" },
      sleeper: ->(_seconds) {},
      retries: 4
    )
  end

  def with_candidate(stage: "prepared", create_state: true)
    Dir.mktmpdir("release-workflow") do |directory|
      artifacts = {
        "rails.gem" => "rails artifact",
        "phoenix.tar" => "hex artifact",
        "phoenix-docs.tar.gz" => "docs artifact"
      }
      artifacts.each { |name, bytes| File.binwrite(File.join(directory, name), bytes) }
      entry = lambda do |distribution, name|
        {"distribution" => distribution, "name" => distribution == "rails" ? "pi-browser-taskbar-rails" : "pi_browser_taskbar_phoenix", "version" => VERSION,
         "filename" => name, "bytes" => artifacts.fetch(name).bytesize, "sha256" => Digest::SHA256.hexdigest(artifacts.fetch(name))}
      end
      manifest = {
        "manifest_version" => 1,
        "product_version" => VERSION,
        "source" => {"repository" => "davelens/pi-browser-taskbar", "ref" => "refs/heads/main", "commit" => COMMIT},
        "artifacts" => [entry.call("rails", "rails.gem"), entry.call("phoenix", "phoenix.tar")],
        "hex_docs" => entry.call("phoenix_docs", "phoenix-docs.tar.gz")
      }
      File.write(File.join(directory, "release-manifest.json"), JSON.pretty_generate(manifest) + "\n")
      candidate = ReleaseWorkflow::Candidate.new(directory)
      state_path = File.join(directory, "release-state.json")
      if create_state
        document = ReleaseWorkflow::State.initial(candidate, "2026-07-31T00:00:00Z")
        document["stage"] = stage
        File.write(state_path, JSON.pretty_generate(document) + "\n")
      end
      yield candidate, state_path
    end
  end

  def state(path)
    JSON.parse(File.read(path))
  end
end
