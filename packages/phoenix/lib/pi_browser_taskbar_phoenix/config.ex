defmodule PiBrowserTaskbarPhoenix.Config do
  @moduledoc "Loads and validates startup-fixed host application configuration."

  @default_timeout_seconds 30 * 60
  @minimum_timeout_seconds 60
  @maximum_timeout_seconds 24 * 60 * 60

  @doc "Returns validated configuration keyed by the host OTP application."
  @spec load!(atom()) :: map()
  def load!(otp_app) when is_atom(otp_app) do
    explicit = Application.get_env(otp_app, :pi_browser_taskbar, [])

    enabled =
      setting(explicit, :enabled, "PI_BROWSER_TASKBAR_ENABLED", true) |> boolean!(:enabled)

    if enabled do
      %{
        enabled: true,
        allowed_hosts:
          setting(explicit, :allowed_hosts, "PI_BROWSER_TASKBAR_ALLOWED_HOSTS", [])
          |> allowed_hosts!(),
        executable:
          setting(explicit, :executable, "PI_BROWSER_TASKBAR_EXECUTABLE", "pi")
          |> non_empty_string!(:executable),
        project_root:
          setting(explicit, :project_root, "PI_BROWSER_TASKBAR_PROJECT_ROOT", File.cwd!())
          |> project_root!(),
        task_timeout:
          setting(
            explicit,
            :task_timeout,
            "PI_BROWSER_TASKBAR_TASK_TIMEOUT",
            @default_timeout_seconds
          )
          |> task_timeout!()
      }
    else
      %{enabled: false}
    end
  end

  @doc "Returns whether the adapter is enabled, validating the activation setting."
  @spec enabled?(atom()) :: boolean()
  def enabled?(otp_app), do: load!(otp_app).enabled

  defp setting(explicit, key, environment, default) do
    if Keyword.has_key?(explicit, key) do
      Keyword.fetch!(explicit, key)
    else
      System.get_env(environment) || default
    end
  end

  defp boolean!(value, _key) when is_boolean(value), do: value
  defp boolean!(value, _key) when value in ["true", "1"], do: true
  defp boolean!(value, _key) when value in ["false", "0"], do: false

  defp boolean!(_value, key),
    do: raise(ArgumentError, "pi_browser_taskbar #{key} must be true or false")

  defp allowed_hosts!(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> allowed_hosts!()
  end

  defp allowed_hosts!(hosts) when is_list(hosts) do
    Enum.map(hosts, fn host ->
      normalized =
        host
        |> non_empty_string!(:allowed_hosts)
        |> String.trim()
        |> non_empty_string!(:allowed_hosts)
        |> String.downcase()
        |> String.trim_trailing(".")

      unless valid_host?(normalized) do
        raise ArgumentError,
              "pi_browser_taskbar allowed_hosts entries must be bare exact DNS names or IP addresses"
      end

      normalized
    end)
  end

  defp allowed_hosts!(_value),
    do:
      raise(
        ArgumentError,
        "pi_browser_taskbar allowed_hosts must be a list or comma-separated string"
      )

  defp valid_host?(host) do
    valid_ip?(host) or
      (byte_size(host) <= 253 and
         Regex.match?(
           ~r/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$/,
           host
         ))
  end

  defp valid_ip?(host) do
    if String.contains?(host, "%"), do: false, else: parsed_ip?(host)
  end

  defp parsed_ip?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _address} -> true
      {:error, :einval} -> false
    end
  end

  defp project_root!(root) do
    root = non_empty_string!(root, :project_root)

    canonical = root |> Path.expand() |> canonical_path!()

    if File.dir?(canonical) do
      canonical
    else
      raise ArgumentError, "pi_browser_taskbar project_root must be an existing directory"
    end
  end

  defp canonical_path!(path), do: resolve_path(Path.split(path), 40)

  defp resolve_path(_parts, 0),
    do: raise(ArgumentError, "pi_browser_taskbar project_root contains too many symbolic links")

  defp resolve_path([root | parts], remaining), do: resolve_parts(root, parts, remaining)

  defp resolve_parts(path, [], _remaining), do: path

  defp resolve_parts(path, [part | parts], remaining) do
    candidate = Path.join(path, part)

    case File.read_link(candidate) do
      {:ok, target} ->
        target =
          if Path.type(target) == :absolute,
            do: target,
            else: Path.expand(target, Path.dirname(candidate))

        resolve_path(Path.split(Path.join([target | parts])), remaining - 1)

      {:error, _reason} ->
        resolve_parts(candidate, parts, remaining)
    end
  end

  defp task_timeout!(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} ->
        task_timeout!(seconds)

      _other ->
        raise ArgumentError,
              "pi_browser_taskbar task_timeout must be an integer number of seconds"
    end
  end

  defp task_timeout!(seconds)
       when is_integer(seconds) and seconds >= @minimum_timeout_seconds and
              seconds <= @maximum_timeout_seconds,
       do: seconds * 1_000

  defp task_timeout!(_value) do
    raise ArgumentError, "pi_browser_taskbar task_timeout must be between 60 and 86400 seconds"
  end

  defp non_empty_string!(value, _key) when is_binary(value) and value != "", do: value

  defp non_empty_string!(_value, key),
    do: raise(ArgumentError, "pi_browser_taskbar #{key} must be a non-empty string")
end
