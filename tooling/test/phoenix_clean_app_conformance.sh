#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
version=$(<"$root/VERSION")
artifact="$root/build/pi_browser_taskbar_phoenix-$version.tar"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pi-browser-taskbar-phoenix.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

package="$tmp/package"
app="$tmp/demo"
mkdir -p "$package" "$app/config" "$app/lib/demo" "$app/lib/demo_web/components/layouts"

tar -xf "$artifact" -C "$tmp" contents.tar.gz
tar -xzf "$tmp/contents.tar.gz" -C "$package"
cp "$root/packages/phoenix/test/support/fake_pi_rpc" "$tmp/fake_pi_rpc"
chmod +x "$tmp/fake_pi_rpc"
cp "$root/contract/fixtures/scenarios/phoenix-whole-page.json" "$tmp/scenario.json"
cp "$root/contract/fixtures/tasks/minimal-task.json" "$tmp/task.json"
cp "$root/contract/fixtures/scenarios/focused-task.json" "$tmp/focused-scenario.json"
cp "$root/contract/fixtures/tasks/focused-task.json" "$tmp/focused-task.json"
mkdir "$tmp/cancellation-scenarios" "$tmp/reset-scenarios"
cp "$root"/contract/fixtures/scenarios/cancellation-*.json "$tmp/cancellation-scenarios/"
cp "$root"/contract/fixtures/scenarios/session-reset-*.json "$tmp/reset-scenarios/"

cat >"$app/mix.exs" <<EOF
defmodule Demo.MixProject do
  use Mix.Project

  def project do
    [
      app: :demo,
      version: "0.1.0",
      elixir: ">= 1.11.0",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:crypto, :logger], mod: {Demo.Application, []}]
  end

  defp deps do
    [
      {:jason, ">= 1.4.0 and < 2.0.0"},
      {:phoenix, ">= 1.7.0 and < 2.0.0"},
      {:pi_browser_taskbar_phoenix, path: "../package", only: :dev, runtime: false}
    ]
  end
end
EOF

cat >"$app/config/config.exs" <<'EOF'
import Config

config :demo, :pi_browser_taskbar,
  executable: System.fetch_env!("PI_BROWSER_TASKBAR_FAKE"),
  project_root: Path.expand("..", __DIR__),
  task_timeout: 60
EOF

cat >"$app/lib/demo/application.ex" <<'EOF'
defmodule Demo.Application do
  use Application

  def start(_type, _args) do
    children = [
      DemoWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Demo.Supervisor)
  end
end
EOF

cat >"$app/lib/demo_web.ex" <<'EOF'
defmodule DemoWeb do
  def router do
    quote do
      use Phoenix.Router
      import Phoenix.Controller
    end
  end

  defmacro __using__(which) when is_atom(which), do: apply(__MODULE__, which, [])
end
EOF

cat >"$app/lib/demo_web/endpoint.ex" <<'EOF'
defmodule DemoWeb.Endpoint do
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def init(:ok), do: {:ok, :ok}
end
EOF

cat >"$app/lib/demo_web/router.ex" <<'EOF'
defmodule DemoWeb.Router do
  use DemoWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
  end
end
EOF

cat >"$app/lib/demo_web/components/layouts/root.html.heex" <<'EOF'
<!doctype html>
<html>
  <body>
    {@inner_content}
  </body>
</html>
EOF

