defmodule PiBrowserTaskbarPhoenix.ConfigTest do
  use ExUnit.Case, async: false

  alias PiBrowserTaskbarPhoenix.Config

  @otp_app :pi_browser_taskbar_config_test

  setup do
    previous = Application.get_env(@otp_app, :pi_browser_taskbar)

    on_exit(fn ->
      if previous do
        Application.put_env(@otp_app, :pi_browser_taskbar, previous)
      else
        Application.delete_env(@otp_app, :pi_browser_taskbar)
      end
    end)
  end

  test "loads safe startup-fixed defaults and explicit host configuration" do
    Application.put_env(@otp_app, :pi_browser_taskbar,
      executable: "pi",
      project_root: File.cwd!(),
      allowed_hosts: ["DEVBOX.localhost", "192.0.2.5"],
      task_timeout: 90
    )

    config = Config.load!(@otp_app)

    assert config.enabled
    assert config.project_root == File.cwd!()
    assert config.allowed_hosts == ["devbox.localhost", "192.0.2.5"]
    assert config.task_timeout == 90_000
  end

  test "rejects unsafe allowed hosts precisely" do
    Application.put_env(@otp_app, :pi_browser_taskbar,
      project_root: File.cwd!(),
      allowed_hosts: ["*.example.test"]
    )

    assert_raise ArgumentError, ~r/allowed_hosts/, fn -> Config.load!(@otp_app) end
  end

  test "disabled configuration does not validate inactive settings" do
    Application.put_env(@otp_app, :pi_browser_taskbar,
      enabled: false,
      project_root: "/missing",
      allowed_hosts: ["*"]
    )

    assert %{enabled: false} = Config.load!(@otp_app)
  end
end
