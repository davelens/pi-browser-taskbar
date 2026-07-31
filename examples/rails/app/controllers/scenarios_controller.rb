class ScenariosController < ApplicationController
  def index
    @cards = [{ title: "First card", detail: "Nested ERB partial focus target" }]
  end

  def navigation; end
end
