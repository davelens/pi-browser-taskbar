defmodule PiBrowserTaskbarPhoenix do
  @moduledoc """
  Development-only Phoenix adapter package seam.
  """

  @version "0.1.0"

  @doc "Returns the lockstep product version."
  @spec version() :: String.t()
  def version, do: @version

  @doc "Returns the package-owned prebuilt browser bootstrap path."
  @spec browser_asset_path() :: String.t()
  def browser_asset_path, do: Path.join(static_path(), "pi_browser_taskbar.js")

  @doc "Returns the package-owned static asset directory."
  @spec static_path() :: String.t()
  def static_path do
    :pi_browser_taskbar_phoenix
    |> :code.priv_dir()
    |> Path.join("static")
  end
end
