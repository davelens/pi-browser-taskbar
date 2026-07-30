defmodule PiBrowserTaskbarPhoenix.IntegrationTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias PiBrowserTaskbarPhoenix.{Layout, Names, Router, Runtime}

  defmodule HostRouter do
    use Phoenix.Router

    import Phoenix.Controller
    require PiBrowserTaskbarPhoenix.Router

    pipeline :browser do
      plug(:accepts, ["html"])

      plug(Plug.Session,
        store: :cookie,
        key: "_host_key",
        signing_salt: "test-signing-salt"
      )

      plug(:fetch_session)
      plug(:protect_from_forgery)
    end

    Router.routes_ast(otp_app: :pi_browser_taskbar_router_test)
  end

  setup do
    name = Names.runtime(:pi_browser_taskbar_router_test)
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
    :ok
  end

  test "router mount serves state and native CSRF rejects an unprotected mutation" do
    state =
      request(:get, "/dev/pi-browser-taskbar/state")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> HostRouter.call(HostRouter.init([]))

    assert state.status == 200

    assert_raise Plug.Conn.WrapperError, ~r/invalid CSRF/, fn ->
      HostRouter.call(
        request(:post, "/dev/pi-browser-taskbar/tasks", Jason.encode!(%{}))
        |> Plug.Conn.put_req_header("content-type", "application/json"),
        HostRouter.init([])
      )
    end
  end

  test "layout bootstrap uses package routes and the native CSRF token" do
    {:safe, safe_html} = Layout.render(mount: "/dev/pi-browser-taskbar", otp_app: :demo)
    html = IO.iodata_to_binary(safe_html)

    assert html =~ ~s(data-pi-browser-taskbar-bootstrap)
    assert html =~ ~s(/dev/pi-browser-taskbar/assets/pi_browser_taskbar.css)
    assert html =~ ~s(/dev/pi-browser-taskbar/assets/pi_browser_taskbar.js)
    assert html =~ ~s(data-project-app="demo")
    assert html =~ ~s(data-csrf-token=")
  end

  defp request(method, path, body \\ "") do
    session_options =
      Plug.Session.init(
        store: :cookie,
        key: "_host_key",
        signing_salt: "test-signing-salt"
      )

    conn(method, path, body)
    |> Map.put(:host, "localhost")
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> Map.put(:secret_key_base, String.duplicate("a", 64))
    |> Plug.Session.call(session_options)
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
