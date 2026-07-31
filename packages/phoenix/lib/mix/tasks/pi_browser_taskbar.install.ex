defmodule Mix.Tasks.PiBrowserTaskbar.Install do
  @moduledoc "Installs, updates, or uninstalls the reversible Phoenix host integration."

  use Mix.Task

  @shortdoc "Installs or uninstalls the development-only Phoenix integration"

  @switches [
    root: :string,
    app: :string,
    web: :string,
    endpoint: :string,
    application: :string,
    router: :string,
    layout: :string,
    mount: :string,
    uninstall: :boolean
  ]

  @impl true
  def run(args) do
    {opts, remaining, invalid} = OptionParser.parse(args, strict: @switches)

    if remaining != [] or invalid != [] do
      Mix.raise(
        "usage: mix pi_browser_taskbar.install [--uninstall] [--root PATH] [--app APP] " <>
          "[--web MODULE] [--endpoint MODULE] [--application PATH] [--router PATH|MODULE] " <>
          "[--layout PATH] [--mount PATH]"
      )
    end

    if Keyword.get(opts, :uninstall, false) do
      PiBrowserTaskbarPhoenix.Installer.uninstall!(opts)
      Mix.Task.rerun("compile", ["--force"])
      Mix.shell().info("Uninstalled Pi Browser Taskbar Phoenix integration")

      Mix.shell().info(
        "Remove the :pi_browser_taskbar_phoenix development dependency manually if no longer needed"
      )
    else
      PiBrowserTaskbarPhoenix.Installer.run!(opts)
      Mix.Task.rerun("compile", ["--force"])
      Mix.shell().info("Installed Pi Browser Taskbar Phoenix integration")
    end
  end
end
