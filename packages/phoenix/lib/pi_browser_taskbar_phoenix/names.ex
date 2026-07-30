defmodule PiBrowserTaskbarPhoenix.Names do
  @moduledoc "Derives collision-resistant registered process names from the host OTP application."

  @doc "Returns the package supervisor name for a host application."
  @spec supervisor(atom()) :: atom()
  def supervisor(otp_app), do: name(otp_app, "Supervisor")

  @doc "Returns the Pi runtime name for a host application."
  @spec runtime(atom()) :: atom()
  def runtime(otp_app), do: name(otp_app, "Runtime")

  defp name(otp_app, suffix) do
    Module.concat([PiBrowserTaskbarPhoenix, Host, Macro.camelize(to_string(otp_app)), suffix])
  end
end
