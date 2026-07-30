defmodule Mix.Tasks.PiBrowserTaskbar.Install do
  @moduledoc "Installs Pi Browser Taskbar into a conventional Phoenix application."

  use Mix.Task

  @shortdoc "Installs the development-only Phoenix taskbar integration"

  @impl true
  def run(args) do
    {opts, remaining, invalid} = OptionParser.parse(args, strict: [root: :string])

    if remaining != [] or invalid != [] do
      Mix.raise("usage: mix pi_browser_taskbar.install [--root PATH]")
    end

    PiBrowserTaskbarPhoenix.Installer.run!(opts)
    Mix.shell().info("Installed Pi Browser Taskbar Phoenix integration")
  end
end
