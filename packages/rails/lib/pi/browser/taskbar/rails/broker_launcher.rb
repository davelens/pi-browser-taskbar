# frozen_string_literal: true

require_relative "broker"

if $PROGRAM_NAME == __FILE__
  project_root = ENV.delete("PI_BROWSER_TASKBAR_BROKER_PROJECT_ROOT")
  executable = ENV.delete("PI_BROWSER_TASKBAR_BROKER_EXECUTABLE")
  task_timeout = ENV.delete("PI_BROWSER_TASKBAR_BROKER_TASK_TIMEOUT")
  runtime_root = ENV.delete("PI_BROWSER_TASKBAR_BROKER_RUNTIME_ROOT")

  identity = Pi::Browser::Taskbar::Rails::Broker::Identity.new(project_root, runtime_root: runtime_root)
  server = Pi::Browser::Taskbar::Rails::Broker::Server.new(
    identity: identity,
    executable: executable,
    task_timeout: Integer(task_timeout)
  )
  %w[INT TERM].each { |signal| Signal.trap(signal) { server.stop } }
  exit(server.run ? 0 : 1)
end
