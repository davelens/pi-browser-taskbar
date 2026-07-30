# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/pi/browser/taskbar/rails/task"

class RailsTaskTest < Minitest::Test
  FIXTURE = File.expand_path("../../../contract/fixtures/tasks/minimal-task.json", __dir__)
  GOLDEN = File.expand_path("../../../contract/fixtures/prompts/minimal-task.json", __dir__)

  def test_validates_and_builds_the_canonical_trusted_untrusted_prompt
    value = JSON.parse(File.read(FIXTURE))
    task = Pi::Browser::Taskbar::Rails::Task.parse(value)
    golden = JSON.parse(File.read(GOLDEN))

    assert_equal value["prompt"], task.prompt
    assert_equal golden.fetch("expected"), task.pi_prompt
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
end
