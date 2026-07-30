defmodule PiBrowserTaskbarPhoenix.TaskTest do
  use ExUnit.Case, async: true

  alias PiBrowserTaskbarPhoenix.Task

  @fixture Path.expand("../../../contract/fixtures/tasks/minimal-task.json", __DIR__)
  @golden Path.expand("../../../contract/fixtures/prompts/minimal-task.json", __DIR__)

  test "validates a whole-page request and separates instruction from untrusted context" do
    params = @fixture |> File.read!() |> Jason.decode!()
    golden = @golden |> File.read!() |> Jason.decode!()

    assert {:ok, task} = Task.new(params)
    assert task.prompt == "Explain the cards page."
    assert task.context["focus_points"] == []
    assert Task.to_prompt(task) == golden["expected"]
  end

  test "rejects unknown fields and empty normalized prompts" do
    params = @fixture |> File.read!() |> Jason.decode!()

    assert {:error, :invalid_task, message} = Task.new(Map.put(params, "unexpected", true))
    assert message =~ "unknown field"

    assert {:error, :invalid_task, "prompt is required"} =
             Task.new(Map.put(params, "prompt", " \r\n\t "))
  end

  test "rejects a page snapshot outside the native page bounds" do
    params = @fixture |> File.read!() |> Jason.decode!()
    node = %{"tag" => "div", "children" => []}

    too_many_nodes =
      put_in(params, ["context", "snapshot"], %{
        "tag" => "main",
        "children" => List.duplicate(node, 750)
      })

    assert {:error, :invalid_task, "snapshot must contain at most 750 nodes"} =
             Task.new(too_many_nodes)

    oversized_snapshot =
      put_in(params, ["context", "snapshot"], %{
        "tag" => "main",
        "children" =>
          Enum.map(1..50, fn _index ->
            %{"tag" => "p", "text" => String.duplicate("x", 1_000), "children" => []}
          end)
      })

    assert {:error, :invalid_task, "snapshot is too large"} = Task.new(oversized_snapshot)
  end
end
