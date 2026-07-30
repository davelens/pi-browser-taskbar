defmodule PiBrowserTaskbarPhoenix.EndpointTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias PiBrowserTaskbarPhoenix.{Endpoint, Runtime}

  @contract_root Path.expand("../../../contract", __DIR__)
  @fixture Path.join(@contract_root, "fixtures/tasks/minimal-task.json")
  @scenario Path.join(@contract_root, "fixtures/scenarios/phoenix-whole-page.json")

  setup do
    name = String.to_atom("endpoint_runtime_#{System.unique_integer([:positive])}")
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

  test "serves the canonical no-store whole-page flow", %{runtime: runtime} do
    state = call(:get, "/state", nil, runtime)
    assert state.status == 200
    assert get_resp_header(state, "cache-control") == ["no-store"]

    assert %{"contract_version" => 1, "session" => %{"status" => "ready"}, "task" => nil} =
             json(state)

    scenario = @scenario |> File.read!() |> Jason.decode!()
    expected = scenario["response"]["body"]

    fixture_path = Path.join(@contract_root, scenario["request"]["body_fixture"])
    params = fixture_path |> File.read!() |> Jason.decode!()

    created = call(:post, scenario["request"]["path"], params, runtime)
    created_json = json(created)

    assert created.status == scenario["response"]["status"]
    assert get_resp_header(created, "cache-control") == ["no-store"]
    assert created_json["contract_version"] == expected["contract_version"]
    assert created_json["session"]["status"] == expected["session_status"]
    assert created_json["task"]["status"] == expected["task_status"]

    wait_until(fn ->
      Runtime.snapshot(runtime).task.status == expected["terminal_task_status"]
    end)

    completed = call(:get, "/state", nil, runtime) |> json()

    assert completed["session"]["status"] == "ready"
    assert completed["task"]["status"] == expected["terminal_task_status"]
    assert completed["task"]["output"] == expected["terminal_output"]
  end

  test "returns stable validation and busy errors", %{runtime: runtime} do
    invalid = call(:post, "/tasks", %{"prompt" => "missing context"}, runtime)
    assert invalid.status == 422
    assert %{"error" => %{"code" => "invalid_task"}} = json(invalid)

    params = @fixture |> File.read!() |> Jason.decode!() |> Map.put("prompt", "hold this task")
    assert call(:post, "/tasks", params, runtime).status == 202

    busy = call(:post, "/tasks", params, runtime)
    assert busy.status == 409

    assert %{"error" => %{"code" => "busy"}, "snapshot" => %{"session" => %{"status" => "busy"}}} =
             json(busy)
  end

  test "rejects non-loopback hosts and clients before state access", %{runtime: runtime} do
    bad_host = call(:get, "/state", nil, runtime, host: "attacker.example")
    assert bad_host.status == 403
    assert %{"error" => %{"code" => "forbidden"}} = json(bad_host)

    remote = call(:get, "/state", nil, runtime, remote_ip: {192, 0, 2, 4})
    assert remote.status == 403
  end

  defp call(method, path, params, runtime, overrides \\ []) do
    body = if params, do: Jason.encode!(params), else: ""

    conn(method, path, body)
    |> Map.put(:host, Keyword.get(overrides, :host, "localhost"))
    |> Map.put(:remote_ip, Keyword.get(overrides, :remote_ip, {127, 0, 0, 1}))
    |> put_req_header("accept", "application/json")
    |> maybe_content_type(params)
    |> Endpoint.call(Endpoint.init(runtime: runtime))
  end

  defp maybe_content_type(conn, nil), do: conn

  defp maybe_content_type(conn, _params),
    do: put_req_header(conn, "content-type", "application/json")

  defp json(conn), do: Jason.decode!(conn.resp_body)

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
