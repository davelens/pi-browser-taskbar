defmodule TaskbarExampleWeb.ScenarioLive do
  use TaskbarExampleWeb, :live_view

  def mount(_params, _session, socket), do: {:ok, assign(socket, count: 0)}

  def handle_params(params, _uri, socket) do
    {count, _rest} = Integer.parse(Map.get(params, "count", "0"))
    {:noreply, assign(socket, count: count)}
  end

  def render(assigns) do
    ~H"""
    <main data-testid="scenario-navigation">
      <h1>LiveView navigation and patch</h1>
      <p data-testid="navigation-target">Patch count: {@count}</p>
      <.scenario_card title="Live card" />
      <.link patch={"/live?count=#{@count + 1}"}>Patch this LiveView</.link>
      <.link href="/">Controller page</.link>
    </main>
    """
  end
end
