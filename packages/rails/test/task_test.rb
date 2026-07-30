# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/pi/browser/taskbar/rails/task"

class RailsTaskTest < Minitest::Test
  FIXTURE = File.expand_path("../../../contract/fixtures/tasks/minimal-task.json", __dir__)
  GOLDEN = File.expand_path("../../../contract/fixtures/prompts/minimal-task.json", __dir__)
  RICH_CONTEXT = File.expand_path("../../../contract/fixtures/browser-context/rich-whole-page.json", __dir__)
  RICH_GOLDEN = File.expand_path("../../../contract/fixtures/prompts/rich-whole-page.json", __dir__)

  def test_validates_and_builds_the_canonical_trusted_untrusted_prompt
    value = JSON.parse(File.read(FIXTURE))
    task = Pi::Browser::Taskbar::Rails::Task.parse(value)
    golden = JSON.parse(File.read(GOLDEN))

    assert_equal value["prompt"], task.prompt
    assert_equal golden.fetch("expected"), task.pi_prompt
  end

  def test_normalizes_rich_context_and_matches_the_shared_prompt_golden
    context = JSON.parse(File.read(RICH_CONTEXT))
    value = {"prompt" => " \r\nImprove the checkout button.\u202e ", "context" => context}
    value["context"]["route"]["method"] = "get"
    value["context"]["snapshot"]["tag"] = "MAIN"
    value["context"]["snapshot"]["name"] = "  Cards\r\n "
    value["context"]["truncation"][0]["reasons"] = %w[string bytes]

    task = Pi::Browser::Taskbar::Rails::Task.parse(value)

    assert_equal JSON.parse(File.read(RICH_CONTEXT)).merge(
      "truncation" => [{"section" => "page", "reasons" => %w[bytes string]}]
    ), task.context
    assert_equal JSON.parse(File.read(RICH_GOLDEN)).fetch("expected").sub(
      '"reasons":["string"]', '"reasons":["bytes","string"]'
    ), task.pi_prompt
  end

  def test_rejects_duplicate_and_out_of_allocation_context
    value = JSON.parse(File.read(FIXTURE))
    value["context"]["location"]["query_names"] = ["page", "page"]
    assert_invalid(value, "location.query_names is invalid")

    value = JSON.parse(File.read(FIXTURE))
    value["context"]["truncation"] = [
      {"section" => "page", "reasons" => ["bytes"]},
      {"section" => "page", "reasons" => ["nodes"]}
    ]
    assert_invalid(value, "truncation sections must be unique")

    value = JSON.parse(File.read(FIXTURE))
    point = {
      "selector" => "#card",
      "source_status" => "unavailable",
      "ancestors" => [],
      "subtree" => {"tag" => "div", "children" => Array.new(100) { {"tag" => "span", "children" => []} }}
    }
    value["context"]["focus_points"] = [point]
    assert_invalid(value, "focus_points[0].subtree must contain at most 100 nodes")
  end

  def test_rejects_unknown_fields_and_normalizes_prompt
    value = JSON.parse(File.read(FIXTURE))
    value["unknown"] = true
    error = assert_raises(Pi::Browser::Taskbar::Rails::Task::Invalid) { Pi::Browser::Taskbar::Rails::Task.parse(value) }
    assert_match(/unknown field/, error.message)

    value.delete("unknown")
    value["prompt"] = " \r\nExplain\u202ethe page. \r"
    assert_equal "Explainthe page.", Pi::Browser::Taskbar::Rails::Task.parse(value).prompt
  end

  def test_rejects_oversized_prompt_and_snapshot_depth
    value = JSON.parse(File.read(FIXTURE))
    value["prompt"] = "x" * 4_001
    assert_raises(Pi::Browser::Taskbar::Rails::Task::Invalid) { Pi::Browser::Taskbar::Rails::Task.parse(value) }

    value = JSON.parse(File.read(FIXTURE))
    node = value.dig("context", "snapshot")
    13.times { node["children"] = [{"tag" => "div", "children" => []}]; node = node["children"].first }
    assert_raises(Pi::Browser::Taskbar::Rails::Task::Invalid) { Pi::Browser::Taskbar::Rails::Task.parse(value) }
  end

  private

  def assert_invalid(value, message)
    error = assert_raises(Pi::Browser::Taskbar::Rails::Task::Invalid) do
      Pi::Browser::Taskbar::Rails::Task.parse(value)
    end
    assert_equal message, error.message
  end
end