cat >"$app/conformance.exs" <<'EOF'
defmodule CleanAppConformance do
  import Plug.Conn
  import Plug.Test

  def run do
    wait_until(fn ->
      PiBrowserTaskbarPhoenix.Runtime.snapshot(
        PiBrowserTaskbarPhoenix.Names.runtime(:demo)
      ).session.status == "ready"
    end)

    scenario = System.fetch_env!("PI_BROWSER_TASKBAR_SCENARIO") |> File.read!() |> Jason.decode!()
    task = System.fetch_env!("PI_BROWSER_TASKBAR_TASK") |> File.read!() |> Jason.decode!()

    state = request(:get, "/dev/pi-browser-taskbar/state")
    assert!(state.status == 200, "state route did not return 200")
    assert!(get_resp_header(state, "cache-control") == ["no-store"], "state was cacheable")

    created = request(:post, "/dev/pi-browser-taskbar" <> scenario["request"]["path"], task)
    created_json = response_json(created)
    expected = scenario["response"]["body"]
    assert!(created.status == scenario["response"]["status"], "task was not accepted")
    assert!(get_resp_header(created, "cache-control") == ["no-store"], "mutation was cacheable")
    assert!(created_json["contract_version"] == expected["contract_version"], "contract version differed")
    assert!(created_json["session"]["status"] == expected["session_status"], "session was not busy")
    assert!(created_json["task"]["status"] == expected["task_status"], "task was not running")
    assert!(byte_size(created_json["session"]["id"]) >= 16, "session identity was not opaque")
    assert!(byte_size(created_json["task"]["id"]) >= 16, "task identity was not opaque")

    wait_until(fn ->
      PiBrowserTaskbarPhoenix.Runtime.snapshot(
        PiBrowserTaskbarPhoenix.Names.runtime(:demo)
      ).task.status == scenario["response"]["body"]["terminal_task_status"]
    end)

    completed = request(:get, "/dev/pi-browser-taskbar/state") |> response_json()
    assert!(completed["task"]["output"] == expected["terminal_output"], "fake output differed")

    focused_scenario = System.fetch_env!("PI_BROWSER_TASKBAR_FOCUSED_SCENARIO") |> File.read!() |> Jason.decode!()
    focused_task = System.fetch_env!("PI_BROWSER_TASKBAR_FOCUSED_TASK") |> File.read!() |> Jason.decode!()
    focused = request(:post, "/dev/pi-browser-taskbar" <> focused_scenario["request"]["path"], focused_task)
    assert!(focused.status == focused_scenario["response"]["status"], "focused task was not accepted")
    wait_until(fn ->
      PiBrowserTaskbarPhoenix.Runtime.snapshot(
        PiBrowserTaskbarPhoenix.Names.runtime(:demo)
      ).task.status == focused_scenario["response"]["body"]["terminal_task_status"]
    end)
    focused_completed = request(:get, "/dev/pi-browser-taskbar/state") |> response_json()
    assert!(focused_completed["task"]["output"] == focused_scenario["response"]["body"]["terminal_output"], "focused fake output differed")

    cancellation_scenarios =
      System.fetch_env!("PI_BROWSER_TASKBAR_CANCELLATION_SCENARIOS")
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Map.new(fn path -> {Path.basename(path, ".json"), path |> File.read!() |> Jason.decode!()} end)

    reset_scenarios =
      System.fetch_env!("PI_BROWSER_TASKBAR_RESET_SCENARIOS")
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Map.new(fn path -> {Path.basename(path, ".json"), path |> File.read!() |> Jason.decode!()} end)

    completed_cancellation = cancellation_scenarios["cancellation-completed"]
    completed_response = request(:delete, "/dev/pi-browser-taskbar/tasks/#{focused_completed["task"]["id"]}")
    completed_body = response_json(completed_response)
    assert!(completed_response.status == completed_cancellation["response"]["status"], "completed task cancellation status differed")
    assert!(completed_body["error"]["code"] == completed_cancellation["response"]["body"]["error_code"], "completed task cancellation code differed")

    [duplicate, invalid_structure] = [
      put_in(focused_task, ["context", "focus_points"], focused_task["context"]["focus_points"] ++ focused_task["context"]["focus_points"]),
      put_in(focused_task, ["context", "focus_points", Access.at(0), "source", "status"], "guessed")
    ]
    focus_rejections = Enum.map([duplicate, invalid_structure], fn invalid_task ->
      response = request(:post, "/dev/pi-browser-taskbar/tasks", invalid_task)
      body = response_json(response)
      assert!(response.status == 422 && body["error"]["code"] == "invalid_task", "invalid focus was accepted")
      %{"status" => response.status, "code" => body["error"]["code"]}
    end)

    held = request(:post, "/dev/pi-browser-taskbar/tasks", Map.put(task, "prompt", "hold this task")) |> response_json()
    held_id = held["task"]["id"]
    wait_until(fn ->
      PiBrowserTaskbarPhoenix.Runtime.snapshot(PiBrowserTaskbarPhoenix.Names.runtime(:demo)).task.output == "Implemented the whole-page request."
    end)
    busy_reset_scenario = reset_scenarios["session-reset-busy"]
    busy_reset_response = request(:post, "/dev/pi-browser-taskbar/session/reset")
    busy_reset = response_json(busy_reset_response)
    assert!(busy_reset_response.status == busy_reset_scenario["response"]["status"], "busy reset status differed")
    assert!(busy_reset["error"]["code"] == busy_reset_scenario["response"]["body"]["error_code"], "busy reset code differed")
    assert!(busy_reset["snapshot"]["task"]["id"] == held_id, "busy reset changed the retained task")

    wait_until(fn ->
      PiBrowserTaskbarPhoenix.Runtime.snapshot(PiBrowserTaskbarPhoenix.Names.runtime(:demo)).task.output == "Implemented the whole-page request."
    end)

    wrong_scenario = cancellation_scenarios["cancellation-wrong-id"]
    wrong_response = request(:delete, "/dev/pi-browser-taskbar/tasks/unknown-task")
    wrong_cancellation = response_json(wrong_response)
    assert!(wrong_response.status == wrong_scenario["response"]["status"], "unknown task cancellation status differed")
    assert!(wrong_cancellation["error"]["code"] == wrong_scenario["response"]["body"]["error_code"], "unknown task cancellation code differed")

    accepted_scenario = cancellation_scenarios["cancellation-accepted"]
    accepted_response = request(:delete, "/dev/pi-browser-taskbar/tasks/#{held_id}")
    cancelling = response_json(accepted_response)
    assert!(accepted_response.status == accepted_scenario["response"]["status"], "cancellation was not accepted")
    assert!(cancelling["task"]["status"] == accepted_scenario["response"]["body"]["task_status"], "task did not enter cancelling")
    assert!(is_nil(cancelling["task"]["finished_at"]), "cancellation finished before agent_settled")

    repeated_scenario = cancellation_scenarios["cancellation-repeated"]
    repeated_response = request(:delete, "/dev/pi-browser-taskbar/tasks/#{held_id}")
    assert!(repeated_response.status == repeated_scenario["response"]["status"], "repeated cancellation was not idempotent")
    assert!(response_json(repeated_response)["task"]["status"] == repeated_scenario["response"]["body"]["task_status"], "repeated cancellation changed state")

    settled_scenario = cancellation_scenarios["cancellation-settled"]
    wait_until(fn ->
      PiBrowserTaskbarPhoenix.Runtime.snapshot(PiBrowserTaskbarPhoenix.Names.runtime(:demo)).task.status == settled_scenario["response"]["body"]["task_status"]
    end)
    settled_response = request(:get, "/dev/pi-browser-taskbar/state")
    cancelled = response_json(settled_response)
    assert!(cancelled["session"]["status"] == settled_scenario["response"]["body"]["session_status"], "session was not ready after settled cancellation")
    assert!(cancelled["task"]["activity"] == settled_scenario["response"]["body"]["task_activity"], "settled cancellation activity differed")
    already = request(:delete, "/dev/pi-browser-taskbar/tasks/#{held_id}")
    assert!(already.status == 200 && response_json(already)["task"]["status"] == "cancelled", "cancelled task was not idempotent")

    accepted_reset_scenario = reset_scenarios["session-reset-accepted"]
    old_session_id = cancelled["session"]["id"]
    accepted_reset_response = request(:post, "/dev/pi-browser-taskbar/session/reset")
    accepted_reset = response_json(accepted_reset_response)
    assert!(accepted_reset_response.status == accepted_reset_scenario["response"]["status"], "session reset was not accepted")
    assert!(accepted_reset["session"]["status"] == accepted_reset_scenario["response"]["body"]["session_status"], "reset did not return ready")
    assert!(is_nil(accepted_reset["task"]), "successful reset retained task feedback")
    assert!(accepted_reset["session"]["id"] != old_session_id, "successful reset retained the old session identity")

    request(:post, "/dev/pi-browser-taskbar/tasks", Map.put(task, "prompt", "reject reset"))
    wait_until(fn ->
      PiBrowserTaskbarPhoenix.Runtime.snapshot(PiBrowserTaskbarPhoenix.Names.runtime(:demo)).task.status == "completed"
    end)
    retained_reset_state = request(:get, "/dev/pi-browser-taskbar/state") |> response_json()
    rejected_reset_scenario = reset_scenarios["session-reset-rejected"]
    rejected_reset_response = request(:post, "/dev/pi-browser-taskbar/session/reset")
    rejected_reset = response_json(rejected_reset_response)
    assert!(rejected_reset_response.status == rejected_reset_scenario["response"]["status"], "extension-rejected reset status differed")
    assert!(rejected_reset["error"]["code"] == rejected_reset_scenario["response"]["body"]["error_code"], "extension-rejected reset code differed")
    assert!(rejected_reset["snapshot"] == retained_reset_state, "extension-rejected reset changed retained state")

    rpc_progress =
      Map.new(%{
        "agent_start" => "Pi is working", "agent_end" => "Pi finished a turn",
        "tool_start" => "Running read", "tool_update" => "Running read", "tool_end" => "Finished read",
        "compaction_start" => "Compacting conversation", "compaction_end" => "Retrying after compaction",
        "retry_start" => "Retrying request (2/3)", "retry_end" => "Pi is working"
      }, fn {event, activity} ->
        created = request(:post, "/dev/pi-browser-taskbar/tasks", Map.put(task, "prompt", "activity #{event}")) |> response_json()
        wait_until(fn ->
          PiBrowserTaskbarPhoenix.Runtime.snapshot(PiBrowserTaskbarPhoenix.Names.runtime(:demo)).task.activity == activity
        end)
        observed = request(:get, "/dev/pi-browser-taskbar/state") |> response_json()
        assert!(observed["task"]["status"] == "running", "#{event} completed before agent_settled")
        request(:delete, "/dev/pi-browser-taskbar/tasks/#{created["task"]["id"]}")
        wait_until(fn ->
          PiBrowserTaskbarPhoenix.Runtime.snapshot(PiBrowserTaskbarPhoenix.Names.runtime(:demo)).task.status == "cancelled"
        end)
        {event, %{"status" => observed["task"]["status"], "activity" => observed["task"]["activity"]}}
      end)

    dialog = request(:post, "/dev/pi-browser-taskbar/tasks", Map.put(task, "prompt", "dialog request")) |> response_json()
    Process.sleep(50)
    request(:delete, "/dev/pi-browser-taskbar/tasks/#{dialog["task"]["id"]}")
    wait_until(fn ->
      PiBrowserTaskbarPhoenix.Runtime.snapshot(PiBrowserTaskbarPhoenix.Names.runtime(:demo)).task.status == "cancelled"
    end)

    request(:post, "/dev/pi-browser-taskbar/tasks", Map.put(task, "prompt", "bounded output"))
    wait_until(fn ->
      PiBrowserTaskbarPhoenix.Runtime.snapshot(PiBrowserTaskbarPhoenix.Names.runtime(:demo)).task.status == "completed"
    end)
    bounded = request(:get, "/dev/pi-browser-taskbar/state") |> response_json()
    rpc_output = %{
      "status" => bounded["task"]["status"], "bytes" => byte_size(bounded["task"]["output"]),
      "valid_utf8" => String.valid?(bounded["task"]["output"]), "suffix" => String.ends_with?(bounded["task"]["output"], "🙂z"),
      "truncated" => bounded["task"]["output_truncated"]
    }

    rpc_failures =
      Map.new(%{
        "rejected command" => "Pi rejected the task", "message error" => "Pi reported a message error",
        "retry failure" => "Pi could not complete the task after retries",
        "compaction failure" => "Pi could not compact the conversation",
        "unexpected response" => "Pi returned an unexpected RPC response",
        "malformed record" => "Pi sent a malformed RPC record", "oversized record" => "Pi sent an oversized RPC record",
        "non-object record" => "Pi sent a non-object RPC record"
      }, fn {prompt, expected_error} ->
        request(:post, "/dev/pi-browser-taskbar/tasks", Map.put(task, "prompt", prompt))
        wait_until(fn ->
          PiBrowserTaskbarPhoenix.Runtime.snapshot(PiBrowserTaskbarPhoenix.Names.runtime(:demo)).task.status == "failed"
        end)
        failed = request(:get, "/dev/pi-browser-taskbar/state") |> response_json()
        assert!(failed["task"]["error"] == expected_error, "unsafe or incorrect #{prompt} evidence")
        wait_until(fn ->
          PiBrowserTaskbarPhoenix.Runtime.snapshot(PiBrowserTaskbarPhoenix.Names.runtime(:demo)).session.status == "ready"
        end)
        {prompt, %{"status" => failed["task"]["status"], "error" => failed["task"]["error"]}}
      end)

    if path = System.get_env("PI_BROWSER_TASKBAR_SEMANTICS") do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(%{
        "created_status" => created.status,
        "created" => created_json,
        "completed_status" => 200,
        "completed" => completed,
        "focus_rejections" => focus_rejections,
        "cancellation" => %{
          "wrong_status" => wrong_response.status,
          "wrong" => wrong_cancellation,
          "accepted_status" => accepted_response.status,
          "accepted" => cancelling,
          "settled_status" => settled_response.status,
          "settled" => cancelled
        },
        "reset" => %{
          "busy_status" => busy_reset_response.status,
          "busy" => busy_reset,
          "accepted_status" => accepted_reset_response.status,
          "accepted" => accepted_reset,
          "rejected_status" => rejected_reset_response.status,
          "rejected" => rejected_reset
        },
        "rpc" => %{
          "progress" => rpc_progress,
          "dialog" => "cancelled",
          "output" => rpc_output,
          "failures" => rpc_failures
        }
      }, pretty: true))
    end

    {:safe, layout} = DemoWeb.PiBrowserTaskbar.layout_bootstrap()
    assert!(IO.iodata_to_binary(layout) =~ "data-pi-browser-taskbar-bootstrap", "layout bootstrap missing")
    assert!(is_pid(Process.whereis(DemoWeb.Endpoint)), "host endpoint did not boot")
    IO.puts("clean Phoenix development conformance passed")
  end

  defp request(method, path, body \\ nil) do
    secret = String.duplicate("a", 64)
    Plug.CSRFProtection.delete_csrf_token()
    Plug.CSRFProtection.load_state(secret, nil)
    token = Plug.CSRFProtection.get_csrf_token()
    state = Plug.CSRFProtection.dump_state()

    session_options = Plug.Session.init(store: :cookie, key: "_demo", signing_salt: "clean-app")
    encoded = if body, do: Jason.encode!(body), else: ""

    conn(method, path, encoded)
    |> Map.put(:host, "localhost")
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> Map.put(:secret_key_base, secret)
    |> Plug.Session.call(session_options)
    |> fetch_session()
    |> put_session("_csrf_token", state)
    |> put_req_header("accept", "application/json")
    |> maybe_json(body)
    |> put_req_header("x-csrf-token", token)
    |> DemoWeb.Router.call(DemoWeb.Router.init([]))
  end

  defp maybe_json(conn, nil), do: conn
  defp maybe_json(conn, _body), do: put_req_header(conn, "content-type", "application/json")
  defp response_json(conn), do: Jason.decode!(conn.resp_body)

  defp wait_until(predicate, attempts \\ 200)
  defp wait_until(predicate, attempts) when attempts > 0 do
    if predicate.(), do: :ok, else: (Process.sleep(10); wait_until(predicate, attempts - 1))
  end
  defp wait_until(_predicate, 0), do: raise("clean Phoenix conformance timed out")
  defp assert!(true, _message), do: :ok
  defp assert!(false, message), do: raise(message)
