defmodule PiBrowserTaskbarPhoenix.Layout do
  @moduledoc "Renders bounded layout bootstrap data for the package-owned Browser Client."

  @doc "Returns safe layout markup using Phoenix's session-bound CSRF token."
  @spec render(keyword()) :: {:safe, iodata()}
  def render(opts \\ []) do
    mount = Keyword.get(opts, :mount, "/dev/pi-browser-taskbar")
    project_app = opts |> Keyword.get(:otp_app, :unknown) |> Atom.to_string()
    csrf_token = Plug.CSRFProtection.get_csrf_token()
    remote_access? = Keyword.get(opts, :remote_access, false)

    html = [
      ~s(<link rel="stylesheet" href="#{escape(mount)}/assets/pi_browser_taskbar.css">),
      ~s(<div data-pi-browser-taskbar-bootstrap data-mount-base="#{escape(mount)}" data-project-app="#{escape(project_app)}" data-csrf-token="#{escape(csrf_token)}" data-remote-access="#{remote_access?}"></div>),
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
