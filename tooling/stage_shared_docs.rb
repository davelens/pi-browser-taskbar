# frozen_string_literal: true

require "fileutils"

root = File.expand_path("..", __dir__)
sources = %w[
  contract/docs/index.md
  contract/traceability.json
  contract/traceability.md
  docs/accessibility-acceptance.md
  docs/security.md
  docs/troubleshooting.md
]
check = ARGV == ["--check"]
abort "usage: #{$PROGRAM_NAME} [--check]" unless ARGV.empty? || check

stale = []
%w[rails phoenix].product(sources).each do |package, source|
  destination = File.join(root, "packages", package, source)
  contents = File.binread(File.join(root, source))
  if check
    stale << destination unless File.file?(destination) && File.binread(destination) == contents
  else
    FileUtils.mkdir_p(File.dirname(destination))
    File.binwrite(destination, contents)
  end
end

abort "staged shared documents are stale:\n#{stale.join("\n")}" unless stale.empty?
puts(check ? "staged shared documents match canonical sources" : "staged shared documents updated")
