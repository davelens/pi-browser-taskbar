# frozen_string_literal: true

require "json"

path = ARGV.fetch(0)
evidence = JSON.parse(File.read(path))
root = File.expand_path("..", __dir__)
rows = JSON.parse(File.read(File.join(root, "tooling/compatibility.json"))).dig("phoenix", "release_rows")
row = rows.find { |item| item.fetch("id") == evidence["row"] }
abort "evidence row is not in the release matrix" unless row

expected_checks = %w[generated_app hex_install boot route asset mutation controller_heex live_view_annotation supervision uninstall development_only no_workspace_fallback]
errors = []
errors << "unsupported evidence schema" unless evidence["schema"] == 1
errors << "evidence was not produced by the standard BEAM runtime" unless evidence.dig("platform", "runtime") == "BEAM"
errors << "evidence was not produced on Linux" unless evidence.dig("platform", "os") == "linux"
%w[elixir otp phoenix live_view].each do |version|
  errors << "#{version} evidence differs from row" unless evidence.dig("versions", version) == row.fetch(version)
end
errors << "artifact digest is malformed" unless evidence.dig("artifact", "sha256").to_s.match?(/\A[0-9a-f]{64}\z/)
errors << "artifact was not installed through Hex" unless evidence.dig("artifact", "hex_scm") == true
dependency_path = evidence.dig("artifact", "dependency_path").to_s
errors << "artifact dependency path is not isolated" unless dependency_path.include?("pi-browser-taskbar-phoenix.") && !dependency_path.include?("/packages/phoenix")
errors << "required compatibility checks are incomplete" unless evidence["checks"] == expected_checks

abort errors.join("\n") unless errors.empty?
puts "Phoenix compatibility evidence is valid for #{row.fetch("id")}"
