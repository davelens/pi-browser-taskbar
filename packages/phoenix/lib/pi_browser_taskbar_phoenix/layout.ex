defmodule PiBrowserTaskbarPhoenix.Layout do
  @moduledoc "Renders bounded layout bootstrap data for the package-owned Browser Client."

  @doc "Returns safe layout markup using Phoenix's session-bound CSRF token."
  @spec render(keyword()) :: {:safe, iodata()}
  def render(opts \\ []) do
    mount = Keyword.get(opts, :mount, "/dev/pi-browser-taskbar")
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    html = [
      ~s(<link rel="stylesheet" href="#{escape(mount)}/assets/pi_browser_taskbar.css">),
      ~s(<div data-pi-browser-taskbar-bootstrap data-mount-base="#{escape(mount)}" data-csrf-token="#{escape(csrf_token)}"></div>),
      ~s(<script defer src="#{escape(mount)}/assets/pi_browser_taskbar.js"></script>)
    ]

    {:safe, html}
  end

  defp escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
