# frozen_string_literal: true

require "digest"
require "json"
require "minitest/autorun"
require "shellwords"
require "tmpdir"
require_relative "../release_gate"

class ReleaseGateTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_writes_manifest_checksums_and_release_notes_from_existing_artifacts
    version = File.read(File.join(ROOT, "VERSION")).strip
    commit = `git -C #{ROOT.shellescape} rev-parse HEAD`.strip

    Dir.mktmpdir("release-gate") do |directory|
      ReleaseGate.new(ROOT).prepare(
        output: directory,
        source_commit: commit,
        source_ref: "refs/heads/main",
        repository: "davelens/pi-browser-taskbar",
        workflow_run: "test-run",
        workflow_attempt: "1",
        verify_workspace: false,
        require_acceptance: false
      )

      manifest = JSON.parse(File.read(File.join(directory, "release-manifest.json")))
      assert_equal version, manifest.fetch("product_version")
      assert_equal 1, manifest.fetch("contract_version")
      assert_equal commit, manifest.dig("source", "commit")
      assert_equal %w[phoenix rails], manifest.fetch("artifacts").map { |entry| entry.fetch("distribution") }.sort

      manifest.fetch("artifacts").each do |entry|
        path = File.join(ROOT, "build", entry.fetch("filename"))
        assert_equal File.size(path), entry.fetch("bytes")
        assert_equal Digest::SHA256.file(path).hexdigest, entry.fetch("sha256")
      end

      checksums = File.read(File.join(directory, "SHA256SUMS"))
      manifest.fetch("artifacts").each do |entry|
        assert_includes checksums, "#{entry.fetch("sha256")}  #{entry.fetch("filename")}"
      end
      assert_includes File.read(File.join(directory, "RELEASE_NOTES.md")), "Pi Browser Taskbar #{version}"
    end
  end

  def test_rejects_source_identity_other_than_head
    error = assert_raises(ReleaseGate::Failure) do
      ReleaseGate.new(ROOT).prepare(
        output: Dir.mktmpdir,
        source_commit: "0" * 40,
        source_ref: "refs/heads/main",
        repository: "davelens/pi-browser-taskbar",
        workflow_run: "test-run",
        workflow_attempt: "1",
        verify_workspace: false,
        require_acceptance: false
      )
    end
    assert_match(/source commit/, error.message)
  end

  def test_check_run_gate_requires_every_release_matrix_row_on_the_source_commit
    commit = "a" * 40
    compatibility = JSON.parse(File.read(File.join(ROOT, "tooling/compatibility.json")))
    names = ["verify"]
    names.concat(compatibility.dig("rails", "release_rows").map { |row| "#{row.fetch("id")} / Puma #{row.fetch("puma")}" })
    names.concat(compatibility.dig("phoenix", "release_rows").map { |row| row.fetch("id") })
    runs = names.each_with_index.map do |name, index|
      {"id" => index, "name" => name, "head_sha" => commit, "status" => "completed", "conclusion" => "success"}
    end

    Dir.mktmpdir("release-checks") do |directory|
      path = File.join(directory, "checks.json")
      File.write(path, JSON.generate("check_runs" => runs))
      assert ReleaseGate.new(ROOT).verify_check_runs(path, commit)

      runs.last["conclusion"] = "failure"
      File.write(path, JSON.generate("check_runs" => runs))
      error = assert_raises(ReleaseGate::Failure) { ReleaseGate.new(ROOT).verify_check_runs(path, commit) }
      assert_match(/#{Regexp.escape(names.last)}: completed\/failure/, error.message)
    end
  end

  def test_manual_evidence_is_explicitly_pending
    Dir.mktmpdir("release-evidence") do |directory|
      error = assert_raises(ReleaseGate::Failure) { ReleaseGate.new(ROOT).verify_manual_evidence(directory) }
      assert_match(/manual release evidence is pending/, error.message)
      assert_match(/accessibility/, error.message)
      assert_match(/real Pi/, error.message)
    end
  end
end
