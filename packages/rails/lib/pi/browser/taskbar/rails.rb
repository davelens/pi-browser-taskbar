# frozen_string_literal: true

require "erb"
require "rails"
require_relative "rails/version"
require_relative "rails/task"
require_relative "rails/broker"

module Pi
  module Browser
    module Taskbar
      module Rails
        class Configuration
          attr_accessor :allowed_hosts, :executable, :project_root, :task_timeout

          def initialize
            @allowed_hosts = []
            @executable = ENV.fetch("PI_BROWSER_TASKBAR_EXECUTABLE", "pi")
            @project_root = nil
            @task_timeout = Integer(ENV.fetch("PI_BROWSER_TASKBAR_TASK_TIMEOUT", "1800"))
          end
        end

        @client_mutex = Mutex.new
        @client_mutex_pid = Process.pid

        class << self
          def browser_asset_path
            File.join(__dir__, "rails", "assets", "pi_browser_taskbar.js")
          end

          def configure
            yield configuration
          end

          def configuration
            @configuration ||= Configuration.new
          end

          def allowed_hosts
            configuration.allowed_hosts.map { |host| host.to_s.downcase.sub(/\.\z/, "") }
          end

          def broker_client
            if @client_mutex_pid != Process.pid
              @client_mutex = Mutex.new
              @client_mutex_pid = Process.pid
            end
            @client_mutex.synchronize do
              root = configuration.project_root || ::Rails.root.to_s
              @broker_client ||= Broker::Client.new(
                project_root: root,
                executable: configuration.executable,
                task_timeout: configuration.task_timeout
              )
              unless @client_exit_pid == Process.pid
                @client_exit_pid = Process.pid
                at_exit { @broker_client.close if @broker_client.respond_to?(:close) }
              end
              @broker_client
            end
          end

          def layout_bootstrap(view, mount: "/dev/pi-browser-taskbar")
            return "" unless ::Rails.env.development?
            escape = ERB::Util.method(:html_escape)
            token = view.form_authenticity_token
            html = [
              %(<link rel="stylesheet" href="#{escape.call(mount)}/assets/pi_browser_taskbar.css">),
              %(<div data-pi-browser-taskbar-bootstrap data-mount-base="#{escape.call(mount)}" data-contract-version="1" data-csrf-token="#{escape.call(token)}"></div>),
              %(<script defer src="#{escape.call(mount)}/assets/pi_browser_taskbar.js"></script>)
            ].join
            html.respond_to?(:html_safe) ? html.html_safe : html
          end
        end
      end
    end
  end
end

require_relative "rails/engine"
