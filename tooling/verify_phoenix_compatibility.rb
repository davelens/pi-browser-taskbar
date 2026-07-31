# frozen_string_literal: true

require "json"
require "open3"

root = File.expand_path("..", __dir__)
phoenix = JSON.parse(File.read(File.join(root, "tooling/compatibility.json"))).fetch("phoenix")
rows = phoenix.fetch("release_rows")
errors = []
check = ->(condition, message) { errors << message unless condition }

required_keys = %w[elixir id live_view otp phoenix]
rows.each do |row|
  check.call(row.keys.sort == required_keys, "#{row.fetch("id", "unknown row")} has unexpected fields")
  %w[phoenix elixir otp live_view].each do |key|
    check.call(row.fetch(key).match?(/\A\d+\.\d+\.\d+(?:\.\d+)?\z/), "#{row.fetch("id")} does not pin a stable #{key} version")
  end
end
check.call(rows.map { |row| row.fetch("id") }.uniq.length == rows.length, "Phoenix matrix row ids are not unique")

minimum_elixirs = {"1.7" => "1.11.4", "1.8" => "1.15.8"}
series_rows = rows.group_by { |row| row.fetch("phoenix").split(".").first(2).join(".") }
check.call(series_rows.keys.sort == minimum_elixirs.keys.sort, "Phoenix matrix must contain every stable series from 1.7 through 1.8")
minimum_elixirs.each do |series, elixir|
  matching = series_rows.fetch(series, []).select { |row| row.fetch("elixir") == elixir }
  check.call(matching.length == 1, "Phoenix #{series} must run once at upstream minimum Elixir #{elixir}")
end
latest_rows = rows.select { |row| row.fetch("phoenix") == phoenix.fetch("latest_framework") }
check.call(latest_rows.any? { |row| row.fetch("elixir") == phoenix.fetch("latest_language") }, "newest Phoenix must run on newest stable Elixir")
check.call(rows.first&.fetch("phoenix", "")&.start_with?("#{phoenix.fetch("framework_floor")}.") && rows.first&.fetch("elixir", "")&.start_with?("#{phoenix.fetch("language_floor")}.") , "Phoenix 1.7/Elixir 1.11 first-release floor is missing")

pr_ids = phoenix.fetch("pull_request_rows")
check.call(pr_ids.length == 2 && pr_ids == [rows.first.fetch("id"), rows.last.fetch("id")], "pull-request matrix must contain only floor and newest boundaries")
%w[pull_request release].each do |profile|
  output, status = Open3.capture2e("ruby", File.join(root, "tooling/phoenix_compatibility_matrix.rb"), profile)
  check.call(status.success?, "#{profile} matrix command failed: #{output}")
  next unless status.success?
  selected = JSON.parse(output).fetch("include")
  expected = profile == "release" ? rows : rows.select { |row| pr_ids.include?(row.fetch("id")) }
  check.call(selected == expected, "#{profile} matrix output differs from compatibility configuration")
end

mix = File.read(File.join(root, "packages/phoenix/mix.exs"))
check.call(mix.include?(%(elixir: ">= #{phoenix.fetch("language_floor")}.0")), "package Elixir floor differs from matrix")
check.call(mix.include?(%({:phoenix, ">= #{phoenix.fetch("framework_floor")}.0 and < 2.0.0")), "package Phoenix bounds differ from tested series")
workflow = File.read(File.join(root, ".github/workflows/phoenix-compatibility.yml")) rescue ""
%w[pull_request workflow_dispatch].each { |trigger| check.call(workflow.include?(trigger), "Phoenix compatibility workflow omits #{trigger}") }
check.call(workflow.include?("phoenix_compatibility_matrix.rb") && workflow.include?("verify_phoenix_evidence.rb") && workflow.include?("upload-artifact"), "Phoenix compatibility workflow does not execute configured rows, validate evidence, and preserve it")
harness = File.read(File.join(root, "tooling/test/phoenix_clean_app_conformance.sh"))
[
  "mix phx.new", "pi_browser_taskbar_phoenix-$version.tar", "repo: \"pbtlocal\"", "Hex.SCM",
  "System.version", "System.otp_release", "production isolation", "uninstall and test isolation",
  "data-phx-loc", "TaskbarExampleWeb.ScenarioLive"
].each { |seam| check.call(harness.include?(seam), "clean Phoenix harness omits #{seam}") }

doc = File.read(File.join(root, "docs/compatibility.md"))
rows.each do |row|
  %w[phoenix elixir otp live_view].each do |key|
    check.call(doc.include?(row.fetch(key)), "compatibility guide omits tested row value #{row.fetch(key)}")
  end
end
check.call(doc.include?(phoenix.fetch("verified_at")) && doc.include?("standard Erlang/Elixir runtime") && doc.include?("Linux"), "compatibility guide omits evidence date or claim boundary")

if errors.empty?
  puts "Phoenix compatibility matrix, package floors, workflow, harness, and claims are synchronized"
else
  warn errors.join("\n")
  exit 1
end
