defmodule TaskbarExample.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: TaskbarExample.PubSub},
      TaskbarExampleWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: TaskbarExample.Supervisor)
  end
end
