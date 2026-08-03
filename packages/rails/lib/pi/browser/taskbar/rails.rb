# frozen_string_literal: true

require "erb"
require "ipaddr"
require "rails"
require_relative "rails/version"
require_relative "rails/task"
require_relative "rails/broker"

module Pi
  module Browser
    module Taskbar
      module Rails
        module LayoutHelper
          def pi_browser_taskbar_tags
            return "" unless Pi::Browser::Taskbar::Rails.active?

            Pi::Browser::Taskbar::Rails.layout_bootstrap(self)
          end
        end

        class Configuration
          attr_accessor :enabled, :allowed_hosts, :executable, :project_root, :task_timeout, :mount_path

          ENVIRONMENT = {
            enabled: "PI_BROWSER_TASKBAR_ENABLED",
            allowed_hosts: "PI_BROWSER_TASKBAR_ALLOWED_HOSTS",
            executable: "PI_BROWSER_TASKBAR_EXECUTABLE",
            project_root: "PI_BROWSER_TASKBAR_PROJECT_ROOT",
            task_timeout: "PI_BROWSER_TASKBAR_TASK_TIMEOUT"
          }.freeze

          DEFAULTS = {
            enabled: true,
            allowed_hosts: [],
            executable: "pi",
            mount_path: "/dev/pi-browser-taskbar",
            task_timeout: 1_800
          }.freeze

          def finalize!(default_project_root:)
            @enabled = parse_boolean(setting(:enabled, DEFAULTS[:enabled]), :enabled)
            return freeze unless @enabled

            @allowed_hosts = parse_allowed_hosts(setting(:allowed_hosts, DEFAULTS[:allowed_hosts]))
            @executable = non_empty_string(setting(:executable, DEFAULTS[:executable]), :executable)
            @mount_path = parse_mount_path(setting(:mount_path, DEFAULTS[:mount_path]))
            @project_root = canonical_root(setting(:project_root, default_project_root))
            @task_timeout = parse_timeout(setting(:task_timeout, DEFAULTS[:task_timeout]))
            freeze
          end

          private

          def setting(name, default)
            return instance_variable_get("@#{name}") if instance_variable_defined?("@#{name}")
            environment = ENVIRONMENT[name]
            environment ? ENV.fetch(environment, default) : default
          end

          def parse_boolean(value, _name)
            return value if value == true || value == false
            return true if ["true", "1"].include?(value)
            return false if ["false", "0"].include?(value)
            raise ArgumentError, "pi_browser_taskbar enabled must be true or false"
          end

          def parse_allowed_hosts(value)
            hosts = value.is_a?(String) ? (value.empty? ? [] : value.split(",", -1)) : value
            unless hosts.is_a?(Array)
              raise ArgumentError, "pi_browser_taskbar allowed_hosts must be a list or comma-separated string"
            end

            hosts.map do |host|
              normalized = non_empty_string(host, :allowed_hosts).strip.downcase.sub(/\.+\z/, "")
              unless valid_host?(normalized)
                raise ArgumentError, "pi_browser_taskbar allowed_hosts entries must be bare exact DNS names or IP addresses"
              end
              normalize_ip(normalized)
            end
          end

          def valid_host?(host)
            return false if host.match?(/[%\/\[\]]/)
            IPAddr.new(host)
            true
          rescue IPAddr::InvalidAddressError
            host.bytesize <= 253 && host.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\z/)
          end

          def normalize_ip(host)
            IPAddr.new(host).to_s
          rescue IPAddr::InvalidAddressError
            host
          end

          def parse_mount_path(value)
            mount = non_empty_string(value, :mount_path).sub(%r{/+\z}, "")
            segments = mount.split("/")
            valid = mount.match?(%r{\A/[A-Za-z0-9._~-]+(?:/[A-Za-z0-9._~-]+)*\z}) && segments.none? { |segment| segment == "." || segment == ".." }
            return mount if valid
            raise ArgumentError, "pi_browser_taskbar mount_path must be an absolute application path without traversal"
          end

          def canonical_root(value)
            root = non_empty_string(value, :project_root)
            canonical = File.realpath(root)
            return canonical if File.directory?(canonical)
            raise ArgumentError, "pi_browser_taskbar project_root must be an existing directory"
          rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR
            raise ArgumentError, "pi_browser_taskbar project_root must be an existing directory"
          end

          def parse_timeout(value)
            seconds = if value.is_a?(Integer)
              value
            elsif value.is_a?(String) && value.match?(/\A[+-]?\d+\z/)
              value.to_i
            else
              raise ArgumentError, "pi_browser_taskbar task_timeout must be an integer number of seconds"
            end
            return seconds if seconds.between?(60, 86_400)
            raise ArgumentError, "pi_browser_taskbar task_timeout must be between 60 and 86400 seconds"
          end

          def non_empty_string(value, setting)
            return value if value.is_a?(String) && !value.empty?
            raise ArgumentError, "pi_browser_taskbar #{setting} must be a non-empty string"
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

          def finalize_configuration!(default_project_root:)
            configuration.finalize!(default_project_root: default_project_root) unless configuration.frozen?
          end

          def active?
            ::Rails.env.development? && configuration.frozen? && configuration.enabled
          end

          def allowed_hosts
            configuration.allowed_hosts
          end

          def broker_client
            raise "Pi Browser Taskbar is inactive" unless active?
            if @client_mutex_pid != Process.pid
              @client_mutex = Mutex.new
              @client_mutex_pid = Process.pid
            end
            @client_mutex.synchronize do
              @broker_client ||= Broker::Client.new(
                project_root: configuration.project_root,
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

          def layout_bootstrap(view, mount: nil)
            return "" unless active?
            mount ||= configuration.mount_path
            escape = ERB::Util.method(:html_escape)
            token = view.form_authenticity_token
            html = [
              %(<link rel="stylesheet" href="#{escape.call(mount)}/assets/pi_browser_taskbar.css">),
              %(<div data-pi-browser-taskbar-bootstrap data-mount-base="#{escape.call(mount)}" data-contract-version="1" data-csrf-token="#{escape.call(token)}" data-remote-access="#{!allowed_hosts.empty?}"></div>),
              %(<script type="module" src="#{escape.call(mount)}/assets/pi_browser_taskbar.js"></script>)
            ].join
            html.respond_to?(:html_safe) ? html.html_safe : html
          end
        end
      end
    end
  end
end

require_relative "rails/engine"