end

CleanAppConformance.run()
EOF

cat >"$app/production_check.exs" <<'EOF'
unless Process.whereis(DemoWeb.Endpoint), do: raise("production host endpoint did not boot")
if Code.ensure_loaded?(PiBrowserTaskbarPhoenix), do: raise("development package loaded in production")
if DemoWeb.PiBrowserTaskbar.layout_bootstrap() != {:safe, ""}, do: raise("production emitted assets")

if Enum.any?(Phoenix.Router.routes(DemoWeb.Router), &String.starts_with?(&1.path, "/dev/pi-browser-taskbar")) do
  raise "production mounted taskbar routes"
end

if Enum.any?(Supervisor.which_children(Demo.Supervisor), fn {_id, pid, _type, _modules} ->
     is_pid(pid) and pid != Process.whereis(DemoWeb.Endpoint)
   end) do
  raise "production started a taskbar process"
end

IO.puts("clean Phoenix production isolation passed")
EOF

export PI_BROWSER_TASKBAR_FAKE="$tmp/fake_pi_rpc"
export PI_BROWSER_TASKBAR_SCENARIO="$tmp/scenario.json"
export PI_BROWSER_TASKBAR_TASK="$tmp/task.json"
export PI_BROWSER_TASKBAR_FOCUSED_SCENARIO="$tmp/focused-scenario.json"
export PI_BROWSER_TASKBAR_FOCUSED_TASK="$tmp/focused-task.json"
export PI_BROWSER_TASKBAR_CANCELLATION_SCENARIOS="$tmp/cancellation-scenarios"
export PI_BROWSER_TASKBAR_RESET_SCENARIOS="$tmp/reset-scenarios"
export PI_BROWSER_TASKBAR_SEMANTICS="$root/build/conformance/phoenix.json"

(
  cd "$app"
  MIX_ENV=dev mix deps.get --quiet
  MIX_ENV=dev mix pi_browser_taskbar.install
  MIX_ENV=dev mix run conformance.exs
)

mv "$package" "$tmp/package-removed"

(
  cd "$app"
  MIX_ENV=prod mix compile --warnings-as-errors
  MIX_ENV=prod mix run production_check.exs
)
