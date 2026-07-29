defmodule PiBrowserTaskbarPhoenix.MixProject do
  use Mix.Project

  def project do
    [
      app: :pi_browser_taskbar_phoenix,
      version: "0.1.0",
      elixir: ">= 1.11.0",
      start_permanent: Mix.env() == :prod,
      deps: [],
      description: "Development-only Pi browser taskbar adapter for Phoenix",
      package: package()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp package do
    [
      files: ["lib", "priv", ".formatter.exs", "mix.exs", "README.md", "CHANGELOG.md"],
      licenses: ["Nonstandard"],
      links: %{"GitHub" => "https://github.com/davelens/pi-browser-taskbar"}
    ]
  end
end
