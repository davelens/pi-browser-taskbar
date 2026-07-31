# frozen_string_literal: true

require "json"
require "pathname"
require "uri"

root = Pathname(File.expand_path("..", __dir__))
errors = []
error = ->(message) { errors << message }

markdown = root.glob("{README.md,contract/**/*.md,docs/**/*.md,examples/**/*.md,packages/**/*.md}")
               .reject { |path| path.to_s.include?("/deps/") || path.to_s.include?("/_build/") }

def anchors(path)
  counts = Hash.new(0)
  path.each_line.filter_map do |line|
    next unless line =~ /^\#{1,6}\s+(.+?)\s*#*$/

    slug = Regexp.last_match(1).gsub(/<[^>]+>/, "").gsub(/[`*_~]/, "").downcase
      .gsub(/[^\p{Alnum}\s-]/, "").strip.gsub(/\s+/, "-")
    suffix = counts[slug].zero? ? "" : "-#{counts[slug]}"
    counts[slug] += 1
    "#{slug}#{suffix}"
  end
end

markdown.each do |path|
  path.read.scan(/(?<!!)\[[^\]]+\]\(([^)\s]+)(?:\s+"[^"]*")?\)/).flatten.each do |link|
    next if link.match?(%r{\A(?:https?|mailto):})

    target, fragment = link.split("#", 2)
    destination = target.nil? || target.empty? ? path : path.dirname.join(URI::DEFAULT_PARSER.unescape(target)).cleanpath
    unless destination.exist?
      error.call("#{path.relative_path_from(root)} has unresolved link #{link}")
      next
    end
    if fragment && !fragment.empty? && destination.file? && !anchors(destination).include?(fragment)
      error.call("#{path.relative_path_from(root)} has unresolved heading #{link}")
    end
  end
end

adapter_headings = [
  "Dependency", "Installer", "Generated integration", "Configuration", "Verification", "Diagnosis",
  "Updates", "Security", "Uninstall", "Changelog and example", "Matching-version contract"
]
%w[rails phoenix].each do |adapter|
  path = root.join("packages", adapter, "README.md")
  actual = path.each_line.filter_map { |line| line[/^## (.+)$/, 1] }
  error.call("#{adapter} guide section order differs") unless actual == adapter_headings
  source = path.read
  error.call("#{adapter} guide does not defer to canonical contract") unless source.include?("contract/docs/index.md")
  %w[GET\ /state POST\ /tasks task_not_found BEGIN\ UNTRUSTED\ BROWSER\ CONTEXT].each do |duplicate|
    error.call("#{adapter} guide duplicates normative contract prose: #{duplicate.tr("\\", "")}") if source.match?(/#{duplicate}/)
  end
end

required_contract_headings = [
  "Shared HTTP API and stable errors", "Initial task request", "Normalized browser context",
  "Prompt envelope", "Pi progress, output, and safe failures", "Task cancellation",
  "Remote development access and diagnostics", "Other executable formats"
]
contract_headings = anchors(root.join("contract/docs/index.md"))
required_contract_headings.each do |heading|
  expected = heading.downcase.gsub(/[^\p{Alnum}\s-]/, "").gsub(/\s+/, "-")
  error.call("canonical contract omits #{heading}") unless contract_headings.include?(expected)
end

compatibility = JSON.parse(root.join("tooling/compatibility.json").read)
version = root.join("VERSION").read.strip
error.call("compatibility product version drift") unless compatibility["product_version"] == version
rails = compatibility.fetch("rails")
phoenix = compatibility.fetch("phoenix")
gemspec = root.join("packages/rails/pi-browser-taskbar-rails.gemspec").read
mix = root.join("packages/phoenix/mix.exs").read
compat_doc = root.join("docs/compatibility.md").read
error.call("Rails language floor drift") unless gemspec.include?(%(required_ruby_version = ">= #{rails.fetch("language_floor")}"))
error.call("Phoenix language floor drift") unless mix.include?(%(elixir: ">= #{phoenix.fetch("language_floor")}.0"))
error.call("Phoenix framework floor drift") unless mix.include?(%({:phoenix, ">= #{phoenix.fetch("framework_floor")}.0))
[version, "Rails #{rails.fetch("framework_floor")}", "Ruby #{rails.fetch("language_floor")}",
 "Rails #{rails.fetch("latest_framework")}", "Ruby #{rails.fetch("latest_language")}",
 "Phoenix #{phoenix.fetch("framework_floor")}", "Phoenix #{phoenix.fetch("latest_framework")}",
 "Elixir #{phoenix.fetch("language_floor")}", "Elixir #{phoenix.fetch("latest_language")}"].each do |claim|
  error.call("compatibility guide omits #{claim}") unless compat_doc.include?(claim)
end
%w[rails phoenix].each do |adapter|
  readme = root.join("packages", adapter, "README.md").read
  error.call("#{adapter} dependency or contract version drift") unless readme.scan(version).length >= 2
end

staged = %w[contract/docs/index.md contract/traceability.md contract/traceability.json docs/accessibility-acceptance.md docs/security.md docs/troubleshooting.md]
%w[rails phoenix].product(staged).each do |adapter, source|
  destination = root.join("packages", adapter, source)
  error.call("#{adapter} staged #{source} differs") unless destination.file? && destination.binread == root.join(source).binread
end

scenario_rows = {}
%w[rails phoenix].each do |adapter|
  readme = root.join("examples", adapter, "README.md").read
  scenario_rows[adapter] = readme.scan(/^\| `([^`]+)` \|/).flatten
end
expected_scenarios = %w[whole-page focused-card cancellation reset navigation fail-closed]
error.call("example scenarios differ") unless scenario_rows.values.uniq == [expected_scenarios]
required_selectors = %w[scenario-whole-page scenario-focused-card scenario-navigation focus-card navigation-target]
%w[rails phoenix].each do |adapter|
  sources = root.glob("examples/#{adapter}/**/*").select(&:file?).reject { |path| path.basename.to_s == "README.md" }
  combined = sources.map(&:read).join("\n")
  required_selectors.each do |selector|
    error.call("#{adapter} example omits stable selector #{selector}") unless combined.include?(%(data-testid=\"#{selector}\")) || combined.include?(%(testid: \"#{selector}\"))
  end
  %w[allowed_hosts PI_BROWSER_TASKBAR_ALLOWED_HOSTS fake_pi_rpc].each do |forbidden|
    error.call("#{adapter} example contains forbidden runtime shortcut #{forbidden}") if combined.include?(forbidden)
  end
end
error.call("Rails example omits nested ERB partial") unless root.join("examples/rails/app/views/scenarios/_card_detail.html.erb").file?
error.call("Rails example omits Turbo public seam") unless root.join("examples/rails/app/javascript/application.js").read.include?("@hotwired/turbo-rails")
error.call("Phoenix example omits controller HEEx") unless root.join("examples/phoenix/lib/taskbar_example_web/controllers/page_html/index.html.heex").file?
error.call("Phoenix example omits LiveView") unless root.join("examples/phoenix/lib/taskbar_example_web/live/scenario_live.ex").read.include?("use TaskbarExampleWeb, :live_view")

if errors.empty?
  puts "documentation, links, compatibility claims, staged content, and examples are consistent"
else
  warn errors.join("\n")
  exit 1
end
