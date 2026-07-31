# frozen_string_literal: true

require "json"

root = File.expand_path("..", __dir__)
rails = JSON.parse(File.read(File.join(root, "tooling/compatibility.json"))).fetch("rails")
profile = ARGV.fetch(0, "release")
rows = rails.fetch("release_rows")
rows = rows.select { |row| rails.fetch("pull_request_rows").include?(row.fetch("id")) } if profile == "pull_request"
abort "profile must be pull_request or release" unless %w[pull_request release].include?(profile)
puts JSON.generate("include" => rows)
