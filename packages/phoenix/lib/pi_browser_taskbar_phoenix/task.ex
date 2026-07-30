defmodule PiBrowserTaskbarPhoenix.Task do
  @moduledoc """
  Validates browser requests and builds the trusted/untrusted Pi prompt envelope.
  """

  @max_request_bytes 128 * 1024
  @max_context_bytes 96 * 1024
  @max_snapshot_bytes 48 * 1024
  @max_focus_bytes 48 * 1024
  @max_snapshot_nodes 750
  @max_prompt_bytes 4_000
  @allowed_task_fields ~w(context prompt)
  @allowed_context_fields ~w(contract_version focus_points location route snapshot truncation)
  @allowed_location_fields ~w(origin path query_names)
  @allowed_route_fields ~w(action handler method pattern)
  @allowed_node_fields ~w(attributes children classes href id name role src state tag text)
  @allowed_attribute_fields ~w(data-testid name placeholder type)
  @allowed_state_fields ~w(checked disabled expanded invalid pressed required selected)
  @allowed_focus_fields ~w(ancestors selector source_status subtree)
  @allowed_summary_fields ~w(id name role tag)
  @allowed_truncation_fields ~w(reasons section)
  @source_statuses ~w(available ambiguous external unavailable)
  @truncation_reasons ~w(bytes nodes depth string)

  @enforce_keys [:prompt, :context]
  defstruct [:prompt, :context]

  @type t :: %__MODULE__{prompt: String.t(), context: map()}

  @doc "Validates and normalizes a version-one browser task request."
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_task, String.t()}
  def new(params) when is_map(params) do
    with :ok <- encoded_size(params, @max_request_bytes, "request is too large"),
         :ok <- exact_fields(params, @allowed_task_fields, "task"),
         {:ok, prompt} <- normalized_prompt(params["prompt"]),
         {:ok, context} <- normalize_context(params["context"]),
         :ok <- valid_context(context) do
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

  defp normalize_context(context) when is_map(context) do
    normalized =
      context
      |> normalize_value()
      |> update_if("location", &normalize_location/1)
      |> update_if("route", &normalize_route/1)
      |> update_if("snapshot", &normalize_node/1)
      |> update_if("focus_points", &normalize_focus_points/1)
      |> update_if("truncation", &normalize_truncation/1)

    {:ok, normalized}
  end

  defp normalize_context(_context), do: invalid("context must be an object")

  defp normalize_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, normalize_value(nested)} end)
  end

  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)

  defp normalize_value(value) when is_binary(value) do
    value
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.normalize(:nfc)
    |> String.replace(
      ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x{9F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u,
      ""
    )
  end

  defp normalize_value(value), do: value

  defp structural(value) when is_binary(value),
    do: value |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp structural(value), do: value

  defp normalize_location(location) when is_map(location) do
    location
    |> update_if("origin", &structural/1)
    |> update_if("path", &structural/1)
    |> update_if("query_names", fn
      values when is_list(values) -> Enum.map(values, &structural/1)
      values -> values
    end)
  end

  defp normalize_location(location), do: location

  defp normalize_route(route) when is_map(route) do
    route
    |> update_if("method", fn value -> value |> structural() |> downcase_or_upcase(:up) end)
    |> update_if("pattern", &structural/1)
    |> update_if("handler", &structural/1)
    |> update_if("action", &structural/1)
    |> null_empty("action")
  end

  defp normalize_route(route), do: route

  defp normalize_node(node) when is_map(node) do
    node =
      node
      |> update_if("tag", fn value -> value |> structural() |> downcase_or_upcase(:down) end)
      |> normalize_optional("role")
      |> normalize_optional("name")
      |> normalize_optional("text")
      |> normalize_optional("id")
      |> update_if("classes", fn
        values when is_list(values) -> Enum.map(values, &structural/1)
        values -> values
      end)
      |> delete_empty("classes")
      |> update_if("attributes", &normalize_attributes/1)
      |> delete_empty("attributes")
      |> update_if("state", &normalize_state/1)
      |> delete_empty("state")
      |> update_if("href", &normalize_location/1)
      |> update_if("src", &normalize_location/1)
      |> update_if("children", fn
        children when is_list(children) -> Enum.map(children, &normalize_node/1)
        children -> children
      end)

    node
  end

  defp normalize_node(node), do: node

  defp normalize_attributes(attributes) when is_map(attributes) do
    Enum.reduce(Map.keys(attributes), attributes, &normalize_optional(&2, &1))
  end

  defp normalize_attributes(attributes), do: attributes

  defp normalize_state(state) when is_map(state) do
    Map.new(state, fn {key, value} ->
      normalized =
        if is_binary(value), do: value |> structural() |> String.downcase(), else: value

      {key, normalized}
    end)
  end

  defp normalize_state(state), do: state

  defp normalize_focus_points(points) when is_list(points) do
    Enum.map(points, fn
      point when is_map(point) ->
        point
        |> update_if("selector", &structural/1)
        |> update_if("source_status", fn value ->
          value |> structural() |> downcase_or_upcase(:down)
        end)
        |> update_if("ancestors", &normalize_summaries/1)
        |> update_if("subtree", &normalize_node/1)

      point ->
        point
    end)
  end

  defp normalize_focus_points(points), do: points

  defp normalize_summaries(summaries) when is_list(summaries) do
    Enum.map(summaries, fn
      summary when is_map(summary) ->
        summary
        |> update_if("tag", fn value -> value |> structural() |> downcase_or_upcase(:down) end)
        |> normalize_optional("role")
        |> normalize_optional("name")
        |> normalize_optional("id")

      summary ->
        summary
    end)
  end

  defp normalize_summaries(summaries), do: summaries

  defp normalize_truncation(entries) when is_list(entries) do
    entries
    |> Enum.map(fn
      entry when is_map(entry) ->
        entry
        |> update_if("section", fn value -> value |> structural() |> downcase_or_upcase(:down) end)
        |> update_if("reasons", fn
          reasons when is_list(reasons) ->
            Enum.sort_by(reasons, fn reason ->
              Enum.find_index(
                @truncation_reasons,
                &(&1 == downcase_or_upcase(structural(reason), :down))
              ) ||
                length(@truncation_reasons)
            end)
            |> Enum.map(fn reason -> reason |> structural() |> downcase_or_upcase(:down) end)

          reasons ->
            reasons
        end)

      entry ->
        entry
    end)
    |> Enum.sort_by(fn
      %{"section" => "page"} ->
        0

      %{"section" => "focus:" <> index} ->
        case Integer.parse(index) do
          {number, ""} -> number
          _error -> 10
        end

      _entry ->
        10
    end)
  end

  defp normalize_truncation(entries), do: entries

  defp normalize_optional(map, key) do
    if Map.has_key?(map, key) do
      value = structural(map[key])
      if value == "", do: Map.delete(map, key), else: Map.put(map, key, value)
    else
      map
    end
  end

  defp null_empty(map, key) do
    if Map.get(map, key) == "", do: Map.put(map, key, nil), else: map
  end

  defp delete_empty(map, key) do
    if Map.get(map, key) in [[], %{}], do: Map.delete(map, key), else: map
  end

  defp update_if(map, key, function) do
    if Map.has_key?(map, key), do: Map.update!(map, key, function), else: map
  end

  defp downcase_or_upcase(value, :down) when is_binary(value), do: String.downcase(value)
  defp downcase_or_upcase(value, :up) when is_binary(value), do: String.upcase(value)
  defp downcase_or_upcase(value, _direction), do: value

  defp valid_context(context) do
    with :ok <- exact_fields(context, @allowed_context_fields, "context"),
         :ok <- equals(context["contract_version"], 1, "contract_version must be 1"),
         :ok <- valid_location(context["location"], "location"),
         :ok <- valid_route(context["route"]),
         :ok <- valid_node(context["snapshot"], "snapshot", 0, 12),
         :ok <- valid_snapshot_bounds(context["snapshot"]),
         :ok <- valid_focus_points(context["focus_points"]),
         :ok <- valid_truncation(context["truncation"]),
         :ok <- encoded_size(context, @max_context_bytes, "context is too large") do
      :ok
    end
  end

  defp valid_location(location, label) when is_map(location) do
    with :ok <- exact_fields(location, @allowed_location_fields, label),
         :ok <- valid_origin(location["origin"], label),
         :ok <-
           bounded_string(location["path"], "#{label}.path", 2_048, fn path ->
             String.starts_with?(path, "/") and !String.contains?(path, ["?", "#"])
           end),
         :ok <- unique_strings(location["query_names"], "#{label}.query_names", 32, 128) do
      :ok
    end
  end

  defp valid_location(_location, label), do: invalid("#{label} must be an object")

  defp valid_origin(origin, label) do
    with :ok <- bounded_string(origin, "#{label}.origin", 512),
         true <-
           Regex.match?(
             ~r/^https?:\/\/(?:\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+)(?::[0-9]{1,5})?$/,
             origin
           ),
         %URI{
           scheme: scheme,
           host: host,
           path: path,
           port: port,
           query: nil,
           fragment: nil,
           userinfo: nil
         } <- URI.parse(origin),
         true <-
           scheme in ["http", "https"] and is_binary(host) and path in [nil, ""] and
             is_integer(port) and port in 1..65_535 and valid_host?(host) do
      :ok
    else
      {:error, _, _} = error -> error
      _other -> invalid("#{label}.origin must be an HTTP(S) origin without credentials or path")
    end
  end

  defp valid_host?(host) do
    cond do
      String.contains?(host, ":") ->
        valid_ip?(host, 8)

      Regex.match?(~r/^[0-9.]+$/, host) ->
        valid_ip?(host, 4)

      true ->
        host
        |> String.split(".")
        |> Enum.all?(&Regex.match?(~r/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/, &1))
    end
  end

  defp valid_ip?(host, expected_size) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> tuple_size(address) == expected_size
      {:error, _reason} -> false
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

  defp valid_node(node, label, depth, maximum_depth)
       when is_map(node) and depth <= maximum_depth do
    with :ok <- fields(node, @allowed_node_fields, ~w(children tag), label),
         :ok <-
           bounded_string(
             node["tag"],
             "#{label}.tag",
             64,
             &Regex.match?(~r/^[a-z][a-z0-9-]*$/, &1)
           ),
         :ok <- optional_field_string(node, "role", "#{label}.role", 64),
         :ok <- optional_field_string(node, "name", "#{label}.name", 512),
         :ok <- optional_field_string(node, "text", "#{label}.text", 1_000),
         :ok <- optional_field_string(node, "id", "#{label}.id", 256),
         :ok <- optional_field_strings(node, "classes", "#{label}.classes", 32, 128),
         :ok <- optional_field(node, "attributes", &valid_attributes(&1, "#{label}.attributes")),
         :ok <- optional_field(node, "state", &valid_state(&1, "#{label}.state")),
         :ok <- optional_field(node, "href", &valid_location(&1, "#{label}.href")),
         :ok <- optional_field(node, "src", &valid_location(&1, "#{label}.src")),
         :ok <- valid_children(node["children"], label, depth, maximum_depth) do
      :ok
    end
  end

  defp valid_node(_node, label, depth, maximum_depth) when depth > maximum_depth,
    do: invalid("#{label} exceeds maximum depth")

  defp valid_node(_node, label, _depth, _maximum_depth), do: invalid("#{label} must be an object")

  defp valid_children(children, label, depth, maximum_depth) when is_list(children) do
    children
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {child, index}, :ok ->
      case valid_node(child, "#{label}.children[#{index}]", depth + 1, maximum_depth) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp valid_children(_children, label, _depth, _maximum_depth),
    do: invalid("#{label}.children must be an array")

  defp valid_attributes(attributes, label) when is_map(attributes) do
    with :ok <- fields(attributes, @allowed_attribute_fields, [], label) do
      attributes
      |> Enum.reduce_while(:ok, fn {key, value}, :ok ->
        case bounded_string(value, "#{label}.#{key}", 256) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp valid_attributes(_attributes, label), do: invalid("#{label} must be an object")

  defp valid_state(state, label) when is_map(state) do
    with :ok <- fields(state, @allowed_state_fields, [], label),
         :ok <- boolean_states(state, label),
         :ok <- enum_state(state, "checked", [true, false, "mixed"], label),
         :ok <- enum_state(state, "pressed", [true, false, "mixed"], label),
         :ok <- enum_state(state, "invalid", [true, false, "grammar", "spelling"], label) do
      :ok
    end
  end

  defp valid_state(_state, label), do: invalid("#{label} must be an object")

  defp boolean_states(state, label) do
    Enum.reduce_while(~w(disabled expanded required selected), :ok, fn key, :ok ->
      if !Map.has_key?(state, key) or is_boolean(state[key]),
        do: {:cont, :ok},
        else: {:halt, invalid("#{label}.#{key} is invalid")}
    end)
  end

  defp enum_state(state, key, allowed, label) do
    if !Map.has_key?(state, key) or state[key] in allowed,
      do: :ok,
      else: invalid("#{label}.#{key} is invalid")
  end

  defp valid_snapshot_bounds(snapshot) do
    with :ok <-
           maximum_node_count(
             snapshot,
             @max_snapshot_nodes,
             "snapshot must contain at most 750 nodes"
           ),
         :ok <- encoded_size(snapshot, @max_snapshot_bytes, "snapshot is too large") do
      :ok
    end
  end

  defp maximum_node_count(snapshot, maximum, message) do
    if node_count(snapshot) <= maximum, do: :ok, else: invalid(message)
  end

  defp node_count(%{"children" => children}), do: 1 + Enum.sum(Enum.map(children, &node_count/1))

  defp valid_focus_points(points) when is_list(points) and length(points) <= 8 do
    with :ok <- validate_each_focus(points),
         :ok <- unique_focus_selectors(points),
         :ok <- encoded_size(points, @max_focus_bytes, "focus_points are too large") do
      :ok
    end
  end

  defp valid_focus_points(_points), do: invalid("focus_points must contain at most 8 items")

  defp validate_each_focus(points) do
    points
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {point, index}, :ok ->
      case valid_focus(point, index) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp valid_focus(point, index) when is_map(point) do
    label = "focus_points[#{index}]"

    with :ok <- exact_fields(point, @allowed_focus_fields, label),
         :ok <- bounded_string(point["selector"], "#{label}.selector", 1_000),
         :ok <- member(point["source_status"], @source_statuses, "#{label}.source_status"),
         :ok <- valid_ancestors(point["ancestors"], label),
         :ok <- valid_node(point["subtree"], "#{label}.subtree", 0, 6),
         :ok <-
           maximum_node_count(
             point["subtree"],
             100,
             "#{label}.subtree must contain at most 100 nodes"
           ) do
      :ok
    end
  end

  defp valid_focus(_point, index), do: invalid("focus_points[#{index}] must be an object")

  defp unique_focus_selectors(points) do
    selectors = Enum.map(points, & &1["selector"])

    if Enum.uniq(selectors) == selectors,
      do: :ok,
      else: invalid("focus_points selectors must be unique")
  end

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
         :ok <-
           bounded_string(
             summary["tag"],
             "#{label}.tag",
             64,
             &Regex.match?(~r/^[a-z][a-z0-9-]*$/, &1)
           ),
         :ok <- optional_field_string(summary, "role", "#{label}.role", 64),
         :ok <- optional_field_string(summary, "name", "#{label}.name", 512),
         :ok <- optional_field_string(summary, "id", "#{label}.id", 256) do
      :ok
    end
  end

  defp valid_summary(_summary, label), do: invalid("#{label} must be an object")

  defp valid_truncation(entries) when is_list(entries) do
    with :ok <- validate_each_truncation(entries),
         :ok <- unique_truncation_sections(entries) do
      :ok
    end
  end

  defp valid_truncation(_entries), do: invalid("truncation must be an array")

  defp validate_each_truncation(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {entry, index}, :ok ->
      case valid_truncation_entry(entry, index) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

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

  defp unique_truncation_sections(entries) do
    sections = Enum.map(entries, & &1["section"])

    if Enum.uniq(sections) == sections,
      do: :ok,
      else: invalid("truncation sections must be unique")
  end

  defp normalized_prompt(prompt) when is_binary(prompt) do
    normalized = prompt |> normalize_value() |> String.trim()

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
    unknown = Enum.sort(keys -- allowed)
    missing = Enum.sort(required -- keys)

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

  defp bounded_string(_value, label, _max, _predicate), do: invalid("#{label} is invalid")

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

  defp optional_field_string(map, key, label, max) do
    optional_field(map, key, &bounded_string(&1, label, max))
  end

  defp optional_field_strings(map, key, label, max_items, max_bytes) do
    optional_field(map, key, &unique_strings(&1, label, max_items, max_bytes))
  end

  defp optional_field(map, key, validator) do
    if Map.has_key?(map, key), do: validator.(map[key]), else: :ok
  end

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
