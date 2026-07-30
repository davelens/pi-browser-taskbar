defmodule PiBrowserTaskbarPhoenix.Supervisor do
  @moduledoc "Supervises the single host-scoped Pi runtime outside Phoenix code reload boundaries."

  use Supervisor

  alias PiBrowserTaskbarPhoenix.{Config, Names, Runtime}

  @doc "Starts the package supervisor for one host OTP application."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    Supervisor.start_link(__MODULE__, otp_app, name: Names.supervisor(otp_app))
  end

  @impl true
  def init(otp_app) do
    config = Config.load!(otp_app)

    children =
      if config.enabled do
        [
          {Runtime,
           name: Names.runtime(otp_app),
           executable: config.executable,
           project_root: config.project_root,
           task_timeout: config.task_timeout,
           allowed_hosts: config.allowed_hosts}
        ]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 5)
  end
end
