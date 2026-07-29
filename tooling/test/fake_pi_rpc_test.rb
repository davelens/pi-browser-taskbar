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

  def test_rejects_an_unexpected_command
    transcript = File.join(ROOT, "contract/fixtures/rpc/startup-success.json")
    command = [File.join(ROOT, "tooling/fake_pi_rpc.rb"), transcript]

    _output, error, status = Open3.capture3(*command, stdin_data: "{}\n")

    refute status.success?
    assert_includes error, "unexpected input"
  end
end
