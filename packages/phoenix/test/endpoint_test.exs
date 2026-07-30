defmodule PiBrowserTaskbarPhoenix.EndpointTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias PiBrowserTaskbarPhoenix.{Endpoint, Runtime}

  @contract_root Path.expand("../../../contract", __DIR__)
  @fixture Path.join(@contract_root, "fixtures/tasks/minimal-task.json")
  @scenario Path.join(@contract_root, "fixtures/scenarios/phoenix-whole-page.json")
  @cancellation_scenarios Path.join(@contract_root, "fixtures/scenarios/cancellation-*.json")

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

  test "serves shared idempotent cancellation scenarios", %{runtime: runtime} do
    scenarios =
      @cancellation_scenarios
      |> Path.wildcard()
      |> Map.new(fn path ->
        scenario = path |> File.read!() |> Jason.decode!()
        {Path.basename(path, ".json"), scenario}
      end)

    params = @fixture |> File.read!() |> Jason.decode!()
    completed = call(:post, "/tasks", params, runtime) |> json()
    wait_until(fn -> Runtime.snapshot(runtime).task.status == "completed" end)

    completed_response = call(:delete, "/tasks/#{completed["task"]["id"]}", nil, runtime)
    assert_scenario_error(completed_response, scenarios["cancellation-completed"])

    held = call(:post, "/tasks", Map.put(params, "prompt", "hold this task"), runtime) |> json()
    task_id = held["task"]["id"]

    wrong = call(:delete, "/tasks/unknown-task", nil, runtime)
    assert_scenario_error(wrong, scenarios["cancellation-wrong-id"])

    accepted = call(:delete, "/tasks/#{task_id}", nil, runtime)
    accepted_json = json(accepted)
    accepted_scenario = scenarios["cancellation-accepted"]
    assert accepted.status == accepted_scenario["response"]["status"]
    assert accepted_json["task"]["status"] == accepted_scenario["response"]["body"]["task_status"]
    assert accepted_json["task"]["finished_at"] == nil
    assert get_resp_header(accepted, "cache-control") == ["no-store"]

    repeated = call(:delete, "/tasks/#{task_id}", nil, runtime)
    repeated_scenario = scenarios["cancellation-repeated"]
    assert repeated.status == repeated_scenario["response"]["status"]

    assert json(repeated)["task"]["status"] ==
             repeated_scenario["response"]["body"]["task_status"]

    wait_until(fn -> Runtime.snapshot(runtime).task.status == "cancelled" end)
    settled = call(:get, "/state", nil, runtime)
    settled_json = json(settled)
    settled_scenario = scenarios["cancellation-settled"]
    assert settled.status == settled_scenario["response"]["status"]

    assert settled_json["session"]["status"] ==
             settled_scenario["response"]["body"]["session_status"]

    assert settled_json["task"]["status"] == settled_scenario["response"]["body"]["task_status"]

    assert settled_json["task"]["activity"] ==
             settled_scenario["response"]["body"]["task_activity"]

    already = call(:delete, "/tasks/#{task_id}", nil, runtime)
    assert already.status == 200
    assert json(already)["task"]["status"] == "cancelled"
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

  test "rejects oversized bodies already parsed by the host endpoint", %{runtime: runtime} do
    params = @fixture |> File.read!() |> Jason.decode!()

    conn =
      conn(:post, "/tasks", "")
      |> Map.put(:body_params, params)
      |> put_req_header("content-length", Integer.to_string(128 * 1024 + 1))
      |> Map.put(:host, "localhost")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> Endpoint.call(Endpoint.init(runtime: runtime))

    assert conn.status == 413
    assert %{"error" => %{"code" => "oversized_payload"}} = json(conn)
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

  defp assert_scenario_error(response, scenario) do
    assert response.status == scenario["response"]["status"]
    assert json(response)["error"]["code"] == scenario["response"]["body"]["error_code"]
    assert get_resp_header(response, "cache-control") == ["no-store"]
  end

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
