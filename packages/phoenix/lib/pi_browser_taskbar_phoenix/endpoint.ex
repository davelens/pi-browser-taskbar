defmodule PiBrowserTaskbarPhoenix.Endpoint do
  @moduledoc "Serves the versioned Phoenix task API and package-owned browser assets."

  @behaviour Plug

  import Plug.Conn

  alias PiBrowserTaskbarPhoenix.{Access, Runtime, Task}

  @max_body_bytes 128 * 1024

  @impl true
  def init(opts), do: Map.new(opts)

  @impl true
  def call(conn, %{runtime: runtime} = opts) do
    allowed_hosts = Runtime.config(runtime).allowed_hosts
    conn = Access.call(conn, allowed_hosts)

    if conn.halted do
      conn
    else
      dispatch(conn, runtime, opts)
    end
  end

  defp dispatch(%{method: "GET", path_info: ["state"]} = conn, runtime, _opts) do
    json(conn, 200, Runtime.snapshot(runtime))
  end

  defp dispatch(%{method: "POST", path_info: ["tasks"]} = conn, runtime, _opts) do
    with {:ok, params, conn} <- decode_body(conn),
         {:ok, task} <- Task.new(params),
         {:ok, snapshot} <- Runtime.submit(runtime, task) do
      json(conn, 202, snapshot)
    else
      {:error, :malformed_json, conn} ->
        error(conn, 400, "malformed_json", "Request body must be valid JSON")

      {:error, :oversized_payload, conn} ->
        error(conn, 413, "oversized_payload", "Request body exceeds 128 KiB")

      {:error, :invalid_task, message} ->
        error(conn, 422, "invalid_task", message)

      {:error, :busy, snapshot} ->
        error(conn, 409, "busy", "Another Pi task is active", snapshot)

      {:error, :unavailable, snapshot} ->
        error(conn, 503, "unavailable", "Pi is not ready", snapshot)
    end
  end

  defp dispatch(%{method: "POST", path_info: ["session", "reset"]} = conn, runtime, _opts) do
    case Runtime.reset(runtime) do
      {:ok, snapshot} ->
        json(conn, 202, snapshot)

      {:error, :reset_while_busy, snapshot} ->
        error(
          conn,
          409,
          "reset_while_busy",
          "A fresh session cannot start while Pi is busy",
          snapshot
        )

      {:error, :session_reset_rejected, snapshot} ->
        error(conn, 409, "session_reset_rejected", "Pi kept the current session", snapshot)

      {:error, :unavailable, snapshot} ->
        error(conn, 503, "unavailable", "Pi is not ready", snapshot)
    end
  end

  defp dispatch(%{method: "DELETE", path_info: ["tasks", id]} = conn, runtime, _opts) do
    case Runtime.cancel(runtime, id) do
      {:ok, :accepted, snapshot} ->
        json(conn, 202, snapshot)

      {:ok, :cancelled, snapshot} ->
        json(conn, 200, snapshot)

      {:error, :not_found, snapshot} ->
        error(conn, 404, "task_not_found", "Task was not found", snapshot)

      {:error, :not_cancellable, snapshot} ->
        error(conn, 409, "task_not_cancellable", "Task can no longer be stopped", snapshot)

      {:error, :unavailable, snapshot} ->
        error(conn, 503, "unavailable", "Pi is not ready", snapshot)
    end
  end

  defp dispatch(%{method: "GET", path_info: ["assets", filename]} = conn, _runtime, _opts)
       when filename in ["pi_browser_taskbar.js", "pi_browser_taskbar.css"] do
    content_type = if String.ends_with?(filename, ".js"), do: "text/javascript", else: "text/css"
    path = Path.join(PiBrowserTaskbarPhoenix.static_path(), filename)

    conn
    |> put_resp_content_type(content_type)
    |> put_resp_header("cache-control", "no-store")
    |> send_file(200, path)
  end

  defp dispatch(conn, _runtime, _opts) do
    error(conn, 404, "not_found", "Taskbar route was not found")
  end

  defp decode_body(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn) do
    case read_body(conn, length: @max_body_bytes, read_length: 64 * 1024) do
      {:ok, body, conn} -> decode_json(body, conn)
      {:more, _partial, conn} -> {:error, :oversized_payload, conn}
      {:error, _reason} -> {:error, :malformed_json, conn}
    end
  end

  defp decode_body(%Plug.Conn{body_params: params} = conn) when is_map(params) do
    content_length =
      case get_req_header(conn, "content-length") do
        [value] ->
          case Integer.parse(value) do
            {length, ""} -> length
            _invalid -> nil
          end

        _missing_or_duplicate ->
          nil
      end

    if content_length && content_length <= @max_body_bytes &&
         byte_size(Jason.encode!(params)) <= @max_body_bytes do
      {:ok, params, conn}
    else
      {:error, :oversized_payload, conn}
    end
  end

  defp decode_json(body, conn) do
    case Jason.decode(body) do
      {:ok, params} when is_map(params) -> {:ok, params, conn}
      _other -> {:error, :malformed_json, conn}
    end
  end

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(payload))
  end

  defp error(conn, status, code, message, snapshot \\ nil) do
    payload = %{error: %{code: code, message: message}}
    payload = if snapshot, do: Map.put(payload, :snapshot, snapshot), else: payload
    json(conn, status, payload)
  end
end
