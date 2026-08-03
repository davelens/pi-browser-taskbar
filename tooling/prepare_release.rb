#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "release_gate"

root = File.expand_path("..", __dir__)
command = ARGV.shift || "prepare"
gate = ReleaseGate.new(root)

begin
  case command
  when "prepare"
    abort "usage: #{$PROGRAM_NAME} prepare OUTPUT" unless ARGV.length == 1
    gate.prepare(
      output: ARGV.fetch(0),
      source_commit: ENV.fetch("RELEASE_SOURCE_COMMIT"),
      source_ref: ENV.fetch("RELEASE_SOURCE_REF", "refs/heads/main"),
      repository: ENV.fetch("GITHUB_REPOSITORY", "davelens/pi-browser-taskbar"),
      workflow_run: ENV.fetch("GITHUB_RUN_ID", "local"),
      workflow_attempt: ENV.fetch("GITHUB_RUN_ATTEMPT", "1")
    )
  when "verify-check-runs"
    abort "usage: #{$PROGRAM_NAME} verify-check-runs CHECK_RUNS_JSON COMMIT" unless ARGV.length == 2
    gate.verify_check_runs(*ARGV)
    puts "complete verify and compatibility checks passed on the release commit"
  else
    abort "unknown command #{command.inspect}"
  end
rescue KeyError, ReleaseGate::Failure => error
  abort "release gate failed: #{error.message}"
end
