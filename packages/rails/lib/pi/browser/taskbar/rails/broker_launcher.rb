# frozen_string_literal: true

require_relative "broker"

if $PROGRAM_NAME == __FILE__
  identity = Pi::Browser::Taskbar::Rails::Broker::Identity.new(
    ENV.fetch("PI_BROWSER_TASKBAR_PROJECT_ROOT"),
    runtime_root: ENV["PI_BROWSER_TASKBAR_RUNTIME_ROOT"]
  )
  server = Pi::Browser::Taskbar::Rails::Broker::Server.new(
    identity: identity,
    executable: ENV.fetch("PI_BROWSER_TASKBAR_EXECUTABLE", "pi"),
    task_timeout: Integer(ENV.fetch("PI_BROWSER_TASKBAR_TASK_TIMEOUT", "1800"))
  )
  %w[INT TERM].each { |signal| Signal.trap(signal) { server.stop } }
  exit(server.run ? 0 : 1)
end
