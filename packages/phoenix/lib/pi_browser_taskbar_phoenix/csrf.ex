defmodule PiBrowserTaskbarPhoenix.CSRF do
  @moduledoc "Applies Plug's native session-bound CSRF check with a stable JSON rejection."

  import Plug.Conn

  @behaviour Plug

  @assets ~w(pi_browser_taskbar.js pi_browser_taskbar.css)

  @impl true
  def init(opts), do: Plug.CSRFProtection.init(opts)

  @impl true
  def call(conn, opts) do
    conn =
      case {conn.method, Enum.take(conn.path_info, -2)} do
        {"GET", ["assets", asset]} when asset in @assets ->
          put_private(conn, :plug_skip_csrf_protection, true)

        _other ->
          conn
      end

    Plug.CSRFProtection.call(conn, opts)
  rescue
    Plug.CSRFProtection.InvalidCSRFTokenError ->
      payload = %{
        error: %{
          code: "invalid_csrf",
          message: "The session CSRF token is invalid"
        }
      }

      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(422, Jason.encode!(payload))
      |> halt()
  end
end
