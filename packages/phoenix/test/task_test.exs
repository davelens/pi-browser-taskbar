defmodule PiBrowserTaskbarPhoenix.TaskTest do
  use ExUnit.Case, async: true

  alias PiBrowserTaskbarPhoenix.Task

  @fixture Path.expand("../../../contract/fixtures/tasks/minimal-task.json", __DIR__)
  @golden Path.expand("../../../contract/fixtures/prompts/minimal-task.json", __DIR__)
  @rich_context Path.expand(
                  "../../../contract/fixtures/browser-context/rich-whole-page.json",
                  __DIR__
                )
  @one_focus Path.expand(
               "../../../contract/fixtures/browser-context/one-focus-unavailable.json",
               __DIR__
             )
  @eight_focus Path.expand(
                 "../../../contract/fixtures/browser-context/eight-focus-unavailable.json",
                 __DIR__
               )
  @rich_golden Path.expand("../../../contract/fixtures/prompts/rich-whole-page.json", __DIR__)
  @contract Path.expand("../../../contract", __DIR__)

  test "validates a whole-page request and separates instruction from untrusted context" do
    params = @fixture |> File.read!() |> Jason.decode!()
    golden = @golden |> File.read!() |> Jason.decode!()

    assert {:ok, task} = Task.new(params)
    assert task.prompt == "Explain the cards page."
    assert task.context["focus_points"] == []
    assert Task.to_prompt(task) == golden["expected"]
  end

  test "normalizes rich context and matches the shared prompt golden" do
    context = @rich_context |> File.read!() |> Jason.decode!()

    params = %{
      "prompt" => "\u00A0\u2003\r\nImprove the checkout button.\u202e\u2003\u00A0",
      "context" =>
        context
        |> put_in(["route", "method"], "get")
        |> put_in(["snapshot", "tag"], "MAIN")
        |> put_in(["snapshot", "name"], "  Cards\r\n ")
        |> put_in(["truncation", Access.at(0), "reasons"], ~w(string bytes))
    }

    assert {:ok, task} = Task.new(params)

    expected_context =
      context
      |> put_in(["truncation", Access.at(0), "reasons"], ~w(bytes string))

    expected_prompt =
      @rich_golden
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("expected")
      |> String.replace(~s("reasons":["string"]), ~s("reasons":["bytes","string"]))

    assert task.context == expected_context
    assert Task.to_prompt(task) == expected_prompt
  end

  test "accepts one and eight ordered advisory focus points" do
    Enum.each([@one_focus, @eight_focus], fn fixture ->
      context = fixture |> File.read!() |> Jason.decode!()

      assert {:ok, task} = Task.new(%{"prompt" => "Improve the marks.", "context" => context})
      assert task.context == context
      assert Enum.all?(task.context["focus_points"], &(&1["source_status"] == "unavailable"))
    end)
  end

  test "rejects duplicate and out-of-allocation context" do
    params = @fixture |> File.read!() |> Jason.decode!()

    point =
      @one_focus |> File.read!() |> Jason.decode!() |> get_in(["focus_points", Access.at(0)])

    assert {:error, :invalid_task, "focus_points selectors must be unique"} =
             params
             |> put_in(["context", "focus_points"], [point, point])
             |> Task.new()

    assert {:error, :invalid_task, "location.query_names is invalid"} =
             params
             |> put_in(["context", "location", "query_names"], ["page", "page"])
             |> Task.new()

    assert {:error, :invalid_task, "truncation sections must be unique"} =
             params
             |> put_in(
               ["context", "truncation"],
               [
                 %{"section" => "page", "reasons" => ["bytes"]},
                 %{"section" => "page", "reasons" => ["nodes"]}
               ]
             )
             |> Task.new()

    point = %{
      "selector" => "#card",
      "source_status" => "unavailable",
      "ancestors" => [],
      "subtree" => %{
        "tag" => "div",
        "children" => List.duplicate(%{"tag" => "span", "children" => []}, 100)
      }
    }

    assert {:error, :invalid_task, "focus_points[0].subtree must contain at most 100 nodes"} =
             params
             |> put_in(["context", "focus_points"], [point])
             |> Task.new()
  end

  test "rejects every shared invalid browser context with the stable error" do
    fixtures =
      @contract
      |> Path.join("fixtures/manifest.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("fixtures")
      |> Enum.filter(fn entry ->
        !entry["expected_valid"] &&
          String.ends_with?(entry["schema"], "browser-context.v1.schema.json")
      end)

    Enum.each(fixtures, fn entry ->
      context =
        @contract
        |> Path.join(entry["path"])
        |> File.read!()
        |> Jason.decode!()

      assert {:error, :invalid_task, _message} =
               Task.new(%{"prompt" => "Explain.", "context" => context}),
             entry["id"]
    end)
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
