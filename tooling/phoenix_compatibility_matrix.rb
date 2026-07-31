# frozen_string_literal: true

require "json"

root = File.expand_path("..", __dir__)
phoenix = JSON.parse(File.read(File.join(root, "tooling/compatibility.json"))).fetch("phoenix")
profile = ARGV.fetch(0, "release")
abort "profile must be pull_request or release" unless %w[pull_request release].include?(profile)
rows = phoenix.fetch("release_rows")
rows = rows.select { |row| phoenix.fetch("pull_request_rows").include?(row.fetch("id")) } if profile == "pull_request"
puts JSON.generate("include" => rows)
