# frozen_string_literal: true

Pi::Browser::Taskbar::Rails::Engine.routes.draw do
  if Rails.env.development?
    get "state", to: "api#state"
    post "tasks", to: "api#tasks"
    delete "tasks/:id", to: "api#cancel_task"
    get "assets/:filename", to: "assets#show", constraints: {filename: /pi_browser_taskbar\.(?:js|css)/}
  end
end
