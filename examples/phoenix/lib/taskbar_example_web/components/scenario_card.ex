defmodule TaskbarExampleWeb.ScenarioCard do
  use Phoenix.Component

  attr :title, :string, required: true

  def scenario_card(assigns) do
    ~H"""
    <article data-testid="focus-card">
      <h3>{@title}</h3>
      <p>Nested HEEx function component focus target.</p>
      <button type="button">Mark this nested component</button>
    </article>
    """
  end
end
