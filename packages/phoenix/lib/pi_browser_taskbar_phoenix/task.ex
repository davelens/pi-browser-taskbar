defmodule PiBrowserTaskbarPhoenix.Task do
  @moduledoc """
  Validates whole-page browser requests and builds the trusted/untrusted Pi prompt envelope.
  """

  @max_request_bytes 128 * 1024
  @max_context_bytes 96 * 1024
  @max_prompt_bytes 4_000
  @allowed_task_fields ~w(context prompt)
  @allowed_context_fields ~w(contract_version focus_points location route snapshot truncation)
  @allowed_location_fields ~w(origin path query_names)
  @allowed_route_fields ~w(action handler method pattern)
  @allowed_node_fields ~w(children classes id name role tag text)
  @allowed_focus_fields ~w(ancestors selector source_status subtree)
  @allowed_summary_fields ~w(id name role tag)
  @allowed_truncation_fields ~w(reasons section)
  @source_statuses ~w(available ambiguous external unavailable)
  @truncation_reasons ~w(bytes nodes depth string)

  @enforce_keys [:prompt, :context]
  defstruct [:prompt, :context]

  @type t :: %__MODULE__{prompt: String.t(), context: map()}

  @doc "Validates and normalizes a version-one whole-page task request."
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_task, String.t()}
  def new(params) when is_map(params) do
    with :ok <- encoded_size(params, @max_request_bytes, "request is too large"),
         :ok <- exact_fields(params, @allowed_task_fields, "task"),
         {:ok, prompt} <- normalized_prompt(params["prompt"]),
         {:ok, context} <- valid_context(params["context"]) do
      {:ok, %__MODULE__{prompt: prompt, context: context}}
    end
  end

  def new(_params), do: invalid("task must be an object")

  @doc "Builds the canonical prompt with browser data in a separate untrusted block."
  @spec to_prompt(t()) :: String.t()
  def to_prompt(%__MODULE__{} = task) do
    task.prompt <>
      "\n\n--- BEGIN UNTRUSTED BROWSER CONTEXT ---\n" <>
      safe_json(task.context) <>
      "\n--- END UNTRUSTED BROWSER CONTEXT ---"
  end

  defp valid_context(context) when is_map(context) do
    with :ok <- encoded_size(context, @max_context_bytes, "context is too large"),
         :ok <- exact_fields(context, @allowed_context_fields, "context"),
         :ok <- equals(context["contract_version"], 1, "contract_version must be 1"),
         :ok <- valid_location(context["location"]),
         :ok <- valid_route(context["route"]),
         :ok <- valid_node(context["snapshot"], "snapshot", 0),
         :ok <- valid_focus_points(context["focus_points"]),
         :ok <- valid_truncation(context["truncation"]) do
      {:ok, context}
    end
  end

  defp valid_context(_context), do: invalid("context must be an object")

  defp valid_location(location) when is_map(location) do
    with :ok <- exact_fields(location, @allowed_location_fields, "location"),
         :ok <- valid_origin(location["origin"]),
         :ok <-
           bounded_string(location["path"], "location.path", 2_048, &String.starts_with?(&1, "/")),
         :ok <- unique_strings(location["query_names"], "location.query_names", 32, 128) do
      :ok
    end
  end

  defp valid_location(_location), do: invalid("location must be an object")

  defp valid_origin(origin) do
    with :ok <- bounded_string(origin, "location.origin", 512),
         %URI{scheme: scheme, host: host, path: path, query: nil, fragment: nil, userinfo: nil} <-
           URI.parse(origin),
         true <- scheme in ["http", "https"] and is_binary(host) and path in [nil, ""] do
      :ok
    else
      {:error, _, _} = error -> error
      _other -> invalid("location.origin must be an HTTP(S) origin without credentials or path")
    end
  end

  defp valid_route(nil), do: :ok

  defp valid_route(route) when is_map(route) do
    with :ok <- exact_fields(route, @allowed_route_fields, "route"),
         :ok <-
           bounded_string(route["method"], "route.method", 16, &Regex.match?(~r/^[A-Z]+$/, &1)),
         :ok <- bounded_string(route["pattern"], "route.pattern", 1_000),
         :ok <- bounded_string(route["handler"], "route.handler", 500),
         :ok <- optional_string(route["action"], "route.action", 256) do
      :ok
    end
  end

  defp valid_route(_route), do: invalid("route must be an object or null")

  defp valid_node(node, label, depth) when is_map(node) and depth <= 12 do
    with :ok <- fields(node, @allowed_node_fields, ~w(children tag), label),
         :ok <-
           bounded_string(
             node["tag"],
             "#{label}.tag",
             64,
             &Regex.match?(~r/^[a-z][a-z0-9-]*$/, &1)
           ),
         :ok <- optional_string(node["role"], "#{label}.role", 64),
         :ok <- optional_string(node["name"], "#{label}.name", 512),
         :ok <- optional_string(node["text"], "#{label}.text", 1_000),
         :ok <- optional_string(node["id"], "#{label}.id", 256),
         :ok <- optional_unique_strings(node["classes"], "#{label}.classes", 32, 128),
         :ok <- valid_children(node["children"], label, depth) do
      :ok
    end
  end

  defp valid_node(_node, label, depth) when depth > 12,
    do: invalid("#{label} exceeds maximum depth")

  defp valid_node(_node, label, _depth), do: invalid("#{label} must be an object")

  defp valid_children(children, label, depth) when is_list(children) do
    children
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {child, index}, :ok ->
      case valid_node(child, "#{label}.children[#{index}]", depth + 1) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp valid_children(_children, label, _depth), do: invalid("#{label}.children must be an array")

  defp valid_focus_points(points) when is_list(points) and length(points) <= 8 do
    points
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {point, index}, :ok ->
      case valid_focus(point, index) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp valid_focus_points(_points), do: invalid("focus_points must contain at most 8 items")

  defp valid_focus(point, index) when is_map(point) do
    label = "focus_points[#{index - 1}]"

    with :ok <- exact_fields(point, @allowed_focus_fields, label),
         :ok <- bounded_string(point["selector"], "#{label}.selector", 1_000),
         :ok <- member(point["source_status"], @source_statuses, "#{label}.source_status"),
         :ok <- valid_ancestors(point["ancestors"], label),
         :ok <- valid_node(point["subtree"], "#{label}.subtree", 0) do
      :ok
    end
  end

  defp valid_focus(_point, index), do: invalid("focus_points[#{index - 1}] must be an object")

  defp valid_ancestors(ancestors, label) when is_list(ancestors) and length(ancestors) <= 8 do
    ancestors
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {summary, index}, :ok ->
      case valid_summary(summary, "#{label}.ancestors[#{index}]") do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp valid_ancestors(_ancestors, label),
    do: invalid("#{label}.ancestors must contain at most 8 items")

  defp valid_summary(summary, label) when is_map(summary) do
    with :ok <- fields(summary, @allowed_summary_fields, ["tag"], label),
         :ok <- bounded_string(summary["tag"], "#{label}.tag", 64),
         :ok <- optional_string(summary["role"], "#{label}.role", 64),
         :ok <- optional_string(summary["name"], "#{label}.name", 512),
         :ok <- optional_string(summary["id"], "#{label}.id", 256) do
      :ok
    end
  end

  defp valid_summary(_summary, label), do: invalid("#{label} must be an object")

  defp valid_truncation(entries) when is_list(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {entry, index}, :ok ->
      case valid_truncation_entry(entry, index) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp valid_truncation(_entries), do: invalid("truncation must be an array")

  defp valid_truncation_entry(entry, index) when is_map(entry) do
    label = "truncation[#{index}]"

    with :ok <- exact_fields(entry, @allowed_truncation_fields, label),
         :ok <-
           bounded_string(
             entry["section"],
             "#{label}.section",
             16,
             &Regex.match?(~r/^(page|focus:[1-8])$/, &1)
           ),
         :ok <- unique_members(entry["reasons"], @truncation_reasons, "#{label}.reasons") do
      :ok
    end
  end

  defp valid_truncation_entry(_entry, index),
    do: invalid("truncation[#{index}] must be an object")

  defp normalized_prompt(prompt) when is_binary(prompt) do
    normalized =
      prompt
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
      |> String.normalize(:nfc)
      |> String.replace(
        ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\x{202A}-\x{202E}\x{2066}-\x{2069}]/u,
        ""
      )
      |> String.trim()

    cond do
      normalized == "" -> invalid("prompt is required")
      byte_size(normalized) > @max_prompt_bytes -> invalid("prompt must be at most 4000 bytes")
      true -> {:ok, normalized}
    end
  end

  defp normalized_prompt(_prompt), do: invalid("prompt is required")

  defp exact_fields(map, allowed, label), do: fields(map, allowed, allowed, label)

  defp fields(map, allowed, required, label) do
    keys = Map.keys(map)
    unknown = keys -- allowed
    missing = required -- keys

    cond do
      unknown != [] -> invalid("#{label} has unknown field #{inspect(hd(unknown))}")
      missing != [] -> invalid("#{label} is missing field #{inspect(hd(missing))}")
      true -> :ok
    end
  end

  defp bounded_string(value, label, max, predicate \\ fn _ -> true end)

  defp bounded_string(value, label, max, predicate) when is_binary(value) do
    if value != "" and byte_size(value) <= max and predicate.(value),
      do: :ok,
      else: invalid("#{label} is invalid")
  end

  defp bounded_string(_value, label, _max, _predicate), do: invalid("#{label} is required")

  defp optional_string(nil, _label, _max), do: :ok
  defp optional_string(value, label, max), do: bounded_optional_string(value, label, max)

  defp bounded_optional_string(value, _label, max)
       when is_binary(value) and byte_size(value) <= max,
       do: :ok

  defp bounded_optional_string(_value, label, _max), do: invalid("#{label} is invalid")

  defp unique_strings(values, label, max_items, max_bytes)
       when is_list(values) and length(values) <= max_items do
    valid =
      Enum.all?(values, &(is_binary(&1) and &1 != "" and byte_size(&1) <= max_bytes)) and
        Enum.uniq(values) == values

    if valid, do: :ok, else: invalid("#{label} is invalid")
  end

  defp unique_strings(_values, label, _max_items, _max_bytes), do: invalid("#{label} is invalid")

  defp optional_unique_strings(nil, _label, _max_items, _max_bytes), do: :ok

  defp optional_unique_strings(values, label, max_items, max_bytes),
    do: unique_strings(values, label, max_items, max_bytes)

  defp unique_members(values, allowed, label) when is_list(values) and values != [] do
    if Enum.uniq(values) == values and Enum.all?(values, &(&1 in allowed)),
      do: :ok,
      else: invalid("#{label} is invalid")
  end

  defp unique_members(_values, _allowed, label), do: invalid("#{label} is invalid")

  defp member(value, allowed, label) do
    if value in allowed, do: :ok, else: invalid("#{label} is invalid")
  end

  defp equals(value, expected, message) do
    if value == expected, do: :ok, else: invalid(message)
  end

  defp encoded_size(value, max, message) do
    if byte_size(Jason.encode!(value)) <= max, do: :ok, else: invalid(message)
  end

  defp safe_json(value) do
    value
    |> canonical_json()
    |> String.replace("<", "\\u003c")
    |> String.replace(">", "\\u003e")
    |> String.replace("&", "\\u0026")
  end

  defp canonical_json(value) when is_map(value) do
    contents =
      value
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(",", fn {key, nested} ->
        Jason.encode!(key) <> ":" <> canonical_json(nested)
      end)

    "{" <> contents <> "}"
  end

  defp canonical_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"

  defp canonical_json(value), do: Jason.encode!(value)

  defp invalid(message), do: {:error, :invalid_task, message}
end
