defmodule TaskbarExampleWeb.Router do
  use TaskbarExampleWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TaskbarExampleWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", TaskbarExampleWeb do
    pipe_through :browser

    get "/", PageController, :index
    live "/live", ScenarioLive, :index
  end
end
