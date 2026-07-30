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

  def test_rejects_an_unexpected_command
    transcript = File.join(ROOT, "contract/fixtures/rpc/startup-success.json")
    command = [File.join(ROOT, "tooling/fake_pi_rpc.rb"), transcript]

    _output, error, status = Open3.capture3(*command, stdin_data: "{}\n")

    refute status.success?
    assert_includes error, "unexpected input"
  end
end
