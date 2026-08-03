defmodule TaskbarExample.MixProject do
  use Mix.Project

  def project do
    [
      app: :taskbar_example,
      version: "0.1.0",
      elixir: "~> 1.17",
      listeners: [Phoenix.CodeReloader],
      deps: deps()
    ]
  end

  def application do
    [mod: {TaskbarExample.Application, []}, extra_applications: [:logger]]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_view, "~> 1.0"},
      {:bandit, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:pi_browser_taskbar_phoenix, path: "../../packages/phoenix", only: :dev, runtime: false}
    ]
  end
end
