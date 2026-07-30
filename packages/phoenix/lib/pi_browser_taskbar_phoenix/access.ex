defmodule PiBrowserTaskbarPhoenix.Access do
  @moduledoc "Restricts every taskbar request by framework-normalized host and peer address."

  import Plug.Conn

  @loopback_addresses [
    {127, 0, 0, 1},
    {0, 0, 0, 0, 0, 0, 0, 1},
    {0, 0, 0, 0, 0, 65_535, 32_512, 1}
  ]

  @doc "Allows loopback host/client pairs or an exact explicitly allowed host."
  @spec call(Plug.Conn.t(), [String.t()]) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, allowed_hosts) do
    host = normalize_host(conn.host)
    configured? = host in allowed_hosts

    allowed? =
      if conn.remote_ip in @loopback_addresses do
        local_host?(host) or configured?
      else
        allowed_hosts != [] and configured?
      end

    if allowed?, do: conn, else: reject(conn)
  end

  defp local_host?(host) do
    host in ["localhost", "127.0.0.1", "::1"] or String.ends_with?(host, ".localhost")
  end

  defp normalize_host(host), do: host |> String.downcase() |> String.trim_trailing(".")

  defp reject(conn) do
    payload = %{
      error: %{
        code: "forbidden",
        message: "Pi Browser Taskbar is not allowed from this host or client address"
      }
    }

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(403, Jason.encode!(payload))
    |> halt()
  end
end
