defmodule PiBrowserTaskbarPhoenix.MixProject do
  use Mix.Project

  def project do
    [
      app: :pi_browser_taskbar_phoenix,
      version: "0.4.0",
      elixir: ">= 1.11.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Development-only Pi browser taskbar adapter for Phoenix",
      package: package(),
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "CHANGELOG.md",
          "contract/docs/index.md",
          "contract/traceability.md",
          "docs/security.md",
          "docs/troubleshooting.md"
        ]
      ]
    ]
  end

  def application do
    [extra_applications: [:crypto, :logger]]
  end

  defp deps do
    [
      {:jason, ">= 1.4.0 and < 2.0.0"},
      {:phoenix, ">= 1.7.0 and < 2.0.0"},
      {:ex_doc, "~> 0.38", only: :docs, runtime: false}
    ]
  end

  defp package do
    [
      files:
        ([".formatter.exs", "mix.exs", "README.md", "CHANGELOG.md", "LICENSE"] ++
           Path.wildcard("{lib,priv,contract,docs}/**/*"))
        |> Enum.filter(&File.regular?/1)
        |> Enum.sort(),
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/davelens/pi-browser-taskbar"}
    ]
  end
end
