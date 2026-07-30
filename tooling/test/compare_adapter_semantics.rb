# frozen_string_literal: true

require "json"

root = File.expand_path("../..", __dir__)
rails = JSON.parse(File.read(File.join(root, "build/conformance/rails.json")))
phoenix = JSON.parse(File.read(File.join(root, "build/conformance/phoenix.json")))

unless rails == phoenix
  warn "Rails/Phoenix semantic drift detected"
  warn "Rails: #{JSON.pretty_generate(rails)}"
  warn "Phoenix: #{JSON.pretty_generate(phoenix)}"
  exit 1
end

puts "Rails/Phoenix semantics match after removing only IDs and timestamps"
