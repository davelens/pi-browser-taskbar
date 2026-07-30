# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"

class FakePiRpcTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_replays_a_versioned_transcript
    transcript = File.join(ROOT, "contract/fixtures/rpc/startup-success.json")
    command = [File.join(ROOT, "tooling/fake_pi_rpc.rb"), transcript]
    input = JSON.generate(type: "get_state", id: "state-1") + "\n"

    output, error, status = Open3.capture3(*command, stdin_data: input)

    assert status.success?, error
    response = JSON.parse(output)
    assert_equal "fixture-session", response.dig("data", "sessionId")
    assert_equal "state-1", response.fetch("id")
  end

  def test_replays_accepted_abort_through_agent_settled
    transcript = File.join(ROOT, "contract/fixtures/rpc/cancellation-success.json")
    command = [File.join(ROOT, "tooling/fake_pi_rpc.rb"), transcript]
    input = [
      {type: "get_state", id: "state-1"},
      {type: "prompt", id: "task-1", message: "Hold this task."},
      {type: "abort", id: "abort-1"}
    ].map { |value| JSON.generate(value) }.join("\n") + "\n"

    output, error, status = Open3.capture3(*command, stdin_data: input)
    events = output.lines.map { |line| JSON.parse(line) }

    assert status.success?, error
    assert_equal true, events.find { |event| event["id"] == "abort-1" }.fetch("success")
    assert_equal "agent_settled", events.last.fetch("type")
  end

  def test_replays_confirmed_and_extension_rejected_session_resets
    success = File.join(ROOT, "contract/fixtures/rpc/session-reset-success.json")
    success_input = [
      {type: "get_state", id: "state-1"},
      {type: "new_session", id: "reset-1"},
      {type: "get_state", id: "state-2"}
    ].map { |value| JSON.generate(value) }.join("\n") + "\n"
    output, error, status = Open3.capture3(File.join(ROOT, "tooling/fake_pi_rpc.rb"), success, stdin_data: success_input)
    assert status.success?, error
    events = output.lines.map { |line| JSON.parse(line) }
    assert_equal "new-session", events.last.dig("data", "sessionId")

    rejected = File.join(ROOT, "contract/fixtures/rpc/session-reset-rejected.json")
    rejected_input = [{type: "get_state", id: "state-1"}, {type: "new_session", id: "reset-1"}]
      .map { |value| JSON.generate(value) }.join("\n") + "\n"
    output, error, status = Open3.capture3(File.join(ROOT, "tooling/fake_pi_rpc.rb"), rejected, stdin_data: rejected_input)
    assert status.success?, error
    assert_equal true, output.lines.map { |line| JSON.parse(line) }.last.dig("data", "cancelled")
  end

  def test_replays_progress_dialog_and_safe_failure_event_transcripts
    progress = File.join(ROOT, "contract/fixtures/rpc/progress-success.json")
    progress_input = [
      {type: "get_state", id: "state-1"},
      {type: "prompt", id: "task-1", message: "fixture prompt"},
      {type: "extension_ui_response", id: "dialog-1", cancelled: true}
    ].map { |value| JSON.generate(value) }.join("\n") + "\n"
    output, error, status = Open3.capture3(File.join(ROOT, "tooling/fake_pi_rpc.rb"), progress, stdin_data: progress_input)
    assert status.success?, error
    types = output.lines.map { |line| JSON.parse(line).fetch("type") }
    assert_includes types, "tool_execution_update"
    assert_includes types, "compaction_end"
    assert_includes types, "auto_retry_end"
    assert_equal "agent_settled", types.last

    failures = File.join(ROOT, "contract/fixtures/rpc/failure-events.json")
    failure_input = [
      {type: "get_state", id: "state-1"},
      {type: "prompt", id: "message-task", message: "message error"},
      {type: "prompt", id: "retry-task", message: "retry failure"},
      {type: "prompt", id: "compaction-task", message: "compaction failure"},
      {type: "prompt", id: "rejected-task", message: "rejected"}
    ].map { |value| JSON.generate(value) }.join("\n") + "\n"
    output, error, status = Open3.capture3(File.join(ROOT, "tooling/fake_pi_rpc.rb"), failures, stdin_data: failure_input)
    assert status.success?, error
    events = output.lines.map { |line| JSON.parse(line) }
    assert events.any? { |event| event.dig("assistantMessageEvent", "type") == "error" }
    assert events.any? { |event| event["type"] == "auto_retry_end" && event["success"] == false }
    assert events.any? { |event| event["type"] == "response" && event["success"] == false }
  end

  def test_rejects_an_unexpected_command
    transcript = File.join(ROOT, "contract/fixtures/rpc/startup-success.json")
    command = [File.join(ROOT, "tooling/fake_pi_rpc.rb"), transcript]

    _output, error, status = Open3.capture3(*command, stdin_data: "{}\n")

    refute status.success?
    assert_includes error, "unexpected input"
  end
end
