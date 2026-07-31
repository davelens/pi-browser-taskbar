defmodule PiBrowserTaskbarPhoenix.Installer do
  @moduledoc "Plans and applies reversible Phoenix host integration."

  @default_mount "/dev/pi-browser-taskbar"
  @module ~r/^[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*$/
  @app ~r/^[a-z][a-z0-9_]*$/

  @doc "Plans every host edit without writing any file."
  @spec plan!(keyword()) :: %{required(String.t()) => String.t()}
  def plan!(opts \\ []) do
    topology = discover!(opts)
    metadata = metadata(topology)
    integration = integration_source(topology, metadata)
    validate_existing_integration!(topology.integration, metadata)

    application =
      topology.application
      |> read!("host application supervisor")
      |> install_supervisor(topology)
      |> format_elixir!("host application supervisor")

    router =
      topology.router
      |> read!("host router")
      |> install_routes(topology)
      |> format_elixir!("host router")

    layout = topology.layout |> read!("host root layout") |> install_layout(topology)

    config =
      topology.config
      |> read!("development configuration")
      |> install_annotations(topology)
      |> format_elixir!("development configuration")

    %{
      topology.integration => integration,
      topology.application => application,
      topology.router => router,
      topology.layout => layout,
      topology.config => config
    }
  end

  @doc "Writes a fully preflighted installation. Re-running it updates intact generated content."
  @spec run!(keyword()) :: :ok
  def run!(opts \\ []), do: opts |> plan!() |> apply_actions!()

  @doc "Plans removal of every recognized installer-owned seam without writing."
  @spec plan_uninstall!(keyword()) :: %{optional(String.t()) => String.t() | :delete}
  def plan_uninstall!(opts \\ []) do
    root = opts |> Keyword.get(:root, File.cwd!()) |> Path.expand()

    case find_integration(root, opts) do
      nil -> plan_repeated_uninstall!(opts)
      integration -> plan_installed_uninstall!(root, integration)
    end
  end

  @doc "Preflights every owned seam, then removes only recognized generated content."
  @spec uninstall!(keyword()) :: :ok
  def uninstall!(opts \\ []), do: opts |> plan_uninstall!() |> apply_actions!()

  defp discover!(opts) do
    root = opts |> Keyword.get(:root, File.cwd!()) |> Path.expand()
    {app_root, app} = discover_app!(root, option(opts, :app, :otp_app))

    endpoint =
      discover_module_file!(
        app_root,
        "**/*endpoint.ex",
        option(opts, :endpoint, :endpoint_module),
        "endpoint",
        "--endpoint"
      )

    endpoint_module = endpoint.module

    web =
      option(opts, :web, :web_module) || String.replace_suffix(endpoint_module, ".Endpoint", "")

    validate_module!(web, "web namespace")

    unless endpoint_module == "#{web}.Endpoint" do
      raise ArgumentError,
            "endpoint #{endpoint_module} does not belong to web namespace #{web}; pass matching --web and --endpoint options"
    end

    router =
      discover_module_file!(
        app_root,
        "**/*router.ex",
        option(opts, :router),
        "router",
        "--router",
        "#{web}.Router"
      )

    application = discover_application!(app_root, endpoint_module, option(opts, :application))
    layout = discover_layout!(app_root, endpoint.path, option(opts, :layout))
    config = discover_config!(root, app_root)

    mount = validate_mount!(Keyword.get(opts, :mount, @default_mount))
    pipeline = String.to_atom("#{app}_pi_browser_taskbar_v1")
    helper = String.to_atom("#{app}_pi_browser_taskbar")

    %{
      root: root,
      app_root: app_root,
      app: String.to_atom(app),
      web: web,
      endpoint: endpoint_module,
      application: application,
      router: router.path,
      layout: layout,
      config: config,
      integration: Path.join(Path.dirname(endpoint.path), "pi_browser_taskbar.ex"),
      mount: mount,
      pipeline: pipeline,
      helper: helper,
      annotations_owned: annotation_state!(root, config) == :absent
    }
  end

  defp discover_app!(root, explicit) do
    candidates =
      [Path.join(root, "mix.exs") | Path.wildcard(Path.join(root, "apps/*/mix.exs"))]
      |> Enum.filter(&File.regular?/1)
      |> Enum.flat_map(fn path ->
        case app_from_mix(path) do
          nil -> []
          app -> [{Path.dirname(path), app}]
        end
      end)

    explicit = explicit && to_string(explicit)
    if explicit, do: validate_app!(explicit)

    matches =
      if explicit, do: Enum.filter(candidates, &(elem(&1, 1) == explicit)), else: candidates

    case matches do
      [candidate] ->
        candidate

      [] when not is_nil(explicit) ->
        raise ArgumentError,
              "could not find OTP application #{inspect(explicit)} below #{root}; pass --root for that application"

      [] ->
        raise ArgumentError,
              "could not discover a conventional OTP application below #{root}; pass --root and --app"

      _ ->
        raise ArgumentError,
              "ambiguous OTP application below #{root}; pass --app and explicit integration options"
    end
  end

  defp app_from_mix(path) do
    matches =
      Regex.scan(~r/\bapp:\s*:([a-z][a-z0-9_]*)\b/, read!(path, "mix.exs"),
        capture: :all_but_first
      )

    case matches do
      [[app]] ->
        app

      [] ->
        nil

      _ ->
        raise ArgumentError,
              "could not discover one conventional OTP application from #{path}; pass --app"
    end
  end

  defp discover_module_file!(root, glob, explicit, label, flag, expected \\ nil) do
    paths =
      cond do
        explicit && String.ends_with?(to_string(explicit), ".ex") ->
          [expand_host_path!(root, to_string(explicit), "#{label} source path")]

        explicit ->
          Path.wildcard(Path.join(root, "lib/**/*.ex"))

        true ->
          Path.wildcard(Path.join(root, "lib/#{glob}"))
      end

    candidates =
      Enum.flat_map(paths, fn path ->
        Enum.map(modules(read!(path, label)), &%{path: path, module: &1})
      end)

    candidates = select_file_or_module(candidates, root, explicit)

    candidates =
      if explicit || is_nil(expected),
        do: candidates,
        else: Enum.filter(candidates, &(&1.module == expected))

    case candidates do
      [candidate] ->
        candidate

      [] ->
        raise ArgumentError,
              "could not discover #{label}; pass #{flag} with its module or source path"

      _ ->
        raise ArgumentError, "ambiguous #{label} discovery; pass #{flag} with its source path"
    end
  end

  defp select_file_or_module(candidates, _root, nil), do: candidates

  defp select_file_or_module(candidates, root, explicit) do
    explicit = to_string(explicit)

    if String.ends_with?(explicit, ".ex") do
      path = expand_host_path!(root, explicit, "source path")
      Enum.filter(candidates, &(&1.path == path))
    else
      validate_module!(explicit, "module option")
      Enum.filter(candidates, &(&1.module == explicit))
    end
  end

  defp discover_application!(root, endpoint, explicit) do
    if explicit do
      path = expand_host_path!(root, to_string(explicit), "application path")
      source = read!(path, "host application supervisor")

      unless String.contains?(source, endpoint),
        do: raise(ArgumentError, "application source does not supervise #{endpoint}")

      path
    else
      candidates =
        root
        |> Path.join("lib/**/*.ex")
        |> Path.wildcard()
        |> Enum.filter(fn path ->
          source = File.read!(path)
          String.contains?(source, "use Application") and String.contains?(source, endpoint)
        end)

      one!(candidates, "application supervisor", "--application")
    end
  end

  defp discover_config!(root, _app_root),
    do: require_config!(Path.join(root, "config/dev.exs"))

  defp require_config!(path) do
    read!(
      path,
      "development configuration; create config/dev.exs or pass --root for the host application"
    )

    path
  end

  defp discover_layout!(root, endpoint_path, explicit) do
    if explicit do
      path = expand_host_path!(root, to_string(explicit), "layout path")

      unless String.ends_with?(path, ".html.heex"),
        do: raise(ArgumentError, "root layout must be a controller/LiveView HEEx .html.heex file")

      read!(path, "root HEEx layout")
      path
    else
      conventional = Path.join(Path.dirname(endpoint_path), "components/layouts/root.html.heex")

      candidates =
        if File.regular?(conventional),
          do: [conventional],
          else: Path.wildcard(Path.join(root, "lib/**/components/layouts/root.html.heex"))

      one!(candidates, "root HEEx layout", "--layout")
    end
  end

  defp one!([value], _label, _flag), do: value

  defp one!([], label, flag),
    do: raise(ArgumentError, "could not discover #{label}; pass #{flag}")

  defp one!(_values, label, flag),
    do: raise(ArgumentError, "ambiguous #{label} discovery; pass #{flag}")

  defp modules(source),
    do:
      Regex.scan(~r/\bdefmodule\s+([A-Z][A-Za-z0-9_.]*)\s+do\b/, source, capture: :all_but_first)
      |> List.flatten()

  defp annotation_state!(_root, config) do
    owned = owned_block(read!(config, "development configuration"), "annotations", :elixir)

    if owned == annotations_block() do
      :absent
    else
      annotation_state_without_owned!(Path.dirname(config))
    end
  end

  defp annotation_state_without_owned!(config_root) do
    settings =
      config_root
      |> Path.join("**/*.{ex,exs}")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        Regex.scan(~r/debug_heex_annotations:\s*(true|false)\b/, File.read!(path),
          capture: :all_but_first
        )
        |> List.flatten()
        |> Enum.map(&{path, &1})
      end)

    case settings do
      [] ->
        :absent

      [{_path, "true"}] ->
        :present

      [{path, "false"}] ->
        raise ArgumentError,
              "debug_heex_annotations is explicitly false in #{path}; set it to true before installing"

      _ ->
        raise ArgumentError,
              "ambiguous debug_heex_annotations configuration; keep one explicit true setting before installing"
    end
  end

  defp install_supervisor(source, topology) do
    block = supervisor_block(topology)
    id = "supervisor"

    case owned_block(source, id, :elixir) do
      nil ->
        needle = "      #{topology.endpoint}"
        collision_free_endpoint!(source, needle)
        String.replace(source, needle, block <> needle)

      ^block ->
        source

      _ ->
        edited!(id)
    end
  end

  defp collision_free_endpoint!(source, needle) do
    case :binary.matches(source, needle) do
      [{_, _}] ->
        :ok

      [] ->
        raise ArgumentError, "could not find conventional endpoint child; pass --application"

      _ ->
        raise ArgumentError,
              "ambiguous endpoint child in application supervisor; pass --application"
    end
  end

  defp supervisor_block(t) do
    "      # pi-browser-taskbar:start supervisor\n      #{t.web}.PiBrowserTaskbar,\n      # pi-browser-taskbar:end supervisor\n"
  end

  defp install_routes(source, topology) do
    expected_module = "defmodule #{topology.web}.Router do"

    unless String.contains?(source, expected_module),
      do: raise(ArgumentError, "router does not define #{topology.web}.Router")

    block = routes_block(topology)

    case owned_block(source, "routes", :elixir) do
      nil ->
        collision_free_routes!(source, topology)
        insert_before_final_end!(source, "\n" <> block)

      ^block ->
        source

      _ ->
        edited!("routes")
    end
  end

  defp collision_free_routes!(source, topology) do
    pipeline = ":#{topology.pipeline}"
    helper = ":#{topology.helper}"

    if String.contains?(source, pipeline),
      do:
        raise(
          ArgumentError,
          "pipeline collision for #{pipeline}; choose another OTP application name or remove the collision"
        )

    if String.contains?(source, helper),
      do:
        raise(
          ArgumentError,
          "route helper collision for #{helper}; choose another OTP application name or remove the collision"
        )

    if Regex.match?(
         ~r/(?:scope|forward|get|post|delete|put|patch)\s+["']#{Regex.escape(topology.mount)}(?:\/|["'])/,
         source
       ),
       do:
         raise(
           ArgumentError,
           "route mount collision at #{topology.mount}; pass a different --mount"
         )
  end

  defp routes_block(t) do
    "  # pi-browser-taskbar:start routes\n  require #{t.web}.PiBrowserTaskbar\n  #{t.web}.PiBrowserTaskbar.routes()\n  # pi-browser-taskbar:end routes\n"
  end

  defp install_layout(source, topology) do
    block = layout_block(topology)

    case owned_block(source, "layout", :heex) do
      nil -> replace_once!(source, "  </body>", block <> "  </body>", "root layout </body>")
      ^block -> source
      _ -> edited!("layout")
    end
  end

  defp layout_block(t) do
    "    <%!-- pi-browser-taskbar:start layout --%>\n    <%= #{t.web}.PiBrowserTaskbar.layout_bootstrap() %>\n    <%!-- pi-browser-taskbar:end layout --%>\n"
  end

  defp install_annotations(source, %{annotations_owned: false}), do: source

  defp install_annotations(source, _topology) do
    block = annotations_block()

    case owned_block(source, "annotations", :elixir) do
      nil -> String.trim_trailing(source) <> "\n\n" <> block
      ^block -> source
      _ -> edited!("annotations")
    end
  end

  defp annotations_block do
    "# pi-browser-taskbar:start annotations\nconfig :phoenix_live_view, debug_heex_annotations: true\n# pi-browser-taskbar:end annotations\n"
  end

  defp owned_block(source, id, kind) do
    {open, close} = markers(id, kind)
    pattern = ~r/^([ \t]*#{Regex.escape(open)}\n.*?^[ \t]*#{Regex.escape(close)}\n?)/ms
    matches = Regex.scan(pattern, source, capture: :all_but_first) |> List.flatten()

    if length(matches) > 1 or marker_count(source, open) != marker_count(source, close),
      do: edited!(id)

    List.first(matches)
  end

  defp marker_count(source, marker), do: length(:binary.matches(source, marker))

  defp markers(id, :elixir),
    do: {"# pi-browser-taskbar:start #{id}", "# pi-browser-taskbar:end #{id}"}

  defp markers(id, :heex),
    do: {"<%!-- pi-browser-taskbar:start #{id} --%>", "<%!-- pi-browser-taskbar:end #{id} --%>"}

  defp edited!(id),
    do:
      raise(
        ArgumentError,
        "edited generated #{id} section is ambiguous; manual removal: restore the complete content between the pi-browser-taskbar:start #{id} and pi-browser-taskbar:end #{id} markers, then rerun --uninstall"
      )

  defp metadata(t) do
    %{
      "schema" => 1,
      "app" => Atom.to_string(t.app),
      "web" => t.web,
      "endpoint" => t.endpoint,
      "application" => relative(t.application, t.root),
      "router" => relative(t.router, t.root),
      "layout" => relative(t.layout, t.root),
      "config" => relative(t.config, t.root),
      "mount" => t.mount,
      "pipeline" => Atom.to_string(t.pipeline),
      "helper" => Atom.to_string(t.helper),
      "annotations_owned" => t.annotations_owned
    }
  end

  defp integration_source(t, metadata) do
    module_metadata =
      inspect(%{
        schema: 1,
        app: t.app,
        web: t.web,
        endpoint: t.endpoint,
        application: metadata["application"],
        router: metadata["router"],
        layout: metadata["layout"],
        config: metadata["config"],
        mount: t.mount,
        pipeline: t.pipeline,
        helper: t.helper,
        annotations_owned: t.annotations_owned
      })

    body =
      """
      defmodule #{t.web}.PiBrowserTaskbar do
        @moduledoc "Development-only host integration generated by Pi Browser Taskbar."
        @pi_browser_taskbar_installation #{module_metadata}

        @doc false
        def installation_metadata, do: @pi_browser_taskbar_installation

        if Mix.env() == :dev and PiBrowserTaskbarPhoenix.Config.enabled?(#{inspect(t.app)}) do
          @otp_app #{inspect(t.app)}
          @mount #{inspect(t.mount)}
          @remote_access PiBrowserTaskbarPhoenix.Config.load!(@otp_app).allowed_hosts != []

          @doc false
          def child_spec(_opts) do
            Supervisor.child_spec({PiBrowserTaskbarPhoenix.Supervisor, otp_app: @otp_app}, id: __MODULE__)
          end

          @doc false
          defmacro routes do
            quote do
              require PiBrowserTaskbarPhoenix.Router
              PiBrowserTaskbarPhoenix.Router.routes_ast(
                otp_app: unquote(@otp_app),
                mount: unquote(@mount),
                pipeline: unquote(#{inspect(t.pipeline)}),
                helper: unquote(#{inspect(t.helper)})
              )
            end
          end

          @doc false
          def layout_bootstrap do
            PiBrowserTaskbarPhoenix.Layout.render(mount: @mount, otp_app: @otp_app, remote_access: @remote_access)
          end
        else
          @doc false
          def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :ignore, []}}
          @doc false
          def ignore, do: :ignore
          @doc false
          defmacro routes, do: quote(do: nil)
          @doc false
          def layout_bootstrap, do: {:safe, ""}
        end
      end
      """
      |> format_elixir!("generated integration")

    json = Jason.encode!(metadata)
    checksum = checksum(json <> "\n" <> body)

    "# Generated by pi-browser-taskbar-phoenix. Do not edit.\n# pi-browser-taskbar:metadata #{json}\n# pi-browser-taskbar:checksum #{checksum}\n" <>
      body
  end

  defp validate_existing_integration!(path, expected_metadata) do
    if File.exists?(path) do
      {metadata, _body} = parse_integration!(path)

      unless metadata == expected_metadata do
        raise ArgumentError,
              "installed integration metadata differs at #{path}; uninstall the existing integration before changing topology"
      end
    end
  end

  defp parse_integration!(path) do
    source = read!(path, "generated integration")

    pattern =
      ~r/\A# Generated by pi-browser-taskbar-phoenix\. Do not edit\.\n# pi-browser-taskbar:metadata ([^\n]+)\n# pi-browser-taskbar:checksum ([0-9a-f]{64})\n(.*)\z/s

    case Regex.run(pattern, source, capture: :all_but_first) do
      [json, expected, body] ->
        if checksum(json <> "\n" <> body) != expected,
          do:
            raise(
              ArgumentError,
              "refusing edited generated integration #{path}; manual removal: restore this checksummed file, then rerun --uninstall, or remove only the complete marked supervisor, routes, layout, and annotations sections before deleting it"
            )

        {Jason.decode!(json), body}

      _ ->
        raise ArgumentError,
              "refusing unrecognized generated integration #{path}; manual removal: restore this generated file, then rerun --uninstall, or remove only the complete marked supervisor, routes, layout, and annotations sections before deleting it"
    end
  end

  defp find_integration(root, opts) do
    explicit_web = option(opts, :web, :web_module)

    candidates =
      Path.wildcard(Path.join(root, "lib/**/pi_browser_taskbar.ex")) ++
        Path.wildcard(Path.join(root, "apps/*/lib/**/pi_browser_taskbar.ex"))

    candidates =
      if explicit_web,
        do:
          Enum.filter(
            candidates,
            &(File.read!(&1) =~ "defmodule #{explicit_web}.PiBrowserTaskbar do")
          ),
        else: candidates

    case candidates do
      [] ->
        nil

      [path] ->
        path

      _ ->
        raise ArgumentError,
              "ambiguous installed integration; pass --web to select the host integration module"
    end
  end

  defp plan_installed_uninstall!(root, integration) do
    {metadata, _body} = parse_integration!(integration)
    t = topology_from_metadata!(root, integration, metadata)

    application =
      t.application
      |> read!("host application supervisor")
      |> remove_owned!("supervisor", :elixir, supervisor_block(t))
      |> format_elixir!("host application supervisor")

    router =
      t.router
      |> read!("host router")
      |> remove_owned!("routes", :elixir, routes_block(t))
      |> format_elixir!("host router")

    layout =
      t.layout |> read!("host root layout") |> remove_owned!("layout", :heex, layout_block(t))

    config_source = read!(t.config, "development configuration")

    config =
      if t.annotations_owned,
        do:
          remove_owned!(config_source, "annotations", :elixir, annotations_block())
          |> format_elixir!("development configuration"),
        else: config_source

    %{
      integration => :delete,
      t.application => application,
      t.router => router,
      t.layout => layout,
      t.config => config
    }
  end

  defp topology_from_metadata!(root, integration, m) do
    required =
      ~w(schema app web endpoint application router layout config mount pipeline helper annotations_owned)

    unless Map.keys(m) |> Enum.sort() == Enum.sort(required) and m["schema"] == 1,
      do:
        raise(
          ArgumentError,
          "unrecognized installation metadata in #{integration}; use manual removal"
        )

    validate_app!(m["app"])
    Enum.each(~w(web endpoint), &validate_module!(m[&1], &1))
    validate_mount!(m["mount"])

    expected_pipeline = "#{m["app"]}_pi_browser_taskbar_v1"
    expected_helper = "#{m["app"]}_pi_browser_taskbar"

    unless m["pipeline"] == expected_pipeline and m["helper"] == expected_helper and
             is_boolean(m["annotations_owned"]) do
      raise ArgumentError,
            "unrecognized installation metadata in #{integration}; use manual removal"
    end

    %{
      root: root,
      app: String.to_atom(m["app"]),
      web: m["web"],
      endpoint: m["endpoint"],
      mount: m["mount"],
      application: expand_host_path!(root, m["application"], "metadata application path"),
      router: expand_host_path!(root, m["router"], "metadata router path"),
      layout: expand_host_path!(root, m["layout"], "metadata layout path"),
      config: expand_host_path!(root, m["config"], "metadata config path"),
      pipeline: String.to_atom(expected_pipeline),
      helper: String.to_atom(expected_helper),
      annotations_owned: m["annotations_owned"]
    }
  end

  defp remove_owned!(source, id, kind, expected) do
    case owned_block(source, id, kind) do
      ^expected -> String.replace(source, expected, "", global: false)
      nil -> edited!(id)
      _ -> edited!(id)
    end
  end

  defp plan_repeated_uninstall!(opts) do
    topology = discover!(opts)

    seams = [
      {topology.application, "supervisor", :elixir},
      {topology.router, "routes", :elixir},
      {topology.layout, "layout", :heex}
    ]

    if Enum.any?(seams, fn {path, id, kind} -> owned_block(read!(path, path), id, kind) end) do
      raise ArgumentError,
            "integration metadata is missing while generated host sections remain; manual removal: remove only complete pi-browser-taskbar:start/end supervisor, routes, layout, and annotations blocks, then rerun --uninstall"
    end

    %{}
  end

  defp apply_actions!(actions) do
    changed =
      Enum.reject(actions, fn {path, value} ->
        value != :delete and File.exists?(path) and File.read!(path) == value
      end)

    Enum.each(changed, fn
      {path, :delete} -> preflight_existing!(path)
      {path, _source} -> preflight_destination!(path)
    end)

    staged =
      Enum.map(changed, fn
        {path, :delete} ->
          {path, :delete, nil}

        {path, source} ->
          {path, source, path <> ".pi-browser-taskbar-#{System.unique_integer([:positive])}"}
      end)

    try do
      Enum.each(staged, fn
        {_path, :delete, nil} ->
          :ok

        {path, source, temp} ->
          File.write!(temp, source, [:exclusive])
          if File.exists?(path), do: File.chmod!(temp, File.stat!(path).mode)
      end)
    rescue
      error ->
        Enum.each(staged, fn {_path, _source, temp} -> if temp, do: File.rm(temp) end)
        reraise error, __STACKTRACE__
    end

    originals =
      Map.new(changed, fn {path, _} ->
        {path, if(File.exists?(path), do: File.read!(path), else: :missing)}
      end)

    try do
      Enum.each(staged, fn
        {path, :delete, nil} -> File.rm!(path)
        {path, _source, temp} -> File.rename!(temp, path)
      end)

      :ok
    rescue
      error ->
        Enum.each(originals, fn {path, original} ->
          if original == :missing, do: File.rm(path), else: File.write!(path, original)
        end)

        reraise error, __STACKTRACE__
    after
      Enum.each(staged, fn {_path, _source, temp} -> if temp, do: File.rm(temp) end)
    end
  end

  defp preflight_existing!(path),
    do:
      if(!File.regular?(path),
        do: raise(ArgumentError, "owned file is missing at #{path}; use manual removal")
      )

  defp preflight_destination!(path) do
    parent = Path.dirname(path)

    unless File.dir?(parent),
      do: raise(ArgumentError, "destination directory is missing at #{parent}")

    if File.exists?(path) and not File.regular?(path),
      do: raise(ArgumentError, "destination is not a regular file at #{path}")
  end

  defp insert_before_final_end!(source, insertion) do
    case Regex.run(~r/\nend\s*\z/, source, return: :index) do
      [{index, length}] ->
        binary_part(source, 0, index) <> insertion <> binary_part(source, index, length)

      _ ->
        raise ArgumentError, "router has no unambiguous final end"
    end
  end

  defp replace_once!(source, needle, replacement, label) do
    case :binary.matches(source, needle) do
      [{_, _}] -> String.replace(source, needle, replacement)
      [] -> raise ArgumentError, "could not find conventional #{label}"
      _ -> raise ArgumentError, "found ambiguous conventional #{label}"
    end
  end

  defp format_elixir!(source, label) do
    formatted = source |> Code.format_string!(line_length: 98) |> IO.iodata_to_binary()
    String.trim_trailing(formatted) <> "\n"
  rescue
    error in [SyntaxError, TokenMissingError] ->
      raise ArgumentError, "#{label} could not be formatted: #{Exception.message(error)}"
  end

  defp validate_mount!(mount) when is_binary(mount) do
    if Regex.match?(~r|^/[A-Za-z0-9._~-]+(?:/[A-Za-z0-9._~-]+)*$|, mount),
      do: mount,
      else:
        raise(
          ArgumentError,
          "mount must be an absolute path without a trailing slash, query, or fragment"
        )
  end

  defp validate_mount!(_), do: raise(ArgumentError, "mount must be an absolute path string")

  defp validate_app!(app) when is_binary(app),
    do:
      if(Regex.match?(@app, app),
        do: :ok,
        else: raise(ArgumentError, "app must be a lowercase OTP application name")
      )

  defp validate_app!(_), do: raise(ArgumentError, "app must be a lowercase OTP application name")

  defp validate_module!(module, label) when is_binary(module),
    do:
      if(Regex.match?(@module, module),
        do: :ok,
        else: raise(ArgumentError, "#{label} must be an Elixir module name")
      )

  defp validate_module!(_, label),
    do: raise(ArgumentError, "#{label} must be an Elixir module name")

  defp expand_host_path!(root, path, label) do
    expanded = Path.expand(path, root)

    unless expanded == root or String.starts_with?(expanded, root <> "/"),
      do: raise(ArgumentError, "#{label} must stay below the host root")

    expanded
  end

  defp relative(path, root), do: Path.relative_to(path, root)
  defp checksum(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp option(opts, key), do: Keyword.get(opts, key)
  defp option(opts, first, second), do: Keyword.get(opts, first) || Keyword.get(opts, second)

  defp read!(path, label) do
    case File.read(path) do
      {:ok, source} -> source
      {:error, reason} -> raise ArgumentError, "could not read #{label} at #{path}: #{reason}"
    end
  end
end
