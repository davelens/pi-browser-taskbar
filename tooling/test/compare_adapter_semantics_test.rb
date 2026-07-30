# frozen_string_literal: true

require "minitest/autorun"
require_relative "compare_adapter_semantics"

class CompareAdapterSemanticsTest < Minitest::Test
  def test_normalizes_only_volatile_values_and_retains_their_keys
    snapshot = {
      "id" => "rails-id",
      "started_at" => nil,
      "nested" => [{"finished_at" => "2026-01-01", "command_id" => "keep-me"}]
    }

    normalized = AdapterSemantics.normalize(snapshot)

    assert_equal "<adapter-specific>", normalized["id"]
    assert_equal "<adapter-specific>", normalized["started_at"]
    assert_equal "<adapter-specific>", normalized.dig("nested", 0, "finished_at")
    assert_equal "keep-me", normalized.dig("nested", 0, "command_id")
    refute_equal normalized, AdapterSemantics.normalize(snapshot.reject { |key| key == "id" })
  end
end
