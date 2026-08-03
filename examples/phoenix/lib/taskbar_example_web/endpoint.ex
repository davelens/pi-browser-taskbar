defmodule TaskbarExampleWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :taskbar_example

  @session_options [store: :cookie, key: "_taskbar_example", signing_salt: "session-salt"]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Session, @session_options
  plug TaskbarExampleWeb.Router
end
