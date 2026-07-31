defmodule TaskbarExampleWeb.PageController do
  use TaskbarExampleWeb, :controller

  def index(conn, _params), do: render(conn, :index)
end
