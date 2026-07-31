defmodule TaskbarExampleWeb do
  def controller do
    quote do
      use Phoenix.Controller, formats: [:html], layouts: [html: TaskbarExampleWeb.Layouts]
      import Plug.Conn
    end
  end

  def html do
    quote do
      use Phoenix.Component
      import Phoenix.HTML
      import TaskbarExampleWeb.ScenarioCard
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView, layout: {TaskbarExampleWeb.Layouts, :app}
      import TaskbarExampleWeb.ScenarioCard
    end
  end

  def router do
    quote do
      use Phoenix.Router
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  defmacro __using__(which), do: apply(__MODULE__, which, [])
end
