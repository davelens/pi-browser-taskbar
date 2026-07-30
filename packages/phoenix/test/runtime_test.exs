defmodule PiBrowserTaskbarPhoenix.RuntimeTest do
  use ExUnit.Case, async: true

  alias PiBrowserTaskbarPhoenix.Runtime
  alias PiBrowserTaskbarPhoenix.Task, as: BrowserTask

  @fixture Path.expand("../../../contract/fixtures/tasks/minimal-task.json", __DIR__)

  setup do
    name = String.to_atom("runtime_#{System.unique_integer([:positive])}")
    executable = Path.expand("support/fake_pi_rpc", __DIR__)

    start_supervised!(
      {Runtime,
       name: name,
       executable: executable,
       project_root: File.cwd!(),
       task_timeout: 60_000,
       allowed_hosts: []}
    )

    wait_until(fn -> Runtime.snapshot(name).session.status == "ready" end)
    %{runtime: name}
  end

  test "runs one whole-page task to completed fake-Pi output", %{runtime: runtime} do
    task = valid_task("Explain the cards page.")

    assert {:ok, running} = Runtime.submit(runtime, task)
    assert running.session.status == "busy"
    assert running.task.status == "running"
    assert opaque?(running.session.id)
    assert opaque?(running.task.id)

    wait_until(fn -> Runtime.snapshot(runtime).task.status == "completed" end)
    snapshot = Runtime.snapshot(runtime)

    assert snapshot.contract_version == 1
    assert snapshot.session.status == "ready"
    assert snapshot.session.model == "test/fake-pi"
    assert snapshot.task.output == "Implemented the whole-page request."
    assert snapshot.task.output_truncated == false
    assert snapshot.task.finished_at
  end

  test "ignores a stale response from an earlier correlated command", %{runtime: runtime} do
    assert {:ok, _running} = Runtime.submit(runtime, valid_task("stale response"))

    wait_until(fn -> Runtime.snapshot(runtime).task.status == "completed" end)
    assert Runtime.snapshot(runtime).task.output == "Implemented the whole-page request."
  end

  test "restarts after an oversized RPC record", %{runtime: runtime} do
    assert {:ok, _running} = Runtime.submit(runtime, valid_task("oversized record"))

    wait_until(fn -> Runtime.snapshot(runtime).task.status == "failed" end)
    wait_until(fn -> Runtime.snapshot(runtime).session.status == "ready" end)

    assert Runtime.snapshot(runtime).task.error == "Pi sent an oversized RPC record"
  end

  test "admits a busy task atomically", %{runtime: runtime} do
    assert {:ok, running} = Runtime.submit(runtime, valid_task("hold this task"))

    submissions =
      1..8
      |> Task.async_stream(fn _ -> Runtime.submit(runtime, valid_task("second task")) end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(submissions, &match?({:error, :busy, _snapshot}, &1))
    assert Runtime.snapshot(runtime).task.id == running.task.id
  end

  defp valid_task(prompt) do
    params = @fixture |> File.read!() |> Jason.decode!() |> Map.put("prompt", prompt)
    {:ok, task} = BrowserTask.new(params)
    task
  end

  defp opaque?(value), do: is_binary(value) and byte_size(value) >= 16

  defp wait_until(predicate, attempts \\ 100)

  defp wait_until(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      wait_until(predicate, attempts - 1)
    end
  end

  defp wait_until(_predicate, 0), do: flunk("condition was not met in time")
end
