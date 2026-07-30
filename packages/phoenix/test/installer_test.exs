defmodule PiBrowserTaskbarPhoenix.InstallerTest do
  use ExUnit.Case, async: false

  alias PiBrowserTaskbarPhoenix.Installer

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "pi_browser_taskbar_installer_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "lib/demo_web/components/layouts"))
    File.mkdir_p!(Path.join(root, "lib/demo"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule Demo.MixProject do
      use Mix.Project
      def project, do: [app: :demo, version: "0.1.0"]
    end
    """)

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

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "installs one idempotent development integration into a conventional Phoenix app", %{
    root: root
  } do
    assert :ok = Installer.run!(root: root)
    first = installed_files(root)
    assert :ok = Installer.run!(root: root)
    assert installed_files(root) == first

    integration = first.integration
    assert integration =~ "if Mix.env() == :dev"
    assert integration =~ "PiBrowserTaskbarPhoenix.Supervisor"
    assert integration =~ "def child_spec"
    assert integration =~ "defmacro routes"
    assert integration =~ ~s(@mount "/dev/pi-browser-taskbar")

    assert first.application =~ "DemoWeb.PiBrowserTaskbar,\n      DemoWeb.Endpoint"
    assert first.router =~ "DemoWeb.PiBrowserTaskbar.routes()"
    assert first.layout =~ "DemoWeb.PiBrowserTaskbar.layout_bootstrap()"

    integration_path = Path.join(root, "lib/demo_web/pi_browser_taskbar.ex")
    previous_env = Mix.env()

    try do
      Mix.env(:prod)
      assert [{DemoWeb.PiBrowserTaskbar, _bytecode}] = Code.compile_file(integration_path)

      assert %{start: {DemoWeb.PiBrowserTaskbar, :ignore, []}} =
               apply(DemoWeb.PiBrowserTaskbar, :child_spec, [[]])

      assert apply(DemoWeb.PiBrowserTaskbar, :layout_bootstrap, []) == {:safe, ""}

      assert {:ok, supervisor} =
               Supervisor.start_link([DemoWeb.PiBrowserTaskbar], strategy: :one_for_one)

      assert [{DemoWeb.PiBrowserTaskbar, :undefined, :worker, [DemoWeb.PiBrowserTaskbar]}] =
               Supervisor.which_children(supervisor)

      Supervisor.stop(supervisor)
      unload_integration()

      Mix.env(:dev)

      Application.put_env(:demo, :pi_browser_taskbar,
        executable: Path.expand("support/fake_pi_rpc", __DIR__),
        project_root: root,
        task_timeout: 60
      )

      assert [{DemoWeb.PiBrowserTaskbar, _bytecode}] = Code.compile_file(integration_path)

      assert {:ok, host_supervisor} =
               Supervisor.start_link([DemoWeb.PiBrowserTaskbar], strategy: :one_for_one)

      assert [{DemoWeb.PiBrowserTaskbar, taskbar_supervisor, :supervisor, _modules}] =
               Supervisor.which_children(host_supervisor)

      assert Process.alive?(taskbar_supervisor)
      Supervisor.stop(host_supervisor)
    after
      Application.delete_env(:demo, :pi_browser_taskbar)
      unload_integration()
      Mix.env(previous_env)
    end
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
      layout: File.read!(Path.join(root, "lib/demo_web/components/layouts/root.html.heex"))
    }
  end
end
