defmodule PiBrowserTaskbarPhoenix.MixProject do
  use Mix.Project

  def project do
    [
      app: :pi_browser_taskbar_phoenix,
      version: "0.1.0",
      elixir: ">= 1.11.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Development-only Pi browser taskbar adapter for Phoenix",
      package: package()
    ]
  end

  def application do
    [extra_applications: [:crypto, :logger]]
  end

  defp deps do
    [
      {:jason, ">= 1.4.0 and < 2.0.0"},
      {:phoenix, ">= 1.7.0 and < 2.0.0"}
    ]
  end

  defp package do
    [
      files: [
        "lib",
        "priv",
        ".formatter.exs",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/davelens/pi-browser-taskbar"}
    ]
  end
end
