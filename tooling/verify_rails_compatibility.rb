# frozen_string_literal: true

require "json"
require "open3"
require "rubygems"

root = File.expand_path("..", __dir__)
config = JSON.parse(File.read(File.join(root, "tooling/compatibility.json")))
rails = config.fetch("rails")
rows = rails.fetch("release_rows")
errors = []
check = ->(condition, message) { errors << message unless condition }

required_keys = %w[id puma rails ruby]
rows.each do |row|
  check.call(row.keys.sort == required_keys, "#{row.fetch("id", "unknown row")} has unexpected fields")
  check.call(row.fetch("rails").match?(/\A\d+\.\d+\.\d+(?:\.\d+)?\z/), "#{row.fetch("id")} does not pin a stable Rails patch")
  check.call(row.fetch("ruby").match?(/\A\d+\.\d+\.\d+\z/), "#{row.fetch("id")} does not pin a stable Ruby patch")
end
check.call(rows.map { |row| row.fetch("id") }.uniq.length == rows.length, "Rails matrix row ids are not unique")

minimum_rubies = {"7.1" => "2.7.0", "7.2" => "3.1.0", "8.0" => "3.2.0", "8.1" => "3.2.0"}
minimum_rows = rows.group_by { |row| row.fetch("rails").split(".").first(2).join(".") }
check.call(minimum_rows.keys.sort == minimum_rubies.keys.sort, "Rails matrix must contain every stable series from 7.1 through 8.1")
minimum_rubies.each do |series, ruby|
  matching = minimum_rows.fetch(series, []).select { |row| row.fetch("ruby") == ruby }
  check.call(matching.length == 1, "Rails #{series} must run once at upstream minimum Ruby #{ruby}")
end
latest_rows = rows.select { |row| row.fetch("rails") == rails.fetch("latest_framework") }
check.call(latest_rows.any? { |row| row.fetch("ruby") == rails.fetch("latest_language") }, "newest Rails must run on newest stable Ruby")
check.call(rows.first&.fetch("rails", "")&.start_with?("#{rails.fetch("framework_floor")}.") && rows.first&.fetch("ruby", "")&.start_with?("#{rails.fetch("language_floor")}.") , "Rails 7.1/Ruby 2.7 first-release floor is missing")
check.call(rows.map { |row| row.fetch("puma") }.sort == %w[clustered phased preloaded single single], "supported Puma modes are not assigned across the release rows")

pr_ids = rails.fetch("pull_request_rows")
check.call(pr_ids.length == 2 && pr_ids.first == rows.first.fetch("id") && pr_ids.last == rows.last.fetch("id"), "pull-request matrix must contain only floor and newest boundaries")

%w[pull_request release].each do |profile|
  output, status = Open3.capture2e("ruby", File.join(root, "tooling/rails_compatibility_matrix.rb"), profile)
  check.call(status.success?, "#{profile} matrix command failed: #{output}")
  next unless status.success?
  selected = JSON.parse(output).fetch("include")
  expected = profile == "release" ? rows : rows.select { |row| pr_ids.include?(row.fetch("id")) }
  check.call(selected == expected, "#{profile} matrix output differs from compatibility configuration")
end

gemspec = File.read(File.join(root, "packages/rails/pi-browser-taskbar-rails.gemspec"))
check.call(gemspec.include?(%(required_ruby_version = ">= #{rails.fetch("language_floor")}")), "gem Ruby floor differs from matrix")
check.call(gemspec.include?(%(add_runtime_dependency "rails", ">= #{rails.fetch("framework_floor")}", "< 8.2")), "gem Rails bounds differ from tested series")
workflow = File.read(File.join(root, ".github/workflows/rails-compatibility.yml")) rescue ""
%w[pull_request workflow_dispatch].each { |trigger| check.call(workflow.include?(trigger), "Rails compatibility workflow omits #{trigger}") }
check.call(workflow.include?("rails_compatibility_matrix.rb") && workflow.include?("verify_rails_evidence.rb") && workflow.include?("upload-artifact"), "Rails compatibility workflow does not execute configured rows, validate evidence, and preserve it")
harness = File.read(File.join(root, "tooling/test/rails_clean_app_conformance.sh"))
[
  "rails new", "pi-browser-taskbar-rails-$version.gem", "loaded Rails gem", "Rails::VERSION::STRING",
  "rails_puma_conformance", "production isolation", "uninstall conformance"
].each { |seam| check.call(harness.include?(seam), "clean Rails harness omits #{seam}") }

doc = File.read(File.join(root, "docs/compatibility.md"))
rows.each do |row|
  [row.fetch("rails"), row.fetch("ruby"), row.fetch("puma")].each do |value|
    check.call(doc.include?(value), "compatibility guide omits tested row value #{value}")
  end
end
check.call(doc.include?(rails.fetch("verified_at")) && doc.include?("MRI") && doc.include?("Linux"), "compatibility guide omits evidence date or claim boundary")

if errors.empty?
  puts "Rails compatibility matrix, package floor, workflow, harness, and claims are synchronized"
else
  warn errors.join("\n")
  exit 1
end
