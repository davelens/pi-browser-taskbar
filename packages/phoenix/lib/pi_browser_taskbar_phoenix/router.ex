defmodule PiBrowserTaskbarPhoenix.Router do
  @moduledoc "Phoenix router expansion for the versioned task API and package assets."

  alias PiBrowserTaskbarPhoenix.Names

  @doc false
  defmacro routes_ast(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    mount = Keyword.get(opts, :mount, "/dev/pi-browser-taskbar")
    pipeline = Keyword.get(opts, :pipeline, :pi_browser_taskbar_v1)
    helper = Keyword.get(opts, :helper, :pi_browser_taskbar)
    runtime = Names.runtime(otp_app)

    quote do
      pipeline unquote(pipeline) do
        plug(:fetch_session)
        plug(PiBrowserTaskbarPhoenix.CSRF)
      end

      scope unquote(mount), alias: false, as: unquote(helper) do
        pipe_through(unquote(pipeline))
        forward("/", PiBrowserTaskbarPhoenix.Endpoint, runtime: unquote(runtime))
      end
    end
  end
end
