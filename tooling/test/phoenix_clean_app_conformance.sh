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

    if path = System.get_env("PI_BROWSER_TASKBAR_SEMANTICS") do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(%{
        "created_status" => created.status,
        "created" => normalize(created_json),
        "completed_status" => 200,
        "completed" => normalize(completed)
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

  defp normalize(value) when is_map(value) do
    value
    |> Map.drop(["id", "started_at", "finished_at"])
    |> Map.new(fn {key, nested} -> {key, normalize(nested)} end)
  end
  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  defp normalize(value), do: value

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
