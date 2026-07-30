# frozen_string_literal: true

Pi::Browser::Taskbar::Rails::Engine.routes.draw do
  get "state", to: "api#state"
  post "tasks", to: "api#tasks"
  get "assets/:filename", to: "assets#show", constraints: {filename: /pi_browser_taskbar\.(?:js|css)/}
end
