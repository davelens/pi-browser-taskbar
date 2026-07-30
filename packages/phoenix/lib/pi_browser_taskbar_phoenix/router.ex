defmodule PiBrowserTaskbarPhoenix.Router do
  @moduledoc "Phoenix router expansion for the versioned task API and package assets."

  alias PiBrowserTaskbarPhoenix.Names

  @doc false
  defmacro routes_ast(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    mount = Keyword.get(opts, :mount, "/dev/pi-browser-taskbar")
    runtime = Names.runtime(otp_app)

    quote do
      pipeline :pi_browser_taskbar_v1 do
        plug(:fetch_session)
        plug(:protect_from_forgery)
      end

      scope unquote(mount), alias: false, as: :pi_browser_taskbar do
        pipe_through(:pi_browser_taskbar_v1)
        forward("/", PiBrowserTaskbarPhoenix.Endpoint, runtime: unquote(runtime))
      end
    end
  end
end
