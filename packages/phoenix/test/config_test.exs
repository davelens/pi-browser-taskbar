defmodule PiBrowserTaskbarPhoenix.ConfigTest do
  use ExUnit.Case, async: false

  alias PiBrowserTaskbarPhoenix.Config

  @otp_app :pi_browser_taskbar_config_test

  @environment ~w[
    PI_BROWSER_TASKBAR_ENABLED
    PI_BROWSER_TASKBAR_ALLOWED_HOSTS
    PI_BROWSER_TASKBAR_EXECUTABLE
    PI_BROWSER_TASKBAR_PROJECT_ROOT
    PI_BROWSER_TASKBAR_TASK_TIMEOUT
  ]

  setup do
    previous = Application.get_env(@otp_app, :pi_browser_taskbar)
    environment = Map.new(@environment, &{&1, System.get_env(&1)})
    Enum.each(@environment, &System.delete_env/1)

    on_exit(fn ->
      if previous do
        Application.put_env(@otp_app, :pi_browser_taskbar, previous)
      else
        Application.delete_env(@otp_app, :pi_browser_taskbar)
      end

      Enum.each(environment, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)
  end

  test "loads safe startup-fixed defaults and explicit host configuration" do
    root = Path.join(System.tmp_dir!(), "taskbar-config-#{System.unique_integer([:positive])}")
    link = root <> "-link"
    File.mkdir_p!(root)
    File.ln_s!(root, link)

    on_exit(fn ->
      File.rm(link)
      File.rm_rf!(root)
    end)

    Application.put_env(@otp_app, :pi_browser_taskbar,
      executable: "pi",
      project_root: link,
      allowed_hosts: ["DEVBOX.localhost", "192.0.2.5"],
      task_timeout: 90
    )

    config = Config.load!(@otp_app)

    assert config.enabled
    assert config.project_root == root
    assert config.allowed_hosts == ["devbox.localhost", "192.0.2.5"]
    assert config.task_timeout == 90_000
  end

  test "framework configuration wins over shared environment fallbacks" do
    System.put_env("PI_BROWSER_TASKBAR_ENABLED", "false")
    System.put_env("PI_BROWSER_TASKBAR_ALLOWED_HOSTS", "ignored.example")
    System.put_env("PI_BROWSER_TASKBAR_EXECUTABLE", "ignored-pi")
    System.put_env("PI_BROWSER_TASKBAR_PROJECT_ROOT", "/missing")
    System.put_env("PI_BROWSER_TASKBAR_TASK_TIMEOUT", "90")

    Application.put_env(@otp_app, :pi_browser_taskbar,
      enabled: true,
      allowed_hosts: ["DEVBOX.localhost.", "2001:0DB8:0:0:0:0:0:1"],
      executable: "explicit-pi",
      project_root: File.cwd!(),
      task_timeout: 120
    )

    assert %{
             enabled: true,
             allowed_hosts: ["devbox.localhost", "2001:db8::1"],
             executable: "explicit-pi",
             task_timeout: 120_000
           } = Config.load!(@otp_app)
  end

  test "loads shared environment fallbacks when framework settings are absent" do
    System.put_env("PI_BROWSER_TASKBAR_ENABLED", "1")
    System.put_env("PI_BROWSER_TASKBAR_ALLOWED_HOSTS", "DEVBOX.localhost., 192.0.2.5")
    System.put_env("PI_BROWSER_TASKBAR_EXECUTABLE", "pi-from-env")
    System.put_env("PI_BROWSER_TASKBAR_PROJECT_ROOT", File.cwd!())
    System.put_env("PI_BROWSER_TASKBAR_TASK_TIMEOUT", "90")

    config = Config.load!(@otp_app)

    assert config.enabled
    assert config.allowed_hosts == ["devbox.localhost", "192.0.2.5"]
    assert config.executable == "pi-from-env"
    assert config.task_timeout == 90_000
  end

  test "rejects invalid allowed host entries" do
    for host <- [
          "",
          " ",
          "https://devbox.test",
          "devbox.test:3000",
          "devbox.test/path",
          "*.example.test",
          ".example.test",
          "192.0.2.0/24",
          "[2001:db8::1]",
          "fe80::1%lo"
        ] do
      Application.put_env(@otp_app, :pi_browser_taskbar, allowed_hosts: [host])
      assert_raise ArgumentError, ~r/allowed_hosts/, fn -> Config.load!(@otp_app) end
    end
  end

  test "rejects empty environment host entries" do
    for hosts <- [",", "devbox.test,", ",devbox.test", "devbox.test,,other.test"] do
      System.put_env("PI_BROWSER_TASKBAR_ALLOWED_HOSTS", hosts)
      assert_raise ArgumentError, ~r/allowed_hosts/, fn -> Config.load!(@otp_app) end
    end
  end

  test "rejects malformed active settings precisely" do
    for {setting, value} <- [
          enabled: "maybe",
          allowed_hosts: ["*.example.test"],
          executable: "",
          project_root: "/missing",
          task_timeout: 59
        ] do
      Application.put_env(@otp_app, :pi_browser_taskbar, [{setting, value}])

      assert_raise ArgumentError, ~r/#{setting}/, fn -> Config.load!(@otp_app) end
    end
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
