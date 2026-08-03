defmodule PiBrowserTaskbarPhoenix.InstallerTest do
  use ExUnit.Case, async: false

  alias PiBrowserTaskbarPhoenix.Installer

  setup do
    root = fixture_root()
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "checked-in example remains installable" do
    root = Path.expand("../../../examples/phoenix", __DIR__)

    assert plan = Installer.plan!(root: root)

    assert Map.has_key?(
             plan,
             Path.join(root, "lib/taskbar_example_web/components/layouts/root.html.heex")
           )

    assert File.read!(Path.join(root, "config/config.exs")) =~
             "adapter: Bandit.PhoenixAdapter"

    assert File.read!(Path.join(root, "lib/taskbar_example_web/endpoint.ex")) =~
             "plug Phoenix.CodeReloader"

    assert File.read!(Path.join(root, "mix.exs")) =~
             "listeners: [Phoenix.CodeReloader]"
  end

  test "discovers and idempotently installs every marked host seam", %{root: root} do
    assert :ok = Installer.run!(root: root)
    first = installed_files(root)
    assert :ok = Installer.run!(root: root)
    assert installed_files(root) == first

    assert first.integration =~ "@pi_browser_taskbar_installation"
    assert first.integration =~ "if Mix.env() == :dev"
    assert first.integration =~ "PiBrowserTaskbarPhoenix.Supervisor"
    assert first.integration =~ ~s(mount: "/dev/pi-browser-taskbar")

    assert first.application =~
             "# pi-browser-taskbar:start supervisor\n      DemoWeb.PiBrowserTaskbar,"

    assert first.application =~
             "DemoWeb.PiBrowserTaskbar,\n      # pi-browser-taskbar:end supervisor\n      DemoWeb.Endpoint"

    assert first.router =~ "# pi-browser-taskbar:start routes"
    assert first.router =~ "DemoWeb.PiBrowserTaskbar.routes()"
    assert first.layout =~ "<%!-- pi-browser-taskbar:start layout --%>"
    assert first.layout =~ "{DemoWeb.PiBrowserTaskbar.layout_bootstrap()}"
    assert first.config =~ "config :phoenix_live_view, debug_heex_annotations: true"
  end

  test "the generated non-development branch compiles without the package", %{root: root} do
    Installer.run!(root: root)
    integration_path = Path.join(root, "lib/demo_web/pi_browser_taskbar.ex")
    previous_env = Mix.env()

    try do
      Mix.env(:prod)
      assert [{DemoWeb.PiBrowserTaskbar, _bytecode}] = Code.compile_file(integration_path)

      assert %{start: {DemoWeb.PiBrowserTaskbar, :ignore, []}} =
               apply(DemoWeb.PiBrowserTaskbar, :child_spec, [[]])

      assert apply(DemoWeb.PiBrowserTaskbar, :layout_bootstrap, []) == {:safe, ""}
      assert apply(DemoWeb.PiBrowserTaskbar, :installation_metadata, []).app == :demo
    after
      unload_integration()
      Mix.env(previous_env)
    end
  end

  test "explicit false compiles out development routes, assets, and Pi ownership", %{root: root} do
    Installer.run!(root: root)
    integration_path = Path.join(root, "lib/demo_web/pi_browser_taskbar.ex")
    previous_env = Mix.env()

    try do
      Mix.env(:dev)
      Application.put_env(:demo, :pi_browser_taskbar, enabled: false)
      assert [{DemoWeb.PiBrowserTaskbar, _bytecode}] = Code.compile_file(integration_path)
      assert apply(DemoWeb.PiBrowserTaskbar, :layout_bootstrap, []) == {:safe, ""}

      assert %{start: {DemoWeb.PiBrowserTaskbar, :ignore, []}} =
               apply(DemoWeb.PiBrowserTaskbar, :child_spec, [[]])

      assert {nil, _binding} =
               Code.eval_quoted(
                 quote do
                   require DemoWeb.PiBrowserTaskbar
                   DemoWeb.PiBrowserTaskbar.routes()
                 end
               )
    after
      Application.delete_env(:demo, :pi_browser_taskbar)
      unload_integration()
      Mix.env(previous_env)
    end
  end

  test "explicit options install a nonstandard application", %{root: root} do
    File.rename!(Path.join(root, "lib/demo/application.ex"), Path.join(root, "lib/demo/host.ex"))

    File.rename!(
      Path.join(root, "lib/demo_web/router.ex"),
      Path.join(root, "lib/demo_web/routes.ex")
    )

    File.rename!(
      Path.join(root, "lib/demo_web/components/layouts/root.html.heex"),
      Path.join(root, "lib/demo_web/components/layouts/shell.html.heex")
    )

    assert :ok =
             Installer.run!(
               root: root,
               app: "demo",
               web: "DemoWeb",
               endpoint: "DemoWeb.Endpoint",
               application: "lib/demo/host.ex",
               router: "lib/demo_web/routes.ex",
               layout: "lib/demo_web/components/layouts/shell.html.heex",
               mount: "/internal/pi"
             )

    integration = File.read!(Path.join(root, "lib/demo_web/pi_browser_taskbar.ex"))
    assert integration =~ ~s(mount: "/internal/pi")
    assert File.read!(Path.join(root, "lib/demo/host.ex")) =~ "DemoWeb.PiBrowserTaskbar"
  end

  test "an umbrella root selects an explicit child application without guessing", %{root: root} do
    app_root = Path.join(root, "apps/demo")
    File.mkdir_p!(app_root)
    File.rename!(Path.join(root, "lib"), Path.join(app_root, "lib"))
    File.rename!(Path.join(root, "mix.exs"), Path.join(app_root, "mix.exs"))

    File.write!(
      Path.join(root, "mix.exs"),
      "defmodule Umbrella.MixProject do\n  use Mix.Project\n  def project, do: [apps_path: \"apps\"]\nend\n"
    )

    assert :ok = Installer.run!(root: root, app: "demo")
    assert File.exists?(Path.join(app_root, "lib/demo_web/pi_browser_taskbar.ex"))
  end

  test "ambiguous discovery refuses every write with actionable explicit options", %{root: root} do
    File.cp!(
      Path.join(root, "lib/demo_web/router.ex"),
      Path.join(root, "lib/demo_web/other_router.ex")
    )

    before = tree(root)

    assert_raise ArgumentError, ~r/ambiguous router.*--router/, fn ->
      Installer.run!(root: root)
    end

    assert tree(root) == before
  end

  test "collisions, annotation conflicts, and unsupported layouts refuse every write", %{
    root: root
  } do
    router = Path.join(root, "lib/demo_web/router.ex")
    File.write!(router, File.read!(router) <> "\n# :demo_pi_browser_taskbar\n")
    before = tree(root)

    assert_raise ArgumentError, ~r/route helper collision/, fn -> Installer.run!(root: root) end
    assert tree(root) == before

    File.write!(
      router,
      String.replace(File.read!(router), "\n# :demo_pi_browser_taskbar\n", "\n")
    )

    config = Path.join(root, "config/dev.exs")

    File.write!(
      config,
      "import Config\nconfig :phoenix_live_view, debug_heex_annotations: false\n"
    )

    before = tree(root)

    assert_raise ArgumentError, ~r/debug_heex_annotations.*false/, fn ->
      Installer.run!(root: root)
    end

    assert tree(root) == before

    File.write!(config, "import Config\n")

    assert_raise ArgumentError, ~r/HEEx/, fn ->
      Installer.run!(root: root, layout: "lib/demo_web/components/layouts/root.html.leex")
    end
  end

  test "updates an intact generated integration while preserving host seams", %{root: root} do
    Installer.run!(root: root)
    path = Path.join(root, "lib/demo_web/pi_browser_taskbar.ex")
    source = File.read!(path)

    [_full, header, json, _checksum, body] =
      Regex.run(
        ~r/\A(# Generated by pi-browser-taskbar-phoenix\. Do not edit\.\n# pi-browser-taskbar:metadata ([^\n]+)\n)# pi-browser-taskbar:checksum ([0-9a-f]{64})\n(.*)\z/s,
        source
      )

    older_body =
      String.replace(
        body,
        "Development-only host integration",
        "Older generated host integration"
      )

    digest = :crypto.hash(:sha256, json <> "\n" <> older_body) |> Base.encode16(case: :lower)
    File.write!(path, header <> "# pi-browser-taskbar:checksum #{digest}\n" <> older_body)

    assert :ok = Installer.run!(root: root)
    assert File.read!(path) == source
  end

  test "edited generated sections refuse update without partial writes", %{root: root} do
    Installer.run!(root: root)
    application = Path.join(root, "lib/demo/application.ex")

    File.write!(
      application,
      String.replace(File.read!(application), "DemoWeb.PiBrowserTaskbar,", "Other.Child,")
    )

    before = tree(root)

    assert_raise ArgumentError, ~r/edited generated supervisor section/, fn ->
      Installer.run!(root: root)
    end

    assert tree(root) == before
  end

  test "uninstall preflights all seams, removes only owned content, and repeats harmlessly", %{
    root: root
  } do
    application = Path.join(root, "lib/demo/application.ex")

    File.write!(
      application,
      String.replace(File.read!(application), "use Application", "use Application\n  # keep me")
    )

    Installer.run!(root: root)
    assert :ok = Installer.uninstall!(root: root)
    after_first = tree(root)
    refute File.exists?(Path.join(root, "lib/demo_web/pi_browser_taskbar.ex"))
    assert File.read!(application) =~ "# keep me"
    refute File.read!(application) =~ "pi-browser-taskbar"
    refute File.read!(Path.join(root, "config/dev.exs")) =~ "debug_heex_annotations"

    assert :ok = Installer.uninstall!(root: root)
    assert tree(root) == after_first
  end

  test "uninstall preserves a pre-existing annotation setting", %{root: root} do
    config = Path.join(root, "config/dev.exs")
    original = "import Config\nconfig :phoenix_live_view, debug_heex_annotations: true\n"
    File.write!(config, original)

    Installer.run!(root: root)
    refute File.read!(config) =~ "pi-browser-taskbar:start annotations"
    Installer.uninstall!(root: root)
    assert File.read!(config) == original
  end

  test "uninstall refuses an edited owned seam and reports it without removing anything", %{
    root: root
  } do
    Installer.run!(root: root)
    layout = Path.join(root, "lib/demo_web/components/layouts/root.html.heex")

    File.write!(
      layout,
      String.replace(File.read!(layout), "layout_bootstrap()", "layout_bootstrap(:edited)")
    )

    before = tree(root)

    assert_raise ArgumentError, ~r/edited generated layout section.*manual/, fn ->
      Installer.uninstall!(root: root)
    end

    assert tree(root) == before
  end

  defp fixture_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "pi_browser_taskbar_installer_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "lib/demo_web/components/layouts"))
    File.mkdir_p!(Path.join(root, "lib/demo"))
    File.mkdir_p!(Path.join(root, "config"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule Demo.MixProject do
      use Mix.Project
      def project, do: [app: :demo, version: "0.1.0"]
    end
    """)

    File.write!(Path.join(root, "config/dev.exs"), "import Config\n")

    File.write!(Path.join(root, "lib/demo/application.ex"), """
    defmodule Demo.Application do
      use Application

      def start(_type, _args) do
        children = [
          DemoWeb.Endpoint
        ]

        Supervisor.start_link(children, strategy: :one_for_one, name: Demo.Supervisor)
      end
    end
    """)

    File.write!(Path.join(root, "lib/demo_web/endpoint.ex"), """
    defmodule DemoWeb.Endpoint do
    end
    """)

    File.write!(Path.join(root, "lib/demo_web/router.ex"), """
    defmodule DemoWeb.Router do
      use DemoWeb, :router

      pipeline :browser do
        plug :fetch_session
        plug :protect_from_forgery
      end

      scope "/", DemoWeb do
        pipe_through :browser
        get "/", PageController, :home
      end
    end
    """)

    File.write!(Path.join(root, "lib/demo_web/components/layouts/root.html.heex"), """
    <!doctype html>
    <html>
      <body>
        {@inner_content}
      </body>
    </html>
    """)

    root
  end

  defp unload_integration do
    :code.purge(DemoWeb.PiBrowserTaskbar)
    :code.delete(DemoWeb.PiBrowserTaskbar)
  end

  defp installed_files(root) do
    %{
      integration: File.read!(Path.join(root, "lib/demo_web/pi_browser_taskbar.ex")),
      application: File.read!(Path.join(root, "lib/demo/application.ex")),
      router: File.read!(Path.join(root, "lib/demo_web/router.ex")),
      layout: File.read!(Path.join(root, "lib/demo_web/components/layouts/root.html.heex")),
      config: File.read!(Path.join(root, "config/dev.exs"))
    }
  end

  defp tree(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reject(&File.dir?/1)
    |> Map.new(&{Path.relative_to(&1, root), File.read!(&1)})
  end
end
