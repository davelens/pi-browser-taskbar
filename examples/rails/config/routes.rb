Rails.application.routes.draw do
  root "scenarios#index"
  get "navigation", to: "scenarios#navigation"
end
