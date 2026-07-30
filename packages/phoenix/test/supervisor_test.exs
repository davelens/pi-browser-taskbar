defmodule PiBrowserTaskbarPhoenix.SupervisorTest do
  use ExUnit.Case, async: false

  alias PiBrowserTaskbarPhoenix.{Names, Runtime}
  alias PiBrowserTaskbarPhoenix.Supervisor, as: TaskbarSupervisor

  @otp_app :pi_browser_taskbar_supervisor_test

  setup do
    Application.put_env(@otp_app, :pi_browser_taskbar,
      executable: Path.expand("support/fake_pi_rpc", __DIR__),
      project_root: File.cwd!(),
      task_timeout: 60
    )

    on_exit(fn -> Application.delete_env(@otp_app, :pi_browser_taskbar) end)
  end

  test "owns exactly one persistent runtime for the host project" do
    supervisor = start_supervised!({TaskbarSupervisor, otp_app: @otp_app})
    children = Supervisor.which_children(supervisor)

    assert [{_, runtime, :worker, [Runtime]}] = children
    assert runtime == Process.whereis(Names.runtime(@otp_app))

    assert {:error, {:already_started, ^supervisor}} =
             TaskbarSupervisor.start_link(otp_app: @otp_app)
  end
end
