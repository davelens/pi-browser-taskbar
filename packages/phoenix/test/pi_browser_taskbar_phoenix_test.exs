defmodule PiBrowserTaskbarPhoenixTest do
  use ExUnit.Case, async: true

  test "exposes the lockstep version" do
    assert PiBrowserTaskbarPhoenix.version() == "0.1.0"
  end

  test "exposes the prebuilt browser asset" do
    asset = PiBrowserTaskbarPhoenix.browser_asset_path()

    assert File.exists?(asset)
    assert File.read!(asset) =~ ~s(productVersion: "0.1.0")
    assert File.read!(asset) =~ ~s(framework: "phoenix")
  end
end
