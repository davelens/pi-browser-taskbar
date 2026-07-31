#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
version=$(<"$root/VERSION")
artifact="$root/build/pi_browser_taskbar_phoenix-$version.tar"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pi-browser-taskbar-phoenix.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

app="$tmp/demo"
phoenix_version=${PI_BROWSER_TASKBAR_TEST_PHOENIX_VERSION:-1.8.9}
elixir_version=${PI_BROWSER_TASKBAR_TEST_ELIXIR_VERSION:-$(elixir -e 'IO.write(System.version())')}
otp_version=${PI_BROWSER_TASKBAR_TEST_OTP_VERSION:-$(elixir -e 'root = :code.root_dir() |> to_string(); major = System.otp_release(); path = Path.join([root, "releases", major, "OTP_VERSION"]); IO.write(if File.exists?(path), do: String.trim(File.read!(path)), else: major)')}
live_view_version=${PI_BROWSER_TASKBAR_TEST_LIVE_VIEW_VERSION:-1.2.8}
repo="$tmp/hex-repo"
repo_name=pbtlocal
http_pid=""
cleanup() {
  [[ -n "$http_pid" ]] && kill "$http_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

[[ -f "$artifact" ]] || { echo "missing built Phoenix package: $artifact" >&2; exit 1; }
[[ "$(elixir -e 'IO.write(System.version())')" == "$elixir_version" ]] || { echo "Elixir runtime differs from matrix row" >&2; exit 1; }
[[ "$(elixir -e 'IO.write(System.otp_release())')" == "${otp_version%%.*}" ]] || { echo "OTP runtime differs from matrix row" >&2; exit 1; }

# Publish the already-built tarball to an isolated signed Hex repository. The generated app therefore
# resolves the adapter through Hex.SCM instead of a path or source-workspace fallback.
export MIX_HOME="$tmp/mix-home"
export HEX_HOME="$tmp/hex-home"
mix local.hex --force >/dev/null
mix local.rebar --force >/dev/null
mkdir -p "$repo/tarballs" "$root/build/conformance" "$root/build/compatibility"
cp "$artifact" "$repo/tarballs/"
openssl genrsa -out "$tmp/hex-private.pem" 2048 >/dev/null 2>&1
mix hex.registry build "$repo" --name="$repo_name" --private-key="$tmp/hex-private.pem" >/dev/null
port=$(ruby -rsocket -e 'server = TCPServer.new("127.0.0.1", 0); puts server.addr[1]; server.close')
(
  cd "$repo"
  python3 -m http.server "$port" >"$tmp/hex-http.log" 2>&1 &
  echo $! >"$tmp/hex-http.pid"
)
http_pid=$(<"$tmp/hex-http.pid")
for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$port/public_key" >/dev/null 2>&1 && break; sleep 0.02; done
mix hex.repo add "$repo_name" "http://127.0.0.1:$port" --public-key="$repo/public_key" >/dev/null

if [[ "$elixir_version" == 1.11.* || "$elixir_version" == 1.15.* ]]; then
  mix hex.package fetch phx_new "$phoenix_version" --unpack --output "$tmp/phx_new" >/dev/null
  sed -Ei 's/@elixir_requirement "[^"]+"/@elixir_requirement ">= 1.11.0"/' "$tmp/phx_new/mix.exs"
  sed -Ei 's/Version\.match\?\(System\.version\(\), "[^"]+"\)/Version.match?(System.version(), ">= 1.11.0")/' "$tmp/phx_new/lib/mix/tasks/phx.new.ex"
  (cd "$tmp/phx_new" && mix archive.build --output "$tmp/phx_new.ez" >/dev/null)
  mix archive.install "$tmp/phx_new.ez" --force >/dev/null
else
  mix archive.install hex phx_new "$phoenix_version" --force >/dev/null
fi
printf 'mix phx.new: generating conventional Phoenix %s application\n' "$phoenix_version"
mix phx.new "$app" --no-install --no-ecto --no-mailer --no-dashboard --no-assets --no-gettext --adapter cowboy

MATRIX_VERSION="$version" MATRIX_PHOENIX="$phoenix_version" MATRIX_ELIXIR="$elixir_version" \
MATRIX_LIVE_VIEW="$live_view_version" ruby - "$app/mix.exs" <<'RUBY'
path = ARGV.fetch(0)
source = File.read(path)
source.sub!(/^\s*elixir: .+,$/, %(      elixir: ">= #{ENV.fetch("MATRIX_ELIXIR")}",)) or abort "generated app Elixir constraint not found"
source.sub!(/^\s*\{:phoenix, .+,$/, %(      {:phoenix, "== #{ENV.fetch("MATRIX_PHOENIX")}"},)) or abort "generated Phoenix dependency not found"
source.sub!(/^\s*\{:phoenix_live_view, .+,$/, %(      {:phoenix_live_view, "== #{ENV.fetch("MATRIX_LIVE_VIEW")}"},)) or abort "generated LiveView dependency not found"
source.sub!(/(  defp deps do\n    \[\n)/, %(\\1      {:pi_browser_taskbar_phoenix, "== #{ENV.fetch("MATRIX_VERSION")}", only: :dev, runtime: false, repo: "pbtlocal"},\n)) or abort "generated dependency list not found"
if ENV.fetch("MATRIX_ELIXIR").start_with?("1.11.")
  source.sub!(/^\s*\{:phoenix_html, .+,$/, %(      {:phoenix_html, "== 3.3.4"},)) or abort "generated Phoenix HTML dependency not found"
  source.sub!(/^\s*\{:telemetry_poller, .+,$/, %(      {:telemetry_poller, "== 1.1.0"},)) or abort "generated telemetry poller dependency not found"
  source.sub!(/^\s*\{:floki, .+,$/, %(      {:floki, "== 0.34.3", only: :test},)) or abort "generated Floki dependency not found"
  source.sub!(/^\s*\{:plug_cowboy, .+$/, %(      {:plug_cowboy, "== 2.8.0"})) or abort "generated Cowboy adapter dependency not found"
  source.sub!(/(\{:phoenix, "==[^\n]+\n)/, "\\1      {:plug, \"== 1.18.1\", override: true},\n      {:plug_crypto, \"== 2.1.1\", override: true},\n")
end
File.write(path, source)
RUBY

cat >>"$app/config/dev.exs" <<'EOF'

config :demo, :pi_browser_taskbar,
  executable: System.fetch_env!("PI_BROWSER_TASKBAR_FAKE"),
  project_root: Path.expand("..", __DIR__),
  task_timeout: 60
EOF

if [[ "$elixir_version" == 1.11.* ]]; then
  cat >"$app/lib/demo_web/components/core_components.ex" <<'EOF'
defmodule DemoWeb.CoreComponents do
  use Phoenix.Component
end
EOF
  cat >"$app/lib/demo_web/components/layouts.ex" <<'EOF'
defmodule DemoWeb.Layouts do
  use Phoenix.Component
  def root(assigns), do: ~H"""
  <!doctype html><html><body><%= @inner_content %></body></html>
  """
  def app(assigns), do: ~H"""
  <main><%= @inner_content %></main>
  """
end
EOF
  cat >"$app/lib/demo_web/controllers/page_html.ex" <<'EOF'
defmodule DemoWeb.PageHTML do
  use Phoenix.Component
  def home(assigns), do: ~H"""
  <main>Home</main>
  """
end
EOF
  printf '<main>Home</main>\n' >"$app/lib/demo_web/controllers/page_html/home.html.heex"
  cat >"$app/lib/demo_web/components/layouts/root.html.heex" <<'EOF'
<!doctype html>
<html>
  <body>
    <%= @inner_content %>
  </body>
</html>
EOF
  printf '<main><%%= @inner_content %%></main>\n' >"$app/lib/demo_web/components/layouts/app.html.heex"
fi

cp "$root/packages/phoenix/test/support/fake_pi_rpc" "$tmp/fake_pi_rpc"
chmod +x "$tmp/fake_pi_rpc"
cp "$root/contract/fixtures/scenarios/phoenix-whole-page.json" "$tmp/scenario.json"
cp "$root/contract/fixtures/tasks/minimal-task.json" "$tmp/task.json"
cp "$root/contract/fixtures/scenarios/focused-task.json" "$tmp/focused-scenario.json"
cp "$root/contract/fixtures/tasks/focused-task.json" "$tmp/focused-task.json"
mkdir "$tmp/cancellation-scenarios" "$tmp/reset-scenarios"
cp "$root"/contract/fixtures/scenarios/cancellation-*.json "$tmp/cancellation-scenarios/"
cp "$root"/contract/fixtures/scenarios/session-reset-*.json "$tmp/reset-scenarios/"

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

    asset = request(:get, "/dev/pi-browser-taskbar/assets/pi_browser_taskbar.css")
    assert!(asset.status == 200, "packaged Browser Client asset did not return 200")
    assert!(asset.resp_body =~ "Generated by tooling/build_browser_assets.mjs", "packaged Browser Client asset differed")
    annotation_provider = :pi_browser_taskbar_phoenix |> :code.priv_dir() |> Path.join("static/pi_browser_taskbar.js") |> File.read!()
    assert!(annotation_provider =~ "data-phx-loc", "LiveView annotation provider missing")

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
    controller_example = TaskbarExampleWeb.PageHTML.index(%{}) |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    live_example = TaskbarExampleWeb.ScenarioLive.render(%{count: 0}) |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    assert!(controller_example =~ ~s(data-testid="scenario-whole-page"), "controller HEEx example missing")
    assert!(controller_example =~ ~s(data-testid="focus-card"), "example focus selector missing")
    assert!(live_example =~ ~s(data-testid="navigation-target"), "LiveView example missing")
    assert!(Application.get_env(:phoenix_live_view, :debug_heex_annotations) == true, "HEEx debug annotations not enabled")
    assert!(is_pid(Process.whereis(PiBrowserTaskbarPhoenix.Names.supervisor(:demo))), "package supervisor did not boot")
    assert!(is_pid(Process.whereis(DemoWeb.Endpoint)), "host endpoint did not boot")

    dependency_path = Path.expand("deps/pi_browser_taskbar_phoenix")
    otp_path = Path.join([to_string(:code.root_dir()), "releases", System.otp_release(), "OTP_VERSION"])
    observation = %{
      "platform" => %{"runtime" => "BEAM", "os" => to_string(:os.type() |> elem(1))},
      "versions" => %{
        "elixir" => System.version(),
        "otp" => if(File.exists?(otp_path), do: String.trim(File.read!(otp_path)), else: System.otp_release()),
        "phoenix" => Application.spec(:phoenix, :vsn) |> to_string(),
        "live_view" => Application.spec(:phoenix_live_view, :vsn) |> to_string()
      },
      "artifact" => %{"hex_scm" => true, "dependency_path" => dependency_path}
    }
    File.write!(System.fetch_env!("PI_BROWSER_TASKBAR_MATRIX_OBSERVATION"), Jason.encode!(observation, pretty: true))
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
    |> put_req_header("referer", "http://localhost/")
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

if Enum.any?(Supervisor.which_children(Demo.Supervisor), fn {id, pid, _type, modules} ->
     is_pid(pid) and String.contains?(inspect({id, modules}), "PiBrowserTaskbar")
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
export PI_BROWSER_TASKBAR_MATRIX_OBSERVATION="$tmp/matrix-observation.json"
export SECRET_KEY_BASE="clean-phoenix-secret-key-base-clean-phoenix-secret-key-base-clean-phoenix-secret-key-base"

(
  cd "$app"
  MIX_ENV=dev mix deps.get --quiet
  MIX_ENV=dev mix pi_browser_taskbar.install
  cp "$root/examples/phoenix/lib/taskbar_example_web.ex" lib/
  cp -R "$root/examples/phoenix/lib/taskbar_example_web" lib/
  if [[ "$elixir_version" == 1.11.* ]]; then
    sed -i 's/use Phoenix.LiveView, layout: {TaskbarExampleWeb.Layouts, :app}/use Phoenix.LiveView/' lib/taskbar_example_web.ex
    sed -i '/^  attr :title/d; s/{@title}/<%= @title %>/; s/{@count}/<%= @count %>/; s/{@inner_content}/<%= @inner_content %>/' \
      lib/taskbar_example_web/components/scenario_card.ex \
      lib/taskbar_example_web/live/scenario_live.ex \
      lib/taskbar_example_web/components/layouts/*.heex
    cat >lib/taskbar_example_web/components/layouts.ex <<'EOF'
defmodule TaskbarExampleWeb.Layouts do
  use TaskbarExampleWeb, :html
  def root(assigns), do: ~H"""
  <!doctype html><html><body><%= @inner_content %></body></html>
  """
  def app(assigns), do: ~H"""
  <main><%= @inner_content %></main>
  """
end
EOF
    cat >lib/taskbar_example_web/live/scenario_live.ex <<'EOF'
defmodule TaskbarExampleWeb.ScenarioLive do
  use Phoenix.LiveView
  def mount(_params, _session, socket), do: {:ok, assign(socket, count: 0)}
  def render(assigns) do
    ~H"""
    <main data-testid="scenario-navigation"><p data-testid="navigation-target">Patch count: <%= @count %></p></main>
    """
  end
end
EOF
    cat >lib/taskbar_example_web/controllers/page_html.ex <<'EOF'
defmodule TaskbarExampleWeb.PageHTML do
  use TaskbarExampleWeb, :html
  def index(assigns) do
    ~H"""
    <main data-testid="scenario-whole-page">
      <section data-testid="scenario-focused-card"><.scenario_card title="First card" /></section>
      <nav data-testid="scenario-navigation"><a href="/live" data-testid="navigation-target">LiveView navigation</a></nav>
    </main>
    """
  end
end
EOF
  fi
  MIX_ENV=dev mix run conformance.exs
  rm -rf lib/taskbar_example_web.ex lib/taskbar_example_web
  MIX_ENV=dev mix pi_browser_taskbar.install

  cp lib/demo_web/router.ex "$tmp/router.before-mutation"
  sed -i 's/DemoWeb.PiBrowserTaskbar.routes()/DemoWeb.PiBrowserTaskbar.routes(:edited)/' lib/demo_web/router.ex
  find config lib -type f -print0 | sort -z | xargs -0 sha256sum >"$tmp/mutated-host.sha256"
  if MIX_ENV=dev mix pi_browser_taskbar.install >"$tmp/mutation.out" 2>&1; then
    echo "edited generated router section was accepted" >&2
    exit 1
  fi
  find config lib -type f -print0 | sort -z | xargs -0 sha256sum >"$tmp/after-refusal.sha256"
  cmp "$tmp/mutated-host.sha256" "$tmp/after-refusal.sha256"
  grep -q 'edited generated routes section' "$tmp/mutation.out"
  mv "$tmp/router.before-mutation" lib/demo_web/router.ex
)

package="$app/deps/pi_browser_taskbar_phoenix"
test -f "$package/hex_metadata.config"
grep -q 'pi_browser_taskbar_phoenix.*:hex.*pbtlocal' "$app/mix.lock"
mv "$package" "$tmp/package-removed"

(
  cd "$app"
  MIX_ENV=prod mix compile --warnings-as-errors
  MIX_ENV=prod mix run production_check.exs
)

mv "$tmp/package-removed" "$package"

(
  cd "$app"
  MIX_ENV=dev mix pi_browser_taskbar.install --uninstall
  MIX_ENV=dev mix pi_browser_taskbar.install --uninstall
  test ! -e lib/demo_web/pi_browser_taskbar.ex
  ! grep -R -q 'pi-browser-taskbar:' lib config
  ! grep -R -q 'PiBrowserTaskbar' lib
)

mv "$package" "$tmp/package-removed"

(
  cd "$app"
  MIX_ENV=test mix compile --warnings-as-errors
  MIX_ENV=test mix run -e '
    unless Process.whereis(DemoWeb.Endpoint), do: raise("test host endpoint did not boot")
    if Code.ensure_loaded?(DemoWeb.PiBrowserTaskbar), do: raise("uninstalled integration loaded")
    IO.puts("clean Phoenix uninstall and test isolation passed")
  '
)

row_id=${PI_BROWSER_TASKBAR_MATRIX_ROW:-local-phoenix-${phoenix_version}-elixir-${elixir_version}-otp-${otp_version}}
evidence="$root/build/compatibility/$row_id.json"
PI_BROWSER_TASKBAR_ROW="$row_id" PI_BROWSER_TASKBAR_ARTIFACT="$artifact" \
PI_BROWSER_TASKBAR_OBSERVATION="$PI_BROWSER_TASKBAR_MATRIX_OBSERVATION" PI_BROWSER_TASKBAR_EVIDENCE="$evidence" ruby <<'RUBY'
require "digest"
require "json"
observation = JSON.parse(File.read(ENV.fetch("PI_BROWSER_TASKBAR_OBSERVATION")))
evidence = observation.merge(
  "schema" => 1,
  "row" => ENV.fetch("PI_BROWSER_TASKBAR_ROW"),
  "artifact" => observation.fetch("artifact").merge("sha256" => Digest::SHA256.file(ENV.fetch("PI_BROWSER_TASKBAR_ARTIFACT")).hexdigest),
  "checks" => %w[generated_app hex_install boot route asset mutation controller_heex live_view_annotation supervision uninstall development_only no_workspace_fallback]
)
File.write(ENV.fetch("PI_BROWSER_TASKBAR_EVIDENCE"), JSON.pretty_generate(evidence) + "\n")
RUBY
echo "Phoenix compatibility evidence: $evidence"
