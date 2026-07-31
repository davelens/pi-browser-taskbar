#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "release_workflow"
require_relative "release_services"

operation = ARGV.shift
candidate_directory = ARGV.shift
abort "usage: #{$PROGRAM_NAME} publish-resume|verify|break-glass-resume CANDIDATE_DIRECTORY" unless ARGV.empty? && operation && candidate_directory

begin
  candidate = ReleaseWorkflow::Candidate.new(candidate_directory)
  root = File.expand_path("..", __dir__)
  checked_version = File.read(File.join(root, "VERSION")).strip
  checked_commit = IO.popen(["git", "-C", root, "rev-parse", "HEAD"], &:read).strip
  raise ReleaseWorkflow::Permanent, "preserved candidate version differs from the checked-out source" unless candidate.version == checked_version
  raise ReleaseWorkflow::Permanent, "preserved candidate commit differs from the checked-out source" unless candidate.source_commit == checked_commit
  if ENV["GITHUB_REPOSITORY"] && candidate.repository != ENV["GITHUB_REPOSITORY"]
    raise ReleaseWorkflow::Permanent, "preserved candidate belongs to a different repository"
  end

  state_path = File.join(candidate.directory, "release-state.json")
  github = ReleaseGitHub.new(candidate: candidate, state_path: state_path)
  github.verify_release_identity!
  workflow = ReleaseWorkflow.new(
    candidate: candidate,
    state_path: state_path,
    registry: ReleaseRegistry.new,
    github: github,
    checkpoint: ->(_state) { github.upload_checkpoint }
  )

  case operation
  when "publish-resume"
    workflow.publish_resume
  when "verify"
    workflow.verify
  when "break-glass-resume"
    workflow.break_glass_resume(
      expected_manifest_sha256: ENV.fetch("RELEASE_MANIFEST_SHA256"),
      reason: ENV.fetch("RELEASE_BREAK_GLASS_REASON")
    )
  else
    raise ReleaseWorkflow::Permanent, "unknown coordinated release operation"
  end
  puts "coordinated release #{operation} completed for #{candidate.tag} at #{candidate.source_commit}"
rescue KeyError, ReleaseWorkflow::Failure => error
  abort "coordinated release stopped safely: #{error.message}"
end
