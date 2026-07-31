# frozen_string_literal: true

require "json"

path = ARGV.fetch(0)
evidence = JSON.parse(File.read(path))
root = File.expand_path("..", __dir__)
rows = JSON.parse(File.read(File.join(root, "tooling/compatibility.json"))).dig("rails", "release_rows")
row = rows.find { |item| item.fetch("id") == evidence["row"] }
abort "evidence row is not in the release matrix" unless row

expected_checks = %w[generated_app boot route asset mutation annotation uninstall production_disabled no_workspace_fallback]
errors = []
errors << "unsupported evidence schema" unless evidence["schema"] == 1
errors << "evidence was not produced by MRI" unless evidence.dig("platform", "engine") == "ruby"
errors << "evidence was not produced on Linux" unless evidence.dig("platform", "os").to_s.include?("linux")
errors << "Ruby evidence differs from row" unless evidence.dig("versions", "ruby") == row.fetch("ruby")
errors << "Rails evidence differs from row" unless evidence.dig("versions", "rails") == row.fetch("rails")
mode = row.fetch("puma")
errors << "Puma evidence differs from row" unless evidence.dig("puma", "mode") == mode
expected_topology = {
  "single" => [0, false], "clustered" => [2, false],
  "preloaded" => [2, true], "phased" => [2, false]
}.fetch(mode)
errors << "Puma worker/preload evidence differs from row" unless [evidence.dig("puma", "workers"), evidence.dig("puma", "preload")] == expected_topology
errors << "artifact digest is malformed" unless evidence.dig("artifact", "sha256").to_s.match?(/\A[0-9a-f]{64}\z/)
errors << "artifact was not loaded from the isolated gem home" unless evidence.dig("artifact", "loaded_from_isolated_gem_home") == true
errors << "required compatibility checks are incomplete" unless evidence["checks"] == expected_checks
if row.fetch("puma") == "phased"
  errors << "phased restart continuity is missing" unless evidence.dig("puma", "phased_restart") == true && evidence.dig("puma", "session_continuity") == true
end

abort errors.join("\n") unless errors.empty?
puts "Rails compatibility evidence is valid for #{row.fetch("id")}"
